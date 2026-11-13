{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - Imported from http2client source revision 709336f542cbedf9ce1ab67d83bddcfd560eb1c0.
  - Unit references use the common and client namespaces.
---
}
unit Http2.Client.Connection;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Tls, Http2.Client.Observer, Http2.Common.FlowControl,
  Http2.Client.Clock, Http2.Common.Hpack, Http2.Client.Connection.Observer,
  Http2.Client.Connection.Queue, Http2.Client.Connection.SendCredit,
  Http2.Client.Connection.Credit, Http2.Client.Connection.HeaderBlock,
  Http2.Client.Config.Security;

const
  /// connection-level receive window we advertise (RFC 7540 section 6.9.2)
  cDefaultConnectionWindowSize = 65535;
  /// per-stream receive window we advertise
  cDefaultStreamWindowSize = 65535;
  /// emit a WINDOW_UPDATE once this many bytes have accrued (half the window)
  cWindowUpdateBatchSize = 32768;
  /// default bound on either frame queue (backpressure instead of growth)
  cDefaultQueueCapacity = 128;
  /// how long a socket read blocks before the thread re-checks outbound work
  cDefaultReadPollMs = 20;

type
  /// an ARC-safe, bounded, blocking queue of T
  // - Shutdown releases every blocked waiter; a later Pop returns False
  IBlockingQueue<T> = interface
    procedure Push(const AItem: T);
    /// block until an item is available or the queue is shut down + empty
    function Pop(out AItem: T): Boolean;
    /// return an item only if one is already available (never blocks)
    function TryPop(out AItem: T): Boolean;
    /// wake every blocked waiter; pending and future operations fail fast
    procedure Shutdown;
  end;

  /// the public generic queue contract. State and wait logic live in the
  /// connection queue unit.
  TBlockingQueue<T> = class(TInterfacedObject, IBlockingQueue<T>)
  private
    FState: Http2.Client.Connection.Queue.TBlockingQueueState<T>;
  public
    constructor Create(const ACapacity: Integer = cDefaultQueueCapacity);
    destructor Destroy; override;
    procedure Push(const AItem: T);
    function Pop(out AItem: T): Boolean;
    function TryPop(out AItem: T): Boolean;
    procedure Shutdown;
    function Count: Integer;
    function WaitersParked: Integer;
    function WaitForItem(const ATimeoutMs: Integer): Boolean;
    function IsShutdown: Boolean;
  end;

  TConnection = class;

  /// the lifecycle state exposed for connection-pool eligibility
  TConnectionState = (csOpening, csOpen, csGoAway, csClosed);

  /// one worker thread per connection. Close stops and joins the worker.
  TConnectionThread = class(TThread)
  private
    FWorker: Pointer;
  protected
    procedure Execute; override;
    procedure DoPreface;
    procedure ApplyPeerSettings(const ASettings: TConnectionSettings);
    procedure RouteInbound(const AFrame: TFrame);
    procedure DrainOutbound;
    procedure WriteTracked(const AFrame: TFrame);
    procedure CheckPingKeepAlive;
    procedure HandlePingAck(const APayload: TBytes);
    procedure Fail(const AMessage: string; const ACode: THttp2ErrorCode;
      const AClientAuthAlert: string = '');
  public
    constructor Create(AConn: TConnection);
    destructor Destroy; override;
    function WorkerTerminated: Boolean;
  end;

  /// the seam S08's stream lease registers with, so a dying connection can
  /// terminate every in-flight stream exactly once
  IConnectionStream = interface
    /// the connection failed: terminate any pending read/write with this error
    procedure OnConnectionFailed(const AMessage: string;
      const ACode: THttp2ErrorCode);
    /// the peer sent GOAWAY: streams above ALastStreamId are retryable
    procedure OnConnectionGoAway(const ALastStreamId: LongWord);
    /// a frame addressed to this stream arrived from the peer
    procedure OnStreamFrame(const AFrame: TFrame);
  end;

  /// the minimal connection object S06/S07 need: state, the two frame queues,
  /// the socket, and the thread. S08 extends it with stream leases.
  TConnection = class
  private
    FLock: TCriticalSection;

    FStreams: TDictionary<LongWord, IConnectionStream>;
    FStreamOneReserved: Boolean;
    FStateEvent: PRTLEvent;
    FSocket: IHttp2Socket;
    FOutbound: IBlockingQueue<TFrame>;
    FInbound: IBlockingQueue<TFrame>;
    FThread: TConnectionThread;
    FHeaderDecoder: THpackCodec; // weak; owner outlives the connection thread
    FHeaderEncoder: THpackCodec; // weak; owner outlives the connection thread
    FHeaderEncoderLock: TCriticalSection; // weak; shared with stream encoding
    FHeaderBlock: THeaderBlockAssembler; // only the connection reader accesses this
    FState: TConnectionState;
    FLocalSettings: TConnectionSettings;
    FPeerSettings: TConnectionSettings;
    FSettingsAcked: Boolean;
    FPeerSettingsReceived: Boolean;
    FGoAwayLastStreamId: LongWord;
    FHighestStreamId: LongWord;
    FHighestOpenedStreamId: LongWord; // highest id that a lease registered
    FError: string;
    FErrorCode: THttp2ErrorCode;
    FClientAuthAlert: string;
    FClosed: Boolean;
    FReadPollMs: Integer;
    FPingIntervalMs: Integer;
    FPingTimeoutMs: Integer;
    FLastActivity: QWord;
    FNotifications: TConnectionObserver;
    FFlowControl: TFlowControl;
    FCredit: TReceiveCreditTracker;
    FSendCreditWaiters: ISendCreditWaiterRegistry;
    FSecurity: TClientSecurityOptions;
    function GetState: TConnectionState;
    function GetWorkerHeaderStream: LongWord;
    function GetPeerSettings: TConnectionSettings;
    function GetObserver: IHttp2Observer;
    procedure SetObserver(const AValue: IHttp2Observer);
    procedure SetHeaderDecoder(const AValue: THpackCodec);
    /// account for received DATA and return window credit to the peer when
    /// enough has accrued (RFC 7540 section 6.9). Called for every inbound
    /// DATA frame, stream-scoped or not.
    /// emit any still-pending WINDOW_UPDATEs (e.g. when a stream ends)
    procedure FlushStreamCredit(const AStreamId: LongWord);
    /// apply an inbound WINDOW_UPDATE to SEND-side credit (RFC 9113 section
    /// 6.9) and wake any sender starved on this window
  public
    /// internal state operations used by the connection worker
    procedure SetState(const AValue: TConnectionState);
    procedure SetSecurity(const AValue: TClientSecurityOptions);
    procedure TrackReceivedData(const AStreamId, ALength: LongWord);
    procedure ApplyWindowUpdate(const AStreamId, AIncrement: LongWord);
    /// release every sender parked on its per-sender event; each re-checks its own
    /// window and its AAbort flag, so a wake that is not for it is harmless
    procedure WakeSendCredit;
    constructor Create(const ASocket: IHttp2Socket); overload;
    constructor Create(const ASocket: IHttp2Socket;
      const ALocalSettings: TConnectionSettings); overload;
    destructor Destroy; override;
    /// spawn the connection thread (sends preface + initial SETTINGS)
    procedure Start;
    /// graceful, idempotent shutdown: sends GOAWAY (highest processed
    /// stream), Terminate+WaitFor the thread, then closes the socket
    procedure Close;
    /// enqueue a frame for the thread to write; False once closed
    function PostFrame(const AFrame: TFrame): Boolean;
    /// connection + per-stream flow-control state (plan S04/S10 seam)
    property FlowControl: TFlowControl read FFlowControl;
    /// emit a WINDOW_UPDATE for AStreamId now, returning any pending credit
    procedure SendWindowUpdate(const AStreamId: LongWord);
    /// block until the peer grants SEND credit on AStreamId, then reserve up
    /// to AMax bytes of it and return the amount reserved. Returns 0 only
    /// when ATimeoutMs expires with no credit. Raises EHttpConnectionClosed
    /// (or the recorded connection error) if the connection ends while
    /// blocked, so a caller can never hang past its deadline.
    // - RFC 9113 section 6.9: a sender must not exceed either the connection
    //   or the stream window and waits for WINDOW_UPDATE when either is
    //   exhausted. Callers must treat a zero-length END_STREAM frame as
    //   exempt: it carries no flow-controlled bytes
    //   A non-nil AAbort that turns non-zero ends the wait at once with 0, so a
    //   sender whose peer has already answered or reset the stream stops
    //   waiting for credit the peer will never grant
    function AcquireSendCredit(const AStreamId: LongWord; const AMax: LongWord;
      const ATimeoutMs: Integer; const AAbort: PLongInt = nil): LongWord;
    /// may a new stream still be opened on this connection?
    function CanOpenStream: Boolean;
    /// RFC 7540 section 6.8: after GOAWAY, a stream with an id strictly above
    /// last-stream-id was never processed and MAY be safely retried
    function IsStreamRetryable(const AStreamId: LongWord): Boolean;
    /// bounded, event-driven wait for a lifecycle state (test/pool seam)
    function WaitForState(const AState: TConnectionState;
      const ATimeoutMs: Integer): Boolean;
    /// record a peer GOAWAY; stops new streams, marks higher ids retryable
    procedure MarkGoAway(const ALastStreamId: LongWord);
    /// move to a failed state and unblock every waiter (thread-internal seam)
    // - AClientAuthAlert is the TLS alert name when the server rejected the
    //   client certificate (doc/design/mtls.md), '' otherwise
    procedure FailWith(const AMessage: string; const ACode: THttp2ErrorCode;
      const AClientAuthAlert: string = '');
    /// the error to raise to a caller of a connection that has failed: an
    /// EHttpTlsClientAuthError when the server rejected the client
    /// certificate, else an EHttpConnectionError with the recorded message
    function FailureError(const AMessage: string;
      const ACode: THttp2ErrorCode): EHttpError;
    /// record peer SETTINGS under the connection lock (thread-internal seam)
    procedure ApplyPeerSettingsValue(const ASettings: TConnectionSettings);
    /// record the peer's SETTINGS ACK (thread-internal seam)
    procedure MarkSettingsAcked;
    /// update the idle clock used by the PING keep-alive schedule
    procedure TouchActivity;
    /// register a stream lease for connection-failure fan-out
    procedure RegisterStream(const AStreamId: LongWord;
      const AStream: IConnectionStream);
    /// RFC 7540 section 3.2: the h2c upgrade request was already received by
    /// the peer as stream 1, so the response arrives on stream 1 without the
    /// client emitting any request frame.  Register AStream for stream id 1
    /// (without sending HEADERS) and return False when stream 1 was already
    /// adopted.
    function AdoptStreamOne(const AStream: IConnectionStream): Boolean;
    /// remove a stream lease (idempotent); call exactly once per stream
    procedure UnregisterStream(const AStreamId: LongWord);
    /// number of in-flight stream leases (test seam)
    function StreamCount: Integer;
    /// number of senders parked for flow-control credit (test seam)
    function SendCreditWaiterCount: Integer;
    /// hand a stream-scoped frame to its lease; False when nobody owns it
    /// (the frame is then left on the shared inbound queue)
    function DispatchStreamFrame(const AFrame: TFrame): Boolean;
    /// Set before Start. Decoding then occurs in wire order, before dispatch.
    property HeaderDecoder: THpackCodec read FHeaderDecoder write SetHeaderDecoder;
    property HeaderEncoder: THpackCodec read FHeaderEncoder write FHeaderEncoder;
    property HeaderEncoderLock: TCriticalSection read FHeaderEncoderLock
      write FHeaderEncoderLock;

    property State: TConnectionState read GetState;
    property PeerSettings: TConnectionSettings read GetPeerSettings;
    property Notifications: TConnectionObserver read FNotifications;
    property LocalSettings: TConnectionSettings read FLocalSettings;
    property WorkerHeaderStream: LongWord read GetWorkerHeaderStream;
    property LastActivity: QWord read FLastActivity;
    property Thread: TConnectionThread read FThread;
    property Outbound: IBlockingQueue<TFrame> read FOutbound;
    property Inbound: IBlockingQueue<TFrame> read FInbound;
    property Socket: IHttp2Socket read FSocket;
    property SettingsAcked: Boolean read FSettingsAcked;
    property GoAwayLastStreamId: LongWord read FGoAwayLastStreamId;
    property HighestStreamId: LongWord read FHighestStreamId
      write FHighestStreamId;
    /// the highest stream id that the client has opened (0 when none)
    property HighestOpenedStreamId: LongWord read FHighestOpenedStreamId;
    property ErrorMessage: string read FError;
    property ErrorCode: THttp2ErrorCode read FErrorCode;
    property ReadPollMs: Integer read FReadPollMs write FReadPollMs;
    property PingIntervalMs: Integer read FPingIntervalMs write FPingIntervalMs;
    property PingTimeoutMs: Integer read FPingTimeoutMs write FPingTimeoutMs;
    /// optional observability sink; nil (the default) means no overhead
    property Observer: IHttp2Observer read GetObserver write SetObserver;
    property Security: TClientSecurityOptions read FSecurity;
  end;

/// the 24-byte client connection preface (RFC 7540 section 3.5)
function ClientPrefaceBytes: TBytes;

implementation

uses
  Http2.Client.Connection.Thread;

const
  cClientPreface: array[0..23] of Byte = (
    $50, $52, $49, $20, $2A, $20, $48, $54, $54, $50, $2F, $32, $2E, $30,
    $0D, $0A, $0D, $0A, $53, $4D, $0D, $0A, $0D, $0A);

function ClientPrefaceBytes: TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, SizeOf(cClientPreface));
  for I := 0 to High(cClientPreface) do
    Result[I] := cClientPreface[I];
end;

constructor TBlockingQueue<T>.Create(const ACapacity: Integer);
begin
  inherited Create;
  FState := Http2.Client.Connection.Queue.TBlockingQueueState<T>.Create(
    ACapacity);
end;

destructor TBlockingQueue<T>.Destroy;
begin
  FState.Free;
  inherited Destroy;
end;

procedure TBlockingQueue<T>.Push(const AItem: T);
begin FState.Push(AItem); end;

function TBlockingQueue<T>.Pop(out AItem: T): Boolean;
begin Result := FState.Pop(AItem); end;

function TBlockingQueue<T>.TryPop(out AItem: T): Boolean;
begin Result := FState.TryPop(AItem); end;

procedure TBlockingQueue<T>.Shutdown;
begin FState.Shutdown; end;

function TBlockingQueue<T>.Count: Integer;
begin Result := FState.Count; end;

function TBlockingQueue<T>.WaitersParked: Integer;
begin Result := FState.WaitersParked; end;

function TBlockingQueue<T>.WaitForItem(const ATimeoutMs: Integer): Boolean;
begin Result := FState.WaitForItem(ATimeoutMs); end;

function TBlockingQueue<T>.IsShutdown: Boolean;
begin Result := FState.IsShutdown; end;

{ TConnection }

constructor TConnection.Create(const ASocket: IHttp2Socket);
begin
  Create(ASocket, TConnectionSettings.Defaults);
end;

constructor TConnection.Create(const ASocket: IHttp2Socket;
  const ALocalSettings: TConnectionSettings);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStateEvent := RTLEventCreate;
  FSendCreditWaiters := NewSendCreditWaiterRegistry;
  FSecurity := TClientSecurityOptions.Default;
  FSocket := ASocket;
  FOutbound := TBlockingQueue<TFrame>.Create(cDefaultQueueCapacity);
  FInbound := TBlockingQueue<TFrame>.Create(0); // unbounded: only the reader fills it
  FLocalSettings := ALocalSettings;
  FPeerSettings := TConnectionSettings.Defaults;
  FState := csOpening;
  FSettingsAcked := False;
  FPeerSettingsReceived := False;
  FGoAwayLastStreamId := MaxStreamId;
  FHighestStreamId := 0;
  FError := '';
  FErrorCode := ecNoError;
  FClosed := False;
  FReadPollMs := cDefaultReadPollMs;
  FPingIntervalMs := 0;
  FPingTimeoutMs := 0;
  FLastActivity := GetTickCount64;
  FNotifications := TConnectionObserver.Create;
  FFlowControl := TFlowControl.Create(cDefaultConnectionWindowSize,
    cDefaultStreamWindowSize);
  FHeaderBlock := THeaderBlockAssembler.Create;
  FCredit := TReceiveCreditTracker.Create;
  FStreams := TDictionary<LongWord, IConnectionStream>.Create;
  FStreamOneReserved := False;
end;

destructor TConnection.Destroy;
begin
  Close;
  FreeAndNil(FCredit);
  FreeAndNil(FHeaderBlock);
  FreeAndNil(FFlowControl);
  FreeAndNil(FNotifications);
  FreeAndNil(FStreams);
  RTLEventDestroy(FStateEvent);
  FSendCreditWaiters := nil;
  FLock.Free;
  inherited Destroy;
end;

constructor TConnectionThread.Create(AConn: TConnection);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FWorker := Http2.Client.Connection.Thread.TConnectionWorker.Create(Self,
    AConn);
end;

destructor TConnectionThread.Destroy;
begin
  if not Finished then
  begin
    Terminate;
    if Suspended then
      Start;
    WaitFor;
  end;
  Http2.Client.Connection.Thread.TConnectionWorker(FWorker).Free;
  inherited Destroy;
end;

procedure TConnectionThread.Execute;
begin Http2.Client.Connection.Thread.TConnectionWorker(FWorker).Run; end;

function TConnectionThread.WorkerTerminated: Boolean;
begin
  Result := Terminated;
end;

procedure TConnectionThread.DoPreface;
begin Http2.Client.Connection.Thread.TConnectionWorker(FWorker).DoPreface; end;

procedure TConnectionThread.ApplyPeerSettings(
  const ASettings: TConnectionSettings);
begin
  Http2.Client.Connection.Thread.TConnectionWorker(FWorker).ApplyPeerSettings(
    ASettings);
end;

procedure TConnectionThread.RouteInbound(const AFrame: TFrame);
begin
  Http2.Client.Connection.Thread.TConnectionWorker(FWorker).RouteInbound(
    AFrame);
end;

procedure TConnectionThread.DrainOutbound;
begin Http2.Client.Connection.Thread.TConnectionWorker(FWorker).DrainOutbound; end;

procedure TConnectionThread.WriteTracked(const AFrame: TFrame);
begin
  Http2.Client.Connection.Thread.TConnectionWorker(FWorker).WriteTracked(AFrame);
end;

procedure TConnectionThread.CheckPingKeepAlive;
begin Http2.Client.Connection.Thread.TConnectionWorker(FWorker).CheckPingKeepAlive; end;

procedure TConnectionThread.HandlePingAck(const APayload: TBytes);
begin
  Http2.Client.Connection.Thread.TConnectionWorker(FWorker).HandlePingAck(
    APayload);
end;

procedure TConnectionThread.Fail(const AMessage: string;
  const ACode: THttp2ErrorCode; const AClientAuthAlert: string);
begin
  Http2.Client.Connection.Thread.TConnectionWorker(FWorker).Fail(AMessage,
    ACode, AClientAuthAlert);
end;

procedure TConnection.Start;
begin
  if FThread = nil then
  begin
    FThread := TConnectionThread.Create(Self);
    FThread.Start;
  end;
end;

procedure TConnection.Close;
begin
  if FClosed then
    Exit;
  FClosed := True;
  // GOAWAY must be queued even while the preface is still being written: the
  // worker sets csOpen only *after* DoPreface returns, so a Close racing with
  // startup would otherwise skip the GOAWAY entirely. Queued frames are
  // drained after the preface, preserving the wire ordering (preface,
  // SETTINGS, then GOAWAY).
  if (FThread <> nil) and (GetState in [csOpening, csOpen]) then
    FOutbound.Push(BuildGoAwayFrame(FHighestStreamId, ecNoError, nil));
  if FThread <> nil then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FThread.Free;
    FThread := nil;
  end;
  FOutbound.Shutdown;
  FInbound.Shutdown;
  if FSocket <> nil then
    FSocket.Close;
  SetState(csClosed);
  FNotifications.EmitConnectionClose('', ecNoError);
end;

function TConnection.PostFrame(const AFrame: TFrame): Boolean;
begin
  Result := not FClosed;
  if Result then
    FOutbound.Push(AFrame);
end;

function TConnection.CanOpenStream: Boolean;
begin
  // opening a stream only needs the connection to be open: a request may send
  // HEADERS immediately. DATA is gated separately in AcquireSendCredit until
  // the peer's SETTINGS_INITIAL_WINDOW_SIZE is known (RFC 9113 section 6.5.3)
  Result := GetState = csOpen;
end;

function TConnection.IsStreamRetryable(const AStreamId: LongWord): Boolean;
var
  S: TConnectionState;
begin
  S := GetState;
  Result := ((S = csGoAway) or (S = csClosed)) and
            (AStreamId > FGoAwayLastStreamId);
  if Result then
    FNotifications.EmitRetry(AStreamId);
end;

function TConnection.WaitForState(const AState: TConnectionState;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if GetState = AState then
      Exit(True);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FStateEvent, Remaining);
  end;
end;

function TConnection.GetState: TConnectionState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TConnection.GetPeerSettings: TConnectionSettings;
begin
  FLock.Acquire;
  try
    Result := FPeerSettings;
  finally
    FLock.Release;
  end;
end;

procedure TConnection.SetState(const AValue: TConnectionState);
begin
  FLock.Acquire;
  try
    FState := AValue;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FStateEvent);
  // a sender parked on send credit must not outlive the state it waited on
  if AValue in [csGoAway, csClosed] then
    WakeSendCredit;
end;

procedure TConnection.MarkSettingsAcked;
begin
  FLock.Acquire;
  try
    FSettingsAcked := True;
  finally
    FLock.Release;
  end;
end;

procedure TConnection.ApplyPeerSettingsValue(
  const ASettings: TConnectionSettings);
var
  Delta: Int64;
begin
  // Use the stream encoder lock first. Stream startup takes this lock before
  // it enters the connection lock, so keep the same order here.
  if FHeaderEncoderLock <> nil then
    FHeaderEncoderLock.Acquire;
  try
    FLock.Acquire;
    try
      // a SETTINGS_INITIAL_WINDOW_SIZE change adjusts every open stream window
      Delta := Int64(ASettings.InitialWindowSize) -
        Int64(FPeerSettings.InitialWindowSize);
      FPeerSettings := ASettings;
      FPeerSettingsReceived := True;
      if Delta <> 0 then
        FFlowControl.ApplyInitialWindowDelta(Delta);
    finally
      FLock.Release;
    end;
    if FHeaderEncoder <> nil then
      FHeaderEncoder.SetPeerTableSize(ASettings.HeaderTableSize);
  finally
    if FHeaderEncoderLock <> nil then
      FHeaderEncoderLock.Release;
  end;
  // wake every sender: a raised window grants credit, and a sender parked only
  // because the peer's SETTINGS had not arrived is now unblocked
  WakeSendCredit;
end;

procedure TConnection.SetHeaderDecoder(const AValue: THpackCodec);
begin
  FHeaderDecoder := AValue;
  if FHeaderDecoder <> nil then
  begin
    FHeaderDecoder.SetDecoderLimit(FLocalSettings.HeaderTableSize);
    FHeaderDecoder.MaxHeaderListSize := FLocalSettings.MaxHeaderListSize;
  end;
end;

procedure TConnection.MarkGoAway(const ALastStreamId: LongWord);
var
  Snapshot: TArray<IConnectionStream>;
  S: IConnectionStream;
begin
  FLock.Acquire;
  try
    FGoAwayLastStreamId := ALastStreamId;
    if FState = csOpen then
      FState := csGoAway;
    Snapshot := FStreams.Values.ToArray;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FStateEvent);
  WakeSendCredit;
  FNotifications.EmitGoAway(ALastStreamId, ecNoError);
  for S in Snapshot do
    S.OnConnectionGoAway(ALastStreamId);
end;

procedure TConnection.RegisterStream(const AStreamId: LongWord;
  const AStream: IConnectionStream);
var
  Failed: Boolean;
  Msg: string;
  Code: THttp2ErrorCode;
begin
  FLock.Acquire;
  try
    FStreams.AddOrSetValue(AStreamId, AStream);
    FFlowControl.OpenStream(AStreamId);
    if AStreamId > FHighestOpenedStreamId then
      FHighestOpenedStreamId := AStreamId;
    Failed := FState = csClosed;
    Msg := FError;
    Code := FErrorCode;
  finally
    FLock.Release;
  end;
  FNotifications.EmitStreamOpen(AStreamId);
  if Failed then
    AStream.OnConnectionFailed(Msg, Code);
end;

procedure TConnection.UnregisterStream(const AStreamId: LongWord);
begin
  SendWindowUpdate(AStreamId);
  FLock.Acquire;
  try
    FStreams.Remove(AStreamId);
    FFlowControl.CloseStream(AStreamId);
    FCredit.Forget(AStreamId);
  finally
    FLock.Release;
  end;
  FNotifications.EmitStreamClose(AStreamId);
end;

function TConnection.AdoptStreamOne(const AStream: IConnectionStream): Boolean;
begin
  FLock.Acquire;
  try
    if FStreamOneReserved then
      Exit(False);
    FStreamOneReserved := True;
    FStreams.AddOrSetValue(1, AStream);
    FFlowControl.OpenStream(1);
    if FHighestStreamId < 1 then
      FHighestStreamId := 1;
    if FHighestOpenedStreamId < 1 then
      FHighestOpenedStreamId := 1;
  finally
    FLock.Release;
  end;
  FNotifications.EmitStreamOpen(1);
  Result := True;
end;

function TConnection.StreamCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FStreams.Count;
  finally
    FLock.Release;
  end;
end;

function TConnection.SendCreditWaiterCount: Integer;
begin
  Result := FSendCreditWaiters.Count;
end;

function TConnection.GetWorkerHeaderStream: LongWord;
begin
  Result := FHeaderBlock.OpenStreamId;
end;

function TConnection.DispatchStreamFrame(const AFrame: TFrame): Boolean;
var
  S: IConnectionStream;
  Routed: TFrame;
begin
  Routed := AFrame;
  if (FHeaderDecoder <> nil) and
     (AFrame.Header.FrameType in [ftHeaders, ftContinuation]) then
  begin
    if AFrame.Header.FrameType = ftHeaders then
      FHeaderBlock.Start(AFrame.Header.StreamId, ExtractHeaderBlock(AFrame))
    else
      FHeaderBlock.Append(AFrame.Header.StreamId, ExtractHeaderBlock(AFrame));
    if AFrame.IsEndHeaders then
    begin
      Routed.DecodedHeaders := FHeaderDecoder.Decode(FHeaderBlock.Take);
      Routed.HeadersDecoded := True;
    end;
  end;
  FLock.Acquire;
  try
    Result := FStreams.TryGetValue(AFrame.Header.StreamId, S);
  finally
    FLock.Release;
  end;
  if Result then
    S.OnStreamFrame(Routed);
end;

procedure TConnection.FailWith(const AMessage: string;
  const ACode: THttp2ErrorCode; const AClientAuthAlert: string);
var
  Snapshot: TArray<IConnectionStream>;
  S: IConnectionStream;
begin
  FLock.Acquire;
  try
    if FState <> csClosed then
    begin
      FState := csClosed;
      FError := AMessage;
      FErrorCode := ACode;
      FClientAuthAlert := AClientAuthAlert;
    end;
    Snapshot := FStreams.Values.ToArray;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FStateEvent);
  WakeSendCredit;
  // fail every in-flight stream and release every blocked waiter
  FOutbound.Shutdown;
  FInbound.Shutdown;
  for S in Snapshot do
    S.OnConnectionFailed(AMessage, ACode);
  FNotifications.EmitConnectionClose(AMessage, ACode);
end;

function TConnection.FailureError(const AMessage: string;
  const ACode: THttp2ErrorCode): EHttpError;
begin
  if FClientAuthAlert <> '' then
    Result := EHttpTlsClientAuthError.Create(AMessage, FClientAuthAlert)
  else
    Result := EHttpConnectionError.Create(AMessage, ACode);
end;

procedure TConnection.TouchActivity;
begin
  FLock.Acquire;
  try
    FLastActivity := GetTickCount64;
  finally
    FLock.Release;
  end;
end;

procedure TConnection.TrackReceivedData(const AStreamId: LongWord;
  const ALength: LongWord);
var
  Win: TWindow;
  EmitConnInc, EmitStreamInc: LongWord;
begin
  if ALength = 0 then
    Exit;
  EmitConnInc := 0;
  EmitStreamInc := 0;
  FLock.Acquire;
  try
    // stream window: only for a stream we still track (an open lease)
    FCredit.OnData(AStreamId, Integer(ALength),
      (AStreamId <> 0) and FFlowControl.TryGetStream(AStreamId, Win),
      cWindowUpdateBatchSize, EmitConnInc, EmitStreamInc);
  finally
    FLock.Release;
  end;
  if EmitConnInc > 0 then
  begin
    PostFrame(BuildWindowUpdateFrame(0, EmitConnInc));
    FNotifications.EmitWindowUpdate(0, EmitConnInc);
  end;
  if EmitStreamInc > 0 then
  begin
    PostFrame(BuildWindowUpdateFrame(AStreamId, EmitStreamInc));
    FNotifications.EmitWindowUpdate(AStreamId, EmitStreamInc);
  end;
end;

procedure TConnection.SendWindowUpdate(const AStreamId: LongWord);
var
  Pending: LongWord;
begin
  FLock.Acquire;
  try
    Pending := FCredit.TakeStream(AStreamId);
  finally
    FLock.Release;
  end;
  if Pending = 0 then
    Exit;
  PostFrame(BuildWindowUpdateFrame(AStreamId, Pending));
  FNotifications.EmitWindowUpdate(AStreamId, Pending);
end;

procedure TConnection.FlushStreamCredit(const AStreamId: LongWord);
begin
  SendWindowUpdate(AStreamId);
end;

procedure TConnection.ApplyWindowUpdate(const AStreamId,
  AIncrement: LongWord);
begin
  FLock.Acquire;
  try
    if AStreamId = 0 then
    begin
      try
        FFlowControl.ApplyConnectionUpdate(AIncrement);
      except
        on E: EHttpError do
          raise EHttpConnectionError.Create(E.Message, E.ErrorCode);
      end;
    end
    else
    begin
      try
        FFlowControl.ApplyStreamUpdate(AStreamId, AIncrement);
      except
        on E: EHttpError do
          raise EHttpStreamError.Create(E.Message, AStreamId, E.ErrorCode);
      end;
    end;
  finally
    FLock.Release;
  end;
  WakeSendCredit;
end;

procedure TConnection.WakeSendCredit;
begin
  // Each parked sender owns an event, so a rapid broadcast cannot collapse
  // several pending signals into one.
  FSendCreditWaiters.WakeAll;
end;

function TConnection.AcquireSendCredit(const AStreamId: LongWord;
  const AMax: LongWord; const ATimeoutMs: Integer;
  const AAbort: PLongInt): LongWord;
var
  Deadline: QWord;
  Remaining: Integer;
  Granted: LongWord;
  Win: TWindow;
  Waiter: ISendCreditWaiter;
begin
  Waiter := nil;
  try
    Deadline := GetTickCount64 + QWord(ATimeoutMs);
    while True do
    begin
      FLock.Acquire;
      try
        if FClosed or (FState = csClosed) then
          if FError <> '' then
            raise FailureError(FError, FErrorCode)
          else
            raise EHttpConnectionClosed.Create(
              'connection closed while waiting for send credit');
        // Reserve min(connection window, stream window, room left in this
        // frame). TryConsume is the atomic check-and-decrement across BOTH
        // windows (it leaves them untouched when either lacks credit), so a
        // stream starved on its own window never eats the connection window.
        Granted := 0;
        // RFC 9113 section 6.5.3: do not emit DATA before the peer's SETTINGS
        // has set INITIAL_WINDOW_SIZE, or a lowered window would be overrun
        // (FLOW_CONTROL_ERROR). Treat that as "no credit yet": the sender parks
        // and ApplyPeerSettingsValue wakes it once the settings are applied.
        if FPeerSettingsReceived and FFlowControl.TryGetStream(AStreamId, Win) then
        begin
          Granted := AMax;
          if LongWord(FFlowControl.Connection.Size) < Granted then
            Granted := LongWord(FFlowControl.Connection.Size);
          if LongWord(Win.Size) < Granted then
            Granted := LongWord(Win.Size);
          if (Granted > 0) and FFlowControl.TryConsume(AStreamId, Granted) then
            Exit(Granted);
        end;
        // credit that is there is still used; only a wait for more is cut short
        if (AAbort <> nil) and (InterlockedExchangeAdd(AAbort^, 0) <> 0) then
          Exit(0);
        // Register before releasing FLock, so a settings or window update
        // cannot land between the credit check and the park.
        if Waiter = nil then
          Waiter := FSendCreditWaiters.NewWaiter;
        Waiter.Register;
      finally
        FLock.Release;
      end;
      if GetTickCount64 >= Deadline then
        Exit(0);
      Remaining := Integer(Deadline - GetTickCount64);
      Waiter.Wait(Remaining);
    end;
  finally
    Waiter := nil;
  end;
end;

function TConnection.GetObserver: IHttp2Observer;
begin
  Result := FNotifications.GetObserver;
end;

procedure TConnection.SetObserver(const AValue: IHttp2Observer);
begin
  FNotifications.SetObserver(AValue);
end;

procedure TConnection.SetSecurity(const AValue: TClientSecurityOptions);
begin FSecurity := AValue; end;

end.
