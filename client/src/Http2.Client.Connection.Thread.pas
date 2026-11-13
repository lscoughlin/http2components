{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, connection
notes:
  - This unit owns the client connection reader and writer thread.
---
}
unit Http2.Client.Connection.Thread;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Connection.Control;

type
  /// one background thread per connection; it is the sole writer to the
  /// socket. It holds ONLY a weak (raw Pointer) reference to TConnection so
  /// the TConnection <-> thread pair cannot form an ARC cycle.
  TConnectionWorker = class
  private
    FThread: TConnectionThread;
    FConn: TConnection;                // weak class pointer; Close joins worker
    FOutbound: IBlockingQueue<TFrame>;
    FControl: TControlFrameQueue;      // control frames, drained first
    FRates: TPeerRateLimits;           // limits on the peer's PING, SETTINGS, RST_STREAM
    FSocket: IHttp2Socket;
    FSockStream: TStream;              // IHttp2Socket -> TStream adapter
    FLocalSettings: TConnectionSettings;
    FReadPollMs: Integer;
    FPeerMaxFrameSize: LongWord;
    FPendingPing: Boolean;
    FPendingPingPayload: TBytes;
    FPingSentAt: QWord;
  public
    constructor Create(AThread: TConnectionThread; AConn: TConnection);
    destructor Destroy; override;
    procedure Run;
    procedure DoPreface;
    procedure ApplyPeerSettings(const ASettings: TConnectionSettings);
    procedure RouteInbound(const AFrame: TFrame);
    procedure RejectUnknownStream(const AFrame: TFrame);
    procedure DrainOutbound;
    /// write one frame and emit the observer's frame-out event for it
    procedure WriteTracked(const AFrame: TFrame);
    procedure CheckPingKeepAlive;
    procedure HandlePingAck(const APayload: TBytes);
    procedure Fail(const AMessage: string; const ACode: THttp2ErrorCode;
      const AClientAuthAlert: string = '');
  end;


implementation

uses
  Http2.Client.Clock, Http2.Client.Observer, Http2.Common.Hpack,
  Http2.Common.FlowControl;

{ TSocketStream: adapts an IHttp2Socket to the TStream ReadFrame/WriteFrame
  API. A read timeout with no bytes yet is re-raised so the thread can poll
  outbound work; once a frame has started arriving the read blocks through to
  completion so no partial frame is ever abandoned. }

type
  TSocketStream = class(TStream)
  private
    FSocket: IHttp2Socket;
  public
    constructor Create(const ASocket: IHttp2Socket);
    function Read(var ABuffer; ACount: LongInt): LongInt; override;
    function Write(const ABuffer; ACount: LongInt): LongInt; override;
    function Seek(const AOffset: Int64; AOrigin: TSeekOrigin): Int64;
      override;
  end;

destructor TConnectionWorker.Destroy;
begin
  FSockStream.Free;
  inherited Destroy;
end;

constructor TSocketStream.Create(const ASocket: IHttp2Socket);
begin
  inherited Create;
  FSocket := ASocket;
end;

function TSocketStream.Read(var ABuffer; ACount: LongInt): LongInt;
var
  Got, N: LongInt;
  P: PByte;
begin
  if ACount <= 0 then
    Exit(0);
  Result := 0;
  P := @ABuffer;
  Got := 0;
  while Got < ACount do
  begin
    try
      N := FSocket.Read(P[Got], ACount - Got);
    except
      on E: EHttpTimeout do
        if Got = 0 then
          raise                 // idle poll: no bytes yet, surface the timeout
        else
          Break;                // partial frame; caller re-invokes Read
    end;
    if N <= 0 then
    begin
      if Got = 0 then
        Exit(0);              // end of stream, nothing buffered
      Break;                  // partial read; caller re-invokes Read
    end;
    Inc(Got, N);
  end;
  Result := Got;
end;

function TSocketStream.Write(const ABuffer; ACount: LongInt): LongInt;
begin
  Result := FSocket.Write(ABuffer, ACount);
end;

function TSocketStream.Seek(const AOffset: Int64;
  AOrigin: TSeekOrigin): Int64;
begin
  Result := 0;
  raise EStreamError.Create('TSocketStream is not seekable');
end;

constructor TConnectionWorker.Create(AThread: TConnectionThread;
  AConn: TConnection);
begin
  inherited Create;
  FThread := AThread;
  FConn := AConn;                   // weak class pointer; Close joins the worker
  FSocket := AConn.Socket;
  FOutbound := AConn.Outbound;
  FControl := AConn.ControlQueue;
  FRates.Init(GetTickCount64);
  FLocalSettings := AConn.LocalSettings;
  FReadPollMs := AConn.ReadPollMs;
  FPeerMaxFrameSize := DefaultMaxFrameSize;
  FPendingPing := False;
  FSockStream := TSocketStream.Create(FSocket);
end;

/// the TLS alert name when E is a client-certificate rejection, else ''
function ClientAuthAlertOf(const E: Exception): string;
begin
  if E is EHttpTlsClientAuthError then
    Result := EHttpTlsClientAuthError(E).Alert
  else
    Result := '';
end;

procedure TConnectionWorker.Run;
var
  Frame: TFrame;
begin
  try
    if FThread.WorkerTerminated then
      Exit;
    DoPreface;
    FConn.SetState(csOpen);
    FConn.Notifications.EmitConnectionOpen;
    while not FThread.WorkerTerminated do
    begin
      DrainOutbound;
      if FControl.Overflowed then
      begin
        Fail('control frame queue is full', ecEnhanceYourCalm);
        Break;
      end;
      if FThread.WorkerTerminated then
        Break;
      CheckPingKeepAlive;
      if FThread.WorkerTerminated then
        Break;
      try
        Frame := ReadFrame(FSockStream, FLocalSettings.MaxFrameSize);
        // the wire stamp: taken before validation and routing, and carried
        // with the frame through the stream's queue to the consumer
        Frame.ArrivedUs := NowUs;
        // RFC 7540 structural rules the decoder cannot enforce on its own:
        // frame-type/stream-id pairing, mandatory payload sizes, zero
        // WINDOW_UPDATE increments. A violation is a connection error.
        ValidateFrameForRole(Frame, FLocalSettings.MaxFrameSize, erClient);
        // routing can also raise EHttpError (malformed SETTINGS/GOAWAY,
        // PUSH_PROMISE while push is disabled); keep it inside this handler
        // so the frame's own error code is reported rather than being
        // downgraded to ecInternalError by the outer catch-all.
        RouteInbound(Frame);
      except
        on E: EHttpTimeout do
          Continue;                 // idle poll: loop back to outbound work
        on E: EHttpError do
        begin
          Fail(E.Message, E.ErrorCode, ClientAuthAlertOf(E));
          Break;
        end;
      end;
    end;
    DrainOutbound;                  // flush anything pending after Terminate
  except
    on E: Exception do
      Fail(E.ClassName + ': ' + E.Message, ecInternalError,
        ClientAuthAlertOf(E));
  end;
end;

procedure TConnectionWorker.DoPreface;
var
  Preface: TBytes;
begin
  FSocket.ReadTimeoutMs := FReadPollMs;
  Preface := ClientPrefaceBytes;
  FSocket.Write(Preface[0], Length(Preface));
  WriteTracked(BuildSettingsFrame(FLocalSettings));
end;

procedure TConnectionWorker.WriteTracked(const AFrame: TFrame);
begin
  WriteFrame(FSockStream, AFrame);
  FConn.Notifications.EmitFrameOut(AFrame);
end;

procedure TConnectionWorker.ApplyPeerSettings(
  const ASettings: TConnectionSettings);
begin
  FConn.ApplyPeerSettingsValue(ASettings);
  FPeerMaxFrameSize := ASettings.MaxFrameSize;
end;

procedure TConnectionWorker.RouteInbound(const AFrame: TFrame);
var
  LastStreamId: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
  Increment: LongWord;
begin
  FConn.Notifications.EmitFrameIn(AFrame);
  if not FRates.Allow(AFrame, GetTickCount64) then
    raise EHttpConnectionError.Create('peer sent too many ' +
      FrameTypeName(AFrame.Header.FrameType) + ' frames', ecEnhanceYourCalm);
  if (FConn.WorkerHeaderStream <> 0) and
     ((AFrame.Header.FrameType <> ftContinuation) or
      (AFrame.Header.StreamId <> FConn.WorkerHeaderStream)) then
    raise EHttpProtocolError.Create('header block requires adjacent CONTINUATION',
      ecProtocolError);
  case AFrame.Header.FrameType of
    ftSettings:
      if AFrame.IsAck then
        FConn.MarkSettingsAcked
      else
      begin
        ApplyPeerSettings(TConnectionSettings.Decode(AFrame.Payload,
          FConn.PeerSettings));
        FConn.PostFrame(BuildSettingsAck);
      end;
    ftPing:
      if AFrame.IsAck then
        HandlePingAck(AFrame.Payload)
      else
        FConn.PostFrame(BuildPingFrame(AFrame.Payload, True));
    ftGoAway:
      begin
        ParseGoAway(AFrame, LastStreamId, Code, Debug);
        FConn.MarkGoAway(LastStreamId);
      end;
    ftPushPromise:
      // We advertise SETTINGS_ENABLE_PUSH = 0 (see TConnectionSettings.Defaults),
      // so a PUSH_PROMISE is a connection error (RFC 9113 section 6.6). Fail
      // loudly instead of silently discarding the frame — otherwise the
      // request simply hangs until the header timeout.
      raise EHttpProtocolError.Create(
        'peer sent PUSH_PROMISE although push is disabled',
        ecProtocolError);
  else
  begin
    // purely additive observability: report flow-control updates and frames
    // the switch above ignores, then keep the original routing unchanged
    if AFrame.Header.FrameType = ftWindowUpdate then
    begin
      // ValidateFrame already rejected a zero increment and a bad payload
      // length, so ParseWindowUpdate cannot fail here. Apply the credit: this
      // is what lets a sender starved on the peer's window resume
      // (RFC 9113 section 6.9)
      Increment := ParseWindowUpdate(AFrame);
      FConn.ApplyWindowUpdate(AFrame.Header.StreamId, Increment);
      FConn.Notifications.EmitWindowUpdate(AFrame.Header.StreamId, Increment);
    end;
    if not IsKnownFrameType(AFrame.Header.FrameType) then
      FConn.Notifications.EmitDiscarded(AFrame,
        'unknown frame type ' + FrameTypeName(AFrame.Header.FrameType))
    else if AFrame.Header.StreamId = 0 then
      FConn.Notifications.EmitDiscarded(AFrame,
        FrameTypeName(AFrame.Header.FrameType) + ' arrived on stream 0');
    // account for received DATA and return window credit to the peer; this
    // must happen for connection-level DATA (stream 0) as well as the
    // stream-scoped case, else a large response stalls on the peer's window
    if AFrame.Header.FrameType = ftData then
      FConn.TrackReceivedData(AFrame.Header.StreamId,
        AFrame.DataLength);
    // route stream-scoped frames to their owning lease; anything unclaimed
    // (no lease registered yet) stays on the shared inbound queue.
    // A stream WINDOW_UPDATE is deliberately NOT dispatched: it has already
    // been consumed above as a send-credit signal (ApplyWindowUpdate), the
    // lease discards it anyway (HandleInboundFrame), and forwarding it would
    // let replenishments pile up in a lease queue that is not drained until
    // the request body has been fully sent -- blocking this reader (the only
    // thread that can apply further credit) and deadlocking the upload.
    // Stream 0 WINDOW_UPDATE never reaches here, so this restores symmetry.
    if (AFrame.Header.StreamId <> 0) and
       (AFrame.Header.FrameType <> ftWindowUpdate) then
    begin
      if not FConn.DispatchStreamFrame(AFrame) then
        RejectUnknownStream(AFrame);
    end;
  end;
  end;
end;

procedure TConnectionWorker.RejectUnknownStream(const AFrame: TFrame);
var
  Id: LongWord;
begin
  Id := AFrame.Header.StreamId;
  // RFC 9113 section 5.1: a frame for a stream that the client opened and then
  // closed or reset is discarded. DATA still returns its connection credit,
  // which TrackReceivedData already posted
  if ((Id and 1) = 1) and (Id <= FConn.HighestOpenedStreamId) then
  begin
    FConn.Notifications.EmitDiscarded(AFrame, 'frame for a closed stream');
    Exit;
  end;
  // PRIORITY is legal on an idle stream (RFC 9113 section 5.1), and a frame
  // of an unknown type is ignored (section 4.1)
  if (AFrame.Header.FrameType = ftPriority) or
     (not IsKnownFrameType(AFrame.Header.FrameType)) then
  begin
    FConn.Notifications.EmitDiscarded(AFrame, 'frame for an idle stream');
    Exit;
  end;
  // any other frame on an idle stream is a connection error
  raise EHttpProtocolError.Create('frame on idle stream ' + IntToStr(Id),
    ecProtocolError);
end;

procedure TConnectionWorker.DrainOutbound;
var
  Frame: TFrame;
begin
  // control frames first: a window update or an acknowledgement is not held
  // behind a backlog of data frames
  while FControl.TryPop(Frame) do
    WriteTracked(Frame);
  while FOutbound.TryPop(Frame) do
    WriteTracked(Frame);
end;

procedure TConnectionWorker.CheckPingKeepAlive;
var
  Now: QWord;
  Interval, Timeout: Integer;
begin
  Interval := FConn.PingIntervalMs;
  if Interval <= 0 then
    Exit;
  Timeout := FConn.PingTimeoutMs;
  Now := GetTickCount64;
  if FPendingPing then
  begin
    if (Timeout > 0) and (Now - FPingSentAt >= QWord(Timeout)) then
    begin
      Fail('PING acknowledgement timed out', ecNoError);
      FThread.Terminate;
    end;
    Exit;
  end;
  if Now - FConn.LastActivity >= QWord(Interval) then
  begin
    SetLength(FPendingPingPayload, 8);
    FPendingPingPayload[0] := 8;
    FPendingPing := True;
    FPingSentAt := Now;
    WriteTracked(BuildPingFrame(FPendingPingPayload, False));
    FConn.TouchActivity;
  end;
end;

procedure TConnectionWorker.HandlePingAck(const APayload: TBytes);
begin
  if FPendingPing and (Length(APayload) = 8) and
     (CompareMem(@APayload[0], @FPendingPingPayload[0], 8)) then
  begin
    FPendingPing := False;
    FConn.TouchActivity;
  end;
end;

procedure TConnectionWorker.Fail(const AMessage: string;
  const ACode: THttp2ErrorCode; const AClientAuthAlert: string);
begin
  if FConn <> nil then
    FConn.FailWith(AMessage, ACode, AClientAuthAlert);
end;

end.
