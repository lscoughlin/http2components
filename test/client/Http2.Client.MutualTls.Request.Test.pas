{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves Mutual TLS client tests from the source project
---
}
unit Http2.Client.MutualTls.Request.Test;

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
  Http2.Client.RequestObserver.Support, Http2.Client.MutualTls.Support,
  Http2.Client.MutualTls.Server.Support,
  Http2.Client.MutualTls.Client.Support;

type
  TMutualTlsRequestTest = class(TMutualTlsTestBase)
  published
    procedure TestRequestIdentityAccessorsAndClone;
    procedure TestRequestIdentityDirect;
    procedure TestRequestIdentityThroughConnect;
    procedure TestRequestIdentityThroughSocks5;
    procedure TestRequestIdentityThroughAnHttpsProxy;
    procedure TestTwoRequestIdentitiesOnOneOriginDoNotShareAConnection;
    procedure TestRequestIdentityWinsOverTheSelector;
    procedure TestRequestIdentityWinsOverTheFixedIdentity;
    procedure TestRequestWithoutIdentityKeepsThePlainKey;
    procedure TestRedirectToTheSameOriginKeepsTheRequestIdentity;
    procedure TestRedirectToAnotherOriginDropsTheRequestIdentity;
    procedure TestWssRequestIdentityDirect;
    procedure TestWssRequestIdentityThroughAnHttpsProxy;
    procedure TestSseRequestIdentity;
    procedure TestExpiredRequestIdentityRaisesBeforeDialling;
    procedure TestExpiredWssRequestIdentityRaisesBeforeDialling;
  end;

implementation

procedure TMutualTlsRequestTest.TestRequestIdentityAccessorsAndClone;
var
  Id, Id2: IClientIdentity;
  R, R2: THttpRequest;
  W: IWebSocketRequest;
begin
  Id := GoodIdentity;
  R := THttpRequest.Create(hmGet, 'https://localhost/');
  AssertTrue('none by default', R.ClientIdentity = nil);
  R2 := R.WithClientIdentity(Id);
  AssertTrue('the original is unchanged', R.ClientIdentity = nil);
  AssertTrue('set', R2.ClientIdentity = Id);
  AssertTrue('Clone keeps it', R2.Clone.ClientIdentity = Id);
  AssertTrue('WithUrl keeps it', R2.WithUrl('https://x/').ClientIdentity = Id);
  AssertTrue('DropBody keeps it', R2.DropBody.ClientIdentity = Id);
  AssertTrue('WithMethodToken keeps it',
    R2.WithMethodToken('GET').ClientIdentity = Id);
  AssertTrue('WithHeader keeps it',
    R2.WithHeader('x', 'y').ClientIdentity = Id);
  AssertTrue('nil clears it', R2.WithClientIdentity(nil).ClientIdentity = nil);
  W := TWebSocketRequest.Create('wss://localhost/', TWsRecorder.Create);
  AssertTrue('ws none by default', W.ClientIdentity = nil);
  Id2 := GoodIdentity;
  AssertTrue('ws set', Supports(W.WithClientIdentity(Id).ClientIdentity,
    IClientIdentity, Id2) and (Id2 = Id));
  AssertTrue('ws original unchanged', W.ClientIdentity = nil);
  AssertTrue('ws other With keeps it',
    Supports(W.WithClientIdentity(Id).WithAutoRequest.WithHeader('x', 'y')
      .ClientIdentity, IClientIdentity, Id2) and (Id2 = Id));
end;

/// the request identity reaches the origin on every route and never the proxy
/// leg; the selector would have answered the client's other identity
procedure TMutualTlsRequestTest.TestRequestIdentityDirect;
begin
  RunRequestVia(False, tmConnect);
end;

procedure TMutualTlsRequestTest.TestRequestIdentityThroughConnect;
begin
  RunRequestVia(True, tmConnect);
end;

procedure TMutualTlsRequestTest.TestRequestIdentityThroughSocks5;
begin
  RunRequestVia(True, tmSocks5);
end;

procedure TMutualTlsRequestTest.TestRequestIdentityThroughAnHttpsProxy;
begin
  RunRequestVia(True, tmHttps);
end;

procedure TMutualTlsRequestTest.TestTwoRequestIdentitiesOnOneOriginDoNotShareAConnection;
var
  Client: IHttpClient;
  Keys: string;
begin
  StartServer(mkH2, cTls13);
  Client := NewClient(nil);
  AssertEquals('a', 200, Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(GoodIdentity)).StatusCode);
  AssertEquals('b', 200, Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(Client2Identity)).StatusCode);
  AssertEquals('a again', 200, Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(GoodIdentity)).StatusCode);
  Keys := KeysOf(Client);
  Client.Close;
  FServer.Stop;
  AssertEquals('two handshakes, the third request reused the first', 2,
    FServer.Handshakes);
  AssertEquals('three requests', 3, FServer.Requests);
  AssertEquals('the second identity handshook once', 1,
    CountOf('mtls client two', FServer.AllSubjects));
  AssertTrue('two keys, one per identity',
    (Pos(GoodIdentity.Fingerprint, Keys) > 0) and
    (Pos(Client2Identity.Fingerprint, Keys) > 0));
end;

procedure TMutualTlsRequestTest.TestRequestIdentityWinsOverTheSelector;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
begin
  StartServer(mkHttp1, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := SelectorClient(SelRef);
  AssertEquals('request identity', 200, Client.Send(
    THttpRequest.Create(hmGet, Url).WithClientIdentity(Client2Identity))
    .StatusCode);
  AssertEquals('selector not asked', 0, Sel.Calls);
  AssertEquals('no identity on the request', 200, SendTo(Client, Url).StatusCode);
  AssertEquals('selector asked once', 1, Sel.Calls);
  Client.Close;
  FServer.Stop;
  AssertEquals('request identity once, selector answer once',
    1, CountOf('mtls client two', FServer.AllSubjects));
  AssertTrue('the selector answered last',
    SubjectIs(FServer.LastSubject, 'mtls client'));
end;

procedure TMutualTlsRequestTest.TestRequestIdentityWinsOverTheFixedIdentity;
var
  Client: IHttpClient;
begin
  StartServer(mkHttp1, cTls13);
  Client := NewClient(GoodIdentity, True);
  AssertEquals('request identity', 200, Client.Send(
    THttpRequest.Create(hmGet, Url).WithClientIdentity(Client2Identity))
    .StatusCode);
  AssertTrue('the origin saw the request identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  AssertEquals('no identity on the request', 200, SendTo(Client, Url).StatusCode);
  Client.Close;
  FServer.Stop;
  AssertTrue('the fixed identity is the fallback',
    SubjectIs(FServer.LastSubject, 'mtls client'));
  AssertEquals('two handshakes', 2, FServer.Handshakes);
end;

procedure TMutualTlsRequestTest.TestRequestWithoutIdentityKeepsThePlainKey;
var
  Client: IHttpClient;
  Keys: string;
begin
  StartServer(mkH2, cTls13);
  Client := NewClient(GoodIdentity);
  AssertEquals('status', 200, SendTo(Client, Url).StatusCode);
  Keys := KeysOf(Client);
  AssertEquals('a request with none keeps the plain key', 0, Pos(' id=', Keys));
  AssertEquals('with identity', 200, Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(Client2Identity)).StatusCode);
  Keys := KeysOf(Client);
  Client.Close;
  FServer.Stop;
  AssertTrue('the identity request has its own key',
    Pos(' id=' + Client2Identity.Fingerprint, Keys) > 0);
  AssertEquals('two handshakes, no sharing', 2, FServer.Handshakes);
end;

procedure TMutualTlsRequestTest.TestRedirectToTheSameOriginKeepsTheRequestIdentity;
var
  Client: IHttpClient;
begin
  StartServer(mkHttp1, cTls13);
  FServer.RedirectTo := '/final';
  Client := NewClient(GoodIdentity, True);
  AssertEquals('status', 200, Client.Send(THttpRequest.Create(hmGet,
    Url + 'redir').WithClientIdentity(Client2Identity)).StatusCode);
  Client.Close;
  FServer.Stop;
  AssertEquals('both hops handshook', 2, FServer.Handshakes);
  AssertEquals('both hops presented the request identity', 2,
    CountOf('mtls client two', FServer.AllSubjects));
end;

procedure TMutualTlsRequestTest.TestRedirectToAnotherOriginDropsTheRequestIdentity;
var
  Other: TMtlsServer;
  Client: IHttpClient;
begin
  StartServer(mkHttp1, cTls13);
  Other := TMtlsServer.Create(mkHttp1, cTls13);
  try
    FServer.RedirectTo := Format('https://localhost:%d/', [Other.Port]);
    Client := NewClient(GoodIdentity, True);
    AssertEquals('status', 200, Client.Send(THttpRequest.Create(hmGet,
      Url + 'redir').WithClientIdentity(Client2Identity)).StatusCode);
    Client.Close;
    FServer.Stop;
    Other.Stop;
    AssertTrue('the first origin saw the request identity',
      SubjectIs(FServer.LastSubject, 'mtls client two'));
    AssertEquals('the other origin handshook once', 1, Other.Handshakes);
    AssertTrue('the other origin saw the client identity',
      SubjectIs(Other.LastSubject, 'mtls client'));
    AssertEquals('the request identity did not follow', 0,
      CountOf('mtls client two', Other.AllSubjects));
  finally
    Other.Stop;
    Other.Free;
  end;
end;

procedure TMutualTlsRequestTest.TestWssRequestIdentityDirect;
begin
  RunWssVia(tmConnect, isRequest, False);
end;

procedure TMutualTlsRequestTest.TestWssRequestIdentityThroughAnHttpsProxy;
begin
  RunWssVia(tmHttps, isRequest, True);
end;

procedure TMutualTlsRequestTest.TestSseRequestIdentity;
var
  Client: IHttpClient;
  Source: TSseSource;
  Event: TSseEvent;
begin
  StartServer(mkSse, cTls13);
  Client := NewClient(GoodIdentity, True);
  Source := TSseSource.Create(Client.Send(
    SseRequest(Url).WithClientIdentity(Client2Identity)));
  try
    AssertTrue('an event arrived', Source.ReadEvent(Event));
  finally
    Source.Close;
  end;
  Client.Close;
  FServer.Stop;
  AssertTrue('the server saw the request identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
end;

procedure TMutualTlsRequestTest.TestExpiredRequestIdentityRaisesBeforeDialling;
var
  Client: IHttpClient;
  Failed: Boolean;
begin
  StartServer(mkH2, cTls13);
  Client := NewClient(GoodIdentity);
  Failed := False;
  try
    Client.Send(THttpRequest.Create(hmGet, Url).WithClientIdentity(
      TClientIdentity.FromPemFiles(Fixture('expired.crt'),
        Fixture('expired.key'))));
  except
    on E: EHttpTlsConfigError do
      Failed := True;
  end;
  Client.Close;
  FServer.Stop;
  AssertTrue('EHttpTlsConfigError', Failed);
  AssertEquals('nothing was dialled', 0, FServer.Connections);
end;

procedure TMutualTlsRequestTest.TestExpiredWssRequestIdentityRaisesBeforeDialling;
var
  Client: IHttpClient;
  Failed: Boolean;
begin
  StartServer(mkWebSocket, cTls13);
  Client := NewClient(GoodIdentity);
  Failed := False;
  try
    Client.Send(TWebSocketRequest.Create(
      Format('wss://localhost:%d/chat', [FServer.Port]), TWsRecorder.Create)
      .WithClientIdentity(TClientIdentity.FromPemFiles(
        Fixture('expired.crt'), Fixture('expired.key'))));
  except
    on E: EHttpTlsConfigError do
      Failed := True;
  end;
  Client.Close;
  FServer.Stop;
  AssertTrue('EHttpTlsConfigError', Failed);
  AssertEquals('nothing was dialled', 0, FServer.Connections);
end;


{ injected factory, selector expiry and the connection cap }

initialization
  RegisterTest(TMutualTlsRequestTest);
end.
