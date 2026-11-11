{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, tls
notes:
  - This unit is part of the imported client transport.
---
}
unit Http2.Client.Tls;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, Http2.Client.Errors, Http2.Client.Tls.Types, Http2.Client.Tls.Plain, Http2.Client.Tls.Socket, Http2.Client.Tls.Tunnel;

const
  cHttp2AlpnProtocol = Http2.Client.Tls.Types.cHttp2AlpnProtocol;
  cHttp11AlpnProtocol = Http2.Client.Tls.Types.cHttp11AlpnProtocol;
  cHttp2AlpnOffer: array[0..0] of string = ('h2');
  cHttp2Http1AlpnOffer: array[0..1] of string = ('h2', 'http/1.1');
  cDefaultSocketTimeoutMs = Http2.Client.Tls.Types.cDefaultSocketTimeoutMs;
  ctReject = Http2.Client.Tls.Types.ctReject;
  ctPriorKnowledge = Http2.Client.Tls.Types.ctPriorKnowledge;
  ctUpgrade = Http2.Client.Tls.Types.ctUpgrade;
  ctHttp1 = Http2.Client.Tls.Types.ctHttp1;
  npHttp2Tls = Http2.Client.Tls.Types.npHttp2Tls;
  npHttp2Cleartext = Http2.Client.Tls.Types.npHttp2Cleartext;
  npHttp1Tls = Http2.Client.Tls.Types.npHttp1Tls;
  npHttp1Cleartext = Http2.Client.Tls.Types.npHttp1Cleartext;

type
  TClearTextPolicy = Http2.Client.Tls.Types.TClearTextPolicy;
  TNegotiatedProtocol = Http2.Client.Tls.Types.TNegotiatedProtocol;
  IHttp2Socket = Http2.Client.Tls.Types.IHttp2Socket;
  ICleartextSocketFactory = Http2.Client.Tls.Types.ICleartextSocketFactory;
  IPartialReader = Http2.Client.Tls.Types.IPartialReader;
  IProxySocketFactory = Http2.Client.Tls.Types.IProxySocketFactory;
  IHttp1SocketFactory = Http2.Client.Tls.Types.IHttp1SocketFactory;
  IIdentitySocketFactory = Http2.Client.Tls.Types.IIdentitySocketFactory;
  TPlainSocket = Http2.Client.Tls.Plain.TPlainSocket;
  TTlsSocket = Http2.Client.Tls.Socket.TTlsSocket;
  TProtocolSocketFactory = Http2.Client.Tls.Tunnel.TProtocolSocketFactory;

function AlpnProtocolList(const AProtocols: array of string): TBytes;
function AlpnSelectedName(const AData: PByte; const ALen: Cardinal): string;
procedure RequireH2Alpn(const AData: PByte; const ALen: Cardinal);
function AlpnOfferFor(const AHttp1Fallback: Boolean): TBytes;
function ClientAuthAlertName(const AReason: Cardinal): string;
function SecureRandomCardinal: Cardinal;
function AlpnNegotiatedName(const AName: string): string;
function SslVerifyModeFor(const AInsecure: Boolean): Integer;
function SocketReadFully(AFd, ACount, ATimeoutMs: Integer; var ABuffer): Integer;
function SocketWriteFully(AFd, ACount, ATimeoutMs: Integer; const ABuffer): Integer;

implementation

function AlpnProtocolList(const AProtocols: array of string): TBytes;
begin Result := Http2.Client.Tls.Types.AlpnProtocolList(AProtocols); end;
function AlpnSelectedName(const AData: PByte; const ALen: Cardinal): string;
begin Result := Http2.Client.Tls.Types.AlpnSelectedName(AData, ALen); end;
procedure RequireH2Alpn(const AData: PByte; const ALen: Cardinal);
begin Http2.Client.Tls.Types.RequireH2Alpn(AData, ALen); end;
function AlpnOfferFor(const AHttp1Fallback: Boolean): TBytes;
begin Result := Http2.Client.Tls.Types.AlpnOfferFor(AHttp1Fallback); end;
function ClientAuthAlertName(const AReason: Cardinal): string;
begin Result := Http2.Client.Tls.Types.ClientAuthAlertName(AReason); end;
function SecureRandomCardinal: Cardinal;
begin Result := Http2.Client.Tls.Types.SecureRandomCardinal; end;
function AlpnNegotiatedName(const AName: string): string;
begin Result := Http2.Client.Tls.Types.AlpnNegotiatedName(AName); end;
function SslVerifyModeFor(const AInsecure: Boolean): Integer;
begin Result := Http2.Client.Tls.Types.SslVerifyModeFor(AInsecure); end;
function SocketReadFully(AFd, ACount, ATimeoutMs: Integer; var ABuffer): Integer;
begin Result := Http2.Client.Tls.Types.SocketReadFully(AFd, ACount, ATimeoutMs, ABuffer); end;
function SocketWriteFully(AFd, ACount, ATimeoutMs: Integer; const ABuffer): Integer;
begin Result := Http2.Client.Tls.Types.SocketWriteFully(AFd, ACount, ATimeoutMs, ABuffer); end;

end.
