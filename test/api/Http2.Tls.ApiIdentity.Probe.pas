{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, api, identity, probe
notes:
  - Compile-time checks for public TLS facade aliases.
---
}
program Http2.Tls.ApiIdentity.Probe;
{$mode delphi}{$H+}{$interfaces com}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Http2.Common, Http2.Common.Tls.Context, Http2.Common.Tls.Session,
  Http2.Common.Tls.Identity, Http2.Client, Http2.Server,
  Http2.OpenSSL, Http2.TlsLib;
type
  TCommonContext = Http2.Common.ITLSContext;
  TDeclaredContext = Http2.Common.Tls.Context.ITLSContext;
  TCommonSession = Http2.Common.ITLSSession;
  TDeclaredSession = Http2.Common.Tls.Session.ITLSSession;
  TCommonIdentity = Http2.Common.ITLSIdentity;
  TDeclaredIdentity = Http2.Common.Tls.Identity.ITLSIdentity;
  TOpenSslIdentityAlias = Http2.OpenSSL.TOpenSSLIdentity;
  TTlsLibIdentityAlias = Http2.TlsLib.TTlsLibIdentity;
var
  C: TCommonContext;
  D: TDeclaredContext;
  S: TCommonSession;
  SD: TDeclaredSession;
  I: TCommonIdentity;
  ID: TDeclaredIdentity;
  ClientFactory: Http2.Client.THttpClientFactory;
  ServerFactory: Http2.Server.THttp2ServerFactory;
begin
  D := C; C := D;
  SD := S; S := SD;
  ID := I; I := ID;
  ClientFactory := Http2.Client.THttpClientFactory.Create;
  ServerFactory := Http2.Server.THttp2ServerFactory.Create;
  ClientFactory.WithTlsContext(C);
  ServerFactory.WithTlsContext(C);
  if (TypeInfo(TOpenSslIdentityAlias) = nil) or
     (TypeInfo(TTlsLibIdentityAlias) = nil) then Halt(2);
  if (C <> nil) or (S <> nil) or (I <> nil) then Halt(1);
end.
