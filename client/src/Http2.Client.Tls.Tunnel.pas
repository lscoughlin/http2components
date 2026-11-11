{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, tls
notes:
  - This unit is part of the imported client transport.
---
}
unit Http2.Client.Tls.Tunnel;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Sockets, BaseUnix, Http2.Client.Errors, Http2.Client.Proxy,
  Http2.Client.Proxy.Types, Http2.Client.IdentityHandle,
  Http2.Client.ClientCert, Http2.Client.Socks, Http2.Client.Tls.Types,
  Http2.Common.Tls.Context;

type
  /// the production transport selector (plan S13): picks TLS or cleartext and
  /// reports the wire protocol it committed to.  Https offers "h2", or
  /// "h2"+"http/1.1" when fallback is on; an empty ALPN result with fallback
  /// on means HTTP/1.1 (RFC 7301).  A cleartext origin honours the policy
  /// (doc/design/fallback.md "Negotiation").
  TProtocolSocketFactory = class(TInterfacedObject, ICleartextSocketFactory,
    IProxySocketFactory, IHttp1SocketFactory, IIdentitySocketFactory)
  private
    FCACertFile: string;
    FInsecure: Boolean;
    FProxyHost: string;
    FProxyPort: Word;
    FIdentity: IClientIdentity;
    FProxyIdentity: IClientIdentity;
    FTlsContext: ITLSContext;
    FProxyTlsContext: ITLSContext;
  public
    /// AIdentity is presented on every TLS connection to an origin; cleartext
    /// dials ignore it (doc/design/mtls.md).  AProxyIdentity is presented to
    /// an https proxy and to nothing else.
    constructor Create(const ACACertFile: string = '';
      const AInsecure: Boolean = False; const AProxyHost: string = '';
      const AProxyPort: Word = 0; const AIdentity: IClientIdentity = nil;
      const AProxyIdentity: IClientIdentity = nil;
      const ATlsContext: ITLSContext = nil;
      const AProxyTlsContext: ITLSContext = nil);
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function DialProtocolVia(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      const AProxy: IProxy;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function DialHttp1(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy): IHttp2Socket;
    function DialProtocolViaAs(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      const AProxy: IProxy; const AIdentity: IClientIdentity;
      const AIdentityExplicit: Boolean; out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function DialHttp1As(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy; const AIdentity: IClientIdentity;
      const AIdentityExplicit: Boolean): IHttp2Socket;
  end;

procedure EstablishProxyTunnelFd(AFd: Integer; const AHost: string;
  const APort: Word; const ATimeoutMs: Integer;
  const AUserName, APassword: string);
function DialRoutedTransport(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer; const AProxy: IProxy;
  const AInsecure: Boolean; const ACACertFile: string;
  const AProxyIdentity: IClientIdentity; out AStream: Boolean;
  const AProxyContext: ITLSContext): IHttp2Socket;

implementation

uses
  Http2.Client.Tls.Plain, Http2.Client.Tls.Socket,
  Http2.Client.SigPipe, mormot.core.base, mormot.core.os,
  Http2.Common.Tls.Types;

type
  /// the proxy exchange over a raw descriptor
  TFdChannel = class(TInterfacedObject, ISocksChannel)
  private
    FFd: Integer;
    FTimeoutMs: Integer;
  public
    constructor Create(const AFd, ATimeoutMs: Integer);
    procedure WriteAll(const AData: TBytes);
    function ReadSome(var ABuffer; const ACount: Integer): Integer;
  end;

  /// the proxy exchange over an IHttp2Socket (for example a TLS socket to an
  /// https proxy)
  TSocketChannel = class(TInterfacedObject, ISocksChannel)
  private
    FSock: IHttp2Socket;
  public
    constructor Create(const ASock: IHttp2Socket);
    procedure WriteAll(const AData: TBytes);
    function ReadSome(var ABuffer; const ACount: Integer): Integer;
  end;

constructor TFdChannel.Create(const AFd, ATimeoutMs: Integer);
begin
  inherited Create;
  FFd := AFd;
  FTimeoutMs := ATimeoutMs;
end;

procedure TFdChannel.WriteAll(const AData: TBytes);
begin
  if Length(AData) > 0 then
    SocketWriteFully(FFd, Length(AData), FTimeoutMs, AData[0]);
end;

function TFdChannel.ReadSome(var ABuffer; const ACount: Integer): Integer;
begin
  // reads exactly ACount (or to EOF): callers ask for exactly what the
  // protocol still needs, so nothing past the proxy reply is consumed
  Result := SocketReadFully(FFd, ACount, FTimeoutMs, ABuffer);
end;

constructor TSocketChannel.Create(const ASock: IHttp2Socket);
begin
  inherited Create;
  FSock := ASock;
end;

procedure TSocketChannel.WriteAll(const AData: TBytes);
begin
  if Length(AData) > 0 then
    FSock.Write(AData[0], Length(AData));
end;

function TSocketChannel.ReadSome(var ABuffer; const ACount: Integer): Integer;
begin
  Result := FSock.Read(ABuffer, ACount);
end;

/// read one CRLF/LF-terminated line from the tunnel handshake; False only at
// EOF.  Byte-at-a-time so it never consumes bytes past the CONNECT response
// (any payload beyond the blank line belongs to the tunnel)
function ProxyReadLineCh(const ACh: ISocksChannel;
  out ALine: AnsiString): Boolean;
var
  C: AnsiChar;
begin
  ALine := '';
  repeat
    if ACh.ReadSome(C, 1) <= 0 then
      Exit(False);
    if C = #10 then
      Exit(True);
    if C <> #13 then
      ALine := ALine + C;
  until Length(ALine) > 16384;
  Result := True;
end;

/// parse the 3-digit status code from an HTTP status line (the token after
// the version, e.g. "HTTP/1.1 200 OK")
function ProxyStatusCode(const ALine: AnsiString): Integer;
var
  I: Integer;
  Digits: AnsiString;
begin
  Result := 0;
  Digits := '';
  I := 1;
  // skip the HTTP-version token
  while (I <= Length(ALine)) and (ALine[I] <> ' ') do
    Inc(I);
  while (I <= Length(ALine)) and (ALine[I] = ' ') do
    Inc(I);
  // collect the status-code digits
  while (I <= Length(ALine)) and (ALine[I] >= '0') and (ALine[I] <= '9') do
  begin
    Digits := Digits + ALine[I];
    Inc(I);
  end;
  if Length(Digits) = 3 then
    Result := StrToIntDef(string(Digits), 0);
end;

function ConnectAuthority(const AHost: string; const APort: Word): AnsiString;
begin
  // an IPv6 literal is bracketed in a request target (RFC 3986)
  if (Pos(':', AHost) > 0) and (Copy(AHost, 1, 1) <> '[') then
    Result := '[' + AnsiString(AHost) + ']'
  else
    Result := AnsiString(AHost);
  Result := Result + ':' + AnsiString(IntToStr(APort));
end;

/// negotiate an HTTP CONNECT tunnel to AHost:APort over ACh.  Sends
/// Proxy-Authorization: Basic when AUserName is not empty.  Raises
/// EHttpConnectionError unless the proxy answers a 2xx status; a non-2xx or a
/// truncated response is a connection failure, not a fallback.  Credentials
/// never appear in a message.
procedure EstablishConnectTunnel(const ACh: ISocksChannel; const AHost: string;
  const APort: Word; const AUserName, APassword: string);
var
  Req, Line, Auth: AnsiString;
  Code: Integer;
  Bytes: TBytes;
begin
  Auth := ConnectAuthority(AHost, APort);
  Req := 'CONNECT ' + Auth + ' HTTP/1.1'#13#10'Host: ' + Auth + #13#10;
  if AUserName <> '' then
    Req := Req + 'Proxy-Authorization: Basic ' +
      AnsiString(ProxyBasicCredentials(AUserName, APassword)) + #13#10;
  Req := Req + #13#10;
  SetLength(Bytes, Length(Req));
  Move(Req[1], Bytes[0], Length(Req));
  ACh.WriteAll(Bytes);
  // skip any informational (1xx) response and any blank separators, then
  // require a 2xx; a blank line must not be treated as a status
  Code := 100;
  repeat
    if not ProxyReadLineCh(ACh, Line) then
      raise EHttpConnectionError.Create(
        'proxy closed the connection during CONNECT');
    if Line = '' then
      Continue;
    Code := ProxyStatusCode(Line);
  until (Code < 100) or (Code >= 200);
  if (Code < 200) or (Code >= 300) then
    raise EHttpConnectionError.CreateFmt('proxy CONNECT failed: %s',
      [string(Line)]);
  // drain the response headers up to the blank line
  repeat
    if not ProxyReadLineCh(ACh, Line) then
      Break;
  until Line = '';
end;

procedure EstablishProxyTunnelFd(AFd: Integer; const AHost: string;
  const APort: Word; const ATimeoutMs: Integer;
  const AUserName: string; const APassword: string);
begin
  EstablishConnectTunnel(TFdChannel.Create(AFd, ATimeoutMs), AHost, APort,
    AUserName, APassword);
end;

/// run the tunnel exchange the proxy kind calls for over ACh
procedure EstablishTunnelOver(const ACh: ISocksChannel; const AProxy: IProxy;
  const AHost: string; const APort: Word);
begin
  if AProxy.Kind = pkSocks5 then
    EstablishSocksTunnel(ACh, AProxy, AHost, APort)
  else
    EstablishConnectTunnel(ACh, AHost, APort, AProxy.UserName,
      AProxy.Password);
end;

{ TPlainSocket }

function DialRoutedTransport(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer; const AProxy: IProxy;
  const AInsecure: Boolean; const ACACertFile: string;
  const AProxyIdentity: IClientIdentity; out AStream: Boolean;
  const AProxyContext: ITLSContext): IHttp2Socket;
var
  Plain: TPlainSocket;
  Who: string;
begin
  RejectLegacyTlsPolicy(AInsecure, ACACertFile);
  AStream := False;
  if AProxy = nil then
  begin
    Result := TPlainSocket.Create(AHost, APort, AConnectTimeoutMs);
    Exit;
  end;
  ValidateProxy(AProxy);
  if (AProxy.Kind = pkHttps) and (AProxyContext = nil) then
    raise EHttpTlsConfigError.Create('an explicit HTTPS proxy TLS context is required');
  if AProxy.Kind = pkHttps then
    RequireClientTlsContext(AProxyContext, 'HTTPS proxy');
  Who := Format('%s:%d', [AProxy.Host, AProxy.Port]);
  // plain TCP to the proxy first: no tunnel is requested by the constructor
  Plain := TPlainSocket.Create(AProxy.Host, AProxy.Port, AConnectTimeoutMs);
  Result := Plain;
  Plain.SetReadTimeoutMs(AConnectTimeoutMs);
  Plain.SetWriteTimeoutMs(AConnectTimeoutMs);
  try
    if AProxy.Kind = pkHttps then
    begin
      // TLS to the proxy, verified against the proxy's host name; no ALPN, the
      // CONNECT exchange is HTTP/1.1.  It presents the proxy identity only:
      // the origin identity never reaches this leg (doc/design/mtls.md)
      try
        if AProxyContext = nil then
          raise EHttpTlsConfigError.Create('an explicit HTTPS proxy TLS context is required');
        Result := DialProxyTlsSocket(Plain, AProxy.Host, AProxyContext,
          AProxyIdentity, AConnectTimeoutMs);
      except
        on E: EHttpConnectionError do
          raise EHttpConnectionError.CreateFmt(
            'TLS to proxy %s failed: %s', [Who, E.Message]);
      end;
      AStream := True;
      EstablishTunnelOver(TSocketChannel.Create(Result), AProxy, AHost, APort);
    end
    else
      EstablishTunnelOver(TFdChannel.Create(Plain.Handle, AConnectTimeoutMs),
        AProxy, AHost, APort);
  except
    Result.Close;
    raise;
  end;
end;

{ TTlsSocket }

{ TProtocolSocketFactory }

constructor TProtocolSocketFactory.Create(const ACACertFile: string;
  const AInsecure: Boolean; const AProxyHost: string;
  const AProxyPort: Word; const AIdentity, AProxyIdentity: IClientIdentity;
  const ATlsContext, AProxyTlsContext: ITLSContext);
begin
  inherited Create;
  FIdentity := AIdentity;
  FProxyIdentity := AProxyIdentity;
  FTlsContext := ATlsContext;
  FProxyTlsContext := AProxyTlsContext;
  FCACertFile := ACACertFile;
  FInsecure := AInsecure;
  FProxyHost := AProxyHost;
  FProxyPort := AProxyPort;
end;

function TProtocolSocketFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  Proxy: IProxy;
begin
  // the proxy given to the constructor is a fixed HTTP proxy for every dial
  Proxy := nil;
  if FProxyHost <> '' then
    Proxy := TProxy.Create(FProxyHost, FProxyPort);
  Result := DialProtocolVia(AHost, APort, AScheme, AHttp1Fallback, APolicy,
    ATimeoutMs, Proxy, AProtocol);
end;

function TProtocolSocketFactory.DialProtocolVia(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  const AProxy: IProxy;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  Result := DialProtocolViaAs(AHost, APort, AScheme, AHttp1Fallback, APolicy,
    ATimeoutMs, AProxy, FIdentity, False, AProtocol);
end;

function TProtocolSocketFactory.DialProtocolViaAs(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  const AProxy: IProxy; const AIdentity: IClientIdentity;
  const AIdentityExplicit: Boolean; out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  Sock: IHttp2Socket;
  Name: string;
  TlsInfo: IHttp2TlsSocketInfo;
  Proxy: IProxy;
begin
  Proxy := AProxy;
  if (Proxy = nil) and (FProxyHost <> '') then Proxy := TProxy.Create(FProxyHost, FProxyPort);
  if (AScheme <> 'http') and (FTlsContext = nil) then
    raise EHttpTlsConfigError.Create('an explicit origin TLS context is required');
  if (Proxy <> nil) and (Proxy.Kind = pkHttps) and (FProxyTlsContext = nil) then
    raise EHttpTlsConfigError.Create('an explicit HTTPS proxy TLS context is required');
  AProtocol := npHttp2Tls;
  if AScheme = 'http' then
  begin
    // cleartext: the policy decides (doc/design/fallback.md "http origins")
    case APolicy of
      ctReject:
        raise EHttpProtocolError.Create(
          'cleartext origin rejected (set WithClearText to enable it)',
          ecProtocolError);
      ctUpgrade, ctHttp1:
        // the cleartext socket speaks HTTP/1.1; under ctUpgrade the pool
        // layers the Upgrade probe on it, under ctHttp1 it sends no probe
        begin
          AProtocol := npHttp1Cleartext;
          Result := TTlsSocket.DialCleartextVia(AHost, APort, ATimeoutMs, Proxy,
            FInsecure, FCACertFile, FProxyIdentity, FProxyTlsContext);
        end;
    else
      // ctPriorKnowledge: speak HTTP/2 at once, the caller writes the preface
      begin
        AProtocol := npHttp2Cleartext;
        Result := TTlsSocket.DialCleartextVia(AHost, APort, ATimeoutMs, Proxy,
          FInsecure, FCACertFile, FProxyIdentity, FProxyTlsContext);
      end;
    end;
    Exit;
  end;

  // https: the ALPN offer follows the fallback flag, then the result maps to a
  // codec.  DialWithAlpn skips the strict check so we can map the name here.
  Sock := TTlsSocket.DialWithAlpnVia(AHost, APort, AlpnOfferFor(AHttp1Fallback),
    FInsecure, ATimeoutMs, FCACertFile, Proxy, AIdentity, FProxyIdentity,
    FTlsContext, FProxyTlsContext, AIdentityExplicit);
  Name := '';
  if Supports(Sock, IHttp2TlsSocketInfo, TlsInfo) then
    Name := TlsInfo.SelectedProtocol;
  try
    AProtocol := ProtocolForTlsAlpn(Name, AHttp1Fallback);
  except
    Sock.Close;
    raise;
  end;
  Result := Sock;
end;

function TProtocolSocketFactory.DialHttp1(const AHost: string;
  const APort: Word; const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy): IHttp2Socket;
begin
  Result := DialHttp1As(AHost, APort, AScheme, ATimeoutMs, AProxy, FIdentity, False);
end;

function TProtocolSocketFactory.DialHttp1As(const AHost: string;
  const APort: Word; const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy; const AIdentity: IClientIdentity;
      const AIdentityExplicit: Boolean): IHttp2Socket;
var
  Proxy: IProxy;
  TlsInfo: IHttp2TlsSocketInfo;
  Name: string;
begin
  Proxy := AProxy;
  if (Proxy = nil) and (FProxyHost <> '') then
    Proxy := TProxy.Create(FProxyHost, FProxyPort);
  if (AScheme <> 'http') and (FTlsContext = nil) then
    raise EHttpTlsConfigError.Create('an explicit origin TLS context is required');
  if (Proxy <> nil) and (Proxy.Kind = pkHttps) and (FProxyTlsContext = nil) then
    raise EHttpTlsConfigError.Create('an explicit HTTPS proxy TLS context is required');
  if AScheme = 'http' then
    Exit(TTlsSocket.DialCleartextVia(AHost, APort, ATimeoutMs, Proxy,
      FInsecure, FCACertFile, FProxyIdentity, FProxyTlsContext));
  Result := TTlsSocket.DialWithAlpnVia(AHost, APort,
    AlpnProtocolList([cHttp11AlpnProtocol]), FInsecure, ATimeoutMs,
    FCACertFile, Proxy, AIdentity, FProxyIdentity, FTlsContext, FProxyTlsContext, AIdentityExplicit);
  Name := '';
  if Supports(Result, IHttp2TlsSocketInfo, TlsInfo) then
    Name := TlsInfo.SelectedProtocol;
  // a server without ALPN support answers nothing and speaks HTTP/1.1; one
  // that picked h2 anyway cannot carry an Upgrade
  if (Name <> '') and (Name <> cHttp11AlpnProtocol) then
  begin
    Result.Close;
    raise EHttpProtocolError.Create(Format(
      'peer selected ALPN "%s" for a connection that needs HTTP/1.1', [Name]),
      ecProtocolError);
  end;
end;

end.
