{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, trust
notes:
  - This unit loads immutable OpenSSL trust policy into a role context.
---
}
unit Http2.OpenSSL.Trust;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, Http2.Common.Tls.Types, mormot.lib.openssl11;
procedure OpenSSLConfigureTrust(const ACtx: PSSL_CTX;
  const AAnchors: TArray<string>; const ASystem, APartial: Boolean;
  const AHasDepth: Boolean; const ADepth: Integer);
implementation
uses Http2.OpenSSL.Session;
procedure OpenSSLConfigureTrust(const ACtx: PSSL_CTX;
  const AAnchors: TArray<string>; const ASystem, APartial: Boolean;
  const AHasDepth: Boolean; const ADepth: Integer);
var I: Integer; Store: PX509_STORE;
begin
  if AHasDepth and not OpenSSLSetVerificationDepth(ACtx, ADepth) then
    raise ETlsContextError.Create('OpenSSL verification-depth control is not available');
  if ASystem and (SSL_CTX_set_default_verify_paths(ACtx) <> 1) then
    raise ETlsContextError.Create('OpenSSL system trust setup failed');
  for I := 0 to High(AAnchors) do
    if SSL_CTX_load_verify_locations(ACtx, PChar(AAnchors[I]), nil) <> 1 then
      raise ETlsContextError.CreateFmt('cannot load trust anchor file "%s"', [AAnchors[I]]);
  if APartial then
  begin
    Store := SSL_CTX_get_cert_store(ACtx);
    if (Store = nil) or (X509_STORE_set_flags(Store, X509_V_FLAG_PARTIAL_CHAIN) <> 1) then
      raise ETlsContextError.Create('OpenSSL partial-chain setup failed');
  end;
end;
end.
