{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.SocketFactory;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils, Http2.Client.Errors,
  Http2.Client.Tls,
  Http2.Client.Proxy,
  Http2.Client.ClientCert,
  Http2.Client.RequestObserver,
  Http2.Client.SocketFactory.Types,
  Http2.Client.Defaults;


type
  TDefaultSocketFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory, IProxySocketFactory, IHttp1SocketFactory,
    IIdentitySocketFactory)
  private
    FCACertFile: string;
    FInsecure: Boolean;
    FProxyHost: string;
    FProxyPort: Word;
    FIdentity: IClientIdentity;
    FProxyIdentity: IClientIdentity;
    FLogger: IHttpLogger;
    FProtocols: TProtocolSocketFactory;
    /// debug line naming the identity a TLS dial to AHost:APort installs
    procedure LogIdentity(const AHost: string; const APort: Word;
      const AIdentity: IClientIdentity);
  public
    /// AIdentity is presented on every TLS connection to an origin and
    /// AProxyIdentity on the TLS leg to an https proxy, never the other way
    /// round; ALogger (may be nil) receives the debug line that names the
    /// origin identity
    constructor Create(const ACACertFile: string = '';
      const AInsecure: Boolean = False; const AProxyHost: string = '';
      const AProxyPort: Word = 0; const AIdentity: IClientIdentity = nil;
      const ALogger: IHttpLogger = nil;
      const AProxyIdentity: IClientIdentity = nil);
    /// a copy of this factory that presents the identities and logs to ALogger
    function WithIdentity(const AIdentity: IClientIdentity;
      const ALogger: IHttpLogger;
      const AProxyIdentity: IClientIdentity = nil): TDefaultSocketFactory;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    /// the per-request-proxy entry point (doc/design/proxy.md); AProxy nil
    /// dials directly.  DialProtocol is this with the constructor's fixed proxy
    function DialProtocolVia(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      const AProxy: IProxy;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    /// an HTTP/1.1-only connection, for WebSocket
    function DialHttp1(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy): IHttp2Socket;
    /// DialProtocolVia and DialHttp1 with the origin identity chosen by the
    /// caller (the selector's answer) instead of the fixed one
    function DialProtocolViaAs(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      const AProxy: IProxy; const AIdentity: IClientIdentity;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function DialHttp1As(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy; const AIdentity: IClientIdentity): IHttp2Socket;
  end;

  TIdentityHttp1Dialer = class(TInterfacedObject, IHttp1SocketFactory)
  private
    FFactory: IIdentitySocketFactory;
    FIdentity: IClientIdentity;
  public
    constructor Create(const AFactory: IIdentitySocketFactory;
      const AIdentity: IClientIdentity);
    function DialHttp1(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy): IHttp2Socket;
  end;

implementation

constructor TIdentityHttp1Dialer.Create(const AFactory: IIdentitySocketFactory;
  const AIdentity: IClientIdentity);
begin
  inherited Create;
  FFactory := AFactory;
  FIdentity := AIdentity;
end;

function TIdentityHttp1Dialer.DialHttp1(const AHost: string; const APort: Word;
  const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy): IHttp2Socket;
begin
  Result := FFactory.DialHttp1As(AHost, APort, AScheme, ATimeoutMs, AProxy,
    FIdentity);
end;

{ IHttp2SocketFactory }

constructor TDefaultSocketFactory.Create(const ACACertFile: string;
  const AInsecure: Boolean; const AProxyHost: string; const AProxyPort: Word;
  const AIdentity: IClientIdentity; const ALogger: IHttpLogger;
  const AProxyIdentity: IClientIdentity);
begin
  inherited Create;
  FCACertFile := ACACertFile;
  FInsecure := AInsecure;
  FProxyHost := AProxyHost;
  FProxyPort := AProxyPort;
  FIdentity := AIdentity;
  FProxyIdentity := AProxyIdentity;
  FLogger := ALogger;
  FProtocols := TProtocolSocketFactory.Create(ACACertFile, AInsecure, AProxyHost,
    AProxyPort, AIdentity, AProxyIdentity);
end;

function TDefaultSocketFactory.WithIdentity(const AIdentity: IClientIdentity;
  const ALogger: IHttpLogger;
  const AProxyIdentity: IClientIdentity): TDefaultSocketFactory;
begin
  Result := TDefaultSocketFactory.Create(FCACertFile, FInsecure, FProxyHost,
    FProxyPort, AIdentity, ALogger, AProxyIdentity);
end;

procedure TDefaultSocketFactory.LogIdentity(const AHost: string;
  const APort: Word; const AIdentity: IClientIdentity);
begin
  if (AIdentity = nil) or (FLogger = nil) then
    Exit;
  // only the subject and the fingerprint: never the PEM, a path or a passphrase
  try
    FLogger.Log(llDebug, Format(
      'TLS to %s:%d presents client identity subject="%s" fingerprint=%s',
      [AHost, APort, AIdentity.Subject, AIdentity.Fingerprint]));
  except
    // a logger that raises must not break a dial
  end;
end;

function TDefaultSocketFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  LogIdentity(AHost, APort, FIdentity);
  Result := TTlsSocket.Dial(AHost, APort, FInsecure, ATimeoutMs, FCACertFile,
    FProxyHost, FProxyPort, FIdentity);
end;

function TDefaultSocketFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  Result := DialProtocolVia(AHost, APort, AScheme, AHttp1Fallback, APolicy,
    ATimeoutMs, nil, AProtocol);
end;

function TDefaultSocketFactory.DialHttp1(const AHost: string;
  const APort: Word; const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy): IHttp2Socket;
begin
  Result := DialHttp1As(AHost, APort, AScheme, ATimeoutMs, AProxy, FIdentity);
end;

function TDefaultSocketFactory.DialHttp1As(const AHost: string;
  const APort: Word; const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy; const AIdentity: IClientIdentity): IHttp2Socket;
begin
  if AScheme <> 'http' then
    LogIdentity(AHost, APort, AIdentity);
  Result := FProtocols.DialHttp1As(AHost, APort, AScheme, ATimeoutMs, AProxy,
    AIdentity);
end;

function TDefaultSocketFactory.DialProtocolVia(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  const AProxy: IProxy;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  Result := DialProtocolViaAs(AHost, APort, AScheme, AHttp1Fallback, APolicy,
    ATimeoutMs, AProxy, FIdentity, AProtocol);
end;

function TDefaultSocketFactory.DialProtocolViaAs(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  const AProxy: IProxy; const AIdentity: IClientIdentity;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  Sock: IHttp2Socket;
  TlsObj: TObject;
  Name: string;
  Proxy: IProxy;
begin
  // a factory built with a fixed proxy (the constructor parameters) keeps
  // tunnelling through it when the caller routes nothing per request, so an
  // injected TDefaultSocketFactory.Create(..., host, port) never falls back
  // to a direct connection
  Proxy := AProxy;
  if (Proxy = nil) and (FProxyHost <> '') then
    Proxy := TProxy.Create(FProxyHost, FProxyPort);

  // cleartext never involves ALPN, so the shared selector is correct there
  if AScheme = 'http' then
    Exit(FProtocols.DialProtocolVia(AHost, APort, AScheme, AHttp1Fallback,
      APolicy, ATimeoutMs, Proxy, AProtocol));

  // https: offer the ALPN list the fallback policy asks for, then map the
  // selected name to a codec.  DialWithAlpn reports the name instead of
  // enforcing "h2", so the mapping happens here
  // (doc/design/fallback.md "Negotiation").
  LogIdentity(AHost, APort, AIdentity);
  Sock := TTlsSocket.DialWithAlpnVia(AHost, APort, AlpnOfferFor(AHttp1Fallback),
    FInsecure, ATimeoutMs, FCACertFile, Proxy, AIdentity, FProxyIdentity);
  // downcast with Supports, NOT a hard class cast: a hard cast reinterprets
  // the interface pointer (which is not the object base) and reads garbage
  Name := '';
  if Supports(Sock, TTlsSocket, TlsObj) then
    Name := TTlsSocket(TlsObj).SelectedProtocol;
  if Name = cHttp11AlpnProtocol then
    AProtocol := npHttp1Tls
  else if Name = cHttp2AlpnProtocol then
    AProtocol := npHttp2Tls
  else if AHttp1Fallback then
    // RFC 7301: no ALPN result means the peer speaks HTTP/1.1
    AProtocol := npHttp1Tls
  else
  begin
    Sock.Close;
    raise EHttpProtocolError.CreateFmt(
      'peer did not negotiate ALPN "%s" (selected "%s")',
      [cHttp2AlpnProtocol, Name]);
  end;
  Result := Sock;
end;

{ THttpRequest }

end.
