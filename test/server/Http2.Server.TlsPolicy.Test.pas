{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, server, alpn, context, test
notes:
  - This unit checks server session protocol offers through the fake context.
---
}
unit Http2.Server.TlsPolicy.Test;
{$mode delphi}{$H+}{$interfaces com}
interface
uses fpcunit, testregistry, Http2.Common.Tls.Types,
  Http2.Common.Tls.Session, Http2.Common.Tls.Context, Http2.Common.Tls.Policy,
  Http2.Server.Tls.Binding, Http2.Test.Tls.Fake;
type
  TTlsProtocolMappingTest = class(TTestCase)
  published
    procedure TestFallbackOffersHttp11AfterH2;
    procedure TestStrictPolicyOffersOnlyH2;
  end;
implementation
procedure TTlsProtocolMappingTest.TestFallbackOffersHttp11AfterH2;
var C: ITLSContext; B: ITlsServerBinding; S: ITLSSession;
    Info: ITlsFakeSessionInfo; Options: TTlsServerSessionOptions;
    Alpn: TArray<string>;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  S := B.CreateSession(100, True);
  Info := S as ITlsFakeSessionInfo;
  Options := Info.ServerOptions;
  Alpn := Options.AlpnValues;
  AssertEquals('h2 is first', 'h2', Alpn[0]);
  AssertEquals('HTTP/1.1 follows h2', 'http/1.1', Alpn[1]);
end;

procedure TTlsProtocolMappingTest.TestStrictPolicyOffersOnlyH2;
var C: ITLSContext; B: ITlsServerBinding; S: ITLSSession;
    Info: ITlsFakeSessionInfo; Options: TTlsServerSessionOptions;
    Alpn: TArray<string>;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  S := B.CreateSession(100, False);
  Info := S as ITlsFakeSessionInfo;
  Options := Info.ServerOptions;
  Alpn := Options.AlpnValues;
  AssertEquals('strict policy offers one protocol', 1, Length(Alpn));
  AssertEquals('strict policy offers h2', 'h2', Alpn[0]);
end;

initialization
  RegisterTest(TTlsProtocolMappingTest);
end.
