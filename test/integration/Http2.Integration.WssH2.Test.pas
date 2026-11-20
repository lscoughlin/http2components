{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, tls, alpn, mutual tls, integration, test
notes:
  - This unit holds integration tests between the library client and the
    library server over TLS. The server uses the generated test PKI.
  - The client opens a WebSocket over TLS with ALPN h2 (extended CONNECT of
    RFC 8441), over TLS with ALPN http/1.1 (the HTTP/1.1 Upgrade), and with a
    client certificate.
  - Each test starts its own server on a port that the system picks. TearDown
    stops the server and closes the client.
  - Every wait has a limit of 10 s and fails with a message.
  - The server handler records the request that it sees, as the unit
    Http2.Integration.WsH2.Test does. The server observer counts the TCP
    connections that the server accepts.
  - The server never offers http/1.1 alone. The server offers h2 and http/1.1
    when its fallback is on, and h2 alone when its fallback is off. No test
    therefore asks for an http/1.1-only server.
---
}
/// Integration tests of a WebSocket over TLS between the library client and the
/// library server
// - each test starts its own server and stops it in TearDown
unit Http2.Integration.WssH2.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common, Http2.Common.Body, Http2.Common.Headers, Http2.Common.Status,
  Http2.Common.Tls.Context, Http2.Common.Tls.Identity, Http2.Common.Tls.Policy,
  Http2.Client, Http2.Client.Errors, Http2.Client.Messages, Http2.Client.Stream,
  Http2.Server, Http2.Server.StreamAdapters, Http2.OpenSSL,
  Http2.Integration.WsH2.Test;

type
  /// what the server handler saw of the client certificate of a request
  // - the test reads a field only after the event of the record
  TWssCertRecord = class
  public
    /// set when the handler has seen a request on the WebSocket path
    RequestSeen: TEvent;
    /// true when the request carried a verified client certificate
    HasCertificate: Boolean;
    /// the common name of the verified client certificate
    CommonName: string;
    /// the request principal, which the server takes from the common name
    Principal: string;
    constructor Create;
    destructor Destroy; override;
  end;

  /// a handler that records the client certificate of the WebSocket request
  // - the handler of the request then runs the handler of the WebSocket route
  TWssCertHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FInner: IHttp2Handler;
    FCert: TWssCertRecord;
  public
    constructor Create(const AInner: IHttp2Handler; const ACert: TWssCertRecord);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a server observer that counts the connections that the server accepts
  TWssAcceptCounter = class(TInterfacedObject, IHttp2ServerObserver)
  public
    /// the number of connections that the server accepted since its start
    Accepted: Integer;
    procedure OnEvent(const AEvent: TServerEvent);
  end;

  /// the integration tests of a WebSocket over TLS
  TWssH2IntegrationTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FClient: IHttpClient;
    FRecord: TWsH2Record;
    FCert: TWssCertRecord;
    FCounter: TWssAcceptCounter;
    FCounterRef: IHttp2ServerObserver;
    procedure StartServer(const AMtls, AFallback: Boolean;
      const AOptions: TWsOptions);
    function NewClient(const AIdentity: ITLSIdentity): IHttpClient;
    function PkiFile(const AName: string): string;
    function WssUrl(const APath: string): string;
    function HttpsUrl(const APath: string): string;
    function WsRequest(const AUrl: string; const AListener: IWebSocketListener;
      const AMode: TWsProtocolMode): IWebSocketRequest;
    procedure AwaitEvent(const AEvent: TEvent; const AWhat: string);
    procedure AwaitRequest(const AMethod: string; const AIsH2: Boolean;
      const AProtocol: string);
    procedure AwaitCertificate(const AWhat: string);
    procedure AssertAccepted(const AExpected: Integer; const AWhat: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestWssEchoSelectsHttp2;
    procedure TestWssWithClientCertificate;
    procedure TestWssRequestClientCertificate;
    procedure TestWssLargeMessage;
    procedure TestWssAutoUsesAPooledHttp2Connection;
    procedure TestWssAutoWithoutAPooledConnectionUsesHttp1;
    procedure TestWssAutoAgainstAnH2OnlyServerFails;
  end;

implementation

const
  /// the path of the WebSocket route
  cPathWs = '/ws';
  /// the path of an ordinary request that answers 200
  cPathEcho = '/echo';
  /// the body of the ordinary answer on cPathEcho
  cEchoBody = 'ok';
  /// the wait for an event, in milliseconds
  cWaitMs = 10000;
  /// the close code of a normal close (RFC 6455 section 7.4.1)
  cCloseCodeNormal = 1000;
  /// the method of an extended CONNECT request
  cMethodConnect = 'CONNECT';
  /// the value of :protocol for a WebSocket
  cProtocolWebSocket = 'websocket';
  /// the method of an HTTP/1.1 Upgrade request
  cMethodGet = 'GET';
  /// the file names of the test PKI that the task makes (tools/server/certs)
  cPkiServerCert = 'server.crt';
  cPkiServerKey = 'server.key';
  cPkiCa = 'ca.crt';
  cPkiClientCert = 'alice.crt';
  cPkiClientKey = 'alice.key';
  /// the common name of the client certificate alice.crt
  cAliceName = 'alice';
  /// the environment variable that names the test PKI
  cEnvPki = 'HTTP2_TEST_PKI';
  /// the size of the large message, in octets: the largest message of the tests
  cLargeMessageSize = 4 * 1024 * 1024;
  /// the text that the echo test sends
  cEchoText = 'wss echo';
  /// the text that the pooled test sends
  cPooledText = 'pooled echo';
  /// the text that the HTTP/1.1 test sends
  cHttp1Text = 'http1 echo';

/// the octets of a byte string, one for each character; the bytes are copied
function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

/// true when two byte arrays hold the same octets
function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := Length(A) = Length(B);
  if Result and (Length(A) > 0) then
    Result := CompareMem(@A[0], @B[0], Length(A));
end;

/// the octets of a text; the characters are copied as bytes
function BytesOfText(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

/// the pattern of the large message: the octet of position I
function LargeMessage: TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, cLargeMessageSize);
  for I := 0 to High(Result) do
    Result[I] := Byte((I * 7) xor (I shr 8));
end;

/// closes the socket and does not raise; the test has already checked its result
procedure AbortQuietly(const ASocket: IWebSocket);
begin
  try
    if ASocket <> nil then
      ASocket.Abort;
  except
    // the test has already checked its result
  end;
end;

constructor TWssCertRecord.Create;
begin
  inherited Create;
  RequestSeen := TEvent.Create(nil, True, False, '');
end;

destructor TWssCertRecord.Destroy;
begin
  RequestSeen.Free;
  inherited Destroy;
end;

constructor TWssCertHandler.Create(const AInner: IHttp2Handler;
  const ACert: TWssCertRecord);
begin
  inherited Create;
  FInner := AInner;
  FCert := ACert;
end;

procedure TWssCertHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Cert: IClientCertificate;
begin
  if ARequest.Path = cPathWs then
  begin
    Cert := ARequest.ClientCertificate;
    FCert.HasCertificate := Cert <> nil;
    if Cert <> nil then
      FCert.CommonName := Cert.CommonName;
    FCert.Principal := ARequest.Principal;
    FCert.RequestSeen.SetEvent;
  end;
  FInner.Handle(ARequest, AResponse);
end;

procedure TWssAcceptCounter.OnEvent(const AEvent: TServerEvent);
begin
  if AEvent.Kind = seConnectionAccepted then
    InterlockedIncrement(Accepted);
end;

procedure TWssH2IntegrationTest.SetUp;
begin
  inherited SetUp;
  FServer := nil;
  FClient := nil;
  FRecord := nil;
  FCert := nil;
  FCounter := nil;
  FCounterRef := nil;
end;

procedure TWssH2IntegrationTest.TearDown;
begin
  try
    if FClient <> nil then
    begin
      try
        FClient.Close;
      except
        // the test has already checked its result
      end;
    end;
    if FServer <> nil then
      FServer.Stop;
  finally
    FClient := nil;
    FServer := nil;
    FCounterRef := nil;
    FCounter := nil;
    FreeAndNil(FCert);
    FreeAndNil(FRecord);
    inherited TearDown;
  end;
end;

function TWssH2IntegrationTest.PkiFile(const AName: string): string;
var
  Pki: string;
begin
  Pki := GetEnvironmentVariable(cEnvPki);
  Result := Pki + '/' + AName;
  if not FileExists(Result) then
    raise Exception.Create(cEnvPki + ' does not hold ' + AName);
end;

procedure TWssH2IntegrationTest.StartServer(const AMtls, AFallback: Boolean;
  const AOptions: TWsOptions);
var
  Identity: ITLSIdentity;
  Policy: TTlsServerPolicy;
  Factory: THttp2ServerFactory;
begin
  FRecord := TWsH2Record.Create;
  FCert := TWssCertRecord.Create;
  FCounter := TWssAcceptCounter.Create;
  FCounterRef := FCounter;
  Identity := TOpenSSLIdentity.FromPemFiles(PkiFile(cPkiServerCert),
    PkiFile(cPkiServerKey));
  Policy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity);
  if AMtls then
    Policy := Policy.WithTrustAnchors([PkiFile(cPkiCa)])
      .WithClientAuth(tlsAuthRequire);
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithHandler(TWssCertHandler.Create(TWsH2HttpHandler.Create(FRecord), FCert))
    .WithHandlerThreads(2).WithIOThreads(1).WithGracefulStopTimeout(250)
    .WithClearTextAllowed(False)
    .WithTlsContext(TOpenSSLTlsContextFactory.Create.WithServerPolicy(Policy).Build)
    .WithClientCertPrincipal(ccpCommonName)
    .WithHttp11Fallback(AFallback)
    .WithWebSockets(AOptions);
  FServer := Factory.Build(FCounterRef);
  FServer.Start;
end;

function TWssH2IntegrationTest.NewClient(const AIdentity: ITLSIdentity): IHttpClient;
var
  Factory: THttpClientFactory;
  Context: ITLSContext;
begin
  Context := TOpenSSLTlsContextFactory.Create.WithClientPolicy(
    TTlsClientPolicy.SecureDefault.WithTrustAnchors([PkiFile(cPkiCa)])).Build;
  Factory := THttpClientFactory.Create.WithTlsContext(Context)
    .WithConnectTimeout(2000).WithHeaderTimeout(3000);
  if AIdentity <> nil then
    Factory := Factory.WithClientIdentity(AIdentity);
  Result := Factory.Build;
end;

function TWssH2IntegrationTest.WssUrl(const APath: string): string;
begin
  Result := 'wss://localhost:' + IntToStr(FServer.Port) + APath;
end;

function TWssH2IntegrationTest.HttpsUrl(const APath: string): string;
begin
  Result := 'https://localhost:' + IntToStr(FServer.Port) + APath;
end;

function TWssH2IntegrationTest.WsRequest(const AUrl: string;
  const AListener: IWebSocketListener; const AMode: TWsProtocolMode): IWebSocketRequest;
begin
  // the listener gets every notification: the demand is one more after each one
  Result := TWebSocketRequest.Create(AUrl, AListener).WithProtocolMode(AMode)
    .WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000).WithAutoRequest(True);
end;

procedure TWssH2IntegrationTest.AwaitEvent(const AEvent: TEvent; const AWhat: string);
begin
  AssertEquals(AWhat + ' within 10 s', Ord(wrSignaled), Ord(AEvent.WaitFor(cWaitMs)));
end;

procedure TWssH2IntegrationTest.AwaitRequest(const AMethod: string;
  const AIsH2: Boolean; const AProtocol: string);
begin
  AwaitEvent(FRecord.RequestSeen, 'the server saw the request');
  AssertEquals('method of the request', AMethod, FRecord.Method);
  AssertEquals('the request is an HTTP/2 request', AIsH2, FRecord.IsH2);
  AssertEquals('value of :protocol', AProtocol, FRecord.Protocol);
end;

procedure TWssH2IntegrationTest.AwaitCertificate(const AWhat: string);
begin
  AwaitEvent(FCert.RequestSeen, AWhat);
  AssertTrue('the server saw a verified client certificate', FCert.HasCertificate);
  AssertEquals('common name of the client certificate', cAliceName, FCert.CommonName);
  AssertEquals('request principal', cAliceName, FCert.Principal);
end;

procedure TWssH2IntegrationTest.AssertAccepted(const AExpected: Integer;
  const AWhat: string);
begin
  AssertEquals(AWhat, AExpected, FCounter.Accepted);
end;

procedure TWssH2IntegrationTest.TestWssEchoSelectsHttp2;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(False, True, TWsOptions.Create);
  FClient := NewClient(nil);
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    // wpmHttp2 dials with the ALPN offer h2 alone
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmHttp2));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
    AssertEquals('one TLS connection', 1, FCounter.Accepted);
    Socket.SendText(cEchoText, True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('echoed text', cEchoText, Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWssH2IntegrationTest.TestWssWithClientCertificate;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, True, TWsOptions.Create);
  // the client identity of the factory is presented on every TLS connection
  FClient := NewClient(TOpenSSLIdentity.FromPemFiles(PkiFile(cPkiClientCert),
    PkiFile(cPkiClientKey)));
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmHttp2));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
    AwaitCertificate('the server saw the certificate of the WebSocket request');
    Socket.SendText(cEchoText, True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', cEchoText, Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWssH2IntegrationTest.TestWssRequestClientCertificate;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, True, TWsOptions.Create);
  // the factory has no identity: the identity of the request is the only one
  FClient := NewClient(nil);
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmHttp2)
      .WithClientIdentity(TOpenSSLIdentity.FromPemFiles(PkiFile(cPkiClientCert),
        PkiFile(cPkiClientKey))));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
    AwaitCertificate('the server saw the certificate of the request identity');
    Socket.SendText(cEchoText, True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', cEchoText, Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWssH2IntegrationTest.TestWssLargeMessage;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Sent: TBytes;
begin
  // the server limits of the defaults are 1 MiB for a message and 64 KiB for a frame
  StartServer(False, True, TWsOptions.Create.WithMaxMessageSize(cLargeMessageSize)
    .WithMaxFrameSize(cLargeMessageSize)
    .WithInboundPipeBytes(cLargeMessageSize + 1048576));
  FClient := NewClient(nil);
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmHttp2));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
    Sent := LargeMessage;
    Socket.SendBinary(Sent, True);
    AwaitEvent(FRecord.MessageSeen, 'the server message');
    AssertFalse('the server saw a binary message', FRecord.LastWasText);
    AssertEquals('server octet count', Length(Sent), Length(FRecord.LastMessage));
    AssertTrue('server octets are the sent octets',
      FRecord.LastMessage = TextOf(Sent));
    AwaitEvent(Listener.BytesDone, 'the 4 MiB echo');
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('echoed octet count', Length(Sent), Length(Listener.Bytes));
    AssertTrue('echoed octets are the sent octets', SameBytes(Sent, Listener.Bytes));
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWssH2IntegrationTest.TestWssAutoUsesAPooledHttp2Connection;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Response: IHttpResponse;
begin
  StartServer(False, True, TWsOptions.Create);
  FClient := NewClient(nil);
  // an ordinary https request over HTTP/2 leaves a pooled connection for the origin
  Response := FClient.Send(THttpRequest.Create(hmGet, HttpsUrl(cPathEcho)));
  AssertEquals('ordinary request status', HttpStatusOk, Response.StatusCode);
  AssertEquals('ordinary request body', cEchoBody, ReadText(Response));
  Response := nil;
  AssertAccepted(1, 'one TLS connection before the WebSocket');
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    // wpmAuto takes a stream of the pooled connection; it never dials h2 itself
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmAuto));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
    AssertAccepted(1, 'the WebSocket reused the pooled TLS connection');
    Socket.SendText(cPooledText, True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', cPooledText, Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWssH2IntegrationTest.TestWssAutoAgainstAnH2OnlyServerFails;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Failed: Boolean;
  ExcName: string;
begin
  // the server offers h2 alone, so the HTTP/1.1 dial of wpmAuto gets no protocol
  StartServer(False, False, TWsOptions.Create);
  FClient := NewClient(nil);
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  Failed := False;
  ExcName := '';
  try
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmAuto));
  except
    on E: EHttpConnectionError do
    begin
      Failed := True;
      ExcName := E.ClassName;
    end;
  end;
  AbortQuietly(Socket);
  Socket := nil;
  KeepListener := nil;
  AssertTrue('wpmAuto without a pooled connection fails the TLS handshake with ' +
    'EHttpConnectionError when the server offers h2 alone', Failed);
  AssertEquals('exception class', 'EHttpConnectionError', ExcName);
  AssertTrue('the server saw no request', FRecord.RequestSeen.WaitFor(0) <> wrSignaled);
end;

procedure TWssH2IntegrationTest.TestWssAutoWithoutAPooledConnectionUsesHttp1;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(False, True, TWsOptions.Create);
  FClient := NewClient(nil);
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    // no request has run on this client, so no pooled connection exists
    Socket := FClient.Send(WsRequest(WssUrl(cPathWs), KeepListener, wpmAuto));
    // the dial offers http/1.1 alone, and the server selects it: one connection
    AwaitRequest(cMethodGet, False, '');
    AssertAccepted(1, 'one TLS connection for the HTTP/1.1 route');
    Socket.SendText(cHttp1Text, True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', cHttp1Text, Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

initialization
  RegisterTest(TWssH2IntegrationTest);

end.
