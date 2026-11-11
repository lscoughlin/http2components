{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this provides TLS test sockets and loopback peers
---
}
unit Http2.Client.Tls.Support;



{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, sockets, baseunix,
  mormot.lib.openssl11, Http2.Client.Errors, Http2.Client.Tls,
  Http2.Common.Tls.Context, Http2.Common.Tls.Policy, Http2.OpenSSL;

type
  /// a trivial mock byte stream; proves at compile time that a small class can
  /// satisfy IHttp2Socket for later stories
  TMockSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FConnected: Boolean;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
  public
    constructor Create;
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

  TWriterThread = class(TThread)
  private
    FFd: Integer;
    FData: TBytes;
    FDelayMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AFd: Integer; const AData: TBytes;
      const ADelayMs: Integer);
  end;

  /// outcome of a real loopback TLS handshake used by the verification tests
  TRealHandshakeResult = record
    Skipped: Boolean;
    Raised: Boolean;
    Connected: Boolean;
  end;

  /// accepts one connection on a loopback listener and runs a real OpenSSL
  /// server handshake with the test certificate (no ALPN selection)
  TLoopbackTlsServer = class(TThread)
  private
    FListenFd: Integer;
    FAcceptedFd: Integer;
    FHandshakeResult: Integer;
    FCertFile: string;
    FKeyFile: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AListenFd: Integer;
      const ACertFile, AKeyFile: string);
    property HandshakeResult: Integer read FHandshakeResult;
  end;

  /// accepts one connection on a loopback listener, reads the CONNECT request
  /// and replies per AReply; captures the request line for assertions
  TLoopbackProxyServer = class(TThread)
  private
    FListenFd: Integer;
    FReply: AnsiString;
    FRequest: AnsiString;
    FAcceptedFd: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AListenFd: Integer; const AReply: AnsiString);
    property Request: AnsiString read FRequest;
  end;

function RawPtrOf(const B: TBytes): PByte;
procedure RawSend(const AFd: Integer; const S: AnsiString);
function MakeSocketPair(out A, B: Integer): Boolean;
function MakeLoopbackListener(out AListenFd: Integer; out APort: Word): Boolean;
function TestCertPath(const AName: string): string;
function RunRealHandshake(const AInsecure: Boolean): TRealHandshakeResult;

implementation

{ TMockSocket }

constructor TMockSocket.Create;
begin
  inherited Create;
  FConnected := True;
  FConnectTimeoutMs := 1000;
  FReadTimeoutMs := 1000;
  FWriteTimeoutMs := 1000;
end;

function TMockSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := 0;
end;

function TMockSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := ACount;
end;

procedure TMockSocket.Close;
begin
  FConnected := False;
end;

function TMockSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TMockSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TMockSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TMockSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TMockSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TMockSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TMockSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

{ TWriterThread }

constructor TWriterThread.Create(const AFd: Integer; const AData: TBytes;
  const ADelayMs: Integer);
begin
  inherited Create(True);
  FFd := AFd;
  FData := AData;
  FDelayMs := ADelayMs;
  FreeOnTerminate := False;
end;

procedure TWriterThread.Execute;
begin
  if FDelayMs > 0 then
    Sleep(FDelayMs);
  if Length(FData) > 0 then
    fpSend(FFd, @FData[0], Length(FData), 0);
end;

{ TLoopbackTlsServer }

constructor TLoopbackTlsServer.Create(const AListenFd: Integer;
  const ACertFile, AKeyFile: string);
begin
  inherited Create(True);
  FListenFd := AListenFd;
  FCertFile := ACertFile;
  FKeyFile := AKeyFile;
  FAcceptedFd := -1;
  FHandshakeResult := -99;
  FreeOnTerminate := False;
end;

procedure TLoopbackTlsServer.Execute;
var
  ctx: PSSL_CTX;
  ssl: PSSL;
  opt: LongInt;
begin
  // ensure the OpenSSL library is loaded before calling any raw SSL_* symbol;
  // the thread may otherwise race the client thread's first load
  if not OpenSslIsAvailable then
    Exit;
  FAcceptedFd := fpAccept(FListenFd, nil, nil);
  if FAcceptedFd < 0 then
    Exit;
  opt := 1;
{$IFDEF DARWIN}
  {$IFDEF DARWIN}
  fpSetSockOpt(FAcceptedFd, SOL_SOCKET, SO_NOSIGPIPE, @opt, SizeOf(opt));
  {$ENDIF}
{$ENDIF}
  ctx := SSL_CTX_new(TLS_server_method());
  try
    SSL_CTX_use_certificate_file(ctx, PUtf8Char(UTF8String(FCertFile)),
      SSL_FILETYPE_PEM);
    SSL_CTX_use_PrivateKey_file(ctx, PUtf8Char(UTF8String(FKeyFile)),
      SSL_FILETYPE_PEM);
    ssl := SSL_new(ctx);
    SSL_set_fd(ssl, FAcceptedFd);
    FHandshakeResult := SSL_accept(ssl);
    Sleep(100);
    SSL_free(ssl);
  finally
    SSL_CTX_free(ctx);
    fpClose(FAcceptedFd);
  end;
end;

{ helpers }

function BytesOf(const S: AnsiString): TBytes;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i - 1] := Ord(S[i]);
end;

procedure RawSend(const AFd: Integer; const S: AnsiString);
var
  B: TBytes;
begin
  B := BytesOf(S);
  if Length(B) > 0 then
    fpSend(AFd, @B[0], Length(B), 0);
end;

function RawPtrOf(const B: TBytes): PByte;
begin
  if Length(B) = 0 then
    Result := nil
  else
    Result := @B[0];
end;

function MakeSocketPair(out A, B: Integer): Boolean;
var
  fds: array[0..1] of cint;
  opt: LongInt;
begin
  Result := fpsocketpair(AF_UNIX, SOCK_STREAM, 0, @fds[0]) = 0;
  if Result then
  begin
    A := fds[0];
    B := fds[1];
    // writing to a peer that has already closed must not kill the process
    opt := 1;
{$IFDEF DARWIN}
    {$IFDEF DARWIN}
    fpSetSockOpt(A, SOL_SOCKET, SO_NOSIGPIPE, @opt, SizeOf(opt));
    {$ENDIF}
    {$IFDEF DARWIN}
    fpSetSockOpt(B, SOL_SOCKET, SO_NOSIGPIPE, @opt, SizeOf(opt));
    {$ENDIF}
{$ENDIF}
  end;
end;

function TestCertPath(const AName: string): string;
begin
  Result := ExtractFilePath(ParamStr(0)) + '../../test/fixtures/client/certs/' + AName;
  if FileExists(Result) then
    Exit;
  Result := 'test/fixtures/client/certs/' + AName;
end;

// run one real loopback TLS handshake against the self-signed test cert and
// report how TTlsSocket.Dial behaved; spills the failure class into the record
function RunRealHandshake(const AInsecure: Boolean): TRealHandshakeResult;
var
  listenFd: Integer;
  addr: TSockAddr;
  alen: LongInt;
  port: Word;
  server: TLoopbackTlsServer;
  Sock: IHttp2Socket;
  Context: ITLSContext;
  Policy: TTlsClientPolicy;
  certFile, keyFile: string;
begin
  Result.Skipped := False;
  Result.Raised := False;
  Result.Connected := False;
  certFile := TestCertPath('localhost.crt');
  keyFile := TestCertPath('localhost.key');
  if (not FileExists(certFile)) or (not FileExists(keyFile)) then
  begin
    Result.Skipped := True;
    Exit;
  end;
  listenFd := fpsocket(AF_INET, SOCK_STREAM, 0);
  if listenFd < 0 then
  begin
    Result.Skipped := True;
    Exit;
  end;
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(0);
  addr.sin_addr.s_addr := htonl($7f000001);
  fpbind(listenFd, @addr, SizeOf(addr));
  fplisten(listenFd, 1);
  alen := SizeOf(addr);
  fpgetsockname(listenFd, @addr, @alen);
  port := ntohs(addr.sin_port);
  server := TLoopbackTlsServer.Create(listenFd, certFile, keyFile);
  server.Start;
  Sleep(30);
  try
    try
      Policy := TTlsClientPolicy.SecureDefault.WithSystemTrust(False)
        .WithInsecure(AInsecure);
      Context := TOpenSSLTlsContextFactory.Create
        .WithClientPolicy(Policy).Build;
      Sock := TTlsSocket.Dial('localhost', port, False, 2000,
        '', '', 0, nil, Context);
      Result.Connected := Sock.Connected;
      Sock.Close;
    except
      on E: EHttpError do
        Result.Raised := True;
      on E: Exception do
        Result.Raised := True;
    end;
  finally
    server.WaitFor;
    server.Free;
    fpClose(listenFd);
  end;
end;

{ tests }

{ TLoopbackProxyServer }

constructor TLoopbackProxyServer.Create(const AListenFd: Integer;
  const AReply: AnsiString);
begin
  inherited Create(True);
  FListenFd := AListenFd;
  FReply := AReply;
  FRequest := '';
  FAcceptedFd := -1;
  FreeOnTerminate := False;
end;

procedure TLoopbackProxyServer.Execute;
var
  C: AnsiChar;
  opt: LongInt;
begin
  FAcceptedFd := fpAccept(FListenFd, nil, nil);
  if FAcceptedFd < 0 then
    Exit;
  opt := 1;
{$IFDEF DARWIN}
  {$IFDEF DARWIN}
  fpSetSockOpt(FAcceptedFd, SOL_SOCKET, SO_NOSIGPIPE, @opt, SizeOf(opt));
  {$ENDIF}
{$ENDIF}
  // read the request headers up to the blank line
  repeat
    if fpRecv(FAcceptedFd, @C, 1, 0) <> 1 then
      Break;
    FRequest := FRequest + C;
  until (Length(FRequest) >= 4) and
    (Copy(FRequest, Length(FRequest) - 3, 4) = #13#10#13#10);
  if Length(FReply) > 0 then
    fpSend(FAcceptedFd, @FReply[1], Length(FReply), 0);
  // hold the tunnel open until the client closes it, so the test's teardown is
  // deterministic rather than racing a fixed sleep
  while fpRecv(FAcceptedFd, @C, 1, 0) = 1 do
    ;
  fpClose(FAcceptedFd);
end;

// host/port of a fresh loopback listener; 0 on failure
function MakeLoopbackListener(out AListenFd: Integer; out APort: Word): Boolean;
var
  addr: TSockAddr;
  alen: LongInt;
  one: LongInt;
begin
  Result := False;
  AListenFd := fpsocket(AF_INET, SOCK_STREAM, 0);
  if AListenFd < 0 then
    Exit;
  one := 1;
  fpSetSockOpt(AListenFd, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(0);
  addr.sin_addr.s_addr := htonl($7f000001);
  if fpbind(AListenFd, @addr, SizeOf(addr)) <> 0 then
  begin
    fpClose(AListenFd);
    Exit;
  end;
  if fplisten(AListenFd, 1) <> 0 then
  begin
    fpClose(AListenFd);
    Exit;
  end;
  alen := SizeOf(addr);
  fpgetsockname(AListenFd, @addr, @alen);
  APort := ntohs(addr.sin_port);
  Result := True;
end;

end.
