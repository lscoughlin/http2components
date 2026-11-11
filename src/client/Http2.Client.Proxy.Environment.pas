{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, proxy
notes:
  - This unit holds client proxy value and selector contracts.
---
}
unit Http2.Client.Proxy.Environment;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  Http2.Client.Proxy.Types;

/// resolve the proxy variables through ALookup.  Lowercase names win over
/// uppercase; uppercase HTTP_PROXY is ignored; an empty value is unset.
function ReadProxyEnvironmentUsing(const ALookup: TEnvLookup): TProxyEnvironment;
/// resolve the proxy variables of the process environment
function ReadProxyEnvironment: TProxyEnvironment;

implementation

uses
  SysUtils;

{ ---- environment ---- }

function Pick(const ALookup: TEnvLookup; const ALower, AUpper: string): string;
begin
  Result := ALookup(ALower);
  if (Result = '') and (AUpper <> '') then
    Result := ALookup(AUpper);
end;

function ReadProxyEnvironmentUsing(const ALookup: TEnvLookup): TProxyEnvironment;
begin
  // uppercase HTTP_PROXY is never read: in a CGI process the Proxy: request
  // header surfaces under that name (httpoxy)
  Result.HttpProxy := Pick(ALookup, 'http_proxy', '');
  Result.HttpsProxy := Pick(ALookup, 'https_proxy', 'HTTPS_PROXY');
  Result.AllProxy := Pick(ALookup, 'all_proxy', 'ALL_PROXY');
  Result.NoProxy := Pick(ALookup, 'no_proxy', 'NO_PROXY');
end;

function ProcessEnvLookup(const AName: string): string;
begin
  Result := GetEnvironmentVariable(AName);
end;

function ReadProxyEnvironment: TProxyEnvironment;
begin
  Result := ReadProxyEnvironmentUsing(ProcessEnvLookup);
end;

end.
