{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
notes:
  - this is the TlsLib provider package facade
---
}
unit Http2.TlsLib;

{$mode delphi}

interface

uses
  SysUtils;

type
  ETlsLibProviderUnavailable = class(Exception);

  TTlsLibContext = class
  public
    function BackendName: string;
    procedure RequireAvailable;
  end;

  TlsLibContext = TTlsLibContext;

implementation

function TTlsLibContext.BackendName: string;
begin
  Result := 'TlsLib';
end;

procedure TTlsLibContext.RequireAvailable;
begin
  raise ETlsLibProviderUnavailable.Create(
    'TlsLib TLS sessions are unavailable until TLS-06 is implemented');
end;

end.
