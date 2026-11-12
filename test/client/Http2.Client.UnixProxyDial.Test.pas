{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests dial through a proxy that listens on a socket file. A scripted
    proxy plays CONNECT or SOCKS5 on a thread, then echoes.
---
}
/// Tests for the client dial path through a proxy on a Unix socket file
// - each test runs its own proxy on a fresh socket file, and removes the file
//   in TearDown
unit Http2.Client.UnixProxyDial.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client.Proxy.Types,
  Http2.Client.Tls.Types, Http2.Client.Tls.Tunnel, Http2.Client.Unix.TestKit;

type
  /// a scripted proxy. It answers one CONNECT request or one SOCKS5 request,
  /// then echoes until the client closes.
  TFakeProxy = class
  private
    FSocks: Boolean;
    procedure HandleConnect(AFd: Integer);
    procedure HandleSocks(AFd: Integer);
  public
    /// the expected Proxy-Authorization value; '' when none is required
    RequireAuth: string;
    /// SOCKS5: the user name and password that the proxy requires
    RequireUser, RequirePass: string;
    /// the status line that answers CONNECT
    ConnectStatus: string;
    /// the REP code that answers a SOCKS5 request
    SocksRep: Integer;
    /// the CONNECT head that arrived, up to the blank line
    Head: RawByteString;
    /// the SOCKS5 address type, host and port of the request
    SeenAtyp: Integer;
    SeenHost: RawByteString;
    SeenPort: Integer;
    /// ASocks selects SOCKS5; otherwise the proxy speaks HTTP CONNECT
    constructor Create(const ASocks: Boolean);
    /// runs the script on one accepted connection
    procedure Handle(AFd: Integer);
  end;

  /// a proxy listener on a socket file. It runs the script of each connection.
  TUnixProxyListener = class(TUnixListener)
  private
    FScript: TFakeProxy;
  public
    constructor Create(const APath: string; AScript: TFakeProxy);
    procedure Serve(AFd: Integer); override;
  end;

  /// a proxy on a loopback TCP port. It accepts one connection.
  TTcpProxyThread = class(TThread)
  private
    FListenFd: Integer;
    FScript: TFakeProxy;
  protected
    procedure Execute; override;
  public
    constructor Create(AListenFd: Integer; AScript: TFakeProxy);
  end;

  /// tests for the client dial path through a proxy on a Unix socket file
  TUnixProxyDialTest = class(TTestCase)
  private
    FPath: string;
    FScript: TFakeProxy;
    FListener: TUnixProxyListener;
    FTcpFd: Integer;
    FTcpPort: Word;
    FTcpThread: TTcpProxyThread;
    procedure StartUnixProxy(const ASocks: Boolean);
    procedure StartTcpProxy;
    function DialThrough(const AProxy: IProxy): IHttp2Socket;
    procedure EchoOnce(const ASock: IHttp2Socket; const AText: RawByteString);
  protected
    procedure TearDown; override;
  published
    procedure TestConnectThroughUnixProxy;
    procedure TestProxyAuthorizationIsSent;
    procedure TestNon2xxAnswerRaisesConnectionError;
    procedure TestSocks5ThroughUnixProxy;
    procedure TestMissingProxySocketRaisesErrorNamingTheProxy;
    procedure TestTcpProxyStillWorks;
  end;

implementation

/// reads exactly ACount bytes; False when the peer closes first
function RecvExact(AFd: Integer; var ABuf; ACount: Integer): Boolean;
var
  Got, N: Integer;
begin
  Got := 0;
  while Got < ACount do
  begin
    N := fpRecv(AFd, PByte(@ABuf) + Got, ACount - Got, 0);
    if N <= 0 then
      Exit(False);
    Inc(Got, N);
  end;
  Result := True;
end;

/// reads up to and including the blank line that ends an HTTP head
function ReadHead(AFd: Integer): RawByteString;
var
  C: Byte;
begin
  Result := '';
  while (Length(Result) < 4) or
        (Copy(Result, Length(Result) - 3, 4) <> #13#10#13#10) do
  begin
    if not RecvExact(AFd, C, 1) then
      Break;
    Result := Result + AnsiChar(C);
  end;
end;

/// two bytes as a string, for a SOCKS5 reply
function TwoBytes(const AFirst, ASecond: Byte): RawByteString;
begin
  SetLength(Result, 2);
  Result[1] := AnsiChar(AFirst);
  Result[2] := AnsiChar(ASecond);
end;

/// echoes what arrives until the peer closes
procedure EchoUntilClosed(AFd: Integer);
var
  Buf: array[0..1023] of Byte;
  N: Integer;
  Chunk: RawByteString;
begin
  while True do
  begin
    N := fpRecv(AFd, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then
      Exit;
    SetString(Chunk, PAnsiChar(@Buf[0]), N);
    WriteAll(AFd, Chunk);
  end;
end;

/// binds a loopback listener on an ephemeral port; -1 when it fails
function ListenLoopbackTcp(out APort: Word): Integer;
var
  Addr: TSockAddr;
  AddrLen: LongInt;
  One: LongInt;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  APort := 0;
  if Result < 0 then
    Exit;
  One := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(0);
  Addr.sin_addr.s_addr := htonl($7f000001);
  if (fpBind(Result, @Addr, SizeOf(Addr)) <> 0) or (fpListen(Result, 1) <> 0) then
  begin
    fpClose(Result);
    Result := -1;
    Exit;
  end;
  AddrLen := SizeOf(Addr);
  fpGetSockName(Result, @Addr, @AddrLen);
  APort := ntohs(Addr.sin_port);
end;

{ TFakeProxy }

constructor TFakeProxy.Create(const ASocks: Boolean);
begin
  inherited Create;
  FSocks := ASocks;
  ConnectStatus := 'HTTP/1.1 200 Connection established';
  SocksRep := 0;
  SeenAtyp := -1;
  SeenPort := -1;
end;

procedure TFakeProxy.Handle(AFd: Integer);
begin
  if FSocks then
    HandleSocks(AFd)
  else
    HandleConnect(AFd);
end;

procedure TFakeProxy.HandleConnect(AFd: Integer);
begin
  Head := ReadHead(AFd);
  if (RequireAuth <> '') and
     (Pos('Proxy-Authorization: ' + RequireAuth + #13#10, string(Head)) = 0) then
  begin
    WriteAll(AFd, 'HTTP/1.1 407 Proxy Authentication Required'#13#10#13#10);
    Exit;
  end;
  WriteAll(AFd, ConnectStatus + #13#10#13#10);
  // a status that is not 2xx ends the exchange
  if Copy(ConnectStatus, 10, 1) <> '2' then
    Exit;
  EchoUntilClosed(AFd);
end;

procedure TFakeProxy.HandleSocks(AFd: Integer);
var
  Hdr: array[0..1] of Byte;
  Methods: array[0..255] of Byte;
  Req: array[0..3] of Byte;
  Addr: array[0..255] of Byte;
  Port: array[0..1] of Byte;
  Reply: array[0..9] of Byte;
  Chunk: RawByteString;
  Wanted, Chosen, Status, B: Byte;
  User, Pass: RawByteString;
  I: Integer;
begin
  // greeting: VER NMETHODS METHODS
  if not RecvExact(AFd, Hdr, 2) then
    Exit;
  if Hdr[1] > 0 then
    if not RecvExact(AFd, Methods, Hdr[1]) then
      Exit;
  if RequireUser <> '' then
    Wanted := 2
  else
    Wanted := 0;
  Chosen := $FF;
  for I := 0 to Hdr[1] - 1 do
    if Methods[I] = Wanted then
      Chosen := Wanted;
  WriteAll(AFd, TwoBytes(5, Chosen));
  if Chosen = $FF then
    Exit;
  if Chosen = 2 then
  begin
    // user name and password: VER ULEN NAME PLEN PASS
    if not RecvExact(AFd, Hdr, 2) then
      Exit;
    SetLength(User, Hdr[1]);
    if Hdr[1] > 0 then
      if not RecvExact(AFd, User[1], Hdr[1]) then
        Exit;
    if not RecvExact(AFd, B, 1) then
      Exit;
    SetLength(Pass, B);
    if B > 0 then
      if not RecvExact(AFd, Pass[1], B) then
        Exit;
    if (User = RequireUser) and (Pass = RequirePass) then
      Status := 0
    else
      Status := 1;
    WriteAll(AFd, TwoBytes(1, Status));
    if Status <> 0 then
      Exit;
  end;
  // request: VER CMD RSV ATYP, then the address and the port
  if not RecvExact(AFd, Req, 4) then
    Exit;
  SeenAtyp := Req[3];
  if Req[3] <> 3 then
    Exit;
  if not RecvExact(AFd, B, 1) then
    Exit;
  SetLength(SeenHost, B);
  if B > 0 then
    if not RecvExact(AFd, SeenHost[1], B) then
      Exit;
  if not RecvExact(AFd, Port, 2) then
    Exit;
  SeenPort := Port[0] * 256 + Port[1];
  FillChar(Reply, SizeOf(Reply), 0);
  Reply[0] := 5;
  Reply[1] := Byte(SocksRep);
  Reply[3] := 1;
  SetString(Chunk, PAnsiChar(@Reply[0]), SizeOf(Reply));
  WriteAll(AFd, Chunk);
  if SocksRep <> 0 then
    Exit;
  EchoUntilClosed(AFd);
end;

{ TUnixProxyListener }

constructor TUnixProxyListener.Create(const APath: string; AScript: TFakeProxy);
begin
  // set before the inherited constructor starts the accept thread
  FScript := AScript;
  inherited Create(APath);
end;

procedure TUnixProxyListener.Serve(AFd: Integer);
begin
  FScript.Handle(AFd);
end;

{ TTcpProxyThread }

constructor TTcpProxyThread.Create(AListenFd: Integer; AScript: TFakeProxy);
begin
  FListenFd := AListenFd;
  FScript := AScript;
  inherited Create(False);
end;

procedure TTcpProxyThread.Execute;
var
  Conn: Integer;
begin
  Conn := fpAccept(FListenFd, nil, nil);
  if Conn < 0 then
    Exit;
  try
    FScript.Handle(Conn);
  finally
    fpClose(Conn);
  end;
end;

{ TUnixProxyDialTest }

procedure TUnixProxyDialTest.TearDown;
begin
  FreeAndNil(FListener);
  if FTcpThread <> nil then
  begin
    if not FTcpThread.Finished then
      fpShutdown(FTcpFd, 2);
    FTcpThread.WaitFor;
    FreeAndNil(FTcpThread);
  end;
  if FTcpFd >= 0 then
  begin
    fpClose(FTcpFd);
    FTcpFd := -1;
  end;
  FreeAndNil(FScript);
  inherited TearDown;
end;

procedure TUnixProxyDialTest.StartUnixProxy(const ASocks: Boolean);
begin
  FPath := NewUnixTestPath;
  FScript := TFakeProxy.Create(ASocks);
  FListener := TUnixProxyListener.Create(FPath, FScript);
end;

procedure TUnixProxyDialTest.StartTcpProxy;
var
  Port: Word;
begin
  FTcpFd := ListenLoopbackTcp(Port);
  AssertTrue('loopback listener', FTcpFd >= 0);
  FScript := TFakeProxy.Create(False);
  FTcpThread := TTcpProxyThread.Create(FTcpFd, FScript);
  FTcpPort := Port;
end;

function TUnixProxyDialTest.DialThrough(const AProxy: IProxy): IHttp2Socket;
var
  Stream: Boolean;
begin
  Result := DialRoutedTransport('example.test', 80, 2000, AProxy, False, '',
    nil, Stream, nil, '');
end;

procedure TUnixProxyDialTest.EchoOnce(const ASock: IHttp2Socket;
  const AText: RawByteString);
var
  Got, N: Integer;
  Buf: RawByteString;
begin
  ASock.Write(AText[1], Length(AText));
  SetLength(Buf, Length(AText));
  Got := 0;
  while Got < Length(AText) do
  begin
    N := ASock.Read(Buf[Got + 1], Length(AText) - Got);
    if N <= 0 then
      Break;
    Inc(Got, N);
  end;
  AssertEquals('echoed bytes', string(AText), string(Buf));
end;

procedure TUnixProxyDialTest.TestConnectThroughUnixProxy;
var
  Sock: IHttp2Socket;
begin
  StartUnixProxy(False);
  Sock := DialThrough(TProxy.CreateUnix(pkHttp, FPath, '', ''));
  try
    EchoOnce(Sock, 'hello over connect');
    AssertTrue('CONNECT head names the origin',
      Pos('CONNECT example.test:80 HTTP/1.1' + #13#10, string(FScript.Head)) = 1);
  finally
    Sock.Close;
  end;
end;

procedure TUnixProxyDialTest.TestProxyAuthorizationIsSent;
var
  Sock: IHttp2Socket;
begin
  StartUnixProxy(False);
  FScript.RequireAuth := 'Basic ' + ProxyBasicCredentials('bob', 'pw');
  Sock := DialThrough(TProxy.CreateUnix(pkHttp, FPath, 'bob', 'pw'));
  try
    EchoOnce(Sock, 'with credentials');
    AssertTrue('Proxy-Authorization line is sent',
      Pos('Proxy-Authorization: Basic ' + ProxyBasicCredentials('bob', 'pw') + #13#10,
        string(FScript.Head)) > 0);
  finally
    Sock.Close;
  end;
end;

procedure TUnixProxyDialTest.TestNon2xxAnswerRaisesConnectionError;
var
  Sock: IHttp2Socket;
begin
  StartUnixProxy(False);
  FScript.ConnectStatus := 'HTTP/1.1 407 Proxy Authentication Required';
  try
    Sock := DialThrough(TProxy.CreateUnix(pkHttp, FPath, '', ''));
    Sock.Close;
    Fail('a 407 answer must raise');
  except
    on E: EHttpConnectionError do
      AssertTrue('the message names the status', Pos('407', E.Message) > 0);
  end;
end;

procedure TUnixProxyDialTest.TestSocks5ThroughUnixProxy;
var
  Sock: IHttp2Socket;
begin
  StartUnixProxy(True);
  Sock := DialThrough(TProxy.CreateUnix(pkSocks5, FPath, '', ''));
  try
    EchoOnce(Sock, 'socks echo');
    AssertEquals('the host is sent as a domain name', 3, FScript.SeenAtyp);
    AssertEquals('the host name', 'example.test', string(FScript.SeenHost));
    AssertEquals('the port', 80, FScript.SeenPort);
  finally
    Sock.Close;
  end;
end;

procedure TUnixProxyDialTest.TestMissingProxySocketRaisesErrorNamingTheProxy;
var
  Path: string;
  Raised: Boolean;
begin
  Path := NewUnixTestPath;
  Raised := False;
  try
    DialThrough(TProxy.CreateUnix(pkHttp, Path, '', '')).Close;
  except
    on E: EHttpConnectionError do
    begin
      Raised := True;
      AssertTrue('the message names the proxy path',
        Pos(Path, E.Message) > 0);
    end;
  end;
  AssertTrue('a missing proxy socket raises', Raised);
end;

procedure TUnixProxyDialTest.TestTcpProxyStillWorks;
var
  Sock: IHttp2Socket;
begin
  StartTcpProxy;
  Sock := DialThrough(TProxy.Create('127.0.0.1', FTcpPort));
  try
    EchoOnce(Sock, 'tcp still works');
    AssertTrue('CONNECT head names the origin',
      Pos('CONNECT example.test:80', string(FScript.Head)) = 1);
  finally
    Sock.Close;
  end;
end;

initialization
  RegisterTest(TUnixProxyDialTest);

end.
