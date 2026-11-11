{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, principal, verified identity
notes:
  - This unit holds the server request principal selection for verified peers.
---
}
unit Http2.Server.Mtls.Types;
{$mode delphi}{$H+}
interface
type
  TClientCertPrincipal = (ccpNone, ccpSubjectDn, ccpCommonName);
function PrincipalTextFor(const APrincipal: TClientCertPrincipal;
  const ASubjectDn, ACommonName: string): string;
implementation
function PrincipalTextFor(const APrincipal: TClientCertPrincipal;
  const ASubjectDn, ACommonName: string): string;
begin
  case APrincipal of
    ccpSubjectDn: Result := ASubjectDn;
    ccpCommonName: Result := ACommonName;
  else
    Result := '';
  end;
end;
end.
