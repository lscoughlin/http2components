{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, proxy
notes:
  - This unit holds client proxy value and selector contracts.
---
}
unit Http2.Client.Proxy.Types;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors;

const
  cProxyDefaultHttpPort   = 80;
  cProxyDefaultHttpsPort  = 443;
  cProxyDefaultSocksPort  = 1080;
  /// RFC 1929: user name and password are each at most 255 octets
  cSocksMaxCredentialLen  = 255;

type
  /// pkHttp: HTTP CONNECT over TCP; pkHttps: HTTP CONNECT over TLS;
  /// pkSocks5: SOCKS5 CONNECT over TCP
  TProxyKind = (pkHttp, pkHttps, pkSocks5);

  /// one proxy endpoint.  Credentials are optional.
  IProxy = interface
    ['{7B1D5E02-9F6A-4C57-8A31-5D2E0C4A9B11}']
    function GetHost: string;
    function GetPort: Word;
    function GetKind: TProxyKind;
    function GetUserName: string;
    function GetPassword: string;
    property Host: string read GetHost;
    property Port: Word read GetPort;
    /// how the proxy is spoken to; also decides whether the leg to it is TLS
    property Kind: TProxyKind read GetKind;
    property UserName: string read GetUserName;
    property Password: string read GetPassword;
  end;

  /// chooses the route for one request URI
  IProxySelector = interface
    ['{7B1D5E02-9F6A-4C57-8A31-5D2E0C4A9B12}']
    /// the proxy to use for AUri, or nil for a direct connection
    function SelectProxy(const AUri: string): IProxy;
  end;

  TProxy = class(TInterfacedObject, IProxy)
  private
    FHost: string;
    FPort: Word;
    FKind: TProxyKind;
    FUserName: string;
    FPassword: string;
  public
    constructor Create(const AHost: string; const APort: Word); overload;
    constructor Create(const AHost: string; const APort: Word;
      const AUserName, APassword: string); overload;
    constructor Create(const AKind: TProxyKind; const AHost: string;
      const APort: Word); overload;
    constructor Create(const AKind: TProxyKind; const AHost: string;
      const APort: Word; const AUserName, APassword: string); overload;
    function GetHost: string;
    function GetPort: Word;
    function GetKind: TProxyKind;
    function GetUserName: string;
    function GetPassword: string;
  end;

  /// the proxy variables of the process environment, captured once
  TProxyEnvironment = record
    HttpProxy: string;
    HttpsProxy: string;
    AllProxy: string;
    NoProxy: string;
  end;

  /// reads one environment variable by exact name ('' when unset)
  TEnvLookup = function(const AName: string): string;

implementation

constructor TProxy.Create(const AHost: string; const APort: Word);
begin
  Create(pkHttp, AHost, APort, '', '');
end;

constructor TProxy.Create(const AHost: string; const APort: Word;
  const AUserName, APassword: string);
begin
  Create(pkHttp, AHost, APort, AUserName, APassword);
end;

constructor TProxy.Create(const AKind: TProxyKind; const AHost: string;
  const APort: Word);
begin
  Create(AKind, AHost, APort, '', '');
end;

constructor TProxy.Create(const AKind: TProxyKind; const AHost: string;
  const APort: Word; const AUserName, APassword: string);
begin
  inherited Create;
  FKind := AKind;
  FHost := AHost;
  FPort := APort;
  FUserName := AUserName;
  FPassword := APassword;
end;

function TProxy.GetHost: string;
begin
  Result := FHost;
end;

function TProxy.GetPort: Word;
begin
  Result := FPort;
end;

function TProxy.GetKind: TProxyKind;
begin
  Result := FKind;
end;

function TProxy.GetUserName: string;
begin
  Result := FUserName;
end;

function TProxy.GetPassword: string;
begin
  Result := FPassword;
end;

{ ---- literals ---- }

end.
