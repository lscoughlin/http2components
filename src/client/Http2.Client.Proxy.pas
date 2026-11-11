{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, proxy
notes:
  - This unit holds client proxy value and selector contracts.
---
}
unit Http2.Client.Proxy;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  Http2.Client.Proxy.Types, Http2.Client.Proxy.Match,
  Http2.Client.Proxy.Environment;

const
  cProxyDefaultHttpPort = Http2.Client.Proxy.Types.cProxyDefaultHttpPort;
  cProxyDefaultHttpsPort = Http2.Client.Proxy.Types.cProxyDefaultHttpsPort;
  cProxyDefaultSocksPort = Http2.Client.Proxy.Types.cProxyDefaultSocksPort;
  cSocksMaxCredentialLen = Http2.Client.Proxy.Types.cSocksMaxCredentialLen;
  pkHttp = Http2.Client.Proxy.Types.pkHttp;
  pkHttps = Http2.Client.Proxy.Types.pkHttps;
  pkSocks5 = Http2.Client.Proxy.Types.pkSocks5;

type
  TProxyKind = Http2.Client.Proxy.Types.TProxyKind;
  IProxy = Http2.Client.Proxy.Types.IProxy;
  IProxySelector = Http2.Client.Proxy.Types.IProxySelector;
  TProxy = Http2.Client.Proxy.Types.TProxy;
  TProxyEnvironment = Http2.Client.Proxy.Types.TProxyEnvironment;
  TEnvLookup = Http2.Client.Proxy.Types.TEnvLookup;
  TNoProxyList = Http2.Client.Proxy.Match.TNoProxyList;

/// parse '[scheme://][user[:password]@]host[:port][/...]' (doc/design/proxy.md
/// "Proxy URL values").  Raises EHttpProxyConfigError; messages never contain
/// the password.  An empty AValue yields nil.
function ParseProxyUrl(const AValue: string): IProxy;

/// the pool-key suffix of a proxied route: '' for nil, else
/// ' via [tls:|socks5:][user@]host:port'.  The password is never included.
function ProxyRouteKey(const AProxy: IProxy): string;

/// validate a proxy returned by a selector (non-empty host, non-zero port,
/// SOCKS5 credential lengths); raises EHttpProxyConfigError
procedure ValidateProxy(const AProxy: IProxy);

/// split an absolute URL into lowercase scheme, host (brackets removed) and
/// effective port.  A URL without a scheme counts as https.
function SplitProxyTarget(const AUri: string; out AScheme, AHost: string;
  out APort: Word): Boolean;

/// parse a dotted IPv4 literal
function ParseIp4Literal(const AText: string; out AValue: LongWord): Boolean;
/// parse an IPv6 literal (no brackets) into 16 bytes; accepts '::' and an
/// embedded IPv4 tail
function ParseIp6Literal(const AText: string; out ABytes: array of Byte): Boolean;

/// is AHost 'localhost' or a loopback literal (127.0.0.0/8, ::1)?
function IsLoopbackHost(const AHost: string): Boolean;

/// base64 of 'user:password' for Proxy-Authorization: Basic
function ProxyBasicCredentials(const AUserName, APassword: string): string;

/// resolve the proxy variables through ALookup.  Lowercase names win over
/// uppercase; uppercase HTTP_PROXY is ignored; an empty value is unset.
function ReadProxyEnvironmentUsing(const ALookup: TEnvLookup): TProxyEnvironment;
/// resolve the proxy variables of the process environment
function ReadProxyEnvironment: TProxyEnvironment;

/// collapse every proxy source into one selector (doc/design/proxy.md
/// "Precedence"): ACustom wins outright; else AFixed, then AAllProxyUrl, then
/// the environment AEnv (when AUseEnv), all filtered by loopback and the
/// no-proxy list ANoProxy.  Returns nil when no source is configured, i.e. the
/// route is direct for every request.  Raises EHttpProxyConfigError for an
/// unusable proxy value.
function BuildProxySelector(const ACustom: IProxySelector;
  const AFixed: IProxy; const AAllProxyUrl: string; const AUseEnv: Boolean;
  const AEnv: TProxyEnvironment; const ANoProxy: string): IProxySelector;

implementation

uses
  SysUtils;

function ParseProxyUrl(const AValue: string): IProxy;
begin Result := Http2.Client.Proxy.Match.ParseProxyUrl(AValue); end;
function ProxyRouteKey(const AProxy: IProxy): string;
begin Result := Http2.Client.Proxy.Match.ProxyRouteKey(AProxy); end;
procedure ValidateProxy(const AProxy: IProxy);
begin Http2.Client.Proxy.Match.ValidateProxy(AProxy); end;
function SplitProxyTarget(const AUri: string; out AScheme, AHost: string;
  out APort: Word): Boolean;
begin Result := Http2.Client.Proxy.Match.SplitProxyTarget(AUri, AScheme, AHost, APort); end;
function ParseIp4Literal(const AText: string; out AValue: LongWord): Boolean;
begin Result := Http2.Client.Proxy.Match.ParseIp4Literal(AText, AValue); end;
function ParseIp6Literal(const AText: string; out ABytes: array of Byte): Boolean;
begin Result := Http2.Client.Proxy.Match.ParseIp6Literal(AText, ABytes); end;
function IsLoopbackHost(const AHost: string): Boolean;
begin Result := Http2.Client.Proxy.Match.IsLoopbackHost(AHost); end;
function ProxyBasicCredentials(const AUserName, APassword: string): string;
begin Result := Http2.Client.Proxy.Match.ProxyBasicCredentials(AUserName, APassword); end;
function ReadProxyEnvironmentUsing(const ALookup: TEnvLookup): TProxyEnvironment;
begin Result := Http2.Client.Proxy.Environment.ReadProxyEnvironmentUsing(ALookup); end;
function ReadProxyEnvironment: TProxyEnvironment;
begin Result := Http2.Client.Proxy.Environment.ReadProxyEnvironment; end;
function BuildProxySelector(const ACustom: IProxySelector;
  const AFixed: IProxy; const AAllProxyUrl: string; const AUseEnv: Boolean;
  const AEnv: TProxyEnvironment; const ANoProxy: string): IProxySelector;
begin
  Result := Http2.Client.Proxy.Match.BuildProxySelector(
    ACustom, AFixed, AAllProxyUrl, AUseEnv, AEnv, ANoProxy);
end;

end.
