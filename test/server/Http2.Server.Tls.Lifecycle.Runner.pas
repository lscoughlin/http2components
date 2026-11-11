{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, server, lifecycle, raw transport, test
notes:
  - This runner checks bounded raw listener lifecycle cases with fake sessions.
---
}
program Http2.Server.Tls.Lifecycle.Runner;
{$mode delphi}{$H+}{$interfaces com}
uses {$IFDEF UNIX}cthreads, Sockets,{$ENDIF} SysUtils, SyncObjs, fpcunit,
  testregistry, consoletestrunner, mormot.core.os, mormot.core.base,
  mormot.net.sock, Http2.Server, Http2.Common.Tls.Types,
  Http2.Common.Tls.Context, Http2.Common.Tls.Session, Http2.Common.Tls.Policy,
  Http2.Server.Tls.Binding, Http2.Server.Tls.Adapter,
  Http2.Test.Tls.Fake;

type
  TObservedContext = class(TInterfacedObject, ITLSContext,
    ITlsFakeContextControl)
  private
    FInner: ITLSContext;
    FLock: TCriticalSection;
    FServerSessions: Integer;
    FMaxPlainWrite: SizeInt;
    FZeroWriteCall, FWriteCalls: Integer;
    FPendingOutputHold, FPendingOutputActive: Boolean;
    FPlainAccepted: RawByteString;
  public
    constructor Create(const AInner: ITLSContext);
    destructor Destroy; override;
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function Lifetime: ITlsFakeLifetime;
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
    function ServerSessionCount: Integer;
    procedure SetPlainWritePolicy(const AMaxBytes: SizeInt;
      const AZeroCall: Integer);
    function PlainWriteLimit(const ARequested: SizeInt): SizeInt;
    procedure SetPendingOutputHold(const AEnabled: Boolean);
    procedure HoldPendingOutput;
    procedure ReleasePendingOutput;
    function PendingOutputHeld: Boolean;
    procedure RecordPlaintext(const ABuffer: TBytes; const AOffset,
      ACount: SizeInt);
    function AcceptedPlaintext: RawByteString;
  end;

  TObservedSession = class(TInterfacedObject, ITLSSession)
  private
    FInner: ITLSSession;
    FContext: TObservedContext;
  public
    constructor Create(const AInner: ITLSSession;
      const AContext: TObservedContext);
    function State: TTlsSessionState;
    function FeedEncrypted(const ABuffer: TBytes; const AOffset,
      ACount: SizeInt): SizeInt;
    function DrainEncrypted(var ABuffer: TBytes; const AOffset,
      ACapacity: SizeInt): SizeInt;
    function WritePlaintext(const ABuffer: TBytes; const AOffset,
      ACount: SizeInt): SizeInt;
    function ReadPlaintext(var ABuffer: TBytes; const AOffset,
      ACapacity: SizeInt): SizeInt;
    function Advance(const AMonotonicMs: Int64): TTlsProgress;
    procedure NotifyTransportEof;
    procedure BeginShutdown;
    procedure Abort;
    function NegotiatedInfo: TTlsNegotiatedInfo;
  end;

  TTlsLifecycleHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  TTlsRawLifecycleTest = class(TTestCase)
  published
    procedure StopClosesAnAcceptedHeldHandshake;
    procedure TwoBindingsKeepTheirSessionsSeparate;
    procedure FailedStartLeavesTheExistingListenerRunning;
    procedure SilentAndTricklingPeersMeetTheAcceptDeadline;
    procedure StrictH2AlpnRoutesToHttp2;
    procedure StrictMissingAndUnsupportedAlpnAreRejected;
    procedure Http11AlpnFallbackRoutesRequests;
    procedure MissingAlpnFallbackRoutesRequests;
    procedure FatalHandshakeErrorDrainsAlertBeforeClose;
    procedure PeerCloseDrainsItsResponseBeforeClose;
    procedure PartialTlsPlaintextRetriesAfterLaterRead;
    procedure PendingProviderOutputBlocksGracefulCloseDrain;
  end;

constructor TObservedContext.Create(const AInner: ITLSContext);
begin
  inherited Create;
  FInner := AInner;
  FLock := TCriticalSection.Create;
end;

destructor TObservedContext.Destroy;
begin
  FInner := nil;
  FLock.Free;
  inherited Destroy;
end;

function TObservedContext.BackendName: string;
begin Result := FInner.BackendName; end;
function TObservedContext.Capabilities: TTlsCapabilities;
begin Result := FInner.Capabilities; end;
function TObservedContext.Info: TTlsContextInfo;
begin Result := FInner.Info; end;
function TObservedContext.Lifetime: ITlsFakeLifetime;
var Control: ITlsFakeContextControl;
begin
  if not Supports(FInner, ITlsFakeContextControl, Control) then
    raise Exception.Create('the inner fake context has no lifetime control');
  Result := Control.Lifetime;
  Control := nil;
end;
function TObservedContext.CreateClientSession(
  const AOptions: TTlsClientSessionOptions): ITLSSession;
begin Result := FInner.CreateClientSession(AOptions); end;
function TObservedContext.CreateServerSession(
  const AOptions: TTlsServerSessionOptions): ITLSSession;
begin
  Result := FInner.CreateServerSession(AOptions);
  Result := TObservedSession.Create(Result, Self);
  FLock.Acquire;
  try Inc(FServerSessions);
  finally FLock.Release; end;
end;
function TObservedContext.ServerSessionCount: Integer;
begin
  FLock.Acquire;
  try Result := FServerSessions;
  finally FLock.Release; end;
end;

procedure TObservedContext.SetPlainWritePolicy(const AMaxBytes: SizeInt;
  const AZeroCall: Integer);
begin
  FLock.Acquire;
  try
    FMaxPlainWrite := AMaxBytes;
    FZeroWriteCall := AZeroCall;
    FWriteCalls := 0;
    FPlainAccepted := '';
  finally FLock.Release; end;
end;
procedure TObservedContext.RecordPlaintext(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt);
var I, OldLength: SizeInt;
begin
  if ACount <= 0 then Exit;
  FLock.Acquire;
  try
    OldLength := Length(FPlainAccepted);
    SetLength(FPlainAccepted, OldLength + ACount);
    for I := 0 to ACount - 1 do
      FPlainAccepted[OldLength + I + 1] := AnsiChar(ABuffer[AOffset + I]);
  finally FLock.Release; end;
end;
function TObservedContext.AcceptedPlaintext: RawByteString;
begin
  FLock.Acquire;
  try Result := FPlainAccepted;
  finally FLock.Release; end;
end;
procedure TObservedContext.SetPendingOutputHold(const AEnabled: Boolean);
begin
  FLock.Acquire;
  try FPendingOutputHold := AEnabled;
  finally FLock.Release; end;
end;
procedure TObservedContext.HoldPendingOutput;
begin
  FLock.Acquire;
  try
    FPendingOutputActive := FPendingOutputHold;
  finally FLock.Release; end;
end;
procedure TObservedContext.ReleasePendingOutput;
begin
  FLock.Acquire;
  try FPendingOutputActive := False;
  finally FLock.Release; end;
end;
function TObservedContext.PendingOutputHeld: Boolean;
begin
  FLock.Acquire;
  try Result := FPendingOutputActive;
  finally FLock.Release; end;
end;
function TObservedContext.PlainWriteLimit(
  const ARequested: SizeInt): SizeInt;
begin
  FLock.Acquire;
  try
    Inc(FWriteCalls);
    if (FZeroWriteCall > 0) and (FWriteCalls = FZeroWriteCall) then
      Exit(0);
    Result := ARequested;
    if (FMaxPlainWrite > 0) and (Result > FMaxPlainWrite) then
      Result := FMaxPlainWrite;
  finally FLock.Release; end;
end;

constructor TObservedSession.Create(const AInner: ITLSSession;
  const AContext: TObservedContext);
begin
  inherited Create;
  FInner := AInner;
  FContext := AContext;
end;
function TObservedSession.State: TTlsSessionState;
begin Result := FInner.State; end;
function TObservedSession.FeedEncrypted(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin Result := FInner.FeedEncrypted(ABuffer, AOffset, ACount); end;
function TObservedSession.DrainEncrypted(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin Result := FInner.DrainEncrypted(ABuffer, AOffset, ACapacity); end;
function TObservedSession.WritePlaintext(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
var Limit: SizeInt;
begin
  Limit := FContext.PlainWriteLimit(ACount);
  if Limit = 0 then Exit(0);
  Result := FInner.WritePlaintext(ABuffer, AOffset, Limit);
  FContext.RecordPlaintext(ABuffer, AOffset, Result);
end;
function TObservedSession.ReadPlaintext(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin Result := FInner.ReadPlaintext(ABuffer, AOffset, ACapacity); end;
function TObservedSession.Advance(const AMonotonicMs: Int64): TTlsProgress;
begin
  Result := FInner.Advance(AMonotonicMs);
  if FContext.PendingOutputHeld then
    Result.PendingPlaintextOutput := 1;
end;
procedure TObservedSession.NotifyTransportEof;
begin FInner.NotifyTransportEof; end;
procedure TObservedSession.BeginShutdown;
begin
  FInner.BeginShutdown;
  FContext.HoldPendingOutput;
end;
procedure TObservedSession.Abort;
begin FInner.Abort; end;
function TObservedSession.NegotiatedInfo: TTlsNegotiatedInfo;
begin Result := FInner.NegotiatedInfo; end;

procedure TTlsLifecycleHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(TBytes([79, 75]));
  AResponse.Finish;
end;

function Factory(const AContext: ITLSContext; const APort: Integer = 0;
  const AAllowHttp11: Boolean = True): THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create.WithHost('127.0.0.1')
    .WithPort(APort).WithClearTextAllowed(True).WithTlsContext(AContext)
    .WithHttp11Fallback(AAllowHttp11)
    .WithHandler(TTlsLifecycleHandler.Create).WithIOThreads(1)
    .WithHandlerThreads(1).WithGracefulStopTimeout(200);
end;

function NewContext(const ATimeoutMs: Cardinal; const AHold: Boolean;
  out AObserved: TObservedContext; const ASelectedAlpn: string = 'h2'): ITLSContext;
begin
  AObserved := TObservedContext.Create(
    TTlsFakeContext.Create([trServer], tlsAuthNone, ATimeoutMs, AHold,
      ASelectedAlpn));
  Result := AObserved;
end;

function FakeLifetime(const AContext: ITLSContext): ITlsFakeLifetime;
var Control: ITlsFakeContextControl;
begin
  if not Supports(AContext, ITlsFakeContextControl, Control) then
    raise Exception.Create('the fake context has no lifetime control');
  Result := Control.Lifetime;
  Control := nil;
end;

function BuildServer(const AContext: ITLSContext;
  const APort: Integer = 0): IHttp2Server;
begin
  Result := Factory(AContext, APort).Build;
end;

function OpenRaw(const APort: Integer): TCrtSocket;
begin
  Result := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, 1500);
end;

procedure SendTlsPrefix(const ASocket: TCrtSocket);
begin
  ASocket.SockSendFlush(RawByteString(#$16#$03#$03#$00#$01#$00));
end;

function WaitForServerSession(const AContext: TObservedContext;
  const ATimeoutMs: Integer): Boolean; forward;

procedure CompleteFakeHandshake(const ASocket: TCrtSocket;
  const AContext: TObservedContext);
begin
  SendTlsPrefix(ASocket);
  if not WaitForServerSession(AContext, 1000) then
    raise Exception.Create('the server did not create a TLS session');
  ASocket.SockSendFlush(RawByteString(#$FC));
end;

function ReadHttpResponse(const ASocket: TCrtSocket;
  const ATimeoutMs: Integer): string;
var Deadline: QWord; Pending: TCrtSocketPending; Data: RawByteString;
begin
  Result := '';
  Deadline := mormot.core.os.GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pending := ASocket.SockReceivePending(0);
    if Pending in [cspSocketError, cspSocketClosed] then Break;
    if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
    begin
      Data := ASocket.SockReceiveString;
      Result := Result + string(Data);
      if Pos('HTTP/1.1 200', Result) > 0 then Exit;
    end
    else
      Sleep(10);
  until mormot.core.os.GetTickCount64 >= Deadline;
end;

function CountText(const AText, APattern: RawByteString): Integer;
var Start, Found: SizeInt;
begin
  Result := 0;
  Start := 1;
  repeat
    Found := Pos(APattern, Copy(AText, Start, MaxInt));
    if Found = 0 then Exit;
    Inc(Result);
    Start := Start + Found + Length(APattern) - 1;
  until Start > Length(AText);
end;

function ReadAtLeast(const ASocket: TCrtSocket; const AWanted,
  ATimeoutMs: Integer): RawByteString;
var Deadline: QWord; Pending: TCrtSocketPending;
begin
  Result := '';
  Deadline := mormot.core.os.GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pending := ASocket.SockReceivePending(0);
    if Pending in [cspSocketError, cspSocketClosed] then Exit;
    if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
      Result := Result + ASocket.SockReceiveString
    else
      Sleep(5);
  until (Length(Result) >= AWanted) or
    (mormot.core.os.GetTickCount64 >= Deadline);
end;

function ReadMore(const ASocket: TCrtSocket; var AData: RawByteString;
  const AWanted, ATimeoutMs: Integer): Boolean;
var Deadline: QWord; Pending: TCrtSocketPending;
begin
  Deadline := mormot.core.os.GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pending := ASocket.SockReceivePending(0);
    if Pending in [cspSocketError, cspSocketClosed] then Break;
    if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
      AData := AData + ASocket.SockReceiveString
    else
      Sleep(5);
  until (Length(AData) >= AWanted) or
    (mormot.core.os.GetTickCount64 >= Deadline);
  Result := Length(AData) >= AWanted;
end;

function SocketClosed(const ASocket: TCrtSocket): Boolean;
var Pending: TCrtSocketPending; Data: RawByteString;
begin
  Pending := ASocket.SockReceivePending(0);
  Result := Pending in [cspSocketError, cspSocketClosed];
  if Pending = cspDataAvailableOnClosedSocket then
  begin
    Data := ASocket.SockReceiveString;
    Result := Data = '';
  end;
end;

function WaitForClosed(const ASocket: TCrtSocket;
  const ATimeoutMs: Integer): Boolean;
var Deadline: QWord;
begin
  Deadline := mormot.core.os.GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if SocketClosed(ASocket) then Exit(True);
    Sleep(10);
  until mormot.core.os.GetTickCount64 >= Deadline;
  Result := SocketClosed(ASocket);
end;

function WaitForServerSession(const AContext: TObservedContext;
  const ATimeoutMs: Integer): Boolean;
var Deadline: QWord;
begin
  Deadline := mormot.core.os.GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if AContext.ServerSessionCount > 0 then Exit(True);
    Sleep(5);
  until mormot.core.os.GetTickCount64 >= Deadline;
  Result := AContext.ServerSessionCount > 0;
end;

procedure TTlsRawLifecycleTest.StopClosesAnAcceptedHeldHandshake;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Life: ITlsFakeLifetime;
begin
  Context := NewContext(2500, True, Observed);
  Life := FakeLifetime(Context);
  Server := BuildServer(Context);
  Server.Start;
  Context := nil;
  Socket := OpenRaw(Server.Port);
  try
    SendTlsPrefix(Socket);
    AssertTrue('the accept creates one server session',
      WaitForServerSession(Observed, 1000));
    Server.Stop;
    AssertTrue('stop closes the peer with a held handshake',
      WaitForClosed(Socket, 1200));
    AssertTrue('the listener retains its TLS context after caller release',
      Life.IsAlive);
  finally
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
  AssertFalse('the TLS context is released when the listener ends', Life.IsAlive);
end;

procedure TTlsRawLifecycleTest.TwoBindingsKeepTheirSessionsSeparate;
var Context1, Context2: ITLSContext; Observed1, Observed2: TObservedContext;
    Server1, Server2: IHttp2Server; Socket1, Socket2: TCrtSocket;
    Life1, Life2: ITlsFakeLifetime;
begin
  Context1 := NewContext(2500, True, Observed1);
  Context2 := NewContext(2500, True, Observed2);
  Life1 := FakeLifetime(Context1);
  Life2 := FakeLifetime(Context2);
  Server1 := BuildServer(Context1);
  Server2 := BuildServer(Context2);
  Server1.Start;
  Server2.Start;
  Context1 := nil;
  Context2 := nil;
  Socket1 := OpenRaw(Server1.Port);
  Socket2 := OpenRaw(Server2.Port);
  try
    SendTlsPrefix(Socket1);
    SendTlsPrefix(Socket2);
    AssertTrue('the first listener owns a session',
      WaitForServerSession(Observed1, 1000));
    AssertTrue('the second listener owns a session',
      WaitForServerSession(Observed2, 1000));
    Server1.Stop;
    AssertTrue('the first listener closes its own peer',
      WaitForClosed(Socket1, 1200));
    Server1 := nil;
    Context1 := nil;
    AssertFalse('stopping one listener releases only its own context',
      Life1.IsAlive);
    AssertTrue('the second listener retains its context', Life2.IsAlive);
    AssertFalse('stopping one binding leaves the other peer open',
      WaitForClosed(Socket2, 150));
  finally
    Server2.Stop;
    Socket2.Free;
    Socket1.Free;
    Server1 := nil;
    Server2 := nil;
    Context1 := nil;
    Context2 := nil;
  end;
  AssertFalse('the second context is released at its listener end',
    Life2.IsAlive);
end;

procedure TTlsRawLifecycleTest.FailedStartLeavesTheExistingListenerRunning;
var Context1, Context2: ITLSContext; Observed1, Observed2: TObservedContext;
    Server1, Server2: IHttp2Server; Failed: Boolean; Reserved: TSocket;
    Address: TInetSockAddr; AddressLen: TSockLen; ReservedPort: Integer;
begin
  Reserved := -1;
  Server1 := nil;
  Server2 := nil;
  Context1 := NewContext(2500, True, Observed1);
  Context2 := NewContext(2500, True, Observed2);
  try
    Server1 := Factory(Context1).Build;
    Server1.Start;
    Reserved := fpsocket(AF_INET, SOCK_STREAM, 0);
    AssertTrue('the port reservation socket opens', Reserved >= 0);
    FillByte(Address, SizeOf(Address), 0);
    Address.sin_family := AF_INET;
    Address.sin_port := htons(0);
    Address.sin_addr.s_addr := htonl(LongWord($7F000001));
    AssertEquals('the raw socket reserves a loopback port', 0,
      fpbind(Reserved, @Address, SizeOf(Address)));
    AssertEquals('the raw socket listens on the reserved port', 0,
      fplisten(Reserved, 1));
    AddressLen := SizeOf(Address);
    AssertEquals('the reserved port is readable', 0,
      fpgetsockname(Reserved, @Address, @AddressLen));
    ReservedPort := ntohs(Address.sin_port);
    Server2 := Factory(Context2, ReservedPort).Build;
    Failed := False;
    try
      Server2.Start;
    except
      on Exception do Failed := True;
    end;
    AssertTrue('a reserved listener start fails', Failed);
    AssertFalse('the failed listener is not running', Server2.IsRunning);
    Server2.Stop;
    Server2 := nil;
    AssertTrue('failed start cleanup leaves the original listener running',
      Server1.IsRunning);
  finally
    if Reserved >= 0 then CloseSocket(Reserved);
    if Server2 <> nil then Server2.Stop;
    if Server1 <> nil then Server1.Stop;
    Server1 := nil;
    Server2 := nil;
    Context1 := nil;
    Context2 := nil;
  end;
end;

procedure TTlsRawLifecycleTest.SilentAndTricklingPeersMeetTheAcceptDeadline;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Silent, Busy: TCrtSocket; Deadline: QWord; BusyClosed, SilentClosed: Boolean;
begin
  Context := NewContext(250, True, Observed);
  Server := Factory(Context).Build;
  Server.Start;
  Silent := OpenRaw(Server.Port);
  Busy := OpenRaw(Server.Port);
  try
    SendTlsPrefix(Busy);
    AssertTrue('the busy peer reaches a held server handshake',
      WaitForServerSession(Observed, 1000));
    Deadline := mormot.core.os.GetTickCount64 + 2500;
    BusyClosed := False;
    SilentClosed := False;
    while (mormot.core.os.GetTickCount64 < Deadline) and
          not (SilentClosed and BusyClosed) do
    begin
      SilentClosed := SocketClosed(Silent);
      BusyClosed := SocketClosed(Busy);
      if not BusyClosed then
        try Busy.SockSendFlush(RawByteString(#$03)); except on Exception do BusyClosed := True; end;
      Sleep(40);
    end;
    AssertTrue('a silent peer expires from accept time', SilentClosed);
    AssertTrue('trickling handshake bytes do not extend the deadline',
      BusyClosed or SocketClosed(Busy));
  finally
    Server.Stop;
    Silent.Free;
    Busy.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.StrictH2AlpnRoutesToHttp2;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Response: RawByteString; PayloadLength: Integer;
begin
  Context := NewContext(250, True, Observed, 'h2');
  Server := Factory(Context, 0, False).Build;
  Server.Start;
  Socket := OpenRaw(Server.Port);
  try
    CompleteFakeHandshake(Socket, Observed);
    Sleep(1200);
    AssertFalse('the handshake deadline no longer applies to an open session',
      SocketClosed(Socket));
    Socket.SockSendFlush('PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10+
      #$00#$00#$00#$04#$00#$00#$00#$00#$00);
    Response := ReadAtLeast(Socket, 13, 1000);
    AssertTrue('the server sends the handshake and SETTINGS header',
      Length(Response) >= 13);
    AssertEquals('the fake handshake response has four bytes', $16,
      Ord(Response[1]));
    AssertEquals('the server sends a SETTINGS frame after ALPN h2', $04,
      Ord(Response[8]));
    PayloadLength := (Ord(Response[5]) shl 16) or
      (Ord(Response[6]) shl 8) or Ord(Response[7]);
    AssertEquals('SETTINGS payload contains whole six-byte values', 0,
      PayloadLength mod 6);
    AssertTrue('the whole SETTINGS payload arrives',
      ReadMore(Socket, Response, 13 + PayloadLength, 1000));
    AssertEquals('the SETTINGS frame uses stream zero', #$00#$00#$00#$00,
      Copy(Response, 10, 4));
  finally
    Server.Stop;
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.StrictMissingAndUnsupportedAlpnAreRejected;
var Selected: array[0..1] of string; I: Integer;
    Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket;
begin
  Selected[0] := '';
  Selected[1] := 'spdy/3';
  for I := 0 to High(Selected) do
  begin
    Context := NewContext(2500, True, Observed, Selected[I]);
    Server := Factory(Context, 0, False).Build;
    Server.Start;
    Socket := OpenRaw(Server.Port);
    try
      CompleteFakeHandshake(Socket, Observed);
      AssertTrue('strict ALPN rejects missing or unsupported selection',
        WaitForClosed(Socket, 1000));
    finally
      Server.Stop;
      Socket.Free;
      Server := nil;
      Context := nil;
    end;
  end;
end;

procedure TTlsRawLifecycleTest.Http11AlpnFallbackRoutesRequests;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Response: string;
begin
  Context := NewContext(2500, True, Observed, 'http/1.1');
  Server := Factory(Context, 0, True).Build;
  Server.Start;
  Socket := OpenRaw(Server.Port);
  try
    CompleteFakeHandshake(Socket, Observed);
    Socket.SockSendFlush('GET / HTTP/1.1'#13#10'Host: localhost'#13#10+
      'Connection: close'#13#10#13#10);
    Response := ReadHttpResponse(Socket, 1500);
    AssertTrue('the fallback route returns HTTP/1.1',
      Pos('HTTP/1.1 200', Response) > 0);
  finally
    Server.Stop;
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.MissingAlpnFallbackRoutesRequests;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Response: string;
begin
  Context := NewContext(2500, True, Observed, '');
  Server := Factory(Context, 0, True).Build;
  Server.Start;
  Socket := OpenRaw(Server.Port);
  try
    CompleteFakeHandshake(Socket, Observed);
    Socket.SockSendFlush('GET / HTTP/1.1'#13#10'Host: localhost'#13#10+
      'Connection: close'#13#10#13#10);
    Response := ReadHttpResponse(Socket, 1500);
    AssertTrue('the missing-ALPN fallback routes HTTP/1.1',
      Pos('HTTP/1.1 200', Response) > 0);
  finally
    Server.Stop;
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.FatalHandshakeErrorDrainsAlertBeforeClose;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Data: RawByteString; Deadline: QWord;
    Pending: TCrtSocketPending;
begin
  Context := NewContext(2500, True, Observed);
  Server := Factory(Context).Build;
  Server.Start;
  Socket := OpenRaw(Server.Port);
  Data := '';
  try
    SendTlsPrefix(Socket);
    AssertTrue('the server creates a session before the fatal input',
      WaitForServerSession(Observed, 1000));
    Socket.SockSendFlush(RawByteString(#$FC));
    Sleep(30);
    Socket.SockSendFlush(RawByteString(#$FF));
    Deadline := mormot.core.os.GetTickCount64 + 1000;
    repeat
      Pending := Socket.SockReceivePending(0);
      if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
        Data := Data + Socket.SockReceiveString
      else if Pending in [cspSocketError, cspSocketClosed] then
        Break
      else
        Sleep(5);
    until mormot.core.os.GetTickCount64 >= Deadline;
    AssertTrue('the fake fatal alert reaches the raw peer before close',
      (Pos(#$15#$02, Data) > 0) or
      ((Pos(#$15, Data) > 0) and (Data[Pos(#$15, Data) + 1] = #$02)));
    AssertTrue('the failed handshake closes after alert output drains',
      WaitForClosed(Socket, 1000));
  finally
    Server.Stop;
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.PeerCloseDrainsItsResponseBeforeClose;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Data: RawByteString; Deadline: QWord;
    Pending: TCrtSocketPending;
begin
  Context := NewContext(2500, True, Observed, 'h2');
  Server := Factory(Context, 0, False).Build;
  Server.Start;
  Socket := OpenRaw(Server.Port);
  Data := '';
  try
    CompleteFakeHandshake(Socket, Observed);
    Socket.SockSendFlush('PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10+
      #$00#$00#$00#$04#$00#$00#$00#$00#$00);
    Data := ReadAtLeast(Socket, 13, 1000);
    AssertTrue('HTTP/2 is selected before peer close', Length(Data) >= 13);
    Socket.SockSendFlush(RawByteString(#$FE));
    Deadline := mormot.core.os.GetTickCount64 + 1000;
    repeat
      Pending := Socket.SockReceivePending(0);
      if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
        Data := Data + Socket.SockReceiveString
      else if Pending in [cspSocketError, cspSocketClosed] then
        Break
      else
        Sleep(5);
    until mormot.core.os.GetTickCount64 >= Deadline;
    AssertTrue('the peer close response drains before raw close',
      Pos(#$15#$00, Data) > 0);
    AssertTrue('the raw connection closes after the response drains',
      WaitForClosed(Socket, 1000));
  finally
    Server.Stop;
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.PartialTlsPlaintextRetriesAfterLaterRead;
var Context: ITLSContext; Observed: TObservedContext; Server: IHttp2Server;
    Socket: TCrtSocket; Data, Accepted: RawByteString; Deadline: QWord;
    Pending: TCrtSocketPending;
begin
  Context := NewContext(2500, True, Observed, 'http/1.1');
  Observed.SetPlainWritePolicy(7, 2);
  Server := Factory(Context, 0, True).Build;
  Server.Start;
  Socket := OpenRaw(Server.Port);
  Data := '';
  try
    CompleteFakeHandshake(Socket, Observed);
    Socket.SockSendFlush('GET /first HTTP/1.1'#13#10'Host: localhost'#13#10#13#10);
    Data := ReadAtLeast(Socket, 7, 1000);
    AssertTrue('the first response reaches the short-write fake',
      Length(Data) >= 7);
    Socket.SockSendFlush('GET /second HTTP/1.1'#13#10'Host: localhost'#13#10+
      'Connection: close'#13#10#13#10);
    Deadline := mormot.core.os.GetTickCount64 + 2500;
    repeat
      Pending := Socket.SockReceivePending(0);
      if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
        Data := Data + Socket.SockReceiveString
      else if Pending in [cspSocketError, cspSocketClosed] then
        Break
      else
        Sleep(5);
    until mormot.core.os.GetTickCount64 >= Deadline;
    AssertEquals('both responses are delivered after a zero and short accept',
      2, CountText(Data, 'HTTP/1.1 200'));
    Accepted := Observed.AcceptedPlaintext;
    AssertTrue('the raw transport has the exact accepted plaintext stream',
      (Length(Data) >= 4 + Length(Accepted)) and
      (Copy(Data, 5, Length(Accepted)) = Accepted));
    AssertTrue('the TLS session closes after the retained suffix drains',
      WaitForClosed(Socket, 1000));
  finally
    Server.Stop;
    Socket.Free;
    Server := nil;
    Context := nil;
  end;
end;

procedure TTlsRawLifecycleTest.PendingProviderOutputBlocksGracefulCloseDrain;
var Context: ITLSContext; Observed: TObservedContext;
    Binding: ITlsServerBinding; Adapter: TServerTlsAdapter;
    Input, Cipher: TBytes; Progress: TTlsProgress; NowMs: Int64;
begin
  Context := NewContext(2500, False, Observed);
  Observed.SetPendingOutputHold(True);
  Binding := NewTlsServerBinding(Context);
  NowMs := mormot.core.os.GetTickCount64;
  Adapter := TServerTlsAdapter.Create(Binding, NowMs, False);
  try
    Input := [$01];
    AssertEquals('fake handshake input is accepted', Length(Input),
      Adapter.FeedEncrypted(Input, 0, Length(Input)));
    Progress := Adapter.Advance(NowMs + 1);
    AssertEquals('the adapter opens before local close', Ord(tssOpen),
      Ord(Progress.State));
    while Adapter.PrepareCipher(Cipher) do
      Adapter.CompleteCipher(True);
    Adapter.BeginShutdown;
    AssertTrue('close output is available from the provider',
      Adapter.PrepareCipher(Cipher));
    Adapter.CompleteCipher(True);
    AssertFalse('the adapter has no more ciphertext to write',
      Adapter.PrepareCipher(Cipher));
    AssertFalse('pending accepted plaintext blocks close completion',
      Adapter.OutputDrained);
    Observed.ReleasePendingOutput;
    AssertFalse('the released provider has no more ciphertext',
      Adapter.PrepareCipher(Cipher));
    AssertTrue('close completion follows provider output completion',
      Adapter.OutputDrained);
  finally
    Adapter.Free;
    Binding := nil;
    Context := nil;
  end;
end;

var App: TTestRunner;
begin
  RegisterTest(TTlsRawLifecycleTest);
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Run;
  finally
    App.Free;
  end;
end.
