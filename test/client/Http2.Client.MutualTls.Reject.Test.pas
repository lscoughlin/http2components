{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves Mutual TLS client tests from the source project
---
}
unit Http2.Client.MutualTls.Reject.Test;

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
  TMutualTlsRejectTest = class(TMutualTlsTestBase)
  published
    procedure TestNoIdentityIsRejectedOnceTls12;
    procedure TestNoIdentityIsRejectedOnceTls13;
    procedure TestNoIdentityOverHttp11IsRejectedTls13;
    procedure TestNoIdentityWithFallbackOnDoesNotFallBackTls13;
    procedure TestNoIdentityOnWssIsRejectedTls13;
    procedure TestWrongCaIsRejectedTls12;
    procedure TestWrongCaIsRejectedTls13;
    procedure TestExpiredIsRejectedOnTheWireTls12;
    procedure TestExpiredIsRejectedOnTheWireTls13;
    procedure TestRejectionIsNotRetried;
  end;

implementation

procedure TMutualTlsRejectTest.TestNoIdentityIsRejectedOnceTls12;
begin
  RunNoIdentity(mkH2, cTls12, False, 'handshake failure');
end;

procedure TMutualTlsRejectTest.TestNoIdentityIsRejectedOnceTls13;
begin
  RunNoIdentity(mkH2, cTls13, False, 'certificate required');
end;

procedure TMutualTlsRejectTest.TestNoIdentityOverHttp11IsRejectedTls13;
begin
  RunNoIdentity(mkHttp1, cTls13, True, 'certificate required');
end;

procedure TMutualTlsRejectTest.TestNoIdentityWithFallbackOnDoesNotFallBackTls13;
begin
  // fallback is on, the server is HTTP/2: the rejection is final
  RunNoIdentity(mkH2, cTls13, True, 'certificate required');
end;

procedure TMutualTlsRejectTest.TestNoIdentityOnWssIsRejectedTls13;
var
  Client: IHttpClient;
  Rec: TWsRecorder;
  RecRef: IWebSocketListener;
  Alert: string;
begin
  StartServer(mkWebSocket, cTls13);
  Client := NewClient(nil);
  Rec := TWsRecorder.Create;
  RecRef := Rec;
  Alert := '';
  try
    Client.Send(TWebSocketRequest.Create(
      Format('wss://localhost:%d/chat', [FServer.Port]), RecRef));
    Fail('the upgrade must be rejected');
  except
    on E: EHttpTlsClientAuthError do
      Alert := E.Alert;
  end;
  Client.Close;
  FServer.Stop;
  AssertEquals('certificate required', Alert);
  AssertEquals('one connection', 1, FServer.Connections);
end;

procedure TMutualTlsRejectTest.TestWrongCaIsRejectedTls12;
begin
  RunWrongCa(cTls12);
end;

procedure TMutualTlsRejectTest.TestWrongCaIsRejectedTls13;
begin
  RunWrongCa(cTls13);
end;

procedure TMutualTlsRejectTest.TestExpiredIsRejectedOnTheWireTls12;
begin
  RunExpiredOnTheWire(cTls12, 'certificate expired');
end;

procedure TMutualTlsRejectTest.TestExpiredIsRejectedOnTheWireTls13;
begin
  RunExpiredOnTheWire(cTls13, 'certificate expired');
end;

procedure TMutualTlsRejectTest.TestRejectionIsNotRetried;
var
  Client: IHttpClient;
  Alert1, Alert2: string;
begin
  // an idempotent GET is the retry candidate; the client must not repeat it
  StartServer(mkH2, cTls13);
  Client := NewClient(nil);
  Alert1 := AlertOfFetch(Client);
  AssertEquals('first attempt', 'certificate required', Alert1);
  AssertEquals('exactly one connection for one request', 1, FServer.Connections);
  Alert2 := AlertOfFetch(Client);
  Client.Close;
  FServer.Stop;
  AssertEquals('second request', 'certificate required', Alert2);
  AssertEquals('one more connection for the second request', 2,
    FServer.Connections);
end;

{ routed dials }

initialization
  RegisterTest(TMutualTlsRejectTest);
end.
