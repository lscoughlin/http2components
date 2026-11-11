{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Core;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  SyncObjs,
  Http2.Client.Errors,
  Http2.Common.Headers,
  Http2.Client.Tls,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.Observer,
  Http2.Client.Proxy,
  Http2.Client.ClientCert,
  Http2.Client.WebSocket,
  Http2.Client.RequestObserver,
  Http2.Client.Api,
  Http2.Client.Request,
  Http2.Client.Pool,
  Http2.Client.Pool.Types,
  Http2.Client.SocketFactory.Types;


type
  THttpClient = class(TInterfacedObject, IHttpClient)
  private
    FPool: TConnectionPool;
    FHeaderTimeoutMs: Integer;
    FFollowRedirects: Boolean;
    FMaxRedirects: Integer;
    FClosed: Boolean;
    FLock: TCriticalSection;
    FHttp1Fallback: Boolean;
    FClearTextPolicy: TClearTextPolicy;
    /// nil = every route is direct (doc/design/proxy.md)
    FProxySelector: IProxySelector;
    FFactory: IHttp2SocketFactory;
    FConnectTimeoutMs: Integer;
    /// the request observers folded into one (nil when none is installed)
    FRequestObserver: IHttpClientObserver;
    FClonedAttempts: Integer;
    /// nil = the factory's fixed identity (or none)
    FIdentitySelector: IClientIdentitySelector;
    function SendOnce(const ARequest: THttpRequest;
      const AExchange: IExchangeObserver): IHttpResponse;
  public
    constructor Create(const AFactory: IHttp2SocketFactory;
      const AMaxConnectionsPerHost, AMaxTotalConnections,
      AMaxStreamsPerConnection: Integer;
      const AFollowRedirects: Boolean; const AMaxRedirects,
      AConnectTimeoutMs, AHeaderTimeoutMs, AIdleTimeoutMs: Integer;
      const AObserver: IHttp2Observer = nil;
      const AHttp1Fallback: Boolean = False;
      const AClearTextPolicy: TClearTextPolicy = ctReject;
      const AProxySelector: IProxySelector = nil);
    destructor Destroy; override;
    function Send(const ARequest: THttpRequest): IHttpResponse; overload;
    function Send(const ARequest: IWebSocketRequest): IWebSocket; overload;
    procedure Close;
    /// a snapshot of the connection pool for polling gauges; all zeros once the
    /// client is closed.  Safe from any thread.
    function PoolStats: TPoolStats;
    /// install the request-level observers and logger (called by Build)
    procedure InstallRequestObservers(
      const AObservers: TArray<IHttpClientObserver>;
      const ALogger: IHttpLogger);
    /// install the origin identity selector (called by Build)
    procedure InstallIdentitySelector(const ASelector: IClientIdentitySelector);
    /// the pool (test seam)
    property Pool: TConnectionPool read FPool;
    /// attempts that were cloned for an observer (test seam): stays 0 for a
    /// client with no request observer
    property ClonedAttempts: Integer read FClonedAttempts;
  end;

implementation

uses
  Http2.Client.Attempt, Http2.Client.Url, Http2.Client.Defaults, Http2.Client.Identity, Http2.Client.SocketFactory, Http2.Client.WebSocket.Connection;

function HttpMethodIsIdempotent(const AToken: string): Boolean;
begin
  Result := (AToken = 'GET') or (AToken = 'HEAD') or (AToken = 'PUT') or
    (AToken = 'DELETE') or (AToken = 'OPTIONS') or (AToken = 'TRACE');
end;

function HttpStatusIsRedirect(const AStatus: LongInt): Boolean;
begin
  Result := (AStatus = 301) or (AStatus = 302) or (AStatus = 303) or
    (AStatus = 307) or (AStatus = 308);
end;

/// ask ASelector for the identity of a dial to AHost:APort; any exception it
// raises fails the dial with EHttpTlsConfigError carrying its message

constructor THttpClient.Create(const AFactory: IHttp2SocketFactory;
  const AMaxConnectionsPerHost, AMaxTotalConnections,
  AMaxStreamsPerConnection: Integer;
  const AFollowRedirects: Boolean; const AMaxRedirects, AConnectTimeoutMs,
  AHeaderTimeoutMs, AIdleTimeoutMs: Integer;
  const AObserver: IHttp2Observer;
  const AHttp1Fallback: Boolean; const AClearTextPolicy: TClearTextPolicy;
  const AProxySelector: IProxySelector);
begin
  inherited Create;
  FProxySelector := AProxySelector;
  FFactory := AFactory;
  FConnectTimeoutMs := AConnectTimeoutMs;
  FLock := TCriticalSection.Create;
  FPool := TConnectionPool.Create(AFactory, AMaxConnectionsPerHost,
    AMaxTotalConnections, AMaxStreamsPerConnection, AConnectTimeoutMs,
    AHeaderTimeoutMs, AIdleTimeoutMs, AObserver, AHttp1Fallback,
    AClearTextPolicy);
  FFollowRedirects := AFollowRedirects;
  FMaxRedirects := AMaxRedirects;
  FHeaderTimeoutMs := AHeaderTimeoutMs;
  FClosed := False;
  FHttp1Fallback := AHttp1Fallback;
  FClearTextPolicy := AClearTextPolicy;
end;

destructor THttpClient.Destroy;
begin
  Close;
  FPool.Free;
  FLock.Free;
  inherited Destroy;
end;

function THttpClient.PoolStats: TPoolStats;
var
  IsClosed: Boolean;
begin
  FLock.Acquire;
  try
    IsClosed := FClosed;
  finally
    FLock.Release;
  end;
  if IsClosed then
    Exit(Default(TPoolStats));
  Result := FPool.Stats;
end;

procedure THttpClient.InstallIdentitySelector(
  const ASelector: IClientIdentitySelector);
begin
  FIdentitySelector := ASelector;
  FPool.IdentitySelector := ASelector;
end;

procedure THttpClient.InstallRequestObservers(
  const AObservers: TArray<IHttpClientObserver>; const ALogger: IHttpLogger);
begin
  if Length(AObservers) = 0 then
    FRequestObserver := nil
  else
    FRequestObserver := TCompositeObserver.Create(AObservers, ALogger);
end;

function THttpClient.Send(const ARequest: THttpRequest): IHttpResponse;
var
  Current, Req: THttpRequest;
  Method: string;
  Location, Target: string;
  Redirects, Retries, Hop, HopRetries, Status: Integer;
  Idempotent, RetryIt: Boolean;
  Tracker: TAttemptTracker;
  TrackerRef: IExchangeObserver;
begin
  if ARequest.Url = '' then
    raise EHttpProtocolError.Create('request URL is empty', ecProtocolError);
  CheckRequestIdentity(ARequest.ClientIdentity);
  if (ARequest.ClientIdentity <> nil) and
     (SchemeOfUrl(ARequest.Url) = 'https') then
    RequireIdentityFactory(FFactory, 'the request carries a client identity');
  FLock.Acquire;
  try
    if FClosed then
      raise EHttpConnectionClosed.Create('client is closed');
  finally
    FLock.Release;
  end;

  Current := ARequest;
  Method := ARequest.MethodToken;
  Idempotent := HttpMethodIsIdempotent(Method);
  Redirects := 0;
  Retries := 0;
  Hop := 0;
  HopRetries := 0;
  while True do
  begin
    Req := Current;
    Tracker := nil;
    TrackerRef := nil;
    if FRequestObserver <> nil then
    begin
      // the observer injects into a private copy of the headers, so the
      // caller's request and the next hop never carry this attempt's values
      Req := Current.Clone;
      InterlockedIncrement(FClonedAttempts);
      Tracker := TAttemptTracker.Create(FRequestObserver);
      TrackerRef := Tracker;
      Tracker.Start(Req, Hop, HopRetries);
    end;
    try
      Result := SendOnce(Req, TrackerRef);
    except
      // transparent retry: only an idempotent request with no body writer,
      // and only when the peer refused the stream or sent GOAWAY so the
      // stream was never processed (plan S10 task 10.9)
      on E: Exception do
      begin
        RetryIt := (E is EHttpStreamError) and Idempotent and
          (EHttpStreamError(E).ErrorCode = ecRefusedStream) and
          (Current.BodyWriter = nil) and (Retries < cMaxTransparentRetries);
        if Tracker <> nil then
        begin
          if RetryIt then
            Tracker.NotifyRetry('REFUSED_STREAM');
          Tracker.Fail(E);
        end;
        if not RetryIt then
          raise;
        Inc(Retries);
        Inc(HopRetries);
        Sleep(1);
        Continue;
      end;
    end;

    try
      if Tracker <> nil then
        Tracker.GotResponse(Result);
      if (not FFollowRedirects) or (not HttpStatusIsRedirect(Result.StatusCode)) then
      begin
        if Tracker <> nil then
          Tracker.Arm(Result);
        Break;
      end;
      Location := Result.Headers.GetFirst('location');
      if Location = '' then
      begin
        if Tracker <> nil then
          Tracker.Arm(Result);
        Break;
      end;

      Inc(Redirects);
      if Redirects > FMaxRedirects then
        raise EHttpTooManyRedirects.CreateFmt(
          'redirect chain exceeded MaxRedirects (%d)', [FMaxRedirects]);

      Target := ResolveLocation(Current.Url, Location);
      Status := Result.StatusCode;
      case Status of
        303:
          begin
            Method := 'GET';
            Current := Current.DropBody;
          end;
        301, 302:
          begin
            // spec errors-redirects.md leaves 301/302 method rewriting to the
            // "standard rules"; these preserve the method for GET/HEAD and
            // rewrite every other method to GET, dropping the body (the
            // behaviour every browser and curl use for a POST -> 301/302)
            if (Method <> 'GET') and (Method <> 'HEAD') then
            begin
              Method := 'GET';
              Current := Current.DropBody;
            end;
          end;
        307, 308:
          if Current.BodyWriter <> nil then
            raise EHttpNotReplayable.Create(
              'a body writer cannot be replayed on a ' +
              IntToStr(Status) + ' redirect');
      end;
      // like a credential header, the request identity follows a redirect
      // to the same origin only (doc/design/mtls.md "Per-request identity")
      if (Current.ClientIdentity <> nil) and
         (OriginOfUrl(Target) <> OriginOfUrl(Current.Url)) then
        Current := Current.WithClientIdentity(nil);
      Current := Current.WithMethodToken(Method);
      Current := Current.WithUrl(Target);
      if Tracker <> nil then
      begin
        // the finished hop ends before the next one starts; its body is
        // discarded, so it ends abandoned unless it was already complete
        Tracker.NotifyRedirect(Req.Url, Target, Status);
        Tracker.Arm(Result);
        Result := nil;
        Tracker.Drop;
      end;
      Inc(Hop);
      HopRetries := 0;
    except
      on E: Exception do
      begin
        if Tracker <> nil then
          Tracker.Fail(E);
        raise;
      end;
    end;
  end;
end;

function THttpClient.Send(const ARequest: IWebSocketRequest): IWebSocket;
var
  Secure: Boolean;
  Host, Target, Authority, Mapped: string;
  Port: Word;
  Proxy: IProxy;
  Dialer: IHttp1SocketFactory;
  IdFactory: IIdentitySocketFactory;
  ReqId: IClientIdentity;
  Closed: Boolean;
  Tracker: TAttemptTracker;
  TrackerRef: IWebSocketAttempt;
begin
  FLock.Acquire;
  try
    Closed := FClosed;
  finally
    FLock.Release;
  end;
  if Closed then
    raise EHttpConnectionError.Create('the client is closed');
  ReqId := nil;
  if ARequest.ClientIdentity <> nil then
    Supports(ARequest.ClientIdentity, IClientIdentity, ReqId);
  CheckRequestIdentity(ReqId);
  WsParseUrl(ARequest.Url, Secure, Host, Port, Target, Authority);
  if Secure and (ReqId <> nil) then
    RequireIdentityFactory(FFactory, 'the request carries a client identity');
  // the session is one attempt: it starts before anything is dialled, and
  // whatever fails below ends it with that failure
  Tracker := nil;
  TrackerRef := nil;
  if FRequestObserver <> nil then
  begin
    Tracker := TAttemptTracker.Create(FRequestObserver);
    TrackerRef := Tracker;
    Tracker.StartSocket(ARequest, Host, Port, Secure);
  end;
  try
    if not Supports(FFactory, IHttp1SocketFactory, Dialer) then
      raise EHttpWebSocketError.Create(
        'the socket factory cannot dial an HTTP/1.1 connection');
    // the request's own identity wins; else a selector chooses the identity
    // of this dial, on this thread
    if Secure and (ReqId <> nil) and
       Supports(FFactory, IIdentitySocketFactory, IdFactory) then
      Dialer := TIdentityHttp1Dialer.Create(IdFactory, ReqId)
    else if Secure and (FIdentitySelector <> nil) and
       Supports(FFactory, IIdentitySocketFactory, IdFactory) then
      Dialer := TIdentityHttp1Dialer.Create(IdFactory,
        ChooseClientIdentity(FIdentitySelector, Host, Port));
    // the route is chosen on the equivalent http(s) URL, so http_proxy,
    // https_proxy and no_proxy apply as they do for the same request
    Proxy := nil;
    if FProxySelector <> nil then
    begin
      if Secure then
        Mapped := 'https://' + Authority + Target
      else
        Mapped := 'http://' + Authority + Target;
      Proxy := FProxySelector.SelectProxy(Mapped);
      ValidateProxy(Proxy);
    end;
    Result := OpenWebSocket(Dialer, ARequest, Proxy, FConnectTimeoutMs, nil,
      TrackerRef);
  except
    on E: Exception do
    begin
      if Tracker <> nil then
        Tracker.FailHandshake(E);
      raise;
    end;
  end;
end;

function THttpClient.SendOnce(const ARequest: THttpRequest;
  const AExchange: IExchangeObserver): IHttpResponse;
var
  Origin, Host, Path: string;
  Port: Word;
  R: TStreamRequest;
  Timeout: Integer;
  Proxy: IProxy;
begin
  ParseHttpUrl(ARequest.Url, Host, Port, Path);
  Origin := OriginOfUrl(ARequest.Url);
  // the cleartext guard (doc/design/fallback.md): the default ctReject raises
  // before any socket is dialled; ctPriorKnowledge/ctUpgrade proceed and the
  // pool's DialProtocol applies the same policy again on the wire
  if (SchemeOfUrl(ARequest.Url) = 'http') and (FClearTextPolicy = ctReject) then
    raise EHttpProtocolError.Create(
      'cleartext origin rejected (set WithClearText(ctPriorKnowledge) or ' +
      'WithClearText(ctUpgrade) or WithClearText(ctHttp1) to enable it)',
      ecProtocolError);
  // the route is chosen per hop (a redirect re-enters here), on this thread
  // and outside the pool lock; a selector exception reaches the caller of Send
  Proxy := nil;
  if FProxySelector <> nil then
  begin
    Proxy := FProxySelector.SelectProxy(ARequest.Url);
    ValidateProxy(Proxy);
  end;
  // the direct key stays the plain origin; a proxied route is its own bucket
  Origin := Origin + ProxyRouteKey(Proxy);
  R := ARequest.ToStreamRequest;
  if AExchange <> nil then
    R := R.WithExchange(AExchange);
  Timeout := FHeaderTimeoutMs;
  if ARequest.HeaderTimeoutMs > 0 then
    Timeout := ARequest.HeaderTimeoutMs;
  Result := FPool.Acquire(Origin, Host, Port, R, Timeout,
    ARequest.CancelToken, Proxy, ARequest.ClientIdentity);
end;

procedure THttpClient.Close;
begin
  FLock.Acquire;
  try
    FClosed := True;
  finally
    FLock.Release;
  end;
  FPool.Close;
end;

{ TResponseReader<T> }

end.
