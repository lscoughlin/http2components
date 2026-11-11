{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Proxy transport tests (doc/design/proxy.md "Interaction with the transport",
/// "TLS to the proxy", "SOCKS5").
// - a scripted loopback server plays an HTTP CONNECT proxy, an HTTPS proxy
//   (TLS to the proxy first) or a SOCKS5 proxy, then acts as the origin
//   inside the tunnel: a plain echo, or a TLS server (so an https origin
//   behind an https proxy is TLS inside TLS, which exercises the memory-BIO
//   mode of TTlsSocket).
// - no network beyond 127.0.0.1 and no real proxy is involved.
unit Http2.Client.ProxyTransport.HttpConnect.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix, fpcunit, testregistry,
  mormot.core.base, mormot.lib.openssl11,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client.Socks, Http2.Client.Tls,
  Http2.Client, Http2.Client.Test.TlsContext,
  Http2.Client.Test.OpenSSL.SigPipe;

type
  TProxyMode = (pmHttp, pmHttps, pmSocks5);

  /// the server side of one byte stream
  TSrvStream = class
  public
    /// some bytes (1..N); 0 at end of stream
    function Read(var ABuf; N: Integer): Integer; virtual; abstract;
    procedure WriteAll(const ABuf; N: Integer); virtual; abstract;
  end;

  TProxyScriptServer = class(TThread)
  private
    FListenFd: Integer;
    FFd: Integer;
    FCertFile, FKeyFile: string;
  protected
    procedure Execute; override;
  public
    // script
    Mode: TProxyMode;
    /// HTTP: when non-empty, the exact Proxy-Authorization value required
    RequireAuthHeader: string;
    /// SOCKS5: when non-empty, username/password is required
    RequireUser, RequirePass: string;
    /// HTTP: the status line to answer CONNECT with
    ConnectReply: AnsiString;
    /// SOCKS5: the REP code to answer with
    SocksRep: Integer;
    /// the origin inside the tunnel: TLS (True) or a plain echo
    OriginTls: Boolean;
    /// the certificate the TLS legs present: 'localhost' (names 127.0.0.1) or
    /// 'other' (names only other.example)
    CertName: string;
    // observations
    Request: AnsiString;
    SeenAtyp: Integer;
    SeenHost: string;
    SeenPort: Integer;
    SeenUser: string;
    Failure: string;
    constructor Create(const AListenFd: Integer; const AMode: TProxyMode);
  end;

  TProxyTransportTest = class(TTestCase)
  private
    FListenFd: Integer;
    FPort: Word;
    FServer: TProxyScriptServer;
    procedure StartServer(const AMode: TProxyMode);
    procedure StopServer;
    procedure EchoRoundTrip(const ASock: IHttp2Socket; const ACount: Integer);
    function Secure: Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestHttpConnectWithCredentialsSendsBasicHeader;
    procedure TestHttpConnectWithoutCredentialsSendsNoAuthHeader;
    procedure TestHttpConnect407DoesNotLeakCredentials;
    procedure TestHttpConnectBracketsAnIpv6Target;
    procedure TestSocks5NoAuthSendsTheNameUnresolved;
    procedure TestSocks5UserPassAuthenticates;
    procedure TestSocks5WrongPasswordIsAConnectionError;
    procedure TestSocks5RefusedReplyNamesTheReason;
    procedure TestSocks5TunnelsAnHttpsOrigin;
    procedure TestSocks5IpLiteralUsesAnAddressType;
    // HTTP CONNECT
    // SOCKS5
    // https proxy (TLS to the proxy)
    // factory dispatch
  end;

implementation

const
  cLocalhost = '127.0.0.1';

function CertPath(const AName: string): string;
const
  cDirs: array[0..3] of string = ('test/fixtures/client/certs/', '../test/fixtures/client/certs/',
    '../../test/fixtures/client/certs/', '../../../test/fixtures/client/certs/');
var
  I: Integer;
  Base: string;
begin
  // the suite runs from the project root (make test) or from bin/; look for
  // the directory instead of assuming the working directory
  Base := ExtractFilePath(ParamStr(0));
  for I := 0 to High(cDirs) do
  begin
    if FileExists(cDirs[I] + AName) then
      Exit(ExpandFileName(cDirs[I] + AName));
    if FileExists(Base + cDirs[I] + AName) then
      Exit(ExpandFileName(Base + cDirs[I] + AName));
  end;
  Result := 'test/fixtures/client/certs/' + AName;
end;

{ server-side streams }

type
  TFdSrv = class(TSrvStream)
  private
    FFd: Integer;
  public
    constructor Create(const AFd: Integer);
    function Read(var ABuf; N: Integer): Integer; override;
    procedure WriteAll(const ABuf; N: Integer); override;
  end;

  TSslFdSrv = class(TSrvStream)
  private
    FCtx: PSSL_CTX;
    FSsl: PSSL;
  public
    constructor Create(const AFd: Integer; const ACert, AKey: string);
    destructor Destroy; override;
    function Read(var ABuf; N: Integer): Integer; override;
    procedure WriteAll(const ABuf; N: Integer); override;
  end;

  /// TLS server over another TSrvStream, through memory BIOs
  TSslBioSrv = class(TSrvStream)
  private
    FBase: TSrvStream;
    FCtx: PSSL_CTX;
    FSsl: PSSL;
    FRbio, FWbio: PBIO;
    procedure Flush;
    function Feed: Boolean;
  public
    constructor Create(const ABase: TSrvStream; const ACert, AKey: string);
    destructor Destroy; override;
    function Read(var ABuf; N: Integer): Integer; override;
    procedure WriteAll(const ABuf; N: Integer); override;
  end;

constructor TFdSrv.Create(const AFd: Integer);
begin
  inherited Create;
  FFd := AFd;
end;

function TFdSrv.Read(var ABuf; N: Integer): Integer;
begin
  Result := fpRecv(FFd, @ABuf, N, 0);
  if Result < 0 then
    Result := 0;
end;

procedure TFdSrv.WriteAll(const ABuf; N: Integer);
var
  Sent, R: Integer;
begin
  Sent := 0;
  while Sent < N do
  begin
    R := fpSend(FFd, PByte(@ABuf) + Sent, N - Sent, 0);
    if R <= 0 then
      Exit;
    Inc(Sent, R);
  end;
end;

constructor TSslFdSrv.Create(const AFd: Integer; const ACert, AKey: string);
begin
  inherited Create;
  FCtx := SSL_CTX_new(TLS_server_method());
  SSL_CTX_use_certificate_file(FCtx, PUtf8Char(UTF8String(ACert)),
    SSL_FILETYPE_PEM);
  SSL_CTX_use_PrivateKey_file(FCtx, PUtf8Char(UTF8String(AKey)),
    SSL_FILETYPE_PEM);
  FSsl := SSL_new(FCtx);
  SSL_set_fd(FSsl, AFd);
  if TestSslAccept(FSsl) <> 1 then
    raise Exception.Create('server TLS accept failed (proxy leg)');
end;

destructor TSslFdSrv.Destroy;
begin
  if FSsl <> nil then
  begin
    TestSslShutdown(FSsl);
    SSL_free(FSsl);
  end;
  if FCtx <> nil then
    SSL_CTX_free(FCtx);
  inherited Destroy;
end;

function TSslFdSrv.Read(var ABuf; N: Integer): Integer;
begin
  Result := SSL_read(FSsl, @ABuf, N);
  if Result < 0 then
    Result := 0;
end;

procedure TSslFdSrv.WriteAll(const ABuf; N: Integer);
var
  Sent, R: Integer;
begin
  Sent := 0;
  while Sent < N do
  begin
    R := TestSslWrite(FSsl, PByte(@ABuf) + Sent, N - Sent);
    if R <= 0 then
      Exit;
    Inc(Sent, R);
  end;
end;

constructor TSslBioSrv.Create(const ABase: TSrvStream; const ACert,
  AKey: string);
var
  R, Err: Integer;
begin
  inherited Create;
  FBase := ABase;
  FCtx := SSL_CTX_new(TLS_server_method());
  SSL_CTX_use_certificate_file(FCtx, PUtf8Char(UTF8String(ACert)),
    SSL_FILETYPE_PEM);
  SSL_CTX_use_PrivateKey_file(FCtx, PUtf8Char(UTF8String(AKey)),
    SSL_FILETYPE_PEM);
  FSsl := SSL_new(FCtx);
  FRbio := BIO_new(BIO_s_mem());
  FWbio := BIO_new(BIO_s_mem());
  SSL_set_bio(FSsl, FRbio, FWbio);
  repeat
    R := TestSslAccept(FSsl);
    Flush;
    if R = 1 then
      Break;
    Err := SSL_get_error(FSsl, R);
    if Err = SSL_ERROR_WANT_READ then
    begin
      if not Feed then
        raise Exception.Create('inner TLS accept: tunnel closed');
    end
    else if Err <> SSL_ERROR_WANT_WRITE then
      raise Exception.CreateFmt('inner TLS accept failed (%d)', [Err]);
  until False;
end;

destructor TSslBioSrv.Destroy;
begin
  if FSsl <> nil then
  begin
    TestSslShutdown(FSsl);
    try
      Flush;
    except
    end;
    SSL_free(FSsl);
  end;
  if FCtx <> nil then
    SSL_CTX_free(FCtx);
  inherited Destroy;
end;

procedure TSslBioSrv.Flush;
var
  Buf: array[0..16383] of Byte;
  N: Integer;
begin
  while BIO_ctrl(FWbio, _BIO_CTRL_PENDING, 0, nil) > 0 do
  begin
    N := BIO_read(FWbio, @Buf[0], SizeOf(Buf));
    if N <= 0 then
      Break;
    FBase.WriteAll(Buf[0], N);
  end;
end;

function TSslBioSrv.Feed: Boolean;
var
  Buf: array[0..16383] of Byte;
  N: Integer;
begin
  N := FBase.Read(Buf[0], SizeOf(Buf));
  if N <= 0 then
  begin
    BIO_ctrl(FRbio, BIO_C_SET_BUF_MEM_EOF_RETURN, 0, nil);
    Exit(False);
  end;
  BIO_write(FRbio, @Buf[0], N);
  Result := True;
end;

function TSslBioSrv.Read(var ABuf; N: Integer): Integer;
var
  R, Err: Integer;
begin
  while True do
  begin
    R := SSL_read(FSsl, @ABuf, N);
    if R > 0 then
      Exit(R);
    Err := SSL_get_error(FSsl, R);
    if Err = SSL_ERROR_WANT_READ then
    begin
      Flush;
      if not Feed then
        Exit(0);
    end
    else if Err = SSL_ERROR_WANT_WRITE then
      Flush
    else
      Exit(0);
  end;
end;

procedure TSslBioSrv.WriteAll(const ABuf; N: Integer);
var
  Sent, R: Integer;
begin
  Sent := 0;
  while Sent < N do
  begin
    R := TestSslWrite(FSsl, PByte(@ABuf) + Sent, N - Sent);
    if R <= 0 then
      Exit;
    Inc(Sent, R);
    Flush;
  end;
end;

{ TProxyScriptServer }

constructor TProxyScriptServer.Create(const AListenFd: Integer;
  const AMode: TProxyMode);
begin
  inherited Create(True);
  FListenFd := AListenFd;
  Mode := AMode;
  CertName := 'localhost';
  ConnectReply := 'HTTP/1.1 200 Connection established'#13#10#13#10;
  SocksRep := 0;
end;

procedure ReadExact(const S: TSrvStream; var ABuf; N: Integer);
var
  Got, R: Integer;
begin
  Got := 0;
  while Got < N do
  begin
    R := S.Read(PByte(@ABuf)[Got], N - Got);
    if R <= 0 then
      raise Exception.Create('peer closed early');
    Inc(Got, R);
  end;
end;

procedure TProxyScriptServer.Execute;
var
  Base, Wrapped, Origin: TSrvStream;
  C: AnsiChar;
  Auth, B1: Byte;
  Hdr: array[0..3] of Byte;
  Greet: array[0..255] of Byte;
  Buf: array[0..4095] of Byte;
  Reply: array[0..9] of Byte;
  N, I, ULen, PLen: Integer;
  Chosen: Byte;
  User, Pass, HostName: string;
  Opt: LongInt;
  Line: AnsiString;
begin
  Base := nil;
  Wrapped := nil;
  Origin := nil;
  FFd := -1;
  FCertFile := CertPath(CertName + '.crt');
  FKeyFile := CertPath(CertName + '.key');
  try
    try
      if not OpenSslIsAvailable then
        Exit;
      FFd := fpAccept(FListenFd, nil, nil);
      if FFd < 0 then
        Exit;
      Opt := 1;
      {$IFDEF DARWIN}
      fpSetSockOpt(FFd, SOL_SOCKET, SO_NOSIGPIPE, @Opt, SizeOf(Opt));
      {$ENDIF}
      Base := TFdSrv.Create(FFd);
      Wrapped := Base;
      if Mode = pmHttps then
      begin
        Wrapped := TSslFdSrv.Create(FFd, FCertFile, FKeyFile);
      end;

      if Mode = pmSocks5 then
      begin
        // method selection
        ReadExact(Wrapped, Hdr, 2);
        N := Hdr[1];
        ReadExact(Wrapped, Greet, N);
        Chosen := $FF;
        if RequireUser <> '' then
        begin
          for I := 0 to N - 1 do
            if Greet[I] = 2 then
              Chosen := 2;
        end
        else
          for I := 0 to N - 1 do
            if Greet[I] = 0 then
              Chosen := 0;
        Reply[0] := 5;
        Reply[1] := Chosen;
        Wrapped.WriteAll(Reply, 2);
        if Chosen = $FF then
          Exit;
        if Chosen = 2 then
        begin
          ReadExact(Wrapped, B1, 1);       // VER 1
          ReadExact(Wrapped, B1, 1);
          ULen := B1;
          SetLength(User, ULen);
          if ULen > 0 then
            ReadExact(Wrapped, User[1], ULen);
          ReadExact(Wrapped, B1, 1);
          PLen := B1;
          SetLength(Pass, PLen);
          if PLen > 0 then
            ReadExact(Wrapped, Pass[1], PLen);
          SeenUser := User;
          Reply[0] := 1;
          if (User = RequireUser) and (Pass = RequirePass) then
            Reply[1] := 0
          else
            Reply[1] := 1;
          Wrapped.WriteAll(Reply, 2);
          if Reply[1] <> 0 then
            Exit;
        end;
        // request
        ReadExact(Wrapped, Hdr, 4);
        SeenAtyp := Hdr[3];
        case Hdr[3] of
          1:
            begin
              ReadExact(Wrapped, Buf, 4);
              HostName := Format('%d.%d.%d.%d', [Buf[0], Buf[1], Buf[2], Buf[3]]);
            end;
          4:
            begin
              ReadExact(Wrapped, Buf, 16);
              HostName := '';
              for I := 0 to 15 do
                HostName := HostName + IntToHex(Buf[I], 2);
            end;
          3:
            begin
              ReadExact(Wrapped, B1, 1);
              SetLength(HostName, B1);
              if B1 > 0 then
                ReadExact(Wrapped, HostName[1], B1);
            end;
        end;
        ReadExact(Wrapped, Buf, 2);
        SeenHost := HostName;
        SeenPort := Buf[0] * 256 + Buf[1];
        FillChar(Reply, SizeOf(Reply), 0);
        Reply[0] := 5;
        Reply[1] := SocksRep;
        Reply[3] := 1;
        Wrapped.WriteAll(Reply, 10);
        if SocksRep <> 0 then
          Exit;
      end
      else
      begin
        // HTTP CONNECT (plain or over the proxy TLS leg): read to the blank line
        Line := '';
        repeat
          if Wrapped.Read(C, 1) <> 1 then
            Break;
          Line := Line + C;
        until (Length(Line) >= 4) and
          (Copy(Line, Length(Line) - 3, 4) = #13#10#13#10);
        Request := Line;
        if (RequireAuthHeader <> '') and
           (Pos('Proxy-Authorization: ' + RequireAuthHeader, string(Line)) = 0) then
        begin
          Line := 'HTTP/1.1 407 Proxy Authentication Required'#13#10 +
            'Proxy-Authenticate: Basic realm="x"'#13#10#13#10;
          Wrapped.WriteAll(Line[1], Length(Line));
          Exit;
        end;
        Wrapped.WriteAll(ConnectReply[1], Length(ConnectReply));
        if Copy(ConnectReply, 10, 1) <> '2' then
          Exit;
      end;

      // the origin inside the tunnel
      Origin := Wrapped;
      if OriginTls then
        Origin := TSslBioSrv.Create(Wrapped, FCertFile, FKeyFile);
      repeat
        N := Origin.Read(Buf, SizeOf(Buf));
        if N <= 0 then
          Break;
        Origin.WriteAll(Buf, N);
      until False;
    except
      on E: Exception do
        Failure := E.Message;
    end;
  finally
    if (Origin <> nil) and (Origin <> Wrapped) then
      Origin.Free;
    if (Wrapped <> nil) and (Wrapped <> Base) then
      Wrapped.Free;
    Base.Free;
    if FFd >= 0 then
      fpClose(FFd);
  end;
end;

{ TProxyTransportTest }

function ListenOnLoopback(out AFd: Integer; out APort: Word): Boolean;
var
  addr: TSockAddr;
  alen: LongInt;
  one: LongInt;
begin
  Result := False;
  AFd := fpsocket(AF_INET, SOCK_STREAM, 0);
  if AFd < 0 then
    Exit;
  one := 1;
  fpSetSockOpt(AFd, SOL_SOCKET, SO_REUSEADDR, @one, SizeOf(one));
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := htons(0);
  addr.sin_addr.s_addr := htonl($7f000001);
  if fpbind(AFd, @addr, SizeOf(addr)) <> 0 then
    Exit;
  if fplisten(AFd, 1) <> 0 then
    Exit;
  alen := SizeOf(addr);
  if fpgetsockname(AFd, @addr, @alen) <> 0 then
    Exit;
  APort := ntohs(addr.sin_port);
  Result := True;
end;

procedure TProxyTransportTest.StartServer(const AMode: TProxyMode);
begin
  if not OpenSslIsAvailable then
    Exit;
  if not ListenOnLoopback(FListenFd, FPort) then
    raise EHttpConnectionError.Create('could not create a loopback listener');
  FServer := TProxyScriptServer.Create(FListenFd, AMode);
end;

procedure TProxyTransportTest.StopServer;
begin
  if (FServer <> nil) and FServer.Suspended then
    FreeAndNil(FServer);          // never started: nothing to wait for
  if FServer <> nil then
  begin
    if not FServer.Finished then
    begin
      // unblock a server still waiting in accept or in a read
      fpShutdown(FListenFd, 2);
      if FServer.FFd > 0 then
        fpShutdown(FServer.FFd, 2);
    end;
    FServer.WaitFor;
    FreeAndNil(FServer);
  end;
  if FListenFd > 0 then
  begin
    fpClose(FListenFd);
    FListenFd := 0;
  end;
end;

procedure TProxyTransportTest.TearDown;
begin
  StopServer;
  inherited TearDown;
end;

function TProxyTransportTest.Secure: Boolean;
begin
  Result := OpenSslIsAvailable;
end;

procedure TProxyTransportTest.EchoRoundTrip(const ASock: IHttp2Socket;
  const ACount: Integer);
var
  Out_, In_: TBytes;
  I, Sent, Got, N: Integer;
begin
  SetLength(Out_, ACount);
  SetLength(In_, ACount);
  for I := 0 to ACount - 1 do
    Out_[I] := (I * 7 + 3) and $FF;
  Sent := 0;
  while Sent < ACount do
  begin
    N := ACount - Sent;
    if N > 3000 then N := 3000;
    ASock.Write(Out_[Sent], N);
    Inc(Sent, N);
    Got := 0;
    // read back what was just sent so the echo never fills both directions
    while Got < N do
    begin
      I := ASock.Read(In_[Sent - N + Got], N - Got);
      AssertTrue('echo read made progress', I > 0);
      Inc(Got, I);
    end;
  end;
  for I := 0 to ACount - 1 do
    if In_[I] <> Out_[I] then
    begin
      Fail('echo mismatch at byte ' + IntToStr(I));
      Break;
    end;
end;

{ HTTP CONNECT }


procedure TProxyTransportTest.TestHttpConnectWithCredentialsSendsBasicHeader;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmHttp);
  FServer.RequireAuthHeader := 'Basic ' + ProxyBasicCredentials('bob', 'pw');
  FServer.Start;
  Sock := TTlsSocket.DialCleartextVia('origin.example', 80, 2000,
    TProxy.Create(pkHttp, cLocalhost, FPort, 'bob', 'pw'));
  EchoRoundTrip(Sock, 500);
  Sock.Close;
  FServer.WaitFor;
  AssertTrue(Pos('CONNECT origin.example:80 HTTP/1.1', string(FServer.Request)) = 1);
  AssertTrue('Basic credential header',
    Pos('Proxy-Authorization: Basic ' + ProxyBasicCredentials('bob', 'pw'),
      string(FServer.Request)) > 0);
  AssertEquals('server error', '', FServer.Failure);
end;

procedure TProxyTransportTest.TestHttpConnectWithoutCredentialsSendsNoAuthHeader;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmHttp);
  FServer.Start;
  Sock := TTlsSocket.DialCleartextVia('origin.example', 80, 2000,
    TProxy.Create(pkHttp, cLocalhost, FPort));
  EchoRoundTrip(Sock, 100);
  Sock.Close;
  FServer.WaitFor;
  AssertEquals('no auth header', 0,
    Pos('Proxy-Authorization', string(FServer.Request)));
end;

procedure TProxyTransportTest.TestHttpConnect407DoesNotLeakCredentials;
var
  Msg: string;
begin
  if not Secure then Exit;
  StartServer(pmHttp);
  FServer.RequireAuthHeader := 'Basic ' + ProxyBasicCredentials('bob', 'right');
  FServer.Start;
  Msg := '';
  try
    TTlsSocket.DialCleartextVia('origin.example', 80, 2000,
      TProxy.Create(pkHttp, cLocalhost, FPort, 'bob', 'TOPSECRET'));
  except
    on E: EHttpConnectionError do
      Msg := E.Message;
  end;
  AssertTrue('raised', Msg <> '');
  AssertTrue('names the status', Pos('407', Msg) > 0);
  AssertEquals('no password', 0, Pos('TOPSECRET', Msg));
  AssertEquals('no base64 of it', 0,
    Pos(ProxyBasicCredentials('bob', 'TOPSECRET'), Msg));
end;

procedure TProxyTransportTest.TestHttpConnectBracketsAnIpv6Target;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmHttp);
  FServer.Start;
  Sock := TTlsSocket.DialCleartextVia('2001:db8::7', 8080, 2000,
    TProxy.Create(pkHttp, cLocalhost, FPort));
  Sock.Close;
  FServer.WaitFor;
  AssertTrue(Pos('CONNECT [2001:db8::7]:8080 HTTP/1.1', string(FServer.Request)) = 1);
end;

{ SOCKS5 }

procedure TProxyTransportTest.TestSocks5NoAuthSendsTheNameUnresolved;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmSocks5);
  FServer.Start;
  Sock := TTlsSocket.DialCleartextVia('origin.example', 8443, 2000,
    TProxy.Create(pkSocks5, cLocalhost, FPort));
  EchoRoundTrip(Sock, 700);
  Sock.Close;
  FServer.WaitFor;
  AssertEquals('ATYP name', 3, FServer.SeenAtyp);
  AssertEquals('origin.example', FServer.SeenHost);
  AssertEquals(8443, FServer.SeenPort);
end;

procedure TProxyTransportTest.TestSocks5UserPassAuthenticates;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmSocks5);
  FServer.RequireUser := 'bob';
  FServer.RequirePass := 'pw';
  FServer.Start;
  Sock := TTlsSocket.DialCleartextVia('origin.example', 80, 2000,
    TProxy.Create(pkSocks5, cLocalhost, FPort, 'bob', 'pw'));
  EchoRoundTrip(Sock, 300);
  Sock.Close;
  FServer.WaitFor;
  AssertEquals('bob', FServer.SeenUser);
end;

procedure TProxyTransportTest.TestSocks5WrongPasswordIsAConnectionError;
var
  Msg: string;
begin
  if not Secure then Exit;
  StartServer(pmSocks5);
  FServer.RequireUser := 'bob';
  FServer.RequirePass := 'right';
  FServer.Start;
  Msg := '';
  try
    TTlsSocket.DialCleartextVia('origin.example', 80, 2000,
      TProxy.Create(pkSocks5, cLocalhost, FPort, 'bob', 'TOPSECRET'));
  except
    on E: EHttpConnectionError do
      Msg := E.Message;
  end;
  AssertTrue('raised', Msg <> '');
  AssertEquals('no password', 0, Pos('TOPSECRET', Msg));
end;

procedure TProxyTransportTest.TestSocks5RefusedReplyNamesTheReason;
var
  Msg: string;
begin
  if not Secure then Exit;
  StartServer(pmSocks5);
  FServer.SocksRep := 5;
  FServer.Start;
  Msg := '';
  try
    TTlsSocket.DialCleartextVia('origin.example', 80, 2000,
      TProxy.Create(pkSocks5, cLocalhost, FPort));
  except
    on E: EHttpConnectionError do
      Msg := E.Message;
  end;
  AssertTrue('connection refused', Pos('connection refused', Msg) > 0);
end;

procedure TProxyTransportTest.TestSocks5TunnelsAnHttpsOrigin;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmSocks5);
  FServer.OriginTls := True;
  FServer.Start;
  Sock := TTlsSocket.DialWithAlpnVia('localhost', 443, nil, False, 3000, '',
    TProxy.Create(pkSocks5, cLocalhost, FPort), nil, nil,
    OpenSslClientTestContext('', True));
  EchoRoundTrip(Sock, 2000);
  Sock.Close;
  FServer.WaitFor;
  AssertEquals('localhost', FServer.SeenHost);
  AssertEquals('server error', '', FServer.Failure);
end;

procedure TProxyTransportTest.TestSocks5IpLiteralUsesAnAddressType;
var
  Sock: IHttp2Socket;
begin
  if not Secure then Exit;
  StartServer(pmSocks5);
  FServer.Start;
  Sock := TTlsSocket.DialCleartextVia('10.9.8.7', 80, 2000,
    TProxy.Create(pkSocks5, cLocalhost, FPort));
  Sock.Close;
  FServer.WaitFor;
  AssertEquals('ATYP ipv4', 1, FServer.SeenAtyp);
  AssertEquals('10.9.8.7', FServer.SeenHost);
end;

{ https proxy }

initialization
  RegisterTest(TProxyTransportTest);
end.
