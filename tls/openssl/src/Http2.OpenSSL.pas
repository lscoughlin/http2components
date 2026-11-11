{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
notes:
  - this is the OpenSSL provider package facade
---
}
unit Http2.OpenSSL;

{$mode delphi}

interface

uses
  SysUtils;

type
  EOpenSSLProviderUnavailable = class(Exception);

  TOpenSSLTlsContext = class
  public
    function BackendName: string;
    procedure RequireAvailable;
  end;

  OpenSSLTlsContext = TOpenSSLTlsContext;

implementation

function TOpenSSLTlsContext.BackendName: string;
begin
  Result := 'OpenSSL';
end;

procedure TOpenSSLTlsContext.RequireAvailable;
begin
  raise EOpenSSLProviderUnavailable.Create(
    'OpenSSL TLS sessions are unavailable until TLS-05 is implemented');
end;

end.
