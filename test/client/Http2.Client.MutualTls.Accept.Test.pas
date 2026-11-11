{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves Mutual TLS client tests from the source project
---
}
unit Http2.Client.MutualTls.Accept.Test;

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
  TMutualTlsAcceptTest = class(TMutualTlsTestBase)
  published
    procedure TestHttp2WithTheIdentityTls12;
    procedure TestHttp2WithTheIdentityTls13;
    procedure TestHttp11FallbackWithTheIdentityTls12;
    procedure TestHttp11FallbackWithTheIdentityTls13;
    procedure TestSseWithTheIdentityTls12;
    procedure TestSseWithTheIdentityTls13;
    procedure TestWssWithTheIdentityTls12;
    procedure TestWssWithTheIdentityTls13;
    procedure TestPkcs12IdentityIsAccepted;
  end;

implementation

procedure TMutualTlsAcceptTest.TestHttp2WithTheIdentityTls12;
begin
  RunAccepts(mkH2, cTls12, False);
end;

procedure TMutualTlsAcceptTest.TestHttp2WithTheIdentityTls13;
begin
  RunAccepts(mkH2, cTls13, False);
end;

procedure TMutualTlsAcceptTest.TestHttp11FallbackWithTheIdentityTls12;
begin
  RunAccepts(mkHttp1, cTls12, True);
end;

procedure TMutualTlsAcceptTest.TestHttp11FallbackWithTheIdentityTls13;
begin
  RunAccepts(mkHttp1, cTls13, True);
end;

procedure TMutualTlsAcceptTest.TestSseWithTheIdentityTls12;
begin
  RunSse(cTls12);
end;

procedure TMutualTlsAcceptTest.TestSseWithTheIdentityTls13;
begin
  RunSse(cTls13);
end;

procedure TMutualTlsAcceptTest.TestWssWithTheIdentityTls12;
begin
  RunWebSocket(cTls12);
end;

procedure TMutualTlsAcceptTest.TestWssWithTheIdentityTls13;
begin
  RunWebSocket(cTls13);
end;

procedure TMutualTlsAcceptTest.TestPkcs12IdentityIsAccepted;
var
  Client: IHttpClient;
  Body: string;
begin
  StartServer(mkH2, cTls13);
  Client := NewClient(TClientIdentity.FromPkcs12File(Fixture('client-chain.p12'),
    cPass));
  AssertEquals('status', 200, Fetch(Client, Body));
  Client.Close;
  FServer.Stop;
  AssertEquals('handshake', 1, FServer.Handshakes);
end;

{ rejection }

initialization
  RegisterTest(TMutualTlsAcceptTest);
end.
