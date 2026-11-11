{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: alpn, tls, server, test
notes:
  - This unit checks strict and fallback ALPN offers through a fake session.
---
}
unit Http2.Server.Alpn.Test;
{$mode delphi}{$H+}{$interfaces com}
interface
uses fpcunit, testregistry, Http2.Common.Tls.Types,
  Http2.Common.Tls.Session, Http2.Common.Tls.Context, Http2.Common.Tls.Policy,
  Http2.Server.Tls.Binding, Http2.Test.Tls.Fake;
type
  TAlpnSelectTest = class(TTestCase)
  published
    procedure TestFallbackOffersHttp11AfterH2;
    procedure TestStrictPolicyOffersOnlyH2;
  end;
implementation
procedure TAlpnSelectTest.TestFallbackOffersHttp11AfterH2;
var C: ITLSContext; B: ITlsServerBinding; S: ITLSSession;
    Info: ITlsFakeSessionInfo; Options: TTlsServerSessionOptions;
    Values: TArray<string>;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  S := B.CreateSession(10, True);
  Info := S as ITlsFakeSessionInfo;
  Options := Info.ServerOptions;
  Values := Options.AlpnValues;
  AssertEquals('h2 is preferred', 'h2', Values[0]);
  AssertEquals('fallback follows h2', 'http/1.1', Values[1]);
end;

procedure TAlpnSelectTest.TestStrictPolicyOffersOnlyH2;
var C: ITLSContext; B: ITlsServerBinding; S: ITLSSession;
    Info: ITlsFakeSessionInfo; Options: TTlsServerSessionOptions;
    Values: TArray<string>;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  S := B.CreateSession(10, False);
  Info := S as ITlsFakeSessionInfo;
  Options := Info.ServerOptions;
  Values := Options.AlpnValues;
  AssertEquals('strict policy has one entry', 1, Length(Values));
  AssertEquals('strict policy offers h2', 'h2', Values[0]);
end;

initialization
  RegisterTest(TAlpnSelectTest);
end.
