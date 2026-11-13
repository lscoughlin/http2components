{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Pool.Http2;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  SyncObjs,
  Http2.Client.Errors,
  Http2.Common.Frames,
  Http2.Common.Hpack,
  Http2.Client.Tls,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.RequestObserver,
  Http2.Client.Pool.Types,
  Http2.Client.Defaults;


type
  THttpConnection = class(TInterfacedObject, IPooledConnection)
  private
    FConn: TConnection;
    FEncoder: THpackCodec;
    FDecoder: THpackCodec;
    FAllocator: TStreamIdAllocator;
    FLock: TCriticalSection;
    FOrigin: string;
    FMaxStreamsPerConnection: Integer;
    FClosing: Boolean;
    procedure MaybeClose;
  public
    constructor Create(const AConn: TConnection; const AOrigin: string;
      const AMaxStreamsPerConnection: Integer);
    destructor Destroy; override;
    function ActiveStreams: Integer;
    function Eligible: Boolean;
    function Acquire(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
    /// acquire with a cancellation token: polls the lease wait so a cancel
    /// posts RST_STREAM(CANCEL) and releases the lease before returning
    function AcquireCancellable(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer; const AToken: ICancellationToken;
      out AAcquired: Boolean): IHttpResponse;
    /// adopt the h2c upgrade request: the peer already received it as stream 1
    /// during the HTTP/1.1 Upgrade, so no request frame is emitted and the 101
    /// is not the response; the response arrives on stream 1 (RFC 7540 s 3.2)
    function AcquireUpgraded(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer): IHttpResponse;
    function Closed: Boolean;
    procedure Drain;
    procedure ReleaseIfIdle;
    function GetConn: TConnection;
    function GetOrigin: string;
    function GetLock: TCriticalSection;
    function GetKey: Pointer;
  end;

implementation

uses
  Http2.Client.Response,
  Http2.Client.Body.Limits,
  Http2.Client.Encoding;

constructor THttpConnection.Create(const AConn: TConnection;
  const AOrigin: string; const AMaxStreamsPerConnection: Integer);
begin
  inherited Create;
  FConn := AConn;
  FOrigin := AOrigin;
  FLock := TCriticalSection.Create;
  FEncoder := THpackCodec.Create;
  FDecoder := THpackCodec.Create;
  FConn.HeaderEncoderLock := FLock;
  FConn.HeaderEncoder := FEncoder;
  FConn.HeaderDecoder := FDecoder;
  FAllocator := TStreamIdAllocator.Create;
  FMaxStreamsPerConnection := AMaxStreamsPerConnection;
  FClosing := False;
end;

destructor THttpConnection.Destroy;
begin
  FConn.Close;
  FConn.HeaderDecoder := nil;
  FConn.HeaderEncoder := nil;
  FConn.HeaderEncoderLock := nil;
  FConn.Free;
  FEncoder.Free;
  FDecoder.Free;
  FAllocator.Free;
  FLock.Free;
  inherited Destroy;
end;

function THttpConnection.GetConn: TConnection;
begin
  Result := FConn;
end;

function THttpConnection.GetOrigin: string;
begin
  Result := FOrigin;
end;

function THttpConnection.GetLock: TCriticalSection;
begin
  Result := FLock;
end;

function THttpConnection.ActiveStreams: Integer;
begin
  Result := FConn.StreamCount;
end;

function THttpConnection.Eligible: Boolean;
var
  St: TConnectionState;
  Peer, Cap: LongWord;
begin
  St := FConn.State;
  if (St <> csOpening) and (St <> csOpen) then
    Exit(False);
  Peer := FConn.PeerSettings.MaxConcurrentStreams;
  Cap := LongWord(FMaxStreamsPerConnection);
  if (Peer > 0) and (Peer < Cap) then
    Cap := Peer;
  Result := LongWord(FConn.StreamCount) < Cap;
end;

function THttpConnection.Acquire(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
begin
  Result := AcquireCancellable(ARequest, ATimeoutMs, nil, AAcquired);
end;

function THttpConnection.AcquireCancellable(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer; const AToken: ICancellationToken;
  out AAcquired: Boolean): IHttpResponse;
var
  Lease: TStreamLease;
  Keep: IConnectionStream;
  Deadline: QWord;
  Slice, Remaining: Integer;
  Ok: Boolean;
  Err: EHttpError;
begin
  AAcquired := False;
  FLock.Acquire;
  try
    if FClosing or (not Eligible) then
    begin
      // a server that rejected the client certificate ends the connection
      // right after it opened; that is final, not a reason for the pool to
      // dial again and repeat the rejection
      if (FConn <> nil) and (FConn.State = csClosed) then
      begin
        Err := FConn.FailureError(FConn.ErrorMessage, FConn.ErrorCode);
        if Err is EHttpTlsClientAuthError then
          raise Err;
        Err.Free;
      end;
      Exit;
    end;
    Lease := TStreamLease.Create(FConn, FAllocator, ARequest, FEncoder,
      FDecoder);
    Keep := Lease;
    Lease.WaitLock := FLock;
    Lease.TimeoutMs := ATimeoutMs;
    Lease.Start;
    AAcquired := True;
    if ARequest.Exchange <> nil then
      ARequest.Exchange.RequestWritten(Lease.BytesSent);
    Deadline := GetTickCount64 + QWord(ATimeoutMs);
    Ok := False;
    while True do
    begin
      if AToken = nil then
        Slice := ATimeoutMs
      else if AToken.IsCancelled then
        Break
      else
        Slice := cCancelPollSliceMs;
      if GetTickCount64 >= Deadline then
        Slice := 0;
      Ok := Lease.WaitForResponseHeader(Slice);
      if Ok then
        Break;
      if AToken = nil then
        Break;                       // a plain wait: the timeout is terminal
      if AToken.IsCancelled then
        Break;
      if GetTickCount64 >= Deadline then
        Break;
      Remaining := Integer(Deadline - GetTickCount64);
      if Remaining <= 0 then
        Break;
    end;
    if not Ok then
    begin
      // a cancelled or expired stream is RESET, never orphaned (10.5-10.8)
      FConn.PostFrame(BuildRstStreamFrame(Lease.StreamId, ecCancel));
      Lease.ReleaseLease;
      if (AToken <> nil) and AToken.IsCancelled then
        raise EHttpStreamError.Create('request cancelled', Lease.StreamId,
          ecCancel);
      raise EHttpTimeout.Create('timed out waiting for response headers');
    end;
    // a body coded by the peer is decoded here, at the one place every
    // response is built, so ReadText and every typed reader inherit it
    Result := THttpResponse.Create(Lease, Keep, Self);
  finally
    FLock.Release;
  end;
  // the wire limit counts the bytes the connection delivers, so it wraps
  // the body before the decoder; the decoded limit and the ratio cap go to
  // the decoder, which runs only when the request offered a coding
  Result := WrapLimitedResponse(Result,
    EffectiveResponseLimit(ARequest, FConn.Security.MaxResponseBytes));
  Result := WrapDecodingResponse(Result,
    ARequest.Headers.Contains('accept-encoding'),
    FConn.Security.MaxDecodedResponseBytes, FConn.Security.MaxDecodeRatio);
end;

procedure THttpConnection.MaybeClose;
begin
  if FClosing and (FConn.StreamCount = 0) then
    FConn.Close;
end;

procedure THttpConnection.Drain;
begin
  FLock.Acquire;
  try
    FClosing := True;
    MaybeClose;
  finally
    FLock.Release;
  end;
end;

procedure THttpConnection.ReleaseIfIdle;
begin
  FLock.Acquire;
  try
    MaybeClose;
  finally
    FLock.Release;
  end;
end;

function THttpConnection.Closed: Boolean;
begin
  Result := FConn.State = csClosed;
end;

function THttpConnection.GetKey: Pointer;
begin
  Result := Pointer(FConn);
end;

function THttpConnection.AcquireUpgraded(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer): IHttpResponse;
var
  Lease: TStreamLease;
  Keep: IConnectionStream;
  Deadline: QWord;
  Slice: Integer;
  Ok: Boolean;
begin
  FLock.Acquire;
  try
    Lease := TStreamLease.Create(FConn, FAllocator, ARequest, FEncoder,
      FDecoder);
    Keep := Lease;
    Lease.WaitLock := FLock;
    Lease.TimeoutMs := ATimeoutMs;
    try
      Lease.AdoptUpgradedStream;
    except
      Lease.ReleaseLease;
      raise;
    end;
    // stream 1 is registered, so it is now safe to start the reader: the
    // preface is written and every inbound stream-1 frame routes to this
    // lease (never to the shared queue)
    FConn.Start;
    // AdoptUpgradedStream registered stream 1, so the response the peer
    // already produced during the Upgrade (RFC 7540 section 3.2) is routed to
    // this lease by the connection thread.
    Deadline := GetTickCount64 + QWord(ATimeoutMs);
    Ok := False;
    while True do
    begin
      if GetTickCount64 >= Deadline then
        Slice := 0
      else
        Slice := Integer(Deadline - GetTickCount64);
      Ok := Lease.WaitForResponseHeader(Slice);
      if Ok then
        Break;
      if GetTickCount64 >= Deadline then
        Break;
    end;
    if not Ok then
    begin
      // the adopted stream is RESET, never orphaned (mirrors AcquireCancellable)
      FConn.PostFrame(BuildRstStreamFrame(Lease.StreamId, ecCancel));
      Lease.ReleaseLease;
      raise EHttpTimeout.Create('timed out waiting for response headers');
    end;
    // a body coded by the peer is decoded here (mirrors AcquireCancellable)
    Result := THttpResponse.Create(Lease, Keep, Self);
  finally
    FLock.Release;
  end;
  // the wire limit counts the bytes the connection delivers, so it wraps
  // the body before the decoder; the decoded limit and the ratio cap go to
  // the decoder, which runs only when the request offered a coding
  Result := WrapLimitedResponse(Result,
    EffectiveResponseLimit(ARequest, FConn.Security.MaxResponseBytes));
  Result := WrapDecodingResponse(Result,
    ARequest.Headers.Contains('accept-encoding'),
    FConn.Security.MaxDecodedResponseBytes, FConn.Security.MaxDecodeRatio);
end;

{ TSingleReadSocket }

end.
