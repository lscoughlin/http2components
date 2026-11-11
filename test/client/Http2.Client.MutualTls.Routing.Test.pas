{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves Mutual TLS client tests from the source project
---
}
unit Http2.Client.MutualTls.Routing.Test;

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
  Http2.Client.MutualTls.Client.Support, Http2.OpenSSL,
  Http2.Common.Tls.Context;

type
  TMutualTlsRoutingTest = class(TMutualTlsTestBase)
  published
    procedure TestConnectTunnelOriginSeesTheOriginIdentityTls13;
    procedure TestSocks5TunnelOriginSeesTheOriginIdentityTls13;
    procedure TestHttpsProxySeesOnlyTheProxyIdentityTls13;
    procedure TestHttpsProxySeesOnlyTheProxyIdentityTls12;
    procedure TestSelectorIsAskedForTheOriginThroughAnHttpsProxy;
    procedure TestSelectorIsAskedForTheOriginThroughAConnectProxy;
    procedure TestSelectorIsAskedForTheOriginThroughASocks5Proxy;
    procedure TestWssThroughAnHttpsProxySplitsTheIdentities;
    procedure TestWssThroughAConnectProxyPresentsTheOriginIdentity;
    procedure TestWssSelectorThroughAnHttpsProxyAsksForTheOrigin;
    procedure TestEveryDialHelperPresentsTheIdentity;
    procedure TestEveryTlsSocketConstructionCarriesTheIdentity;
    procedure TestFixedIdentitySelectorAnswersTheIdentity;
    procedure TestSelectorIsCalledOncePerDialNotPerRequest;
    procedure TestSelectorRunsOnTheDiallingThreadOutsideThePoolLock;
    procedure TestSelectorChoosesTheIdentityPerOrigin;
    procedure TestNilAnswerPresentsNoCertificate;
    procedure TestThrowingSelectorFailsTheDial;
    procedure TestRotationOpensANewConnectionAndTheOldOneStillAnswers;
    procedure TestNilAnswerNeverSharesAConnectionWithAnIdentity;
    procedure TestSelectorAppliesToWss;
    procedure TestSelectorIsNotCalledForCleartext;
    procedure TestSelectorAndFixedIdentityReplaceEachOther;
    procedure TestOriginIdentityAloneIsRefusedByAnHttpsProxyThatAsksForOne;
    procedure TestProxyIdentityAloneIsNotPresentedToTheOrigin;
    procedure TestHttpsProxyToACleartextOriginGetsTheProxyIdentity;
    procedure TestSelectorKeyForACleartextOriginBehindAnHttpsProxy;
    procedure TestExpiredProxyIdentityFailsBuild;
  end;

implementation

procedure TMutualTlsRoutingTest.TestConnectTunnelOriginSeesTheOriginIdentityTls13;
begin
  RunTunnel(tmConnect, cTls13);
end;

procedure TMutualTlsRoutingTest.TestSocks5TunnelOriginSeesTheOriginIdentityTls13;
begin
  RunTunnel(tmSocks5, cTls13);
end;

procedure TMutualTlsRoutingTest.TestHttpsProxySeesOnlyTheProxyIdentityTls13;
begin
  RunTunnel(tmHttps, cTls13);
end;

procedure TMutualTlsRoutingTest.TestHttpsProxySeesOnlyTheProxyIdentityTls12;
begin
  RunTunnel(tmHttps, cTls12);
end;

procedure TMutualTlsRoutingTest.TestSelectorIsAskedForTheOriginThroughAnHttpsProxy;
begin
  RunSelectorVia(tmHttps);
end;

procedure TMutualTlsRoutingTest.TestSelectorIsAskedForTheOriginThroughAConnectProxy;
begin
  RunSelectorVia(tmConnect);
end;

procedure TMutualTlsRoutingTest.TestSelectorIsAskedForTheOriginThroughASocks5Proxy;
begin
  RunSelectorVia(tmSocks5);
end;

/// a wss dial follows the same rules as a request: the origin identity (fixed,
/// selected or per request) goes to the origin, the proxy identity to an https
/// proxy only
procedure TMutualTlsRoutingTest.TestWssThroughAnHttpsProxySplitsTheIdentities;
begin
  RunWssVia(tmHttps, isFixed, True);
end;

procedure TMutualTlsRoutingTest.TestWssThroughAConnectProxyPresentsTheOriginIdentity;
begin
  RunWssVia(tmConnect, isFixed, True);
end;

procedure TMutualTlsRoutingTest.TestWssSelectorThroughAnHttpsProxyAsksForTheOrigin;
begin
  RunWssVia(tmHttps, isSelector, True);
end;

{ dial helpers }

procedure TMutualTlsRoutingTest.TestEveryDialHelperPresentsTheIdentity;
var
  Id: IClientIdentity;
  Context: ITLSContext;
  Sock: IHttp2Socket;
  Offer: TBytes;
  Before: Integer;

  procedure Check(const AWhat: string);
  begin
    Sock.Close;
    Sock := nil;
    // the server handshake counter moves once the client has finished
    Sleep(50);
    Inc(Before);
    AssertEquals(AWhat + ': the server accepted the identity', Before,
      FServer.Handshakes);
  end;

begin
  StartServer(mkH2, cTls13);
  Id := GoodIdentity;
  Context := ClientTlsContext(Id);
  Offer := AlpnOfferFor(False);
  Before := 0;
  Sock := TTlsSocket.Dial('localhost', FServer.Port, False, 3000,
    '', '', 0, Id, Context);
  Check('Dial');
  Sock := TTlsSocket.DialWithAlpn('localhost', FServer.Port, Offer, False, 3000,
    '', '', 0, Id, Context);
  Check('DialWithAlpn');
  Sock := TTlsSocket.DialVia('localhost', FServer.Port, False, 3000,
    '', nil, Id, nil, Context);
  Check('DialVia');
  Sock := TTlsSocket.DialWithAlpnVia('localhost', FServer.Port, Offer, False,
    3000, '', nil, Id, nil, Context);
  Check('DialWithAlpnVia');
  Sock := TProtocolSocketFactory.Create('', False, '', 0, Id, nil, Context)
    .DialHttp1('localhost', FServer.Port, 'https', 3000, nil);
  Check('TProtocolSocketFactory.DialHttp1');
end;

/// enumeration check: every TTlsSocket construction is handed an identity
/// parameter (the dial helpers decide which leg may present it)

procedure TMutualTlsRoutingTest.TestEveryTlsSocketConstructionCarriesTheIdentity;
var
  Names: array[0..2] of string;
  Calls: array[0..3] of string;
  I, J, P, Q, E, Seen: Integer;
  Text, Stmt, Path: string;
  L: TStringList;
begin
  Names[0] := 'client/src/Http2.Client.Tls.Socket.pas';
  Names[1] := 'client/src/Http2.Client.Tls.Tunnel.pas';
  Names[2] := 'client/src/Http2.Client.SocketFactory.pas';
  Calls[0] := 'TTlsSocket.Create(';
  Calls[1] := 'TTlsSocket.Dial(';
  Calls[2] := 'TTlsSocket.DialWithAlpnVia(';
  Calls[3] := 'TTlsSocket.DialWithAlpn(';
  Seen := 0;
  for I := 0 to High(Names) do
  begin
    Path := ExtractFilePath(ParamStr(0)) + '../' + Names[I];
    if not FileExists(Path) then
      Path := Names[I];
    if not FileExists(Path) then
    begin
      Fail('cannot find ' + Names[I] + ' from ' + GetCurrentDir);
    end;
    L := TStringList.Create;
    try
      L.LoadFromFile(Path);
      Text := L.Text;
    finally
      L.Free;
    end;
    for J := 0 to High(Calls) do
    begin
      P := 1;
      while True do
      begin
        Q := Pos(Calls[J], Copy(Text, P, MaxInt));
        if Q = 0 then
          Break;
        P := P + Q - 1;
        E := Pos(';', Copy(Text, P, MaxInt)) + P - 1;
        Stmt := Copy(Text, P, E - P);
        // a declaration or a method heading, not a call
        if Pos('const ', Stmt) = 0 then
          Inc(Seen);
        if Pos('const ', Stmt) = 0 then
          AssertTrue(Names[I] + ': ' + Calls[J] + ' passes the identity: ' +
            Stmt, Pos('Identity', Stmt) > 0);
        P := E;
      end;
    end;
  end;
  AssertEquals('the scan found every dial site', 8, Seen);
end;

{ selector }

procedure TMutualTlsRoutingTest.TestFixedIdentitySelectorAnswersTheIdentity;
var
  Id: IClientIdentity;
  Sel: IClientIdentitySelector;
  Client: IHttpClient;
  Body: string;
begin
  Id := GoodIdentity;
  Sel := FixedIdentitySelector(Id);
  AssertTrue('the helper answers the identity it wraps',
    Sel.Select('a.example', 443) = Id);
  AssertTrue('and the same one for any origin', Sel.Select('b.example', 8443) = Id);
  AssertTrue('a nil identity gives a nil answer',
    FixedIdentitySelector(nil).Select('a.example', 443) = nil);
  // and it behaves as the fixed identity on the wire
  StartServer(mkH2, cTls13);
  Client := SelectorClient(Sel);
  AssertEquals('status', 200, Fetch(Client, Body));
  Client.Close;
  FServer.Stop;
  AssertTrue('the server saw the client certificate',
    SubjectIs(FServer.LastSubject, 'mtls client'));
end;

procedure TMutualTlsRoutingTest.TestSelectorIsCalledOncePerDialNotPerRequest;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Body: string;
  I: Integer;
begin
  StartServer(mkH2, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := SelectorClient(SelRef);
  for I := 1 to 3 do
    AssertEquals('status', 200, Fetch(Client, Body));
  Client.Close;
  FServer.Stop;
  AssertEquals('three requests', 3, FServer.Requests);
  AssertEquals('one connection', 1, FServer.Connections);
  AssertEquals('one selector call for the one dial', 1, Sel.Calls);
  AssertEquals('asked for the origin host', 'localhost', Sel.LastHost);
  AssertEquals('asked for the origin port', FServer.Port, Sel.LastPort);
end;

procedure TMutualTlsRoutingTest.TestSelectorRunsOnTheDiallingThreadOutsideThePoolLock;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Body: string;
begin
  StartServer(mkH2, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := SelectorClient(SelRef);
  Sel.ProbeLockWith(Client);
  AssertEquals('status', 200, Fetch(Client, Body));
  Client.Close;
  FServer.Stop;
  AssertEquals('one call', 1, Sel.Calls);
  AssertTrue('on the thread that sent the request',
    Sel.LastThread = GetCurrentThreadId);
  AssertTrue('another thread could take the pool lock meanwhile',
    Sel.LockWasFree);
end;

procedure TMutualTlsRoutingTest.TestSelectorChoosesTheIdentityPerOrigin;
var
  Other: TMtlsServer;
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
begin
  StartServer(mkH2, cTls13);
  Other := TMtlsServer.Create(mkH2, cTls13);
  try
    Sel := TCountingSelector.Create;
    SelRef := Sel;
    Sel.Answer := GoodIdentity;
    Sel.ForPort := Other.Port;
    Sel.PortAnswer := Client2Identity;
    Client := SelectorClient(SelRef);
    AssertEquals('first origin', 200, SendTo(Client, ServerUrl(FServer)).StatusCode);
    AssertEquals('second origin', 200, SendTo(Client, ServerUrl(Other)).StatusCode);
    AssertEquals('first again, pooled', 200,
      SendTo(Client, ServerUrl(FServer)).StatusCode);
    Client.Close;
    FServer.Stop;
    Other.Stop;
    AssertEquals('two dials, two selector calls', 2, Sel.Calls);
    AssertTrue('first origin saw the first identity',
      SubjectIs(FServer.LastSubject, 'mtls client'));
    AssertTrue('second origin saw the second identity',
      SubjectIs(Other.LastSubject, 'mtls client two'));
    AssertEquals('first origin: one handshake', 1, FServer.Handshakes);
    AssertEquals('second origin: one handshake', 1, Other.Handshakes);
  finally
    Other.Stop;
    Other.Free;
  end;
end;

procedure TMutualTlsRoutingTest.TestNilAnswerPresentsNoCertificate;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
begin
  StartServer(mkH2, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Client := SelectorClient(SelRef);
  AssertEquals('the server asks for a certificate and gets none',
    'certificate required', AlertOfFetch(Client));
  Client.Close;
  FServer.Stop;
  AssertEquals('one selector call', 1, Sel.Calls);
  AssertEquals('no handshake completed', 0, FServer.Handshakes);
end;

procedure TMutualTlsRoutingTest.TestThrowingSelectorFailsTheDial;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Body, Msg: string;
begin
  StartServer(mkH2, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Fail := True;
  Client := SelectorClient(SelRef);
  Msg := '';
  try
    Fetch(Client, Body);
    Fail('the dial must fail');
  except
    on E: EHttpTlsConfigError do
      Msg := E.Message;
  end;
  AssertTrue('the selector message is carried: ' + Msg,
    Pos('selector refused', Msg) > 0);
  AssertEquals('the failed dial opened no connection', 0, FServer.Connections);
  // the next request asks again and, once the selector recovers, succeeds
  Sel.Fail := False;
  Sel.Answer := GoodIdentity;
  AssertEquals('status', 200, Fetch(Client, Body));
  Client.Close;
  FServer.Stop;
  AssertEquals('two calls', 2, Sel.Calls);
  AssertEquals('one connection in all', 1, FServer.Connections);
end;

procedure TMutualTlsRoutingTest.TestRotationOpensANewConnectionAndTheOldOneStillAnswers;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Old, Fresh: IHttpResponse;
  Stats: TPoolStats;
  FpOld, FpNew: string;
begin
  StartServer(mkHttp1, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  FpOld := Sel.Answer.Leaf.FingerprintSha256;
  Client := SelectorClient(SelRef);
  // the first response is held open, so its connection stays in use
  Old := SendTo(Client, Url);
  AssertEquals('first status', 200, Old.StatusCode);
  AssertTrue('the first connection presented the first identity',
    SubjectIs(FServer.LastSubject, 'mtls client'));
  // rotate: the next dial presents the new identity
  Sel.Answer := Client2Identity;
  FpNew := Sel.Answer.Leaf.FingerprintSha256;
  Fresh := SendTo(Client, Url);
  AssertEquals('second status', 200, Fresh.StatusCode);
  AssertEquals('two selector calls: one per dial', 2, Sel.Calls);
  AssertTrue('the new connection presented the new identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  // the pool keeps the identities apart
  Stats := (Client as THttpClient).PoolStats;
  AssertEquals('two pool keys', 2, Length(Stats.PerOrigin));
  AssertTrue('keys carry the fingerprints',
    ((Pos(FpOld, Stats.PerOrigin[0].Origin) > 0) and
     (Pos(FpNew, Stats.PerOrigin[1].Origin) > 0)) or
    ((Pos(FpNew, Stats.PerOrigin[0].Origin) > 0) and
     (Pos(FpOld, Stats.PerOrigin[1].Origin) > 0)));
  // the connection of the replaced certificate still delivers its response
  AssertEquals('old connection still answers', 'ok', ReadBody(Old));
  AssertEquals('new connection answers', 'ok', ReadBody(Fresh));
  Client.Close;
  FServer.Stop;
  AssertEquals('two handshakes', 2, FServer.Handshakes);
end;

procedure TMutualTlsRoutingTest.TestNilAnswerNeverSharesAConnectionWithAnIdentity;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Old: IHttpResponse;
begin
  StartServer(mkHttp1, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := SelectorClient(SelRef);
  Old := SendTo(Client, Url);
  AssertEquals('first status', 200, Old.StatusCode);
  // the selector now answers nil; the open connection holds an identity, so
  // it must not be used for a request that is to present none
  Sel.Answer := nil;
  AssertEquals('the new dial presented no certificate',
    'certificate required', AlertOfFetch(Client));
  AssertEquals('two selector calls', 2, Sel.Calls);
  AssertEquals('old connection still answers', 'ok', ReadBody(Old));
  Client.Close;
  FServer.Stop;
  AssertEquals('one handshake completed', 1, FServer.Handshakes);
end;

procedure TMutualTlsRoutingTest.TestSelectorAppliesToWss;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Rec: TWsRecorder;
  RecRef: IWebSocketListener;
  Sock: IWebSocket;
begin
  StartServer(mkWebSocket, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := Client2Identity;
  Client := SelectorClient(SelRef);
  Rec := TWsRecorder.Create;
  RecRef := Rec;
  Sock := Client.Send(TWebSocketRequest.Create(
    Format('wss://localhost:%d/chat', [FServer.Port]), RecRef).WithAutoRequest);
  AssertTrue('the server sent a message', Rec.WaitText(4000));
  Sock.Close;
  Sleep(50);
  Client.Close;
  FServer.Stop;
  AssertEquals('one selector call', 1, Sel.Calls);
  AssertEquals('asked for the wss origin', FServer.Port, Sel.LastPort);
  AssertTrue('the server saw the selector identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
end;

procedure TMutualTlsRoutingTest.TestSelectorIsNotCalledForCleartext;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
begin
  StartServer(mkPlain, 0);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := THttpClientFactory.Create
    .WithClientIdentitySelector(SelRef)
    .WithClearText(ctHttp1)
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(5000)
    .Build;
  AssertEquals('status', 200,
    SendTo(Client, Format('http://localhost:%d/', [FServer.Port])).StatusCode);
  Client.Close;
  FServer.Stop;
  AssertEquals('no handshake, so no question', 0, Sel.Calls);
end;

procedure TMutualTlsRoutingTest.TestSelectorAndFixedIdentityReplaceEachOther;
var
  Id: IClientIdentity;
  Sel: IClientIdentitySelector;
  F: THttpClientFactory;
begin
  Id := GoodIdentity;
  Sel := FixedIdentitySelector(Id);
  F := THttpClientFactory.Create.WithClientIdentity(Id)
    .WithClientIdentitySelector(Sel);
  AssertTrue('the selector is installed', F.ClientIdentitySelector = Sel);
  AssertTrue('the fixed identity is gone', F.ClientIdentity = nil);
  F := F.WithClientIdentity(Id);
  AssertTrue('the fixed identity is back', F.ClientIdentity = Id);
  AssertTrue('the selector is gone', F.ClientIdentitySelector = nil);
  F := F.WithClientIdentitySelector(Sel).WithClientIdentitySelector(nil);
  AssertTrue('nil removes the selector', F.ClientIdentitySelector = nil);
end;

/// the proxy asks for a certificate and the client has only an origin identity

procedure TMutualTlsRoutingTest.TestOriginIdentityAloneIsRefusedByAnHttpsProxyThatAsksForOne;
var
  Client: IHttpClient;
  Body: string;
  Failed: Boolean;
begin
  StartServer(mkH2, cTls13);
  FProxy := TTunnelProxy.Create(tmHttps, FServer.Port, True);
  Client := NewClient(GoodIdentity);
  Failed := False;
  try
    Fetch(Client, Body);
  except
    on E: EHttpConnectionError do
      Failed := True;
  end;
  AssertTrue('the proxy must refuse a client without a proxy identity', Failed);
  Client.Close;
  FProxy.Stop;
  FServer.Stop;
  AssertEquals('the proxy accepted no certificate', '', FProxy.LastSubject);
  AssertEquals('no tunnel', 0, FProxy.Tunnels);
  AssertEquals('the origin was never reached', 0, FServer.Connections);
end;

/// the proxy identity never goes to the origin, on a direct route either

procedure TMutualTlsRoutingTest.TestProxyIdentityAloneIsNotPresentedToTheOrigin;
var
  Client: IHttpClient;
begin
  StartServer(mkH2, cTls13);
  FProxyIdentity := Client2Identity;
  Client := NewClient(nil);
  AssertEquals('the origin demands a certificate', 'certificate required',
    AlertOfFetch(Client));
  Client.Close;
  FServer.Stop;
  AssertFalse('the origin was offered no certificate', FServer.SawClientCert);
end;

procedure TMutualTlsRoutingTest.TestHttpsProxyToACleartextOriginGetsTheProxyIdentity;
var
  Client: IHttpClient;
begin
  // http origin through an https proxy: the TLS leg is the proxy's, and it
  // gets the proxy identity; there is no origin handshake to hand the origin
  // identity to
  StartServer(mkPlain, 0);
  FProxy := TTunnelProxy.Create(tmHttps, FServer.Port, True);
  Client := THttpClientFactory.Create
    .WithTlsContext(ClientTlsContext(nil))
    .WithProxyTlsContext(ClientTlsContext(FProxyIdentity))
    .WithClientIdentity(GoodIdentity)
    .WithProxyClientIdentity(Client2Identity)
    .WithProxySelector(TFixedSelector.Create(pkHttps, FProxy.Port))
    .WithClearText(ctHttp1)
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(5000)
    .Build;
  AssertEquals('status', 200,
    SendTo(Client, Format('http://localhost:%d/', [FServer.Port])).StatusCode);
  Client.Close;
  FProxy.Stop;
  FServer.Stop;
  AssertTrue('the proxy saw the proxy identity',
    SubjectIs(FProxy.LastSubject, 'mtls client two'));
  AssertEquals('one origin request', 1, FServer.Requests);
end;

/// a cleartext origin behind an https proxy has no origin identity: the
/// selector is not asked and the key has no identity part

procedure TMutualTlsRoutingTest.TestSelectorKeyForACleartextOriginBehindAnHttpsProxy;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Keys: string;
begin
  StartServer(mkPlain, 0);
  FProxy := TTunnelProxy.Create(tmHttps, FServer.Port, True);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Client := THttpClientFactory.Create
    .WithTlsContext(ClientTlsContext(nil))
    .WithProxyTlsContext(ClientTlsContext(Client2Identity))
    .WithClientIdentitySelector(SelRef)
    .WithProxyClientIdentity(Client2Identity)
    .WithProxySelector(TFixedSelector.Create(pkHttps, FProxy.Port))
    .WithClearText(ctHttp1)
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(5000)
    .Build;
  AssertEquals('status', 200,
    SendTo(Client, Format('http://localhost:%d/', [FServer.Port])).StatusCode);
  Keys := KeysOf(Client);
  Client.Close;
  FProxy.Stop;
  FServer.Stop;
  AssertEquals('the selector is not asked', 0, Sel.Calls);
  AssertEquals('no identity part in the key', 0, Pos(' id=', Keys));
  AssertTrue('the proxy saw the proxy identity',
    SubjectIs(FProxy.LastSubject, 'mtls client two'));
end;

procedure TMutualTlsRoutingTest.TestExpiredProxyIdentityFailsBuild;
var
  Failed: Boolean;
begin
  Failed := False;
  try
    THttpClientFactory.Create
      .WithProxyClientIdentity(TOpenSSLIdentity.FromPemFiles(
        Fixture('expired.crt'), Fixture('expired.key')))
      .Build;
  except
    on E: EHttpTlsConfigError do
      Failed := True;
  end;
  AssertTrue('Build refuses an expired proxy identity', Failed);
end;

{ per-request identity }

initialization
  RegisterTest(TMutualTlsRoutingTest);
end.
