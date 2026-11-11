{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves Mutual TLS client tests from the source project
---
}
unit Http2.Client.MutualTls.Other.Test;

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
  TMutualTlsOtherTest = class(TMutualTlsTestBase)
  published
    procedure TestInjectedFactoryWithFixedIdentityFailsBuild;
    procedure TestInjectedFactoryWithSelectorFailsBuild;
    procedure TestInjectedFactoryWithProxyIdentityFailsBuild;
    procedure TestInjectedFactoryWithRequestIdentityFailsBeforeDialling;
    procedure TestInjectedFactoryWithWssRequestIdentityFailsBeforeDialling;
    procedure TestInjectedFactoryWithoutIdentitiesStillWorks;
    procedure TestExpiredSelectorAnswerFailsTheDialBeforeDialling;
    procedure TestExpiredSelectorAnswerFailsWssBeforeDialling;
    procedure TestRotationAtThePerHostCapEvictsTheIdleOldIdentity;
    procedure TestRotationAtTheTotalCapEvictsTheIdleOldIdentity;
    procedure TestBusyOldIdentityIsNeverEvicted;
    procedure TestTwoIdentitiesShareThePerHostCap;
    procedure TestConcurrentColdRequestsAskTheSelectorOnce;
    procedure TestCleartextIgnoresTheIdentity;
    procedure TestLogLineHasSubjectAndFingerprintButNoSecrets;
  end;

implementation

procedure TMutualTlsOtherTest.TestInjectedFactoryWithFixedIdentityFailsBuild;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpClientFactory.Create
      .WithSocketFactory(TPlainSocketFactory.Create)
      .WithClientIdentity(GoodIdentity)
      .Build;
  except
    on E: EHttpTlsConfigError do
      Raised := True;
  end;
  AssertTrue('Build refuses an identity the injected factory cannot present',
    Raised);
end;

procedure TMutualTlsOtherTest.TestInjectedFactoryWithSelectorFailsBuild;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpClientFactory.Create
      .WithSocketFactory(TPlainSocketFactory.Create)
      .WithClientIdentitySelector(FixedIdentitySelector(GoodIdentity))
      .Build;
  except
    on E: EHttpTlsConfigError do
      Raised := True;
  end;
  AssertTrue('Build refuses a selector the injected factory cannot use',
    Raised);
end;

procedure TMutualTlsOtherTest.TestInjectedFactoryWithProxyIdentityFailsBuild;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpClientFactory.Create
      .WithSocketFactory(TPlainSocketFactory.Create)
      .WithProxyClientIdentity(GoodIdentity)
      .Build;
  except
    on E: EHttpTlsConfigError do
      Raised := True;
  end;
  AssertTrue('Build refuses a proxy identity the factory cannot present',
    Raised);
end;

procedure TMutualTlsOtherTest.TestInjectedFactoryWithRequestIdentityFailsBeforeDialling;
var
  Plain: TPlainSocketFactory;
  PlainRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Raised: Boolean;
begin
  Plain := TPlainSocketFactory.Create;
  PlainRef := Plain;
  Client := THttpClientFactory.Create.WithSocketFactory(PlainRef).Build;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'https://localhost:9/')
      .WithClientIdentity(GoodIdentity));
  except
    on E: EHttpTlsConfigError do
      Raised := True;
  end;
  Client.Close;
  AssertTrue('Send refuses a request identity the factory cannot present',
    Raised);
  AssertEquals('nothing was dialled', 0, Plain.Dials);
end;

procedure TMutualTlsOtherTest.TestInjectedFactoryWithWssRequestIdentityFailsBeforeDialling;
var
  Plain: TPlainSocketFactory;
  PlainRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Raised: Boolean;
begin
  Plain := TPlainSocketFactory.Create;
  PlainRef := Plain;
  Client := THttpClientFactory.Create.WithSocketFactory(PlainRef).Build;
  Raised := False;
  try
    Client.Send(TWebSocketRequest.Create('wss://localhost:9/chat',
      TWsRecorder.Create).WithClientIdentity(GoodIdentity));
  except
    on E: EHttpTlsConfigError do
      Raised := True;
  end;
  Client.Close;
  AssertTrue('Send refuses a wss request identity the factory cannot present',
    Raised);
  AssertEquals('nothing was dialled', 0, Plain.Dials);
end;

procedure TMutualTlsOtherTest.TestInjectedFactoryWithoutIdentitiesStillWorks;
var
  Plain: TPlainSocketFactory;
  PlainRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Dialled: Boolean;
begin
  Plain := TPlainSocketFactory.Create;
  PlainRef := Plain;
  Client := THttpClientFactory.Create.WithSocketFactory(PlainRef).Build;
  Dialled := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'https://localhost:9/'));
  except
    on E: EHttpConnectionError do
      Dialled := True;
  end;
  Client.Close;
  AssertTrue('a request with no identity reaches the factory', Dialled);
  AssertEquals('dialled once', 1, Plain.Dials);
end;

procedure TMutualTlsOtherTest.TestExpiredSelectorAnswerFailsTheDialBeforeDialling;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Msg: string;
begin
  StartServer(mkH2, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := TClientIdentity.FromPemFiles(Fixture('expired.crt'),
    Fixture('expired.key'));
  Client := SelectorClient(SelRef);
  Msg := '';
  try
    SendTo(Client, Url);
  except
    on E: EHttpTlsConfigError do
      Msg := E.Message;
  end;
  Client.Close;
  FServer.Stop;
  AssertTrue('EHttpTlsConfigError naming the expiry: ' + Msg,
    Pos('expired on', Msg) > 0);
  AssertEquals('no key material in the message', 0, Pos('PRIVATE', Msg));
  AssertEquals('the selector was asked once', 1, Sel.Calls);
  AssertEquals('nothing was dialled', 0, FServer.Connections);
end;

procedure TMutualTlsOtherTest.TestExpiredSelectorAnswerFailsWssBeforeDialling;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  Failed: Boolean;
begin
  StartServer(mkWebSocket, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := TClientIdentity.FromPemFiles(Fixture('expired.crt'),
    Fixture('expired.key'));
  Client := SelectorClient(SelRef);
  Failed := False;
  try
    Client.Send(TWebSocketRequest.Create(
      Format('wss://localhost:%d/chat', [FServer.Port]), TWsRecorder.Create));
  except
    on E: EHttpTlsConfigError do
      Failed := True;
  end;
  Client.Close;
  FServer.Stop;
  AssertTrue('EHttpTlsConfigError', Failed);
  AssertEquals('nothing was dialled', 0, FServer.Connections);
end;

procedure TMutualTlsOtherTest.TestRotationAtThePerHostCapEvictsTheIdleOldIdentity;
var
  Client: IHttpClient;
  Stats: TPoolStats;
  Id2: IClientIdentity;
begin
  StartServer(mkH2, cTls13);
  Client := RouteVia(THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(1500)
    .WithMaxConnectionsPerHost(1)).Build;
  Id2 := Client2Identity;
  AssertEquals('first body', 'ok', ReadBody(Client.Send(
    THttpRequest.Create(hmGet, Url).WithClientIdentity(GoodIdentity))));
  AssertEquals('second body', 'ok', ReadBody(Client.Send(
    THttpRequest.Create(hmGet, Url).WithClientIdentity(Id2))));
  Stats := (Client as THttpClient).PoolStats;
  AssertEquals('the cap holds across identities', 1, Stats.Connections);
  AssertEquals('one pool key', 1, Length(Stats.PerOrigin));
  AssertTrue('the surviving connection is the new identity',
    Pos(Id2.Fingerprint, Stats.PerOrigin[0].Origin) > 0);
  AssertTrue('the origin saw the new identity',
    SubjectIs(FServer.LastSubject, 'mtls client two'));
  Client.Close;
  FServer.Stop;
  AssertEquals('two connections were opened', 2, FServer.Connections);
end;

procedure TMutualTlsOtherTest.TestRotationAtTheTotalCapEvictsTheIdleOldIdentity;
var
  Client: IHttpClient;
  Stats: TPoolStats;
  Id2: IClientIdentity;
begin
  StartServer(mkH2, cTls13);
  Client := RouteVia(THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(1500)
    .WithMaxTotalConnections(1)).Build;
  Id2 := Client2Identity;
  AssertEquals('first body', 'ok', ReadBody(Client.Send(
    THttpRequest.Create(hmGet, Url).WithClientIdentity(GoodIdentity))));
  AssertEquals('second body', 'ok', ReadBody(Client.Send(
    THttpRequest.Create(hmGet, Url).WithClientIdentity(Id2))));
  Stats := (Client as THttpClient).PoolStats;
  AssertEquals('the total cap holds', 1, Stats.Connections);
  Client.Close;
  FServer.Stop;
  AssertEquals('two connections were opened', 2, FServer.Connections);
end;

procedure TMutualTlsOtherTest.TestBusyOldIdentityIsNeverEvicted;
var
  Client: IHttpClient;
  Old: IHttpResponse;
  Stats: TPoolStats;
  TimedOut: Boolean;
begin
  StartServer(mkHttp1, cTls13);
  Client := RouteVia(THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(300)
    .WithHttp1Fallback(True)
    .WithMaxConnectionsPerHost(1)).Build;
  // the first response is held open, so its connection is busy
  Old := Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(GoodIdentity));
  TimedOut := False;
  try
    Client.Send(THttpRequest.Create(hmGet, Url)
      .WithClientIdentity(Client2Identity));
  except
    on E: EHttpTimeout do
      TimedOut := True;
  end;
  AssertTrue('the new identity waits for a slot and times out', TimedOut);
  Stats := (Client as THttpClient).PoolStats;
  AssertEquals('the busy connection is still pooled', 1, Stats.Connections);
  AssertEquals('the old connection still answers', 'ok', ReadBody(Old));
  Client.Close;
  FServer.Stop;
  AssertEquals('no second connection was dialled', 1, FServer.Connections);
end;

procedure TMutualTlsOtherTest.TestTwoIdentitiesShareThePerHostCap;
var
  Client: IHttpClient;
  Old, Second: IHttpResponse;
  Stats: TPoolStats;
  TimedOut: Boolean;
begin
  StartServer(mkHttp1, cTls13);
  Client := RouteVia(THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(300)
    .WithHttp1Fallback(True)
    .WithMaxConnectionsPerHost(2)).Build;
  // two busy connections, one per identity, fill the cap of two
  Old := Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(GoodIdentity));
  Second := Client.Send(THttpRequest.Create(hmGet, Url)
    .WithClientIdentity(Client2Identity));
  AssertEquals('second identity fits', 200, Second.StatusCode);
  TimedOut := False;
  try
    // a third request of the first identity cannot open another connection
    Client.Send(THttpRequest.Create(hmGet, Url)
      .WithClientIdentity(GoodIdentity));
  except
    on E: EHttpTimeout do
      TimedOut := True;
  end;
  AssertTrue('the origin never exceeds MaxConnectionsPerHost', TimedOut);
  Stats := (Client as THttpClient).PoolStats;
  AssertEquals('two connections in all', 2, Stats.Connections);
  AssertEquals('under two keys', 2, Length(Stats.PerOrigin));
  ReadBody(Old);
  ReadBody(Second);
  Client.Close;
  FServer.Stop;
  AssertEquals('two connections were opened', 2, FServer.Connections);
end;

procedure TMutualTlsOtherTest.TestConcurrentColdRequestsAskTheSelectorOnce;
var
  Sel: TCountingSelector;
  SelRef: IClientIdentitySelector;
  Client: IHttpClient;
  A, B: TFetchThread;
begin
  StartServer(mkH2, cTls13);
  Sel := TCountingSelector.Create;
  SelRef := Sel;
  Sel.Answer := GoodIdentity;
  Sel.DelayMs := 500;
  Client := SelectorClient(SelRef);
  A := TFetchThread.Create(Client, Url);
  Sleep(100);                   // B arrives while A's selector call runs
  B := TFetchThread.Create(Client, Url);
  A.WaitFor;
  B.WaitFor;
  AssertFalse('A succeeded', A.Failed);
  AssertFalse('B succeeded', B.Failed);
  AssertEquals('A status', 200, A.Status);
  AssertEquals('B status', 200, B.Status);
  A.Free;
  B.Free;
  Client.Close;
  FServer.Stop;
  AssertEquals('the selector is asked once for one dial', 1, Sel.Calls);
  AssertEquals('one connection serves both', 1, FServer.Connections);
end;

{ other }

procedure TMutualTlsOtherTest.TestCleartextIgnoresTheIdentity;
var
  Client: IHttpClient;
  Body: string;
begin
  StartServer(mkPlain, 0);
  Client := THttpClientFactory.Create
    .WithClientIdentity(GoodIdentity)
    .WithClearText(ctHttp1)
    .WithConnectTimeout(3000)
    .WithHeaderTimeout(5000)
    .Build;
  AssertEquals('status', 200,
    Client.Send(THttpRequest.Create(hmGet, Url('http'))).StatusCode);
  Client.Close;
  FServer.Stop;
  AssertEquals('one request', 1, FServer.Requests);
  Body := '';
  AssertEquals('no handshake', 0, FServer.Handshakes);
end;

procedure TMutualTlsOtherTest.TestLogLineHasSubjectAndFingerprintButNoSecrets;
var
  Logger: TRecordingLogger;
  LoggerRef: IHttpLogger;
  Client: IHttpClient;
  Body, Joined, Fingerprint: string;
  I: Integer;
  Id: IClientIdentity;
  Found: Boolean;
begin
  StartServer(mkH2, cTls13);
  Logger := TRecordingLogger.Create;
  LoggerRef := Logger;
  Id := TClientIdentity.FromPemFiles(Fixture('client-chain.pem'),
    Fixture('client-encrypted.key'), cPass);
  Fingerprint := Id.Fingerprint;
  Client := THttpClientFactory.Create
    .WithCACertFile(Fixture('ca.crt'))
    .WithClientCertificateFiles(Fixture('client-chain.pem'),
      Fixture('client-encrypted.key'), cPass)
    .WithLogger(LoggerRef)
    .Build;
  AssertEquals('status', 200, Fetch(Client, Body));
  Client.Close;
  FServer.Stop;
  Found := False;
  Joined := '';
  for I := 0 to Logger.Count - 1 do
  begin
    Joined := Joined + Logger.MessageAt(I) + #10;
    if (Pos(Id.Subject, Logger.MessageAt(I)) > 0) and
       (Pos(Fingerprint, Logger.MessageAt(I)) > 0) then
    begin
      Found := True;
      AssertTrue('at debug level', Logger.LevelAt(I) = llDebug);
    end;
  end;
  AssertTrue('a line names the subject and fingerprint', Found);
  AssertEquals('no passphrase logged', 0, Pos(cPass, Joined));
  AssertEquals('no key path logged', 0, Pos('client-encrypted.key', Joined));
  AssertEquals('no PEM logged', 0, Pos('-----BEGIN', Joined));
end;

initialization
  RegisterTest(TMutualTlsOtherTest);
end.
