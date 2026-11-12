{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Factory;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  Http2.Client.Errors,
  Http2.Client.Tls,
  Http2.Client.Proxy,
  Http2.Client.ClientCert,
  Http2.Common.Tls.Context,
  Http2.Client.Observer,
  Http2.Client.RequestObserver,
  Http2.Client.Api,
  Http2.Client.Defaults,
  Http2.Client.SocketFactory.Types;


type
  THttpClientFactory = record
  private
    FMaxConnectionsPerHost: Integer;
    FMaxTotalConnections: Integer;
    FMaxStreamsPerConnection: Integer;
    FFollowRedirects: Boolean;
    FMaxRedirects: Integer;
    FConnectTimeoutMs: Integer;
    FHeaderTimeoutMs: Integer;
    FIdleTimeoutMs: Integer;
    FProxyHost: string;
    FProxyPort: Word;
    FSocketFactory: IHttp2SocketFactory;
    FCACertFile: string;
    FInsecure: Boolean;
    FObserver: IHttp2Observer;
    FHttp1Fallback: Boolean;
    FClearTextPolicy: TClearTextPolicy;
    FProxySelector: IProxySelector;
    FAllProxy: string;
    FProxyEnvVars: Boolean;
    FNoProxy: string;
    FEnvLookup: TEnvLookup;
    FRequestObservers: TArray<IHttpClientObserver>;
    FLogger: IHttpLogger;
    FIdentity: IClientIdentity;
    FIdentitySelector: IClientIdentitySelector;
    FProxyIdentity: IClientIdentity;
    FTlsContext: ITLSContext;
    FProxyTlsContext: ITLSContext;
    FUnixPath: string;
    FUnixPathError: string;
  public
    class function Create: THttpClientFactory; static;
    /// compatibility shim: sets BOTH the per-host and the total cap to AMax,
    /// so a single-authority pool keeps its historic meaning. Prefer the two
    /// explicit setters below.
    function WithMaxConnections(const AMax: Integer): THttpClientFactory;
    /// cap concurrent TCP connections to one authority (`host:port`)
    function WithMaxConnectionsPerHost(const AMax: Integer): THttpClientFactory;
    /// cap concurrent TCP connections across every authority combined
    function WithMaxTotalConnections(const AMax: Integer): THttpClientFactory;
    function WithMaxStreamsPerConnection(const AMax: Integer): THttpClientFactory;
    function WithFollowRedirects(const AFollow: Boolean): THttpClientFactory;
    function WithMaxRedirects(const AMax: Integer): THttpClientFactory;
    function WithProxy(const AHost: string; const APort: Word): THttpClientFactory;
    /// the proxy for the request is chosen by ASelector (nil = direct); it
    /// overrides every other proxy setting (doc/design/proxy.md)
    function WithProxySelector(const ASelector: IProxySelector): THttpClientFactory;
    /// every connection goes to this socket file; the URL host still names
    /// the authority.  APath must be absolute, hold no NUL byte and be at most
    /// 103 bytes long; Build raises EHttpUnixSocketConfigError otherwise.
    /// '' clears the option.  A Unix socket cannot be used with a proxy.
    function WithUnixSocket(const APath: string): THttpClientFactory;
    /// one proxy URL ('[scheme://][user[:password]@]host[:port]', schemes
    /// http, https, socks5, socks5h) for every scheme without a more specific
    /// proxy; the manual form of all_proxy.  '' clears it.
    function WithAllProxy(const AUrl: string): THttpClientFactory;
    /// read http_proxy, https_proxy, all_proxy and no_proxy from the process
    /// environment when Build runs.  Off by default.
    function WithProxyEnvironmentVars(const AEnable: Boolean = True): THttpClientFactory;
    /// hosts that always connect directly: the no_proxy grammar (comma list;
    /// '*', domain suffixes, host:port, IP literals, CIDR).  Repeated calls
    /// append.
    function WithNoProxy(const AList: string): THttpClientFactory;
    /// test seam: read the proxy variables through ALookup instead of the
    /// process environment (nil restores the process environment)
    function WithProxyEnvironmentLookup(const ALookup: TEnvLookup): THttpClientFactory;
    /// the connect/header/idle deadlines are factory defaults
    function WithConnectTimeout(const AMs: Integer): THttpClientFactory;
    function WithHeaderTimeout(const AMs: Integer): THttpClientFactory;
    function WithIdleTimeout(const AMs: Integer): THttpClientFactory;
    /// test seam: inject the transport factory (no real sockets)
    function WithSocketFactory(const AFactory: IHttp2SocketFactory): THttpClientFactory;
    /// obsolete trust setting; a nonempty value raises EHttpTlsConfigError.
    /// Configure peer trust with WithTlsContext.
    function WithCACertFile(const AFileName: string): THttpClientFactory;
    /// obsolete insecure setting; True raises EHttpTlsConfigError. Configure
    /// verification with WithTlsContext.
    function WithInsecureTls(const AInsecure: Boolean = True): THttpClientFactory;
    /// use AContext for origin TLS sessions. Required for owned HTTPS routes.
    function WithTlsContext(const AContext: ITLSContext): THttpClientFactory;
    /// use AContext only for TLS to an HTTPS proxy.
    function WithProxyTlsContext(const AContext: ITLSContext): THttpClientFactory;
    /// present AIdentity (doc/design/mtls.md) on every TLS connection to an
    /// origin: HTTP/2, HTTP/1.1, SSE and wss, direct or through a tunnel.
    /// Cleartext connections ignore it.  Build raises EHttpTlsConfigError when
    /// the leaf certificate has expired.  nil removes it.
    function WithClientIdentity(const AIdentity: IClientIdentity): THttpClientFactory;
    /// ask ASelector for the identity of each new TLS connection to an origin
    /// (doc/design/mtls.md "Selector and proxy identity"), in place of a fixed
    /// identity.  It is called once per dial, on the dialling thread and
    /// outside the pool lock, with the origin's host and port; nil presents no
    /// certificate and an exception fails that dial with EHttpTlsConfigError.
    /// A selector that returns a fresh identity rotates the certificate: the
    /// next new connection presents it and older connections serve until they
    /// close.  The pool key then carries the identity fingerprint, so two
    /// identities never share a connection.  nil removes it.
    function WithClientIdentitySelector(
      const ASelector: IClientIdentitySelector): THttpClientFactory;
    /// present AIdentity to an https proxy on the TLS leg to the proxy, and
    /// nowhere else; the origin identity is never sent to the proxy.  nil
    /// removes it.  Build raises EHttpTlsConfigError when the leaf has expired.
    function WithProxyClientIdentity(const AIdentity: IClientIdentity): THttpClientFactory;
    /// offer "http/1.1" as an ALPN alternative and accept an HTTP/1.1
    /// response when the peer does not select "h2" (doc/design/fallback.md).
    /// Off by default: strict mode keeps failing loudly (interop A.9).
    function WithHttp1Fallback(const AEnable: Boolean = True): THttpClientFactory;
    /// select the cleartext policy for "http" origins.  The default ctReject
    /// raises EHttpProtocolError; ctPriorKnowledge speaks HTTP/2 at once;
    /// ctUpgrade tries the HTTP/1.1 Upgrade dance first (doc/design/fallback.md);
    /// ctHttp1 speaks cleartext HTTP/1.1 with no Upgrade probe.
    function WithClearText(const APolicy: TClearTextPolicy): THttpClientFactory;
    /// observability seam: every connection opened by Build reports its
    /// connection/stream/frame events to AObserver (doc/design/
    /// testing-observability.md). Nil disables observation.
    function WithObserver(const AObserver: IHttp2Observer): THttpClientFactory;
    /// request-level observability (doc/design/request-observability.md):
    /// AObserver is told when each attempt starts, gets response headers,
    /// redirects, retries and ends, and may inject headers into every attempt.
    /// Each call adds an observer; start callbacks run in registration order
    /// and end callbacks in reverse.  A nil observer is ignored.
    function WithRequestObserver(
      const AObserver: IHttpClientObserver): THttpClientFactory;
    /// receives library diagnostics, such as an observer that raised
    function WithLogger(const ALogger: IHttpLogger): THttpClientFactory;
    function Build: IHttpClient;

    /// compatibility alias for MaxConnectionsPerHost
    property MaxConnections: Integer read FMaxConnectionsPerHost;
    property MaxConnectionsPerHost: Integer read FMaxConnectionsPerHost;
    property MaxTotalConnections: Integer read FMaxTotalConnections;
    property MaxStreamsPerConnection: Integer read FMaxStreamsPerConnection;
    property FollowRedirects: Boolean read FFollowRedirects;
    property MaxRedirects: Integer read FMaxRedirects;
    property ConnectTimeoutMs: Integer read FConnectTimeoutMs;
    property HeaderTimeoutMs: Integer read FHeaderTimeoutMs;
    property IdleTimeoutMs: Integer read FIdleTimeoutMs;
    property ProxyHost: string read FProxyHost;
    property ProxyPort: Word read FProxyPort;
    property ProxySelector: IProxySelector read FProxySelector;
    property AllProxy: string read FAllProxy;
    property ProxyEnvironmentVars: Boolean read FProxyEnvVars;
    property NoProxy: string read FNoProxy;
    property CACertFile: string read FCACertFile;
    property InsecureTls: Boolean read FInsecure;
    property ClientIdentity: IClientIdentity read FIdentity;
    property ClientIdentitySelector: IClientIdentitySelector
      read FIdentitySelector;
    property ProxyClientIdentity: IClientIdentity read FProxyIdentity;
    property Observer: IHttp2Observer read FObserver;
    property RequestObservers: TArray<IHttpClientObserver>
      read FRequestObservers;
    property Logger: IHttpLogger read FLogger;
    property Http1Fallback: Boolean read FHttp1Fallback;
    property ClearTextPolicy: TClearTextPolicy read FClearTextPolicy;
    /// the socket file that every connection uses, '' when none is set
    property UnixPath: string read FUnixPath;
  end;

implementation

uses
  Http2.Client.SocketFactory, Http2.Client.Core, Http2.Client.Identity,
  Http2.Common.UnixPath;

class function THttpClientFactory.Create: THttpClientFactory;
begin
  Result.FMaxConnectionsPerHost := cDefaultMaxConnectionsPerHost;
  Result.FMaxTotalConnections := cDefaultMaxTotalConnections;
  Result.FMaxStreamsPerConnection := cDefaultMaxStreamsPerConnection;
  Result.FFollowRedirects := cDefaultFollowRedirects;
  Result.FMaxRedirects := cDefaultMaxRedirects;
  Result.FConnectTimeoutMs := cDefaultConnectTimeoutMs;
  Result.FHeaderTimeoutMs := cDefaultHeaderTimeoutMs;
  Result.FIdleTimeoutMs := cDefaultIdleTimeoutMs;
  Result.FProxyHost := '';
  Result.FProxyPort := 0;
  Result.FProxySelector := nil;
  Result.FAllProxy := '';
  Result.FProxyEnvVars := False;
  Result.FNoProxy := '';
  Result.FEnvLookup := nil;
  Result.FCACertFile := '';
  Result.FInsecure := False;
  Result.FIdentity := nil;
  Result.FIdentitySelector := nil;
  Result.FProxyIdentity := nil;
  Result.FTlsContext := nil;
  Result.FProxyTlsContext := nil;
  Result.FUnixPath := '';
  Result.FUnixPathError := '';
  Result.FObserver := nil;
  Result.FRequestObservers := nil;
  Result.FLogger := nil;
  Result.FHttp1Fallback := cDefaultHttp1Fallback;
  Result.FClearTextPolicy := ctReject;   // strict by default
  Result.FSocketFactory := TDefaultSocketFactory.Create;
end;

function THttpClientFactory.WithMaxConnections(
  const AMax: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FMaxConnectionsPerHost := AMax;
  Result.FMaxTotalConnections := AMax;
end;

function THttpClientFactory.WithMaxConnectionsPerHost(
  const AMax: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FMaxConnectionsPerHost := AMax;
end;

function THttpClientFactory.WithMaxTotalConnections(
  const AMax: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FMaxTotalConnections := AMax;
end;

function THttpClientFactory.WithMaxStreamsPerConnection(
  const AMax: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FMaxStreamsPerConnection := AMax;
end;

function THttpClientFactory.WithFollowRedirects(
  const AFollow: Boolean): THttpClientFactory;
begin
  Result := Self;
  Result.FFollowRedirects := AFollow;
end;

function THttpClientFactory.WithMaxRedirects(
  const AMax: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FMaxRedirects := AMax;
end;

function THttpClientFactory.WithProxy(const AHost: string;
  const APort: Word): THttpClientFactory;
begin
  Result := Self;
  Result.FProxyHost := AHost;
  Result.FProxyPort := APort;
  // the route is chosen per request at Build time (doc/design/proxy.md); the
  // socket factory no longer carries a proxy of its own
end;

function THttpClientFactory.WithProxySelector(
  const ASelector: IProxySelector): THttpClientFactory;
begin
  Result := Self;
  Result.FProxySelector := ASelector;
end;

function THttpClientFactory.WithUnixSocket(
  const APath: string): THttpClientFactory;
begin
  Result := Self;
  Result.FUnixPath := APath;
  // the rule lives in Http2.Common.UnixPath; an empty path has no problem
  Result.FUnixPathError := '';
  if APath <> '' then
    Result.FUnixPathError := UnixPathProblem(APath);
end;

function THttpClientFactory.WithAllProxy(const AUrl: string): THttpClientFactory;
begin
  Result := Self;
  Result.FAllProxy := Trim(AUrl);
end;

function THttpClientFactory.WithProxyEnvironmentVars(
  const AEnable: Boolean): THttpClientFactory;
begin
  Result := Self;
  Result.FProxyEnvVars := AEnable;
end;

function THttpClientFactory.WithNoProxy(const AList: string): THttpClientFactory;
begin
  Result := Self;
  if Trim(AList) = '' then
    Exit;
  if Result.FNoProxy = '' then
    Result.FNoProxy := Trim(AList)
  else
    Result.FNoProxy := Result.FNoProxy + ',' + Trim(AList);
end;

function THttpClientFactory.WithProxyEnvironmentLookup(
  const ALookup: TEnvLookup): THttpClientFactory;
begin
  Result := Self;
  Result.FEnvLookup := ALookup;
end;

function THttpClientFactory.WithSocketFactory(
  const AFactory: IHttp2SocketFactory): THttpClientFactory;
begin
  Result := Self;
  Result.FSocketFactory := AFactory;
end;

function THttpClientFactory.WithCACertFile(
  const AFileName: string): THttpClientFactory;
begin
  if AFileName <> '' then
    raise EHttpTlsConfigError.Create(
      'CA files are no longer accepted; configure peer trust in WithTlsContext');
  Result := Self;
end;

function THttpClientFactory.WithInsecureTls(
  const AInsecure: Boolean): THttpClientFactory;
begin
  if AInsecure then
    raise EHttpTlsConfigError.Create(
      'WithInsecureTls is no longer supported; configure verification in WithTlsContext');
  Result := Self;
end;

function THttpClientFactory.WithTlsContext(
  const AContext: ITLSContext): THttpClientFactory;
begin
  Result := Self;
  Result.FTlsContext := AContext;
end;

function THttpClientFactory.WithProxyTlsContext(
  const AContext: ITLSContext): THttpClientFactory;
begin
  Result := Self;
  Result.FProxyTlsContext := AContext;
end;

function THttpClientFactory.WithClientIdentity(
  const AIdentity: IClientIdentity): THttpClientFactory;
begin
  Result := Self;
  Result.FIdentity := AIdentity;
  Result.FIdentitySelector := nil;
end;

function THttpClientFactory.WithClientIdentitySelector(
  const ASelector: IClientIdentitySelector): THttpClientFactory;
begin
  Result := Self;
  Result.FIdentitySelector := ASelector;
  Result.FIdentity := nil;
end;

function THttpClientFactory.WithProxyClientIdentity(
  const AIdentity: IClientIdentity): THttpClientFactory;
begin
  Result := Self;
  Result.FProxyIdentity := AIdentity;
end;

function THttpClientFactory.WithConnectTimeout(
  const AMs: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FConnectTimeoutMs := AMs;
end;

function THttpClientFactory.WithHeaderTimeout(
  const AMs: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FHeaderTimeoutMs := AMs;
end;

function THttpClientFactory.WithIdleTimeout(
  const AMs: Integer): THttpClientFactory;
begin
  Result := Self;
  Result.FIdleTimeoutMs := AMs;
end;

function THttpClientFactory.WithObserver(
  const AObserver: IHttp2Observer): THttpClientFactory;
begin
  Result := Self;
  Result.FObserver := AObserver;
end;

function THttpClientFactory.WithRequestObserver(
  const AObserver: IHttpClientObserver): THttpClientFactory;
var
  N: Integer;
begin
  Result := Self;
  if AObserver = nil then
    Exit;
  // the array is shared by value copies of the record: copy before appending
  // so a forked factory never sees its sibling's observers
  N := Length(FRequestObservers);
  Result.FRequestObservers := Copy(FRequestObservers, 0, N);
  SetLength(Result.FRequestObservers, N + 1);
  Result.FRequestObservers[N] := AObserver;
end;

function THttpClientFactory.WithLogger(
  const ALogger: IHttpLogger): THttpClientFactory;
begin
  Result := Self;
  Result.FLogger := ALogger;
end;

function THttpClientFactory.WithHttp1Fallback(
  const AEnable: Boolean): THttpClientFactory;
begin
  Result := Self;
  Result.FHttp1Fallback := AEnable;
end;

function THttpClientFactory.WithClearText(
  const APolicy: TClearTextPolicy): THttpClientFactory;
begin
  Result := Self;
  Result.FClearTextPolicy := APolicy;
end;

function THttpClientFactory.Build: IHttpClient;
var
  Fixed: IProxy;
  Env: TProxyEnvironment;
  Selector: IProxySelector;
  Client: THttpClient;
  Factory: IHttp2SocketFactory;
begin
  if FUnixPathError <> '' then
    raise EHttpUnixSocketConfigError.Create(FUnixPathError);
  Factory := FSocketFactory;
  // an injected factory that cannot present identities would drop them
  // silently: refuse the combination
  if FIdentity <> nil then
    RequireIdentityFactory(Factory, 'a client identity is configured');
  if FIdentitySelector <> nil then
    RequireIdentityFactory(Factory, 'a client identity selector is configured');
  if FProxyIdentity <> nil then
    RequireIdentityFactory(Factory, 'a proxy client identity is configured');
  if FIdentity <> nil then
    if FIdentity.Leaf.NotAfterUtc < LocalTimeToUniversal(Now) then
      raise EHttpTlsConfigError.CreateFmt(
        'the client certificate expired on %s UTC',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', FIdentity.Leaf.NotAfterUtc)]);
  if FProxyIdentity <> nil then
    if FProxyIdentity.Leaf.NotAfterUtc < LocalTimeToUniversal(Now) then
      raise EHttpTlsConfigError.CreateFmt(
        'the proxy client certificate expired on %s UTC',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', FProxyIdentity.Leaf.NotAfterUtc)]);
  // an injected transport factory that presents identities is left alone; with a
  // selector installed the fixed identity is nil and each dial is handed the
  // selector's answer instead
  if ((FIdentity <> nil) or (FProxyIdentity <> nil) or
      (FIdentitySelector <> nil)) and (Factory is TDefaultSocketFactory) then
    Factory := TDefaultSocketFactory(Factory as TObject).WithIdentity(
      FIdentity, FLogger, FProxyIdentity);
  if (Factory is TDefaultSocketFactory) and
     ((FTlsContext <> nil) or (FProxyTlsContext <> nil)) then
    Factory := TDefaultSocketFactory(Factory as TObject).WithTlsContexts(
      FTlsContext, FProxyTlsContext);
  // every proxy source collapses into one selector here (nil = all direct);
  // an unusable proxy value raises EHttpProxyConfigError before any request
  Fixed := nil;
  if FProxyHost <> '' then
    Fixed := TProxy.Create(FProxyHost, FProxyPort);
  FillChar(Env, SizeOf(Env), 0);
  if FProxyEnvVars then
    if Assigned(FEnvLookup) then
      Env := ReadProxyEnvironmentUsing(FEnvLookup)
    else
      Env := ReadProxyEnvironment;
  // a Unix socket carries no proxy: any proxy source is a configuration error
  if (FUnixPath <> '') and ((FProxyHost <> '') or (FAllProxy <> '') or
     (FProxySelector <> nil) or (FProxyEnvVars and
     ((Env.HttpProxy <> '') or (Env.HttpsProxy <> '') or (Env.AllProxy <> '')))) then
    raise EHttpUnixSocketConfigError.Create(
      'a Unix socket path cannot be used together with a proxy');
  Selector := BuildProxySelector(FProxySelector, Fixed, FAllProxy,
    FProxyEnvVars, Env, FNoProxy);
  Client := THttpClient.Create(Factory, FMaxConnectionsPerHost,
    FMaxTotalConnections, FMaxStreamsPerConnection, FFollowRedirects,
    FMaxRedirects, FConnectTimeoutMs, FHeaderTimeoutMs, FIdleTimeoutMs,
    FObserver, FHttp1Fallback, FClearTextPolicy, Selector);
  Client.InstallRequestObservers(FRequestObservers, FLogger);
  Client.InstallIdentitySelector(FIdentitySelector);
  Result := Client;
end;

{ TGuardedBody }

end.
