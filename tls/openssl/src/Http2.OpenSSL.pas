{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl
notes:
  - This unit exports neutral OpenSSL provider names.
---
}
unit Http2.OpenSSL;
{$mode delphi}{$H+}{$modeswitch advancedrecords}{$interfaces com}
interface
uses Http2.OpenSSL.Identity, Http2.OpenSSL.Context, Http2.OpenSSL.Factory;
type
  EOpenSSLProviderUnavailable = Http2.OpenSSL.Identity.EOpenSSLProviderUnavailable;
  TOpenSSLIdentity = Http2.OpenSSL.Identity.TOpenSSLIdentity;
  TOpenSSLTlsContext = Http2.OpenSSL.Context.TOpenSSLTlsContext;
  OpenSSLTlsContext = Http2.OpenSSL.Context.OpenSSLTlsContext;
  TOpenSSLTlsContextFactory = Http2.OpenSSL.Factory.TOpenSSLTlsContextFactory;
implementation
end.
