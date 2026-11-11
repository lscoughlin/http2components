{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this contains shared Mutual TLS test setup and helpers
---
}
unit Http2.Client.MutualTls.Support;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  mormot.core.base, mormot.core.os, mormot.lib.openssl11,
  Http2.Client.Errors, Http2.Client.ClientCert, Http2.Client.Proxy, Http2.Client.Tls, Http2.Client.Messages,
  Http2.Client.Stream,
  Http2.Client,
  Http2.Client.Sse, Http2.Client.WebSocket, Http2.Client.RequestObserver,
  Http2.Client.RequestObserver.Support, Http2.Client.MutualTls.Server.Support,
  Http2.Client.MutualTls.Client.Support;

type
  TMutualTlsTestBase = class(TTestCase)
  protected
    FServer: TMtlsServer;
    FProxy: TTunnelProxy;
    /// the identity for the TLS leg to an https proxy (nil = none)
    FProxyIdentity: IClientIdentity;
    function StartServer(const AKind: TMtlsKind; const AVersion: Integer;
      const AOptionalCert: Boolean = False): TMtlsServer;
    function RouteVia(const AFactory: THttpClientFactory): THttpClientFactory;
    function Url(const AScheme: string = 'https'): string;
    function GoodIdentity: IClientIdentity;
    function NewClient(const AIdentity: IClientIdentity;
      const AFallback: Boolean = False): IHttpClient;
    function Fetch(const AClient: IHttpClient; out ABody: string): Integer;
    function AlertOfFetch(const AClient: IHttpClient): string;
    procedure RunAccepts(const AKind: TMtlsKind; const AVersion: Integer;
      const AFallback: Boolean);
    procedure RunSse(const AVersion: Integer);
    procedure RunWebSocket(const AVersion: Integer);
    procedure RunNoIdentity(const AKind: TMtlsKind; const AVersion: Integer;
      const AFallback: Boolean; const AExpected: string);
    procedure RunWrongCa(const AVersion: Integer);
    procedure RunExpiredOnTheWire(const AVersion: Integer;
      const AExpected: string);
    procedure RunTunnel(const AMode: TTunnelMode; const AVersion: Integer);
    function ServerUrl(const AServer: TMtlsServer): string;
    function SendTo(const AClient: IHttpClient; const AUrl: string): IHttpResponse;
    function ReadBody(const AResponse: IHttpResponse): string;
    function Client2Identity: IClientIdentity;
    function SubjectIs(const ASubject, AName: string): Boolean;
    procedure RunSelectorVia(const AMode: TTunnelMode);
    procedure RunWssVia(const AMode: TTunnelMode; const AWho: TIdentitySource;
      const AViaProxy: Boolean);
    procedure RunRequestVia(const AViaProxy: Boolean; const AMode: TTunnelMode);
    function KeysOf(const AClient: IHttpClient): string;
    function CountOf(const ASub, AText: string): Integer;
    function SelectorClient(const ASelector: IClientIdentitySelector): IHttpClient;
    function ProbeAlert(const AVersion: Integer;
      const AIdentity: IClientIdentity; const AKind: TMtlsKind): string;
    procedure TearDown; override;
  end;

implementation

procedure TMutualTlsTestBase.TearDown;
begin
  FProxyIdentity := nil;
  if FProxy <> nil then
  begin
    FProxy.Stop;
    FreeAndNil(FProxy);
  end;
  if FServer <> nil then
  begin
    FServer.Stop;
    FreeAndNil(FServer);
  end;
end;

function TMutualTlsTestBase.StartServer(const AKind: TMtlsKind;
  const AVersion: Integer; const AOptionalCert: Boolean): TMtlsServer;
begin
  if not OpenSslIsAvailable then
    Fail('OpenSSL is not available: set OPENSSL_LIBPATH');
  FServer := TMtlsServer.Create(AKind, AVersion, AOptionalCert);
  Result := FServer;
end;

function TMutualTlsTestBase.Url(const AScheme: string): string;
begin
  Result := Format('%s://localhost:%d/', [AScheme, FServer.Port]);
end;

function TMutualTlsTestBase.GoodIdentity: IClientIdentity;
begin
  Result := TClientIdentity.FromPemFiles(Fixture('client-chain.pem'),
    Fixture('client.key'));
end;

function TMutualTlsTestBase.NewClient(const AIdentity: IClientIdentity;
  const AFallback: Boolean): IHttpClient;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(5000);
  if AIdentity <> nil then
    F := F.WithClientIdentity(AIdentity);
  if AFallback then
    F := F.WithHttp1Fallback(True);
  Result := RouteVia(F).Build;
end;

/// loopback origins bypass the built-in selectors, so route through FProxy
/// explicitly when there is one
function TMutualTlsTestBase.RouteVia(
  const AFactory: THttpClientFactory): THttpClientFactory;
begin
  Result := AFactory;
  if FProxyIdentity <> nil then
    Result := Result.WithProxyClientIdentity(FProxyIdentity);
  if FProxy <> nil then
    case FProxy.Mode of
      tmConnect: Result := Result.WithProxySelector(
        TFixedSelector.Create(pkHttp, FProxy.Port));
      tmSocks5: Result := Result.WithProxySelector(
        TFixedSelector.Create(pkSocks5, FProxy.Port));
      tmHttps: Result := Result.WithProxySelector(
        TFixedSelector.Create(pkHttps, FProxy.Port));
    end;
end;

function TMutualTlsTestBase.Fetch(const AClient: IHttpClient;
  out ABody: string): Integer;
var
  Resp: IHttpResponse;
  Raw: TBytes;
begin
  Resp := AClient.Send(THttpRequest.Create(hmGet, Url));
  Result := Resp.StatusCode;
  Raw := ReadAllBodyBytes(Resp.Body);
  SetString(ABody, PAnsiChar(@Raw[0]), Length(Raw));
end;

function TMutualTlsTestBase.AlertOfFetch(const AClient: IHttpClient): string;
var
  Body: string;
begin
  Result := '';
  try
    Fetch(AClient, Body);
    Fail('the request must be rejected');
  except
    on E: EHttpTlsClientAuthError do
      Result := E.Alert;
  end;
end;

procedure TMutualTlsTestBase.RunAccepts(const AKind: TMtlsKind;
  const AVersion: Integer; const AFallback: Boolean);
var
  Client: IHttpClient;
  Body: string;
begin
  StartServer(AKind, AVersion);
  Client := NewClient(GoodIdentity, AFallback);
  AssertEquals('status', 200, Fetch(Client, Body));
  AssertEquals('body', 'ok', Body);
  Client.Close;
  FServer.Stop;
  AssertEquals('one handshake completed', 1, FServer.Handshakes);
  AssertEquals('one request', 1, FServer.Requests);
  AssertTrue('the server saw the client certificate',
    Pos('mtls client', FServer.LastSubject) > 0);
end;

procedure TMutualTlsTestBase.RunSse(const AVersion: Integer);
var
  Client: IHttpClient;
  Source: TSseSource;
  Event: TSseEvent;
begin
  StartServer(mkSse, AVersion);
  Client := NewClient(GoodIdentity, True);
  Source := TSseSource.Create(Client.Send(SseRequest(Url)));
  try
    AssertTrue('an event arrived', Source.ReadEvent(Event));
    AssertEquals('data', 'hello', Event.Data);
  finally
    Source.Close;
  end;
  Client.Close;
  FServer.Stop;
  AssertEquals('one handshake completed', 1, FServer.Handshakes);
  AssertTrue('the server saw the client certificate',
    Pos('mtls client', FServer.LastSubject) > 0);
end;

procedure TMutualTlsTestBase.RunWebSocket(const AVersion: Integer);
var
  Client: IHttpClient;
  Rec: TWsRecorder;
  RecRef: IWebSocketListener;
  Sock: IWebSocket;
begin
  StartServer(mkWebSocket, AVersion);
  Client := NewClient(GoodIdentity);
  Rec := TWsRecorder.Create;
  RecRef := Rec;
  Sock := Client.Send(TWebSocketRequest.Create(
    Format('wss://localhost:%d/chat', [FServer.Port]), RecRef).WithAutoRequest);
  AssertTrue('the server sent a message', Rec.WaitText(4000));
  AssertEquals('text', 'hello', Rec.Text);
  Sock.Close;
  Sleep(50);
  Client.Close;
  FServer.Stop;
  AssertEquals('one handshake completed', 1, FServer.Handshakes);
  AssertTrue('the server saw the client certificate',
    Pos('mtls client', FServer.LastSubject) > 0);
end;

procedure TMutualTlsTestBase.RunNoIdentity(const AKind: TMtlsKind;
  const AVersion: Integer; const AFallback: Boolean; const AExpected: string);
var
  Client: IHttpClient;
  Alert: string;
begin
  StartServer(AKind, AVersion);
  Client := NewClient(nil, AFallback);
  Alert := AlertOfFetch(Client);
  Client.Close;
  FServer.Stop;
  AssertEquals('the alert', AExpected, Alert);
  AssertEquals('one connection: no retry, no fallback dial', 1,
    FServer.Connections);
  AssertEquals('the handshake never completed', 0, FServer.Handshakes);
end;

procedure TMutualTlsTestBase.RunWrongCa(const AVersion: Integer);
var
  Client: IHttpClient;
  Alert: string;
begin
  StartServer(mkH2, AVersion);
  Client := NewClient(TClientIdentity.FromPemFiles(Fixture('other-client.crt'),
    Fixture('other-client.key')));
  Alert := AlertOfFetch(Client);
  Client.Close;
  FServer.Stop;
  AssertEquals('the alert', 'unknown ca', Alert);
  AssertEquals('one connection', 1, FServer.Connections);
end;

/// dial straight through TTlsSocket (Build refuses an expired identity) and
/// report the alert, whether it surfaces in the handshake or on the first read
function TMutualTlsTestBase.ProbeAlert(const AVersion: Integer;
  const AIdentity: IClientIdentity; const AKind: TMtlsKind): string;
var
  Sock: IHttp2Socket;
  B: array[0..8] of Byte;
begin
  Result := '';
  try
    Sock := TTlsSocket.DialWithAlpn('localhost', FServer.Port,
      AlpnProtocolList([cHttp2AlpnProtocol, cHttp11AlpnProtocol]), False, 3000,
      Fixture('ca.crt'), '', 0, AIdentity);
    B[0] := 0;
    Sock.Write(B[0], 1);
    Sock.Read(B[0], 9);
    Fail('the server must reject the certificate');
  except
    on E: EHttpTlsClientAuthError do
      Result := E.Alert;
  end;
end;

procedure TMutualTlsTestBase.RunExpiredOnTheWire(const AVersion: Integer;
  const AExpected: string);
var
  Alert: string;
begin
  StartServer(mkH2, AVersion);
  Alert := ProbeAlert(AVersion, TClientIdentity.FromPemFiles(
    Fixture('expired.crt'), Fixture('expired.key')), mkH2);
  FServer.Stop;
  AssertEquals('the alert', AExpected, Alert);
end;

/// the origin identity reaches the origin through every kind of proxy; an
/// https proxy sees only the proxy identity on its own leg
procedure TMutualTlsTestBase.RunTunnel(const AMode: TTunnelMode;
  const AVersion: Integer);
var
  Client: IHttpClient;
  Body: string;
begin
  StartServer(mkH2, AVersion);
  FProxy := TTunnelProxy.Create(AMode, FServer.Port, AMode = tmHttps,
    AVersion);
  if AMode = tmHttps then
    FProxyIdentity := Client2Identity;
  Client := NewClient(GoodIdentity);
  AssertEquals('status', 200, Fetch(Client, Body));
  AssertEquals('body', 'ok', Body);
  Client.Close;
  FProxy.Stop;
  FServer.Stop;
  AssertEquals('one tunnel', 1, FProxy.Tunnels);
  AssertEquals('one origin handshake', 1, FServer.Handshakes);
  AssertTrue('the origin saw the origin identity',
    SubjectIs(FServer.LastSubject, 'mtls client'));
  AssertFalse('the origin never sees the proxy identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  if AMode = tmHttps then
  begin
    AssertTrue('the https proxy saw a certificate', FProxy.SawClientCert);
    AssertTrue('the proxy saw the proxy identity',
      SubjectIs(FProxy.LastSubject, 'mtls client two'));
    AssertFalse('the proxy never sees the origin identity',
      SubjectIs(FProxy.LastSubject, 'mtls client'));
  end
  else
    AssertFalse('there is no TLS to this proxy to present one on',
      FProxy.SawClientCert);
end;

function TMutualTlsTestBase.ServerUrl(const AServer: TMtlsServer): string;
begin
  Result := Format('https://localhost:%d/', [AServer.Port]);
end;

function TMutualTlsTestBase.SendTo(const AClient: IHttpClient;
  const AUrl: string): IHttpResponse;
begin
  Result := AClient.Send(THttpRequest.Create(hmGet, AUrl));
end;

function TMutualTlsTestBase.ReadBody(const AResponse: IHttpResponse): string;
var
  Raw: TBytes;
begin
  Raw := ReadAllBodyBytes(AResponse.Body);
  Result := '';
  if Length(Raw) > 0 then
    SetString(Result, PAnsiChar(@Raw[0]), Length(Raw));
end;

function TMutualTlsTestBase.Client2Identity: IClientIdentity;
begin
  Result := TClientIdentity.FromPemFiles(Fixture('client2-chain.pem'),
    Fixture('client2.key'));
end;

/// the subject's common name is exactly AName ('mtls client' is not a match
/// for 'mtls client two')
function TMutualTlsTestBase.SubjectIs(const ASubject, AName: string): Boolean;
var
  P, After: Integer;
begin
  P := Pos('CN=' + AName, ASubject);
  After := P + Length('CN=' + AName);
  Result := (P > 0) and ((After > Length(ASubject)) or
    (ASubject[After] in [',', '/']));
end;

/// a client whose identity comes only from ASelector; HTTP/1.1 is allowed so
/// one connection serves one request and the next request dials again
function TMutualTlsTestBase.SelectorClient(
  const ASelector: IClientIdentitySelector): IHttpClient;
begin
  Result := RouteVia(THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(5000)
    .WithHttp1Fallback(True)
    .WithClientIdentitySelector(ASelector))
    .Build;
end;

function TMutualTlsTestBase.KeysOf(const AClient: IHttpClient): string;
var
  Stats: TPoolStats;
  I: Integer;
begin
  Stats := (AClient as THttpClient).PoolStats;
  Result := '';
  for I := 0 to High(Stats.PerOrigin) do
    Result := Result + Stats.PerOrigin[I].Origin + '|';
end;

function TMutualTlsTestBase.CountOf(const ASub, AText: string): Integer;
var
  P: Integer;
  Rest: string;
begin
  Result := 0;
  Rest := AText;
  repeat
    P := Pos(ASub, Rest);
    if P = 0 then
      Break;
    Inc(Result);
    Rest := Copy(Rest, P + Length(ASub), MaxInt);
  until False;
end;

/// the selector is asked with the origin's host and port on every route, the
/// origin sees its answer, and an https proxy sees the proxy identity only;
/// the key carries the origin identity fingerprint
procedure TMutualTlsTestBase.RunSelectorVia(const AMode: TTunnelMode);
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Keys: string;
begin
  StartServer(mkH2, cTls13);
  FProxy := TTunnelProxy.Create(AMode, FServer.Port, AMode = tmHttps);
  if AMode = tmHttps then
    FProxyIdentity := GoodIdentity;
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := Client2Identity;
  Client := SelectorClient(SelRef);
  AssertEquals('status', 200, SendTo(Client, Url).StatusCode);
  AssertEquals('pooled', 200, SendTo(Client, Url).StatusCode);
  Keys := KeysOf(Client);
  Client.Close;
  FProxy.Stop;
  FServer.Stop;
  AssertEquals('one dial, one call', 1, Sel.Calls);
  AssertEquals('asked for the origin host', 'localhost', Sel.LastHost);
  AssertEquals('asked for the origin port', FServer.Port, Sel.LastPort);
  AssertTrue('the origin saw the selector identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  AssertTrue('the key carries the origin identity fingerprint',
    Pos(Client2Identity.Fingerprint, Keys) > 0);
  if AMode = tmHttps then
  begin
    AssertTrue('the proxy saw the proxy identity only',
      SubjectIs(FProxy.LastSubject, 'mtls client'));
    AssertFalse('the proxy never sees the selector identity',
      SubjectIs(FProxy.LastSubject, 'mtls client two'));
  end
  else
    AssertFalse('no TLS to the proxy', FProxy.SawClientCert);
  AssertEquals('one tunnel, one pooled connection', 1, FProxy.Tunnels);
end;

{ accepted identity }


procedure TMutualTlsTestBase.RunWssVia(const AMode: TTunnelMode;
  const AWho: TIdentitySource; const AViaProxy: Boolean);
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Rec: TWsRecorder;
  RecRef: IWebSocketListener;
  Sock: IWebSocket;
  Req: IWebSocketRequest;
begin
  StartServer(mkWebSocket, cTls13);
  if AViaProxy then
  begin
    FProxy := TTunnelProxy.Create(AMode, FServer.Port, AMode = tmHttps);
    if AMode = tmHttps then
      FProxyIdentity := GoodIdentity;
  end;
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := Client2Identity;
  case AWho of
    isSelector: Client := SelectorClient(SelRef);
    isRequest: Client := NewClient(nil);
  else
    Client := NewClient(Client2Identity);
  end;
  Rec := TWsRecorder.Create;
  RecRef := Rec;
  Req := TWebSocketRequest.Create(
    Format('wss://localhost:%d/chat', [FServer.Port]), RecRef).WithAutoRequest;
  if AWho = isRequest then
    Req := Req.WithClientIdentity(Client2Identity);
  Sock := Client.Send(Req);
  AssertTrue('the server sent a message', Rec.WaitText(4000));
  Sock.Close;
  Sleep(50);
  Client.Close;
  if FProxy <> nil then
    FProxy.Stop;
  FServer.Stop;
  AssertTrue('the origin saw the origin identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  if AWho = isSelector then
  begin
    AssertEquals('one selector call', 1, Sel.Calls);
    AssertEquals('asked for the origin port', FServer.Port, Sel.LastPort);
  end
  else
    AssertEquals('no selector call', 0, Sel.Calls);
  if AViaProxy and (AMode = tmHttps) then
  begin
    AssertTrue('the proxy saw the proxy identity only',
      SubjectIs(FProxy.LastSubject, 'mtls client'));
    AssertFalse('the proxy never sees the origin identity',
      SubjectIs(FProxy.LastSubject, 'mtls client two'));
  end
  else if AViaProxy then
    AssertFalse('no TLS to the proxy', FProxy.SawClientCert);
end;

procedure TMutualTlsTestBase.RunRequestVia(const AViaProxy: Boolean;
  const AMode: TTunnelMode);
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Keys: string;
begin
  StartServer(mkH2, cTls13);
  if AViaProxy then
  begin
    FProxy := TTunnelProxy.Create(AMode, FServer.Port, AMode = tmHttps);
    if AMode = tmHttps then
      FProxyIdentity := GoodIdentity;
  end;
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := SelectorClient(SelRef);
  AssertEquals('status', 200, Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(Client2Identity)).StatusCode);
  AssertEquals('pooled', 200, Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(Client2Identity)).StatusCode);
  Keys := KeysOf(Client);
  Client.Close;
  if FProxy <> nil then
    FProxy.Stop;
  FServer.Stop;
  AssertEquals('the selector is not asked', 0, Sel.Calls);
  AssertTrue('the origin saw the request identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  AssertEquals('one origin handshake: the second request reused it', 1,
    FServer.Handshakes);
  AssertTrue('the key carries the request identity fingerprint',
    Pos(Client2Identity.Fingerprint, Keys) > 0);
  if AViaProxy and (AMode = tmHttps) then
  begin
    AssertTrue('the proxy saw the proxy identity only',
      SubjectIs(FProxy.LastSubject, 'mtls client'));
    AssertFalse('the proxy never sees the request identity',
      SubjectIs(FProxy.LastSubject, 'mtls client two'));
  end
  else if AViaProxy then
    AssertFalse('no TLS to the proxy', FProxy.SawClientCert);
end;


end.
