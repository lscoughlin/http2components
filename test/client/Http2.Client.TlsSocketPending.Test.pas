{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, tls, pending, http1, reuse
notes:
  - This unit tests TTlsSocket.HasPendingInput against a real OpenSSL peer.
  - A TLS 1.3 NewSessionTicket alone is not pending input.
---
}
unit Http2.Client.TlsSocketPending.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  mormot.lib.openssl11, mormot.core.os,
  Http2.Client.Errors, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1,
  Http2.Client.Pool.Types, Http2.Client.Pool.Http1,
  Http2.Client.Tls.Types, Http2.Client.Tls.Plain, Http2.Client.Tls.Socket,
  Http2.Client.Tls.Support, Http2.Client.Test.TlsContext,
  Http2.Client.Test.OpenSSL.SigPipe,
  Http2.Common.Tls.Session, Http2.Common.Tls.Types;

type
  TPeerScript = (psIdle, psTicketThenLater, psTwoRecords, psCloseNotify,
    psHttpThenStray);

  /// a real OpenSSL server: it handshakes, runs one script and then waits
  /// until the test lets it close
  TPeerServer = class(TThread)
  private
    FListenFd: Integer;
    FScript: TPeerScript;
    FMaxTls12: Boolean;
    FRelease, FDone: TEvent;
    procedure Say(const ASsl: PSSL; const AText: AnsiString);
    procedure RunScript(const ASsl: PSSL);
  protected
    procedure Execute; override;
  public
    constructor Create(const AListenFd: Integer; const AScript: TPeerScript;
      const AMaxTls12: Boolean);
    destructor Destroy; override;
    /// lets the script send its second step
    procedure Release;
    /// lets the server close the connection
    procedure Finish;
  end;

  /// a transport that counts the bytes that the TLS socket reads
  TProbeTransport = class(TInterfacedObject, IHttp2Socket, IPartialReader,
    IPendingInput)
  private
    FInner: IHttp2Socket;
    FBytesRead: Integer;
  public
    constructor Create(const AInner: IHttp2Socket);
    function Read(var ABuffer; ACount: Integer): Integer;
    function ReadSome(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function HasPendingInput: Boolean;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
    property BytesRead: Integer read FBytesRead;
  end;

  TTlsSocketPendingTest = class(TTestCase)
  private
    FListenFd: Integer;
    FPort: Word;
    FServer: TPeerServer;
    FProbe: TProbeTransport;
    FSocket: IHttp2Socket;
    function Start(const AScript: TPeerScript;
      const AMaxTls12: Boolean): Boolean;
    procedure WaitReadable;
    function ReadText(const ACount: Integer): string;
  protected
    procedure TearDown; override;
  published
    procedure TestNoDataIsNotPending;
    procedure TestSecondRecordIsPending;
    procedure TestSessionTicketAloneIsNotPending;
    procedure TestCloseNotifyIsPending;
    procedure TestPooledHttp1ConnectionWithStrayBodyIsNotReused;
  end;

implementation

const
  cWaitMs = 5000;

{ TPeerServer }

constructor TPeerServer.Create(const AListenFd: Integer;
  const AScript: TPeerScript; const AMaxTls12: Boolean);
begin
  inherited Create(True);
  FListenFd := AListenFd;
  FScript := AScript;
  FMaxTls12 := AMaxTls12;
  FRelease := TEvent.Create(nil, True, False, '');
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TPeerServer.Destroy;
begin
  FDone.Free;
  FRelease.Free;
  inherited Destroy;
end;

procedure TPeerServer.Release;
begin
  FRelease.SetEvent;
end;

procedure TPeerServer.Finish;
begin
  FDone.SetEvent;
  FRelease.SetEvent;
end;

procedure TPeerServer.Say(const ASsl: PSSL; const AText: AnsiString);
begin
  TestSslWrite(ASsl, PAnsiChar(AText), Length(AText));
end;

procedure TPeerServer.RunScript(const ASsl: PSSL);
var
  Request: AnsiString;
  C: AnsiChar;
begin
  case FScript of
    psIdle:
      ;   // nothing follows the handshake
    psTicketThenLater:
      begin
        // the TLS 1.3 server sent its tickets at the end of the handshake;
        // it sends nothing else until the test releases it
        FRelease.WaitFor(cWaitMs);
        Say(ASsl, 'after');
      end;
    psTwoRecords:
      begin
        Say(ASsl, 'AAAA');
        Say(ASsl, 'BBBB');
      end;
    psCloseNotify:
      TestSslShutdown(ASsl);
    psHttpThenStray:
      begin
        Request := '';
        while Pos(#13#10#13#10, Request) = 0 do
        begin
          if TestSslRead(ASsl, @C, 1) <> 1 then
            Exit;
          Request := Request + C;
        end;
        Say(ASsl, 'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok');
        FRelease.WaitFor(cWaitMs);
        Say(ASsl, 'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10 +
          'evil!');
      end;
  end;
end;

procedure TPeerServer.Execute;
var
  Ctx: PSSL_CTX;
  Ssl: PSSL;
  Fd: Integer;
  Opt: LongInt;
begin
  if not OpenSslIsAvailable then
    Exit;
  Fd := fpAccept(FListenFd, nil, nil);
  if Fd < 0 then
    Exit;
  Opt := 1;
{$IFDEF DARWIN}
  fpSetSockOpt(Fd, SOL_SOCKET, SO_NOSIGPIPE, @Opt, SizeOf(Opt));
{$ENDIF}
  Ctx := SSL_CTX_new(TLS_server_method());
  try
    SSL_CTX_use_certificate_file(Ctx,
      PUtf8Char(UTF8String(TestCertPath('localhost.crt'))), SSL_FILETYPE_PEM);
    SSL_CTX_use_PrivateKey_file(Ctx,
      PUtf8Char(UTF8String(TestCertPath('localhost.key'))), SSL_FILETYPE_PEM);
    if FMaxTls12 then
    begin
      // TLS 1.2 without tickets: nothing follows the handshake
      SSL_CTX_set_max_proto_version(Ctx, TLS1_2_VERSION);
      SSL_CTX_set_options(Ctx, SSL_OP_NO_TICKET);
    end;
    Ssl := SSL_new(Ctx);
    SSL_set_fd(Ssl, Fd);
    try
      if TestSslAccept(Ssl) = 1 then
        RunScript(Ssl);
      FDone.WaitFor(cWaitMs);
    finally
      SSL_free(Ssl);
    end;
  finally
    SSL_CTX_free(Ctx);
    fpClose(Fd);
  end;
end;

{ TProbeTransport }

constructor TProbeTransport.Create(const AInner: IHttp2Socket);
begin
  inherited Create;
  FInner := AInner;
end;

function TProbeTransport.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := FInner.Read(ABuffer, ACount);
  if Result > 0 then
    Inc(FBytesRead, Result);
end;

function TProbeTransport.ReadSome(var ABuffer; ACount: Integer): Integer;
begin
  Result := (FInner as IPartialReader).ReadSome(ABuffer, ACount);
  if Result > 0 then
    Inc(FBytesRead, Result);
end;

function TProbeTransport.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := FInner.Write(ABuffer, ACount);
end;

procedure TProbeTransport.Close;
begin
  FInner.Close;
end;

function TProbeTransport.HasPendingInput: Boolean;
begin
  Result := (FInner as IPendingInput).HasPendingInput;
end;

function TProbeTransport.GetConnected: Boolean;
begin
  Result := FInner.Connected;
end;

function TProbeTransport.GetConnectTimeoutMs: Integer;
begin
  Result := FInner.ConnectTimeoutMs;
end;

procedure TProbeTransport.SetConnectTimeoutMs(const AValue: Integer);
begin
  FInner.ConnectTimeoutMs := AValue;
end;

function TProbeTransport.GetReadTimeoutMs: Integer;
begin
  Result := FInner.ReadTimeoutMs;
end;

procedure TProbeTransport.SetReadTimeoutMs(const AValue: Integer);
begin
  FInner.ReadTimeoutMs := AValue;
end;

function TProbeTransport.GetWriteTimeoutMs: Integer;
begin
  Result := FInner.WriteTimeoutMs;
end;

procedure TProbeTransport.SetWriteTimeoutMs(const AValue: Integer);
begin
  FInner.WriteTimeoutMs := AValue;
end;

{ TTlsSocketPendingTest }

function TTlsSocketPendingTest.Start(const AScript: TPeerScript;
  const AMaxTls12: Boolean): Boolean;
var
  Info: IHttp2TlsSocketInfo;
  Want: TTlsVersion;
begin
  Result := False;
  if not OpenSslIsAvailable then
    Exit;
  if not (FileExists(TestCertPath('localhost.crt')) and
          FileExists(TestCertPath('localhost.key'))) then
    Exit;
  AssertTrue('listener', MakeLoopbackListener(FListenFd, FPort));
  FServer := TPeerServer.Create(FListenFd, AScript, AMaxTls12);
  FServer.Start;
  FProbe := TProbeTransport.Create(
    TPlainSocket.Create('127.0.0.1', FPort, cWaitMs));
  FSocket := TTlsSocket.Create(FProbe, 'localhost',
    OpenSslClientTestContext('', True), nil, ['http/1.1'], cWaitMs);
  AssertTrue('TLS info', Supports(FSocket, IHttp2TlsSocketInfo, Info));
  if AMaxTls12 then
    Want := tls12
  else
    Want := tls13;
  // the version proves that the peer is in the intended mode
  AssertTrue('negotiated version', Info.NegotiatedTlsInfo.Version = Want);
  Result := True;
end;

/// a bounded wait until the kernel reports input on the transport; it does not
// read from the TLS socket
procedure TTlsSocketPendingTest.WaitReadable;
var
  Limit: QWord;
begin
  Limit := GetTickCount64 + cWaitMs;
  while not FProbe.HasPendingInput and (GetTickCount64 < Limit) do
    Sleep(1);
  AssertTrue('the peer sent bytes', FProbe.HasPendingInput);
end;

function TTlsSocketPendingTest.ReadText(const ACount: Integer): string;
var
  Buffer: array[0..255] of AnsiChar;
  N: Integer;
begin
  N := FSocket.Read(Buffer[0], ACount);
  SetString(Result, PAnsiChar(@Buffer[0]), N);
end;

procedure TTlsSocketPendingTest.TearDown;
begin
  if FServer <> nil then
    FServer.Finish;
  if FSocket <> nil then
    FSocket.Close;
  FSocket := nil;
  FProbe := nil;
  if FServer <> nil then
  begin
    FServer.WaitFor;
    FServer.Free;
    FServer := nil;
  end;
  if FListenFd <> 0 then
    fpClose(FListenFd);
  FListenFd := 0;
  inherited TearDown;
end;

procedure TTlsSocketPendingTest.TestNoDataIsNotPending;
var
  Pending: IPendingInput;
  Before: Integer;
begin
  if not Start(psIdle, True) then
    Exit;
  AssertTrue('the socket reports pending input',
    Supports(FSocket, IPendingInput, Pending));
  Before := FProbe.BytesRead;
  AssertFalse('an idle session has no pending input', Pending.HasPendingInput);
  AssertEquals('the check read nothing', Before, FProbe.BytesRead);
end;

procedure TTlsSocketPendingTest.TestSecondRecordIsPending;
var
  Pending: IPendingInput;
begin
  if not Start(psTwoRecords, False) then
    Exit;
  Supports(FSocket, IPendingInput, Pending);
  // the client reads one octet; the rest stays in the session or the socket
  AssertEquals('first octet', 'A', ReadText(1));
  AssertTrue('decrypted octets remain', Pending.HasPendingInput);
  AssertEquals('no octet is lost', 'AAABBBB', ReadText(7));
end;

procedure TTlsSocketPendingTest.TestSessionTicketAloneIsNotPending;
var
  Pending: IPendingInput;
  Before: Integer;
begin
  if not Start(psTicketThenLater, False) then
    Exit;
  Supports(FSocket, IPendingInput, Pending);
  // the peer sent its NewSessionTicket records and nothing else
  WaitReadable;
  Before := FProbe.BytesRead;
  AssertFalse('a session ticket is not pending input', Pending.HasPendingInput);
  AssertTrue('the check consumed the ticket bytes', FProbe.BytesRead > Before);
  AssertFalse('still not pending', Pending.HasPendingInput);
  FServer.Release;
  WaitReadable;
  AssertTrue('data after the ticket is pending', Pending.HasPendingInput);
  AssertEquals('the data is not lost', 'after', ReadText(5));
end;

procedure TTlsSocketPendingTest.TestCloseNotifyIsPending;
var
  Pending: IPendingInput;
  Buffer: Byte;
  Limit: QWord;
begin
  if not Start(psCloseNotify, False) then
    Exit;
  Supports(FSocket, IPendingInput, Pending);
  WaitReadable;
  // the tickets and the alert can arrive in separate segments: the query that
  // consumes only the tickets reports no pending input, so the test polls
  Limit := GetTickCount64 + cWaitMs;
  while not Pending.HasPendingInput and (GetTickCount64 < Limit) do
    Sleep(1);
  AssertTrue('an alert is pending input', Pending.HasPendingInput);
  AssertEquals('the end of stream follows', 0, FSocket.Read(Buffer, 1));
end;

procedure TTlsSocketPendingTest.TestPooledHttp1ConnectionWithStrayBodyIsNotReused;
var
  H1: THttp1Connection;
  Wire: IPooledConnection;
  Req: TStreamRequest;
  R: IHttpResponse;
  Acquired: Boolean;
  Buf: array[0..255] of Byte;
  N: Integer;
begin
  if not Start(psHttpThenStray, False) then
    Exit;
  H1 := THttp1Connection.Create(FSocket, 2000);
  Wire := THttp1PooledConnection.Create(H1, 'https://localhost');
  Req := TStreamRequest.Create('GET', 'localhost').WithScheme('https')
    .WithPath('/x');
  R := Wire.Acquire(Req, 2000, Acquired);
  AssertTrue('the first request was acquired', Acquired);
  repeat
    N := R.Body.Read(Buf[0], SizeOf(Buf));
  until N <= 0;
  AssertTrue('the first body reached its end', R.Body.Eof);
  R := nil;
  // the stray response comes in a later record and stays in the TLS session
  FServer.Release;
  WaitReadable;
  R := Wire.Acquire(Req, 2000, Acquired);
  AssertFalse('the connection with a stray body is not reused', Acquired);
  R := nil;
  Wire := nil;
end;

initialization
  RegisterTest(TTlsSocketPendingTest);
end.
