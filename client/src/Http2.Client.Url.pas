{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Url;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  Http2.Client.Errors,
  Http2.Client.Defaults,
  Http2.Common.Uri;


/// the URL with the scheme that a scheme-less input takes (decided: Q7).
// - when no ':' comes before the first '/', '?' or '#', and the text does
//   not start with '//', the result starts with 'https://'
// - ParseURI itself never adds a scheme; only the client inputs do
function WithDefaultScheme(const AUrl: string): string;

/// parse a request URL with ParseURI; False when it is not a valid URL with
/// a host and a port that is not 0. Never raises and never returns the text.
function TryParseRequestUrl(const AUrl: string; out AUri: TURI): Boolean;

procedure ParseHttpUrl(const AUrl: string; out AHost: string; out APort: Word;
  out APath: string);

function SchemeOfUrl(const AUrl: string): string;

function DefaultPortForScheme(const AScheme: string): Word;

function BracketedHost(const AHost: string): string;

function OriginOfUrl(const AUrl: string): string;

function ResolveLocation(const ABaseUrl, ALocation: string): string;

implementation

function WithDefaultScheme(const AUrl: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(AUrl)) and not (AUrl[I] in ['/', '?', '#', ':']) do
    Inc(I);
  if (I <= Length(AUrl)) and (AUrl[I] = ':') then
    Exit(AUrl);
  if Copy(AUrl, 1, 2) = '//' then
    Exit(AUrl);
  Result := 'https://' + AUrl;
end;

function IsUsableRequestUri(const AUri: TURI): Boolean;
begin
  Result := AUri.IsAbsolute and AUri.HasAuthority and (AUri.Host <> '') and
    (not AUri.HasPort or (AUri.Port > 0));
end;

function TryParseRequestUrl(const AUrl: string; out AUri: TURI): Boolean;
begin
  Result := TryParseURI(WithDefaultScheme(AUrl), AUri) and IsUsableRequestUri(AUri);
end;

// parse or raise; the message never holds the URL or the port text
function ParseRequestUrl(const AUrl: string): TURI;
begin
  if not TryParseRequestUrl(AUrl, Result) then
    raise EHttpProtocolError.Create('invalid URL: no host, or a bad port',
      ecProtocolError);
end;

// the port of a parsed URI: the explicit port, else the scheme default
function EffectivePort(const AUri: TURI): Word;
begin
  if AUri.HasPort then
    Result := Word(AUri.Port)
  else
    Result := DefaultPortForScheme(AUri.Scheme);
end;

// the request target: the path, then the query; '/' when both are empty
// (a URL without a path keeps the form of the earlier parser: '?q' stays '?q')
function RequestTarget(const AUri: TURI): string;
begin
  Result := AUri.Path;
  if AUri.HasQuery then
    Result := Result + '?' + AUri.Query;
  if Result = '' then
    Result := '/';
end;

procedure ParseHttpUrl(const AUrl: string; out AHost: string; out APort: Word;
  out APath: string);
var
  Uri: TURI;
begin
  Uri := ParseRequestUrl(AUrl);
  AHost := Uri.Host;
  APort := EffectivePort(Uri);
  APath := RequestTarget(Uri);
end;

function SchemeOfUrl(const AUrl: string): string;
begin
  Result := ParseRequestUrl(AUrl).Scheme;
end;

function DefaultPortForScheme(const AScheme: string): Word;
begin
  // the origin/authority omit the port only when it is the scheme default,
  // so 80 is default for http and 443 for everything else
  if LowerCase(AScheme) = 'http' then
    Result := cDefaultHttpPort
  else
    Result := cDefaultHttpsPort;
end;

function BracketedHost(const AHost: string): string;
begin
  if (Pos(':', AHost) > 0) and (Copy(AHost, 1, 1) <> '[') then
    Result := '[' + AHost + ']'
  else
    Result := AHost;
end;

function OriginOfUrl(const AUrl: string): string;
var
  Uri: TURI;
  Port: Word;
begin
  Uri := ParseRequestUrl(AUrl);
  Port := EffectivePort(Uri);
  Result := BracketedHost(Uri.Host);
  if Port <> DefaultPortForScheme(Uri.Scheme) then
    Result := Result + ':' + IntToStr(Port);
  // a different scheme is a different origin even on the same host:port, so
  // an http redirect target never reuses a pooled https connection
  if Uri.Scheme <> 'https' then
    Result := Uri.Scheme + '://' + Result;
end;

function ResolveLocation(const ABaseUrl, ALocation: string): string;
var
  Base, Ref: TURI;
begin
  if ALocation = '' then
    Exit('');
  // only the base takes the scheme-less rule: a Location is a relative
  // reference, so '/login' must not become 'https:///login'
  Base := ParseRequestUrl(ABaseUrl);
  Ref := ParseURI(ALocation);
  Result := UriToString(ResolveReference(Base, Ref));
end;

end.
