{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, factory
notes:
  - This unit validates provider policies before context creation.
---
}
unit Http2.OpenSSL.Factory;
{$mode delphi}{$H+}{$interfaces com}
interface
uses Http2.Common.Tls.Policy, Http2.Common.Tls.Context;
type
  TOpenSSLTlsContextFactory = record
  private
    FHasClient, FHasServer: Boolean;
    FClient: TTlsClientPolicy;
    FServer: TTlsServerPolicy;
    FTimeout: Cardinal;
  public
    class function Create: TOpenSSLTlsContextFactory; static;
    function WithClientPolicy(const APolicy: TTlsClientPolicy): TOpenSSLTlsContextFactory;
    function WithServerPolicy(const APolicy: TTlsServerPolicy): TOpenSSLTlsContextFactory;
    function WithHandshakeTimeoutMs(const AMilliseconds: Cardinal): TOpenSSLTlsContextFactory;
    function Build: ITLSContext;
  end;
implementation
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.OpenSSL.Context, Http2.OpenSSL.Identity;
class function TOpenSSLTlsContextFactory.Create: TOpenSSLTlsContextFactory;
begin Result := Default(TOpenSSLTlsContextFactory); end;
function TOpenSSLTlsContextFactory.WithClientPolicy(const APolicy: TTlsClientPolicy): TOpenSSLTlsContextFactory;
begin Result := Self; Result.FClient := APolicy; Result.FHasClient := True; end;
function TOpenSSLTlsContextFactory.WithServerPolicy(const APolicy: TTlsServerPolicy): TOpenSSLTlsContextFactory;
begin Result := Self; Result.FServer := APolicy; Result.FHasServer := True; end;
function TOpenSSLTlsContextFactory.WithHandshakeTimeoutMs(const AMilliseconds: Cardinal): TOpenSSLTlsContextFactory;
begin Result := Self; Result.FTimeout := AMilliseconds; end;
function TOpenSSLTlsContextFactory.Build: ITLSContext;
var C: TTlsClientPolicy; S: TTlsServerPolicy;
begin
  C := TTlsClientPolicy.SecureDefault; S := TTlsServerPolicy.SecureDefault;
  if FHasClient then C := FClient;
  if FHasServer then S := FServer;
  if not FHasClient and not FHasServer then
    raise ETlsContextError.Create('at least one TLS role policy is required');
  if FHasClient and ((C.MinVersion > C.MaxVersion) or
    (C.VerifyHostname and not C.VerifyPeer)) then
    raise ETlsContextError.Create('invalid client TLS policy');
  if FHasServer and (S.MinVersion > S.MaxVersion) then
    raise ETlsContextError.Create('invalid server TLS version range');
  if FHasServer and (S.ServerIdentity = nil) then
    raise ETlsContextError.Create('server TLS policy requires a server identity');
  if FHasClient and (C.DefaultIdentity <> nil) and not OpenSSLIdentityIsNative(C.DefaultIdentity) then
    raise ETlsContextError.Create('client identity belongs to another TLS provider');
  if FHasServer and (S.ServerIdentity <> nil) and not OpenSSLIdentityIsNative(S.ServerIdentity) then
    raise ETlsContextError.Create('server identity belongs to another TLS provider');
  if FHasServer and (OpenSSLIdentityMaterialSize(S.ServerIdentity) >
    TlsMaxHandshakeIdentityBytes) then
    raise ETlsContextError.Create('server certificate chain exceeds the TLS handshake bound');
  Result := TOpenSSLTlsContext.Create(C, S, FTimeout, FHasClient, FHasServer);
end;
end.
