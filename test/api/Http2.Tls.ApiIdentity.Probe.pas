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
  Http2.Common.Tls.Identity, Http2.Client, Http2.Server;
type
  TCommonContext = Http2.Common.ITLSContext;
  TDeclaredContext = Http2.Common.Tls.Context.ITLSContext;
  TCommonSession = Http2.Common.ITLSSession;
  TDeclaredSession = Http2.Common.Tls.Session.ITLSSession;
  TCommonIdentity = Http2.Common.ITLSIdentity;
  TDeclaredIdentity = Http2.Common.Tls.Identity.ITLSIdentity;
var
  C: TCommonContext;
  D: TDeclaredContext;
  S: TCommonSession;
  SD: TDeclaredSession;
  I: TCommonIdentity;
  ID: TDeclaredIdentity;
begin
  D := C; C := D;
  SD := S; S := SD;
  ID := I; I := ID;
  if (C <> nil) or (S <> nil) or (I <> nil) then Halt(1);
end.
