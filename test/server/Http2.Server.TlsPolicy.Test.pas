{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls, protocol-range
notes:
  - This unit checks the factory protocol range mapping without a socket.
---
}
unit Http2.Server.TlsPolicy.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  fpcunit, testregistry, mormot.lib.openssl11,
  Http2.Server.Config, Http2.Server.Config.Tls, Http2.Server.Seam,
  Http2.Server.Tls, Http2.Server.Async.Options;

type
  TNullTlsHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  TTlsPolicyTest = class(TTestCase)
  published
    procedure TestFactoryMapsProtocolRange;
  end;

implementation

procedure TNullTlsHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
end;

procedure TTlsPolicyTest.TestFactoryMapsProtocolRange;
var
  Factory: THttp2ServerFactory;
  Policy: TTlsPolicy;
begin
  Factory := THttp2ServerFactory.Create
    .WithHandler(TNullTlsHandler.Create)
    .WithClearTextAllowed(False)
    .WithTls(TTlsServerOptions.Create
      .WithCertificateFile('unused.pem')
      .WithMinTlsVersion(tvTls13)
      .WithMaxTlsVersion(tvTls13));
  Policy := BuildTlsPolicy(Factory);
  AssertEquals('the minimum reaches the policy', TLS1_3_VERSION,
    Policy.MinProtocol);
  AssertEquals('the maximum reaches the policy', TLS1_3_VERSION,
    Policy.MaxProtocol);
  Factory := THttp2ServerFactory.Create
    .WithHandler(TNullTlsHandler.Create)
    .WithClearTextAllowed(False)
    .WithTls(TTlsServerOptions.Create.WithCertificateFile('unused.pem'));
  Policy := BuildTlsPolicy(Factory);
  AssertEquals('the default minimum is TLS 1.2', TLS1_2_VERSION,
    Policy.MinProtocol);
  AssertEquals('the default maximum is TLS 1.3', TLS1_3_VERSION,
    Policy.MaxProtocol);
end;

initialization
  RegisterTest(TTlsPolicyTest);
end.
