{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, proxy
notes:
  - This unit holds the validation rule of a proxy on a Unix socket.
---
}
unit Http2.Client.Proxy.Unix;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  Http2.Client.Proxy.Types, Http2.Common.UnixPath;

/// the empty text for a usable Unix proxy, else a short text that names the
/// broken rule
// - a TLS proxy on a Unix socket is refused (pkHttps)
// - the text never holds the path
function UnixProxyProblem(const APath: string; const AKind: TProxyKind): string;

implementation

function UnixProxyProblem(const APath: string; const AKind: TProxyKind): string;
begin
  Result := UnixPathProblem(APath);
  if (Result = '') and (AKind = pkHttps) then
    Result := 'a Unix proxy cannot use TLS';
end;

end.
