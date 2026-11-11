{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, test, tls, context
notes:
  - This helper builds provider-owned client contexts for client tests.
---
}
unit Http2.Client.Test.TlsContext;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  Http2.Common.Tls.Context, Http2.Common.Tls.Identity,
  Http2.OpenSSL;

function OpenSslClientTestContext(const ATrustAnchor: string = '';
  const AInsecure: Boolean = False;
  const AIdentity: ITLSIdentity = nil): ITLSContext;

implementation

uses
  Http2.Common.Tls.Policy;

function OpenSslClientTestContext(const ATrustAnchor: string;
  const AInsecure: Boolean; const AIdentity: ITLSIdentity): ITLSContext;
var
  Policy: TTlsClientPolicy;
begin
  Policy := TTlsClientPolicy.SecureDefault.WithSystemTrust(
    (ATrustAnchor = '') and not AInsecure)
    .WithInsecure(AInsecure);
  if ATrustAnchor <> '' then
    Policy := Policy.WithTrustAnchors([ATrustAnchor]);
  if AIdentity <> nil then
    Policy := Policy.WithDefaultIdentity(AIdentity);
  Result := TOpenSSLTlsContextFactory.Create.WithClientPolicy(Policy).Build;
end;

end.
