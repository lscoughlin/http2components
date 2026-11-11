{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Pool.Http1;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  SyncObjs,
  BaseUnix,
  Sockets,
  Http2.Client.Errors,
  Http2.Client.Tls,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.Http1,
  Http2.Client.RequestObserver,
  Http2.Client.Pool.Types,
  Http2.Client.Defaults;


type
  TSingleReadSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FInner: IHttp2Socket;
    FFd: Integer;            // -1 when FInner exposes no raw socket handle
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
  public
    constructor Create(const AInner: IHttp2Socket);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
  end;

  THttp1PooledConnection = class(TInterfacedObject, IPooledConnection)
  private
    FH1: THttp1Connection;
    FLock: TCriticalSection;
    FOrigin: string;
    FClosing: Boolean;
    /// the in-flight response body, if any: the connection is only eligible
    /// for reuse once it is drained
    FLastBody: IHttpBodyStream;
  public
    constructor Create(const AH1: THttp1Connection; const AOrigin: string);
    destructor Destroy; override;
    function ActiveStreams: Integer;
    function Eligible: Boolean;
    function Acquire(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
    /// an HTTP/1.1 entry never adopts an h2c stream: the upgrade only happens
    /// on a fresh connection (UnsupportedOperation is the honest answer)
    function AcquireUpgraded(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer): IHttpResponse;
    /// finish the response of a request already written on this socket (the
    /// declined h2c upgrade probe) and mark the connection busy until its body
    /// is drained
    function Resume(const ARequest: TStreamRequest;
      const AStatusLine: string): IHttpResponse;
    function Closed: Boolean;
    procedure Drain;
    procedure ReleaseIfIdle;
    function GetConn: TConnection;
    function GetOrigin: string;
    function GetLock: TCriticalSection;
    function GetKey: Pointer;
  end;

implementation

constructor TSingleReadSocket.Create(const AInner: IHttp2Socket);
var
  Plain: TObject;
  H: Integer;
begin
  inherited Create;
  FInner := AInner;
  FFd := -1;
  H := -1;
  // TPlainSocket is the only cleartext transport that exposes an OS handle;
  // reusing its fd lets a single fpRecv bypass the exact-count loop
  try
    if (AInner <> nil) and Supports(AInner, TPlainSocket, Plain) then
      H := TPlainSocket(Plain).Handle;
  except
    H := -1;
  end;
  if H >= 0 then
    FFd := H;
  FConnectTimeoutMs := cDefaultSocketTimeoutMs;
  FReadTimeoutMs := cDefaultSocketTimeoutMs;
  FWriteTimeoutMs := cDefaultSocketTimeoutMs;
end;

destructor TSingleReadSocket.Destroy;
begin
  // FInner is freed by its own reference (no Free here: it may be shared)
  inherited Destroy;
end;

function TSingleReadSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  N: ssize_t;
  tv: TTimeVal;
  PR: IPartialReader;
begin
  if ACount <= 0 then
    Exit(0);
  if FFd < 0 then
  begin
    // no raw handle (a TLS socket): take whatever the wrapped transport has
    // available.  Its Read insists on the full count, which on a keep-alive
    // connection would wait until the server gave up
    if Supports(FInner, IPartialReader, PR) then
      Exit(PR.ReadSome(ABuffer, ACount));
    Exit(FInner.Read(ABuffer, ACount));
  end;
  tv.tv_sec := 0;
  if FReadTimeoutMs > 0 then
  begin
    tv.tv_sec := FReadTimeoutMs div 1000;
    tv.tv_usec := (FReadTimeoutMs mod 1000) * 1000;
  end;
  fpSetSockOpt(FFd, SOL_SOCKET, SO_RCVTIMEO, @tv, SizeOf(tv));
  repeat
    N := fpRecv(FFd, @ABuffer, ACount, 0);
    if N >= 0 then
      Exit(N);
    if (fpGetErrno = ESysEAGAIN) or (fpGetErrno = ESysEWOULDBLOCK) then
      raise EHttpTimeout.CreateFmt('read timed out after %d ms',
        [FReadTimeoutMs]);
    if fpGetErrno = ESysEINTR then
      Continue;
    raise EHttpConnectionClosed.CreateFmt('socket read failed (errno %d)',
      [fpGetErrno]);
  until False;
end;

function TSingleReadSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := FInner.Write(ABuffer, ACount);
end;

procedure TSingleReadSocket.Close;
begin
  FInner.Close;
end;

function TSingleReadSocket.GetConnected: Boolean;
begin
  Result := FInner.Connected;
end;

function TSingleReadSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TSingleReadSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
  FInner.ConnectTimeoutMs := AValue;
end;

function TSingleReadSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TSingleReadSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
  FInner.ReadTimeoutMs := AValue;
end;

function TSingleReadSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TSingleReadSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
  FInner.WriteTimeoutMs := AValue;
end;

{ THttp1PooledConnection }

constructor THttp1PooledConnection.Create(const AH1: THttp1Connection;
  const AOrigin: string);
begin
  inherited Create;
  FH1 := AH1;
  FOrigin := AOrigin;
  FLock := TCriticalSection.Create;
  FClosing := False;
  FLastBody := nil;
end;

destructor THttp1PooledConnection.Destroy;
begin
  FH1.Free;               // closes the socket
  FLock.Free;
  inherited Destroy;
end;

function THttp1PooledConnection.ActiveStreams: Integer;
begin
  // HTTP/1.1 carries one request at a time: a connection stays busy until the
  // current response body is drained (doc/design/fallback.md "HTTP/1.1 codec")
  if (FLastBody <> nil) and (not FLastBody.Eof) then
    Result := cHttp1StreamLimit
  else
    Result := 0;
end;

function THttp1PooledConnection.Eligible: Boolean;
begin
  Result := (not FClosing) and (ActiveStreams = 0);
end;

function THttp1PooledConnection.Closed: Boolean;
begin
  Result := FClosing or (not FH1.Reusable);
end;

function THttp1PooledConnection.Acquire(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
begin
  AAcquired := False;
  Result := nil;
  FLock.Acquire;
  try
    if FClosing then
      Exit;
    if not Eligible then
      Exit;                // one request in flight: the pool tries another
    try
      FLastBody := nil;
      Result := FH1.Send(ARequest);
      FLastBody := Result.Body;
      AAcquired := True;
    except
      // a failed exchange leaves the HTTP/1.1 stream unusable (a half-read
      // response would desynchronize the next one): close and let the pool
      // drop the connection instead of reusing it
      FClosing := True;
      FH1.Close;
      raise;
    end;
  finally
    FLock.Release;
  end;
end;

function THttp1PooledConnection.Resume(const ARequest: TStreamRequest;
  const AStatusLine: string): IHttpResponse;
begin
  FLock.Acquire;
  try
    try
      Result := FH1.ResumeResponse(ARequest, AStatusLine);
      FLastBody := Result.Body;
    except
      // a half-read response leaves the stream unusable
      FClosing := True;
      FH1.Close;
      raise;
    end;
  finally
    FLock.Release;
  end;
end;

function THttp1PooledConnection.AcquireUpgraded(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer): IHttpResponse;
begin
  // an h2c upgrade only ever runs on a freshly created HTTP/2 connection; a
  // pooled HTTP/1.1 entry can never adopt stream 1
  raise EHttpProtocolError.Create(
    'an HTTP/1.1 pooled connection cannot adopt an h2c upgrade stream',
    ecProtocolError);
end;

procedure THttp1PooledConnection.Drain;
begin
  FLock.Acquire;
  try
    FClosing := True;
    if ActiveStreams = 0 then
      FH1.Close;
  finally
    FLock.Release;
  end;
end;

procedure THttp1PooledConnection.ReleaseIfIdle;
begin
  FLock.Acquire;
  try
    if FClosing and (ActiveStreams = 0) then
      FH1.Close;
  finally
    FLock.Release;
  end;
end;

function THttp1PooledConnection.GetConn: TConnection;
begin
  // an HTTP/1.1 connection has no TConnection; nil marks it non-HTTP/2
  Result := nil;
end;

function THttp1PooledConnection.GetOrigin: string;
begin
  Result := FOrigin;
end;

function THttp1PooledConnection.GetLock: TCriticalSection;
begin
  Result := FLock;
end;

function THttp1PooledConnection.GetKey: Pointer;
begin
  Result := Pointer(FH1);
end;

{ TConnectionPool }

end.
