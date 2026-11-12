{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests in this unit check THttpClientFactory.WithUnixProxy, its checks
    at Build, and a request that goes through a proxy on a socket file.
---
}
/// Tests for the client option WithUnixProxy
// - each test runs its own listener on a fresh socket file, and removes the
//   file in TearDown
unit Http2.Client.UnixProxyClient.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client.Proxy.Types,
  Http2.Client.Messages, Http2.Client.Factory, Http2.Client,
  mormot.lib.openssl11, Http2.Client.Tls.Support,
  Http2.Client.Test.OpenSSL.SigPipe, Http2.Client.Test.TlsContext,
  Http2.Client.Unix.TestKit, Http2.Client.UnixClientWire.Test;

type
  /// a proxy listener on a socket file. It answers CONNECT with 200, then
  /// answers the origin request inside the tunnel with 200.
  TConnectProxyListener = class(TUnixListener)
  private
    FHead: RawByteString;
    FInner: RawByteString;
  public
    /// reads the CONNECT head, then the request head inside the tunnel
    procedure Serve(AFd: Integer); override;
    /// the CONNECT head that the listener read
    property Head: RawByteString read FHead;
    /// the request head that arrived inside the tunnel
    property Inner: RawByteString read FInner;
  end;

  /// a proxy listener on a socket file. It answers CONNECT with 200, then
  /// runs a TLS server handshake with the test certificate on the tunnel,
  /// so the tunnel acts as the origin. It answers one request over TLS.
  TConnectTlsProxyListener = class(TUnixListener)
  private
    FHead: RawByteString;
    FRequest: RawByteString;
    FHandshake: Integer;
  public
    /// reads the CONNECT head, then the TLS handshake and the request
    procedure Serve(AFd: Integer); override;
    /// the CONNECT head that the listener read
    property Head: RawByteString read FHead;
    /// the request head that arrived inside the TLS session
    property Request: RawByteString read FRequest;
    /// 1 when the server handshake on the tunnel succeeded
    property HandshakeResult: Integer read FHandshake;
  end;

  /// a selector that answers one fixed proxy for every URI
  TFixedProxySelector = class(TInterfacedObject, IProxySelector)
  private
    FProxy: IProxy;
  public
    constructor Create(const AProxy: IProxy);
    function SelectProxy(const AUri: string): IProxy;
  end;

  /// tests for THttpClientFactory.WithUnixProxy
  TUnixProxyClientTest = class(TTestCase)
  private
    FPath: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestWithUnixProxyIsCopyOnWrite;
    procedure TestLaterCallWins;
    procedure TestBuildRaisesForBadProxyPath;
    procedure TestBuildRaisesWhenUnixSocketAndUnixProxy;
    procedure TestBuildRaisesWhenUnixSocketAndSelector;
    procedure TestSelectorReturningABadUnixProxyFailsAtDialAsProxyConfigError;
    procedure TestNoProxyHostGoesDirectOverTcp;
    procedure TestRequestGoesThroughTheUnixProxy;
    procedure TestHttpsOriginThroughUnixProxyUsesTlsToTheOrigin;
  end;

implementation

const
  /// the blank line that ends an HTTP/1.1 head
  HeadEndMark = #13#10#13#10;
  /// the answer to CONNECT: the tunnel is open
  ConnectAnswer = 'HTTP/1.1 200 Connection established'#13#10#13#10;
  /// the answer to the origin request inside the tunnel
  OriginAnswer = 'HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10 +
    'Connection: close'#13#10#13#10;

/// reads from a descriptor until AMarker arrives, the peer closes or the
/// timeout expires; returns what arrived
function ReadHeadUntil(AFd: Integer; const AMarker: RawByteString;
  const ATimeoutMs: Integer): RawByteString;
var
  Pfd: pollfd;
  Buf: array[0..511] of Byte;
  N, Old: Integer;
begin
  Result := '';
  while Pos(AMarker, Result) = 0 do
  begin
    Pfd.fd := AFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    if fpPoll(@Pfd, 1, ATimeoutMs) <= 0 then
      Break;
    N := fpRecv(AFd, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then
      Break;
    Old := Length(Result);
    SetLength(Result, Old + N);
    Move(Buf[0], Result[Old + 1], N);
  end;
end;

/// the path of AChars bytes after the leading slash
function AbsolutePathOfLength(const ALength: Integer): string;
begin
  Result := '/' + StringOfChar('a', ALength - 1);
end;

/// reads over a TLS session until AMarker arrives, the peer closes or the
/// timeout expires; the descriptor of the session is polled first
function ReadTlsHeadUntil(ASsl: PSSL; AFd: Integer;
  const AMarker: RawByteString; const ATimeoutMs: Integer): RawByteString;
var
  Pfd: pollfd;
  Buf: array[0..511] of Byte;
  N, Old: Integer;
begin
  Result := '';
  while Pos(AMarker, Result) = 0 do
  begin
    Pfd.fd := AFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    if fpPoll(@Pfd, 1, ATimeoutMs) <= 0 then
      Break;
    N := TestSslRead(ASsl, @Buf[0], SizeOf(Buf));
    if N <= 0 then
      Break;
    Old := Length(Result);
    SetLength(Result, Old + N);
    Move(Buf[0], Result[Old + 1], N);
  end;
end;

/// true when Build raises EHttpUnixSocketConfigError
function BuildRaisesUnixConfigError(const AFactory: THttpClientFactory): Boolean;
begin
  Result := False;
  try
    AFactory.Build;
  except
    on EHttpUnixSocketConfigError do
      Result := True;
  end;
end;

{ TConnectProxyListener }

procedure TConnectProxyListener.Serve(AFd: Integer);
begin
  FHead := ReadHeadUntil(AFd, HeadEndMark, 3000);
  WriteAll(AFd, ConnectAnswer);
  FInner := ReadHeadUntil(AFd, HeadEndMark, 3000);
  WriteAll(AFd, OriginAnswer);
end;

{ TConnectTlsProxyListener }

procedure TConnectTlsProxyListener.Serve(AFd: Integer);
var
  Ctx: PSSL_CTX;
  Ssl: PSSL;
  Answer: RawByteString;
begin
  Answer := OriginAnswer;
  FHandshake := 0;
  FHead := ReadHeadUntil(AFd, HeadEndMark, 3000);
  WriteAll(AFd, ConnectAnswer);
  Ctx := SSL_CTX_new(TLS_server_method());
  try
    SSL_CTX_use_certificate_file(Ctx,
      PUtf8Char(UTF8String(TestCertPath('localhost.crt'))), SSL_FILETYPE_PEM);
    SSL_CTX_use_PrivateKey_file(Ctx,
      PUtf8Char(UTF8String(TestCertPath('localhost.key'))), SSL_FILETYPE_PEM);
    Ssl := SSL_new(Ctx);
    try
      SSL_set_fd(Ssl, AFd);
      FHandshake := TestSslAccept(Ssl);
      if FHandshake = 1 then
      begin
        FRequest := ReadTlsHeadUntil(Ssl, AFd, HeadEndMark, 3000);
        TestSslWrite(Ssl, Pointer(Answer), Length(Answer));
      end;
      TestSslShutdown(Ssl);
    finally
      SSL_free(Ssl);
    end;
  finally
    SSL_CTX_free(Ctx);
  end;
end;

{ TFixedProxySelector }

constructor TFixedProxySelector.Create(const AProxy: IProxy);
begin
  inherited Create;
  FProxy := AProxy;
end;

function TFixedProxySelector.SelectProxy(const AUri: string): IProxy;
begin
  Result := FProxy;
end;

{ TUnixProxyClientTest }

procedure TUnixProxyClientTest.SetUp;
begin
  FPath := NewUnixTestPath;
end;

procedure TUnixProxyClientTest.TearDown;
begin
  if FileExists(FPath) then
    DeleteFile(FPath);
end;

procedure TUnixProxyClientTest.TestWithUnixProxyIsCopyOnWrite;
var
  A, B: THttpClientFactory;
begin
  A := THttpClientFactory.Create;
  B := A.WithUnixProxy('/tmp/h2-proxy.sock');
  AssertEquals('', A.UnixProxyPath);
  AssertEquals('/tmp/h2-proxy.sock', B.UnixProxyPath);
  AssertFalse('a Unix proxy is not a TCP proxy', B.ProxyHost <> '');
end;

procedure TUnixProxyClientTest.TestLaterCallWins;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create.WithProxy('proxy.corp', 3128)
    .WithUnixProxy('/tmp/h2-proxy.sock');
  AssertEquals('Unix proxy after WithProxy', '/tmp/h2-proxy.sock', F.UnixProxyPath);
  AssertEquals('TCP proxy host cleared', '', F.ProxyHost);
  AssertFalse('Build accepts the Unix proxy', BuildRaisesUnixConfigError(F));

  F := THttpClientFactory.Create.WithUnixProxy('/tmp/h2-proxy.sock')
    .WithProxy('proxy.corp', 3128);
  AssertEquals('TCP proxy after WithUnixProxy', '', F.UnixProxyPath);
  AssertEquals('TCP proxy host kept', 'proxy.corp', F.ProxyHost);
  AssertEquals('TCP proxy port kept', 3128, F.ProxyPort);
end;

procedure TUnixProxyClientTest.TestBuildRaisesForBadProxyPath;
begin
  AssertTrue('relative path',
    BuildRaisesUnixConfigError(THttpClientFactory.Create.WithUnixProxy('h2.sock')));
  AssertTrue('path of 104 bytes',
    BuildRaisesUnixConfigError(THttpClientFactory.Create.WithUnixProxy(
      AbsolutePathOfLength(104))));
  AssertTrue('TLS to the proxy is refused',
    BuildRaisesUnixConfigError(THttpClientFactory.Create.WithUnixProxy(
      '/tmp/h2-proxy.sock', pkHttps)));
end;

procedure TUnixProxyClientTest.TestBuildRaisesWhenUnixSocketAndUnixProxy;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithUnixProxy('/tmp/h2-proxy.sock')));
end;

procedure TUnixProxyClientTest.TestBuildRaisesWhenUnixSocketAndSelector;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithProxySelector(TFixedProxySelector.Create(nil))));
end;

procedure TUnixProxyClientTest.TestSelectorReturningABadUnixProxyFailsAtDialAsProxyConfigError;
var
  Client: IHttpClient;
  Failed: Boolean;
begin
  Client := THttpClientFactory.Create.WithClearText(ctHttp1)
    .WithProxySelector(TFixedProxySelector.Create(
      TProxy.CreateUnix(pkHttp, 'relative.sock', '', '')))
    .Build;
  Failed := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
  except
    on EHttpProxyConfigError do
      Failed := True;
  end;
  AssertTrue('the bad proxy path raises at dial', Failed);
end;

procedure TUnixProxyClientTest.TestNoProxyHostGoesDirectOverTcp;
var
  L: TUnixListener;
  T: TTcpAnswerListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  L := TUnixListener.Create(FPath);
  try
    T := TTcpAnswerListener.Create;
    try
      Client := THttpClientFactory.Create.WithUnixProxy(FPath)
        .WithNoProxy('127.0.0.1').WithClearText(ctHttp1)
        .WithConnectTimeout(2000).WithHeaderTimeout(3000).Build;
      R := Client.Send(THttpRequest.Create(hmGet,
        'http://127.0.0.1:' + IntToStr(T.Port) + '/x'));
      AssertEquals('status', 200, R.StatusCode);
      AssertEquals('the proxy file gets no connection', 0, L.Accepted);
      Client.Close;
    finally
      T.Free;
    end;
  finally
    L.Free;
  end;
end;

procedure TUnixProxyClientTest.TestRequestGoesThroughTheUnixProxy;
var
  L: TConnectProxyListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  L := TConnectProxyListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixProxy(FPath)
      .WithClearText(ctHttp1).WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    AssertEquals('status', 200, R.StatusCode);
    AssertEquals('one connection on the file', 1, L.Accepted);
    AssertTrue('CONNECT to the origin', Pos('CONNECT example.test:80 HTTP/1.1',
      L.Head) = 1);
    AssertTrue('origin request in the tunnel', Pos('GET /x HTTP/1.1', L.Inner) = 1);
    AssertTrue('Host header', Pos('Host: example.test', L.Inner) > 0);
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixProxyClientTest.TestHttpsOriginThroughUnixProxyUsesTlsToTheOrigin;
var
  L: TConnectTlsProxyListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  // the fake origin is a TLS server, so the test needs the OpenSSL provider
  // and the test certificate
  if not OpenSslIsAvailable then
  begin
    AssertTrue('OpenSSL unavailable; skipped', True);
    Exit;
  end;
  if (not FileExists(TestCertPath('localhost.crt'))) or
     (not FileExists(TestCertPath('localhost.key'))) then
  begin
    AssertTrue('test certs unavailable; skipped', True);
    Exit;
  end;
  L := TConnectTlsProxyListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixProxy(FPath)
      .WithTlsContext(OpenSslClientTestContext('', True))
      .WithHttp1Fallback.WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'https://example.test/x'));
    AssertEquals('status', 200, R.StatusCode);
    AssertEquals('one connection on the file', 1, L.Accepted);
    AssertTrue('CONNECT to the origin on port 443', Pos(
      'CONNECT example.test:443 HTTP/1.1', L.Head) = 1);
    AssertEquals('TLS handshake with the origin through the tunnel', 1,
      L.HandshakeResult);
    AssertTrue('origin request inside TLS', Pos('GET /x HTTP/1.1', L.Request) = 1);
    Client.Close;
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TUnixProxyClientTest);
end.
