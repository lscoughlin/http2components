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
  Http2.Client.Defaults;


procedure ParseHttpUrl(const AUrl: string; out AHost: string; out APort: Word;
  out APath: string);

function SchemeOfUrl(const AUrl: string): string;

function DefaultPortForScheme(const AScheme: string): Word;

function BracketedHost(const AHost: string): string;

function OriginOfUrl(const AUrl: string): string;

function ResolveLocation(const ABaseUrl, ALocation: string): string;

implementation

procedure ParseHttpUrl(const AUrl: string; out AHost: string; out APort: Word;
  out APath: string);
var
  Rest, AuthorityPart, PathPart, PortStr: string;
  P, Colon: Integer;
  Port: LongInt;
begin
  AHost := '';
  APath := '/';
  Rest := AUrl;
  // the default port follows the scheme: 80 for http, 443 for https
  // (doc/design/fallback.md "Terms")
  P := Pos('://', Rest);
  if (P > 0) and (LowerCase(Copy(Rest, 1, P - 1)) = 'http') then
    APort := cDefaultHttpPort
  else
    APort := cDefaultHttpsPort;
  if P > 0 then
    Rest := Copy(Rest, P + 3, Length(Rest));    // drop "scheme://"
  PathPart := '';
  P := Pos('/', Rest);
  Colon := Pos('?', Rest);
  if (P > 0) and ((Colon = 0) or (P < Colon)) then
  begin
    AuthorityPart := Copy(Rest, 1, P - 1);
    PathPart := Copy(Rest, P, Length(Rest));
  end
  else if Colon > 0 then
  begin
    AuthorityPart := Copy(Rest, 1, Colon - 1);
    PathPart := Copy(Rest, Colon, Length(Rest));
  end
  else
    AuthorityPart := Rest;

  // userinfo never reaches :authority or the dial: drop everything up to the
  // last '@' (RFC 3986 section 3.2)
  for P := Length(AuthorityPart) downto 1 do
    if AuthorityPart[P] = '@' then
    begin
      AuthorityPart := Copy(AuthorityPart, P + 1, MaxInt);
      Break;
    end;

  PortStr := '';
  if Copy(AuthorityPart, 1, 1) = '[' then
  begin
    // bracketed IPv6 literal (RFC 3986): the host is returned WITHOUT the
    // brackets, which are re-added wherever a host:port string is written
    P := Pos(']', AuthorityPart);
    if P = 0 then
      raise EHttpProtocolError.Create('invalid URL host: unterminated "["',
        ecProtocolError);
    AHost := Copy(AuthorityPart, 2, P - 2);
    Rest := Copy(AuthorityPart, P + 1, MaxInt);
    if Rest <> '' then
    begin
      if Rest[1] <> ':' then
        raise EHttpProtocolError.Create('invalid URL host: junk after "]"',
          ecProtocolError);
      PortStr := Copy(Rest, 2, MaxInt);
    end;
  end
  else
  begin
    Colon := Pos(':', AuthorityPart);
    if Colon > 0 then
    begin
      AHost := Copy(AuthorityPart, 1, Colon - 1);
      PortStr := Copy(AuthorityPart, Colon + 1, Length(AuthorityPart));
    end
    else
      AHost := AuthorityPart;
  end;
  if PortStr <> '' then
  begin
    Port := StrToIntDef(PortStr, APort);
    if (Port <= 0) or (Port > 65535) then
      raise EHttpProtocolError.Create('invalid URL port: ' + PortStr,
        ecProtocolError);
    APort := Word(Port);
  end;

  if PathPart <> '' then
    APath := PathPart;
end;

function SchemeOfUrl(const AUrl: string): string;
var
  P: Integer;
begin
  P := Pos('://', AUrl);
  if P > 0 then
    Result := LowerCase(Copy(AUrl, 1, P - 1))
  else
    Result := 'https';
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
  Host, Path, Scheme: string;
  Port: Word;
begin
  ParseHttpUrl(AUrl, Host, Port, Path);
  Host := BracketedHost(Host);
  Scheme := SchemeOfUrl(AUrl);
  if Port = DefaultPortForScheme(Scheme) then
    Result := Host
  else
    Result := Host + ':' + IntToStr(Port);
  // a different scheme is a different origin even on the same host:port, so
  // an http redirect target never reuses a pooled https connection
  if Scheme <> 'https' then
    Result := Scheme + '://' + Result;
end;

function ResolveLocation(const ABaseUrl, ALocation: string): string;
var
  Base, Prefix, Rest, Path, Dir: string;
  P, Cut: Integer;
begin
  if ALocation = '' then
    Exit('');
  if Pos('://', ALocation) > 0 then
    Exit(ALocation);
  if Copy(ALocation, 1, 2) = '//' then
    Exit(SchemeOfUrl(ABaseUrl) + ':' + ALocation);

  Base := ABaseUrl;
  P := Pos('://', Base);
  if P > 0 then
    Prefix := Copy(Base, 1, P + 2)     // 'scheme://'
  else
    Prefix := 'https://';
  Rest := Copy(Base, Length(Prefix) + 1, Length(Base));  // authority + path

  // authority ends at the first '/' or '?'
  P := Pos('/', Rest);
  Cut := Pos('?', Rest);
  if (Cut > 0) and ((P = 0) or (Cut < P)) then
    P := Cut;
  if P = 0 then
  begin
    // no path at all: the base directory is the root
    if Copy(ALocation, 1, 1) <> '/' then
      Exit(Prefix + Rest + '/' + ALocation);
    Exit(Prefix + Rest + ALocation);
  end;

  Path := Copy(Rest, P, Length(Rest));   // '/...' incl. any query
  Cut := Pos('?', Path);
  if Cut > 0 then
    Path := Copy(Path, 1, Cut - 1);      // drop the base query

  if Copy(ALocation, 1, 1) = '/' then
    Exit(Prefix + Copy(Rest, 1, P - 1) + ALocation);

  // path-relative: drop the final path segment (RFC 3986 merge). A base with
  // a query but no path merges at the root.
  if Path = '' then
    Dir := '/'
  else
  begin
    Cut := Length(Path);
    while (Cut > 1) and (Path[Cut] <> '/') do
      Dec(Cut);
    Dir := Copy(Path, 1, Cut);
  end;
  Result := Prefix + Copy(Rest, 1, P - 1) + Dir + ALocation;
end;

end.
