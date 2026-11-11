{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, integration, context, lifecycle
notes:
  - Bounded tests for dual-role provider contexts.
---
}
program Http2TlsIntegrationTests;
{$mode delphi}{$H+}{$interfaces com}{$modeswitch advancedrecords}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Http2.Common.Tls.Context,
  Http2.Common.Tls.Identity, Http2.Common.Tls.Policy, Http2.Common.Tls.Session,
  Http2.OpenSSL, Http2.TlsLib;

procedure Check(const AValue: Boolean; const AMessage: string);
begin
  if not AValue then raise Exception.Create(AMessage);
end;

const
  cCert = 'test/fixtures/client/certs/localhost.crt';
  cKey = 'test/fixtures/client/certs/localhost.key';

procedure CheckRoles(const AContext: ITLSContext);
var
  ClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  ClientSession, ServerSession: ITLSSession;
begin
  ClientOptions := Default(TTlsClientSessionOptions);
  ClientOptions.HostName := 'localhost';
  ClientOptions := ClientOptions.WithAlpns(['h2']);
  ServerOptions := Default(TTlsServerSessionOptions);
  ServerOptions := ServerOptions.WithAlpns(['h2']);
  ClientSession := AContext.CreateClientSession(ClientOptions);
  ServerSession := AContext.CreateServerSession(ServerOptions);
  try
    Check(ClientSession <> nil, 'client session exists');
    Check(ServerSession <> nil, 'server session exists');
    Check(Pointer(ClientSession) <> Pointer(ServerSession),
      'role sessions are distinct');
  finally
    ClientSession.Abort;
    ServerSession.Abort;
  end;
end;

procedure TestOpenSslContextCreatesConcurrentRoleSessions;
var Context: ITLSContext; Identity: ITLSIdentity;
  Factory: TOpenSSLTlsContextFactory;
begin
  Identity := TOpenSSLIdentity.FromPemFiles(cCert, cKey);
  Factory := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithInsecure(True))
    .WithServerPolicy(TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity));
  Context := Factory.Build;
  CheckRoles(Context);
end;

procedure TestTlsLibContextCreatesConcurrentRoleSessions;
var Context: ITLSContext; Identity: ITLSIdentity;
  Factory: TTlsLibContextFactory;
begin
  Identity := TTlsLibIdentity.FromPemFiles(cCert, cKey);
  Factory := TTlsLibContextFactory.Create
    .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithInsecure(True))
    .WithServerPolicy(TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity));
  Context := Factory.Build;
  CheckRoles(Context);
end;

begin
  TestOpenSslContextCreatesConcurrentRoleSessions;
  TestTlsLibContextCreatesConcurrentRoleSessions;
  WriteLn('PASS 2 dual-role context cases');
end.
