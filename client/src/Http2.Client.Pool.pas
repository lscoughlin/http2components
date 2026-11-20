{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Pool;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  Generics.Collections,
  Http2.Client.Errors,
  Http2.Common.Frames,
  Http2.Common.Status,
  Http2.Client.Tls,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Observer,
  Http2.Client.Messages,
  Http2.Client.Http1,
  Http2.Client.Proxy,
  Http2.Client.ClientCert,
  Http2.Client.Pool.State,
  Http2.Client.Pool.Types,
  Http2.Client.SocketFactory.Types,
  Http2.Client.Tunnel.Types,
  Http2.Client.WebSocket;


type
  /// how an AcquireTunnel call ended
  TTunnelOutcome = (
    toTunnel,           // AFields and AStatus hold the 200 answer; the result is the tunnel
    toRefused,          // the server answered with another status; the result is nil
    toHttp1,            // the connection speaks HTTP/1.1 (or an h2c Upgrade dial); result nil
    toNoExtendedConnect // HTTP/2, but the peer did not allow the extended CONNECT; result nil
  );

  TConnectionPool = class(TPoolState)
  private
    function DialFor(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer; const AProxy: IProxy;
      const AUseIdentity: Boolean; const AIdentity: IClientIdentity;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function StartHttp2(const Sock: IHttp2Socket; const AOrigin: string;
      const AStart: Boolean): IPooledConnection;
    function WrapHttp1(const Sock: IHttp2Socket;
      const AOrigin: string): IPooledConnection;
    function OpenForTxn(const AOrigin, AHost: string; const APort: Word;
      const ARequest: TStreamRequest; const AHeaderTimeoutMs: Integer;
      const AScheme: string; const AProxy: IProxy;
      const AUseIdentity: Boolean; const AIdentity: IClientIdentity;
      out AConn: IPooledConnection; out AUpgraded: Boolean;
      out AFirst: IHttpResponse): Boolean;
  public
    function Acquire(const AOrigin, AHost: string; const APort: Word;
      const ARequest: TStreamRequest; const AHeaderTimeoutMs: Integer;
      const AToken: ICancellationToken = nil;
      const AProxy: IProxy = nil;
      const ARequestIdentity: IClientIdentity = nil): IHttpResponse;
    /// acquire a tunnel: an extended CONNECT (RFC 8441) over a pooled connection.
    /// The pool keys and dials as Acquire does, but it never uses the h2c Upgrade.
    /// ARequest must keep its stream open (KeepOpen). The result is the tunnel for
    /// a 200 answer; AOutcome says how the call ended.
    function AcquireTunnel(const AOrigin, AHost: string;
      const APort: Word; const ARequest: TStreamRequest;
      const AHeaderTimeoutMs: Integer; const AProxy: IProxy;
      const ARequestIdentity: IClientIdentity;
      out AOutcome: TTunnelOutcome; out AStatus: Integer;
      out AFields: TArray<TWsHeaderField>; out ARefusalBody: string): IH2Tunnel;
  end;

implementation

uses
  Http2.Client.Pool.Http1, Http2.Client.Pool.Http2, Http2.Client.Upgrade, Http2.Client.Identity, Http2.Client.Defaults,
  Http2.Client.WebSocket.LeaseTunnel, Http2.Client.Pool.H2cUpgrade;

function TConnectionPool.DialFor(const AHost: string; const APort: Word;
  const AScheme: string; const ATimeoutMs: Integer; const AProxy: IProxy;
  const AUseIdentity: Boolean; const AIdentity: IClientIdentity;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  CF: ICleartextSocketFactory;
  PF: IProxySocketFactory;
  IdFactory: IIdentitySocketFactory;
begin
  // the selector's answer, nil included, replaces the factory's fixed identity
  if AUseIdentity and Supports(FFactory, IIdentitySocketFactory, IdFactory) then
    Exit(IdFactory.DialProtocolViaAs(AHost, APort, AScheme, FHttp1Fallback,
      FClearTextPolicy, ATimeoutMs, AProxy, AIdentity, True, AProtocol));

  // a factory that takes the route per dial (the default factory) gets the
  // proxy chosen for this request; nil dials directly
  if Supports(FFactory, IProxySocketFactory, PF) then
    Exit(PF.DialProtocolVia(AHost, APort, AScheme, FHttp1Fallback,
      FClearTextPolicy, ATimeoutMs, AProxy, AProtocol));

  // the default factory (and any factory that opted into the extended
  // contract) selects TLS vs cleartext and the ALPN codec for us
  if Supports(FFactory, ICleartextSocketFactory, CF) then
    Exit(CF.DialProtocol(AHost, APort, AScheme, FHttp1Fallback,
      FClearTextPolicy, ATimeoutMs, AProtocol));

  // legacy factory (the injected test seam): it only knows TLS + h2, so an
  // https origin stays strict; a cleartext origin is dialled directly.  Such a
  // factory predates per-request routing and is never given a proxy
  if AScheme = 'http' then
  begin
    if FClearTextPolicy in [ctUpgrade, ctHttp1] then
      AProtocol := npHttp1Cleartext
    else
      AProtocol := npHttp2Cleartext;
    Result := TTlsSocket.DialCleartext(AHost, APort, ATimeoutMs);
  end
  else
  begin
    AProtocol := npHttp2Tls;
    Result := FFactory.Dial(AHost, APort, ATimeoutMs);
  end;
end;

function TConnectionPool.StartHttp2(const Sock: IHttp2Socket;
  const AOrigin: string; const AStart: Boolean): IPooledConnection;
var
  Conn: TConnection;
  Pooled: THttpConnection;
  Err: EHttpError;
begin
  Conn := TConnection.Create(Sock);
  Conn.SetSecurity(FSecurity);
  if FObserver <> nil then
    Conn.Observer := FObserver;
  if FIdleTimeoutMs > 0 then
  begin
    Conn.PingIntervalMs := FIdleTimeoutMs;
    Conn.PingTimeoutMs := FIdleTimeoutMs;
  end;
  Pooled := THttpConnection.Create(Conn, AOrigin, FMaxStreamsPerConnection);
  if AStart then
  begin
    Conn.Start;    // DoPreface writes the preface + the initial SETTINGS frame
    if not Conn.WaitForState(csOpen, FConnectTimeoutMs) then
    begin
      // a server that rejected the client certificate closes before the
      // connection opens; report that, not a generic open failure
      if Conn.State = csClosed then
      begin
        Err := Conn.FailureError(Conn.ErrorMessage, Conn.ErrorCode);
        if Err is EHttpTlsClientAuthError then
        begin
          Pooled.Free;
          raise Err;
        end;
        Err.Free;
      end;
      Pooled.Free;
      raise EHttpConnectionError.Create('HTTP/2 connection did not open');
    end;
  end;
  // the caller registers it (under FLock) once the dial has finished
  Result := Pooled;
end;

function TConnectionPool.WrapHttp1(const Sock: IHttp2Socket;
  const AOrigin: string): IPooledConnection;
var
  H1: THttp1Connection;
  Pooled: THttp1PooledConnection;
begin
  // the HTTP/1.1 codec reads in 16 KiB fills; an exact-count transport would
  // block on a keep-alive peer, so single-read the underlying socket here
  H1 := THttp1Connection.Create(TSingleReadSocket.Create(Sock),
    FHeaderTimeoutMs);
  Pooled := THttp1PooledConnection.Create(H1, AOrigin);
  // the client option for the body limit; a request may override it
  Pooled.MaxResponseBytes := FSecurity.MaxResponseBytes;
  Result := Pooled;
end;

function TConnectionPool.OpenForTxn(const AOrigin, AHost: string;
  const APort: Word; const ARequest: TStreamRequest;
  const AHeaderTimeoutMs: Integer; const AScheme: string;
  const AProxy: IProxy; const AUseIdentity: Boolean;
  const AIdentity: IClientIdentity;
  out AConn: IPooledConnection; out AUpgraded: Boolean;
  out AFirst: IHttpResponse): Boolean;
var
  Sock: IHttp2Socket;
  Protocol: TNegotiatedProtocol;
  StatusLine: string;
begin
  Result := False;
  AConn := nil;
  AUpgraded := False;
  AFirst := nil;
  Sock := DialFor(AHost, APort, AScheme, FConnectTimeoutMs, AProxy,
    AUseIdentity, AIdentity, Protocol);
  try
    case Protocol of
      npHttp2Tls, npHttp2Cleartext:
        // prior knowledge writes no Upgrade; TConnection.DoPreface sends the
        // preface + SETTINGS itself
        AConn := StartHttp2(Sock, AOrigin, True);
      npHttp1Tls:
        AConn := WrapHttp1(Sock, AOrigin);
      npHttp1Cleartext:
        begin
          // ctUpgrade probes; ctHttp1 never does.  A bodyless request is
          // eligible for the probe; a request with a body is NOT, because
          // that would transmit the body twice (once in the probe, once over
          // HTTP/2).
          if (FClearTextPolicy <> ctUpgrade) or ARequest.Body.IsSet or
            (ARequest.BodyWriter <> nil) then
            AConn := WrapHttp1(Sock, AOrigin)
          else if TryH2cUpgrade(Sock, ARequest, StatusLine) then
          begin
            // 101: the peer already answered the upgrade request and will
            // send its response on stream 1, so the socket is now an HTTP/2
            // transport.  Do NOT start the reader yet: the caller must adopt
            // stream 1 first, else the peer's stream-1 HEADERS could arrive
            // before a lease owns them and be dropped on the shared queue.
            AConn := StartHttp2(Sock, AOrigin, False);
            AUpgraded := True;
          end
          else
          begin
            // non-101: the probe is a complete HTTP/1.1 request, so the
            // status line the peer answered with belongs to it.  Keep the
            // socket as the pooled HTTP/1.1 connection and finish that
            // response instead of sending the request again
            // (doc/design/fallback.md "h2c upgrade procedure").
            AConn := WrapHttp1(Sock, AOrigin);
            AFirst := (AConn as THttp1PooledConnection).Resume(ARequest,
              StatusLine);
          end;
        end;
    end;
  except
    // a failure mid-handshake leaves the socket unusable; StartHttp2/WrapHttp1
    // only own it once they have returned
    if AConn = nil then
      Sock.Close;
    raise;
  end;
  Result := AConn <> nil;
end;

/// the wait slice of a caller: at most 50 ms, and not past the deadline
function SliceMs(const ADeadline: QWord): Integer;
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if Now >= ADeadline then
    Exit(1);
  if ADeadline - Now > 50 then
    Result := 50
  else
    Result := Integer(ADeadline - Now);
end;

function TConnectionPool.Acquire(const AOrigin, AHost: string;
  const APort: Word; const ARequest: TStreamRequest;
  const AHeaderTimeoutMs: Integer;
  const AToken: ICancellationToken; const AProxy: IProxy;
  const ARequestIdentity: IClientIdentity): IHttpResponse;
var
  Deadline: QWord;
  Conn: IPooledConnection;
  Acquired, Upgraded: Boolean;
  Sliced: Integer;
  First: IHttpResponse;
  Waiting, Opened: Boolean;
  Protocol: TNegotiatedProtocol;
  Key, PendingKey, Remembered, Fingerprint, BaseKey, ContextKey: string;
  Selecting, Resolved, NeedSelect, Fixed, Marked, Deferred: Boolean;
  Dialing, DialOk, WasMarked: Boolean;
  Late: IPooledConnection;
  WaitDial: TOriginDial;
  WaitGen: Cardinal;
  Retry, DeferredSignal: Boolean;
  Identity: IClientIdentity;
  ContextKeyFactory: ITlsContextPoolKey;
begin
  Marked := False;
  WaitDial := nil;
  WaitGen := 0;
  DeferredSignal := False;
  Deadline := GetTickCount64 + QWord(AHeaderTimeoutMs);
  Waiting := False;
  ContextKey := '';
  if Supports(FFactory, ITlsContextPoolKey, ContextKeyFactory) then
    ContextKey := ContextKeyFactory.TlsContextPoolKey;
  BaseKey := AOrigin + ' tls=' + ContextKey + ' protocol=' +
    IntToStr(Ord(FHttp1Fallback)) + ':' + IntToStr(Ord(FClearTextPolicy));
  PendingKey := BaseKey;
  // a selector only applies to a TLS dial on a factory that can take the
  // identity per dial; everything else keeps the plain key
  Selecting := (FIdentitySelector <> nil) and (ARequest.Scheme = 'https') and
    Supports(FFactory, IIdentitySocketFactory);
  Resolved := False;
  Identity := nil;
  Fingerprint := '';
  // the request's own identity replaces the selector and the fixed identity
  // for this dial and keys the connection; a cleartext origin has no TLS to
  // present it on
  Fixed := (ARequestIdentity <> nil) and (ARequest.Scheme = 'https') and
    Supports(FFactory, IIdentitySocketFactory);
  if Fixed then
  begin
    Selecting := False;
    Identity := ARequestIdentity;
    Fingerprint := ARequestIdentity.Leaf.FingerprintSha256;
  end;
  try
    while True do
    begin
      if (AToken <> nil) and AToken.IsCancelled then
        raise EHttpStreamError.Create('request cancelled', 0, ecCancel);
      Upgraded := False;
      First := nil;
      Opened := False;
      NeedSelect := False;
      Deferred := False;
      Dialing := False;
      Retry := False;
      FLock.Acquire;
      try
        // the wait of the last round ends: the checks below decide again
        if WaitDial <> nil then
        begin
          LeaveWait(WaitDial);
          WaitDial := nil;
        end;
        // back from asking the selector: this request now dials (or parks).
        // A concurrent request keeps waiting for it until the dial has
        // registered its connection (or failed), so one cold origin is dialled
        // once; the mark is cleared at the end of this section when no dial
        // follows, else in the locked section that ends the dial
        WasMarked := Marked;
        // with a selector the key carries the fingerprint: the one the
        // selector just answered, else the one the last dial here presented,
        // so a reused connection never asks the selector again
        Key := BaseKey;
        if Selecting then
        begin
          if Resolved then
            Remembered := Fingerprint
          else if not FIdentityKeys.TryGetValue(BaseKey, Remembered) then
            Remembered := '';
          Key := BaseKey + ' id=' + Remembered;
        end
        else if Fixed then
          Key := BaseKey + ' id=' + Fingerprint;
        if Waiting and (PendingKey <> Key) then
        begin
          AddPendingLocked(PendingKey, -1);
          AddPendingLocked(Key, 1);
        end;
        PendingKey := Key;
        ReapClosed;
        ReapIdleLocked;
        Conn := PickEligible(Key);
        // one dial in flight per origin and route: a caller that finds one
        // waits (poll below) and then picks the connection it registered, so a
        // cold burst multiplexes on the first connection; another origin is
        // not affected
        if (Conn = nil) and (DialingForBase(Key) = 0) and
          CanOpenNew(Key, not (Selecting and not Resolved)) then
        begin
          if Selecting and not Resolved then
          begin
            // a dial is needed: ask the selector outside the lock, then come
            // back and key the new connection by its answer.  While another
            // request is already asking for this origin, wait for its dial
            // to publish a connection (or fail) instead of asking again
            if FSelecting.ContainsKey(BaseKey) then
              Deferred := True
            else
            begin
              NeedSelect := True;
              FSelecting.Add(BaseKey, True);
              Marked := True;
            end;
          end
          else
          begin
            // the slot is reserved below, at the end of this locked section;
            // the dial itself runs after FLock is released, so a slow origin
            // never blocks a call for another origin
            Dialing := True;
          end;
        end;
        // a caller with no connection and no answer parks below: count it so
        // PoolStats can report the queue
        // (a caller about to ask the selector is not parked: it goes straight
        // round again)
        if not (NeedSelect or Deferred) then
          if (Conn <> nil) or (First <> nil) or Dialing then
          begin
            if Waiting then
              AddPendingLocked(Key, -1);
            Waiting := False;
          end
          else if not Waiting then
          begin
            AddPendingLocked(Key, 1);
            Waiting := True;
          end;
        // last statement of the section: nothing after it can fail, so the
        // reservation always reaches the try..finally below
        if WasMarked and not Dialing then
        begin
          FSelecting.Remove(BaseKey);
          SignalOrigin(Key);
          Marked := False;
        end;
        if Dialing then
          ReserveDial(Key)
        else if (Conn = nil) and not NeedSelect then
        begin
          // the caller waits below: it counts as a waiter and reads the
          // generation under FLock, so a dial that ends later is never missed
          WaitDial := EnterWait(Key, WaitGen);
          Retry := WaitDial = nil;
        end;
      finally
        FLock.Release;
      end;
      if not Dialing then
        CloseVictims;                // what ReapIdleLocked took out, outside FLock
      if Retry then
      begin
        ThreadSwitch;
        Continue;
      end;

      if Dialing then
      begin
        Late := nil;
        DialOk := False;
        try
          // an idle connection that Evict took out closes here, outside FLock;
          // inside the try, so a raise still gives the reserved slot back
          CloseVictims;
          // the one transport-selection point: TLS vs cleartext and the
          // HTTP/2 vs HTTP/1.1 codec (doc/design/fallback.md "Negotiation")
          OpenForTxn(Key, AHost, APort, ARequest, AHeaderTimeoutMs,
            ARequest.Scheme, AProxy, Selecting or Fixed, Identity, Conn,
            Upgraded, First);
          DialOk := True;
        finally
          // every exit of the dial (success, a raise) gives the reserved
          // slot back and registers the connection in ONE locked section
          FLock.Acquire;
          try
            // a new HTTP/1.1 connection goes to its dialer first (see
            // ReleaseDial); every other end of a dial wakes the waiters now
            DeferredSignal := (Conn <> nil) and (Conn.Conn = nil) and
              not FClosed;
            ReleaseDial(Key, not DeferredSignal);
            if Marked then
            begin
              FSelecting.Remove(BaseKey);
              Marked := False;
            end;
            if Conn <> nil then
              if FClosed then
                Late := Conn
              else
              begin
                Register(Key, Conn);
                if DialOk and Selecting then
                  FIdentityKeys.AddOrSetValue(BaseKey, Fingerprint);
              end;
          finally
            FLock.Release;
          end;
          // the pool closed during the dial: the new connection closes
          if Late <> nil then
            Late.Drain;
        end;
        if Late <> nil then
        begin
          Conn := nil;
          First := nil;
          raise EHttpConnectionClosed.Create('client is closed');
        end;
        Opened := Conn <> nil;
        // the token fired during the dial: the connection stays in the pool
        // (it is healthy and still useful), the call ends with the cancel error
        if (AToken <> nil) and AToken.IsCancelled then
        begin
          if Upgraded and (Conn <> nil) then
            Conn.Drain;               // unstarted, and no request adopts it
          First := nil;
          Conn := nil;
          raise EHttpStreamError.Create('request cancelled', 0, ecCancel);
        end;
      end;

      if NeedSelect then
      begin
        Identity := ChooseClientIdentity(FIdentitySelector, AHost, APort);
        Fingerprint := '';
        if Identity <> nil then
          Fingerprint := Identity.Leaf.FingerprintSha256;
        Resolved := True;
        Continue;
      end;

      if First <> nil then
      begin
        // a declined h2c upgrade: the probe carried the request, so its
        // response is the answer and the request is not written again
        if ARequest.Exchange <> nil then
        begin
          ARequest.Exchange.RouteChosen(npHttp1Cleartext, False);
          ARequest.Exchange.RequestWritten(0);
        end;
        Result := First;
        Exit;
      end;

      if Upgraded then
      begin
        // h2c upgrade: the 101 switch already happened inside the handshake, so
        // adopt stream 1 and wait for its response (RFC 7540 section 3.2: the
        // request is never re-sent).  FLock is released so a slow stream-1
        // response never blocks other origins.
        if ARequest.Exchange <> nil then
        begin
          ARequest.Exchange.RouteChosen(npHttp2Cleartext, False);
          ARequest.Exchange.RequestWritten(0);
        end;
        Result := (Conn as THttpConnection).AcquireUpgraded(ARequest,
          AHeaderTimeoutMs);
        Exit;
      end;

      if Conn <> nil then
      begin
        if ARequest.Exchange <> nil then
        begin
          // the codec follows the connection; the scheme picks TLS or not
          if Conn.Conn <> nil then
            Protocol := npHttp2Tls
          else
            Protocol := npHttp1Tls;
          if ARequest.Scheme <> 'https' then
            Inc(Protocol);
          ARequest.Exchange.RouteChosen(Protocol, not Opened);
        end;
        // an HTTP/1.1 pooled connection has no cancellable path (one request in
        // flight, no RST_STREAM); Acquire either returns at once or raises
        try
          if (AToken <> nil) and (Conn.Conn <> nil) then
          begin
            Sliced := AHeaderTimeoutMs;
            if Sliced <= 0 then
              Sliced := cDefaultHeaderTimeoutMs;
            Result := (Conn as THttpConnection).AcquireCancellable(ARequest,
              Sliced, AToken, Acquired);
          end
          else
            Result := Conn.Acquire(ARequest, AHeaderTimeoutMs, Acquired);
        finally
          if DeferredSignal then
          begin
            DeferredSignal := False;
            FLock.Acquire;
            try
              SignalOrigin(Key);
            finally
              FLock.Release;
            end;
          end;
        end;
        if Acquired then
        begin
          FLock.Acquire;
          try
            MarkUsed(Conn);
          finally
            FLock.Release;
          end;
          Exit;
        end;
        // the connection filled up between selection and registration; retry
        // after a wake or a slice
        FLock.Acquire;
        try
          WaitDial := EnterWait(Key, WaitGen);
        finally
          FLock.Release;
        end;
        if WaitDial <> nil then
          WaitDial.WaitSlice(WaitGen, SliceMs(Deadline))
        else
          ThreadSwitch;
      end
      else
      begin
        if FClosed then
          raise EHttpConnectionClosed.Create('client is closed');
        if GetTickCount64 >= Deadline then
          raise EHttpTimeout.Create(
            'timed out waiting for a connection slot ' +
            '(MaxConnectionsPerHost or MaxTotalConnections reached)');
        if WaitDial <> nil then
          WaitDial.WaitSlice(WaitGen, SliceMs(Deadline));
      end;
    end;
  finally
    if Waiting or Marked or DeferredSignal or (WaitDial <> nil) then
    begin
      FLock.Acquire;
      try
        if DeferredSignal then
          SignalOrigin(BaseKey);
        if WaitDial <> nil then
          LeaveWait(WaitDial);
        if Marked then
        begin
          FSelecting.Remove(BaseKey);
          SignalOrigin(BaseKey);
        end;
        if Waiting then
          AddPendingLocked(PendingKey, -1);
      finally
        FLock.Release;
      end;
    end;
  end;
end;

function TConnectionPool.AcquireTunnel(const AOrigin, AHost: string;
  const APort: Word; const ARequest: TStreamRequest;
  const AHeaderTimeoutMs: Integer; const AProxy: IProxy;
  const ARequestIdentity: IClientIdentity;
  out AOutcome: TTunnelOutcome; out AStatus: Integer;
  out AFields: TArray<TWsHeaderField>; out ARefusalBody: string): IH2Tunnel;
var
  Deadline: QWord;
  Conn: IPooledConnection;
  Sock: IHttp2Socket;
  Protocol: TNegotiatedProtocol;
  Key, BaseKey, ContextKey, Remembered, Fingerprint: string;
  Selecting, Resolved, NeedSelect, Fixed, Marked, WasMarked: Boolean;
  Dialing, DialOk, Retry, Acquired, Allowed: Boolean;
  Late: IPooledConnection;
  WaitDial: TOriginDial;
  WaitGen: Cardinal;
  Identity: IClientIdentity;
  ContextKeyFactory: ITlsContextPoolKey;
  H2: TConnection;
  Lease: TStreamLease;
  Keep: IConnectionStream;
begin
  Result := nil;
  AOutcome := toHttp1;
  AStatus := -1;
  AFields := nil;
  ARefusalBody := '';
  if not ARequest.KeepOpen then
    raise EHttpProtocolError.Create(
      'a tunnel needs a request that keeps its stream open', ecProtocolError);
  Marked := False;
  WaitDial := nil;
  WaitGen := 0;
  Deadline := GetTickCount64 + QWord(AHeaderTimeoutMs);
  // the key rules are those of Acquire: origin, TLS context, route and identity
  ContextKey := '';
  if Supports(FFactory, ITlsContextPoolKey, ContextKeyFactory) then
    ContextKey := ContextKeyFactory.TlsContextPoolKey;
  BaseKey := AOrigin + ' tls=' + ContextKey + ' protocol=' +
    IntToStr(Ord(FHttp1Fallback)) + ':' + IntToStr(Ord(FClearTextPolicy));
  Selecting := (FIdentitySelector <> nil) and (ARequest.Scheme = 'https') and
    Supports(FFactory, IIdentitySocketFactory);
  Resolved := False;
  Identity := nil;
  Fingerprint := '';
  Fixed := (ARequestIdentity <> nil) and (ARequest.Scheme = 'https') and
    Supports(FFactory, IIdentitySocketFactory);
  if Fixed then
  begin
    Selecting := False;
    Identity := ARequestIdentity;
    Fingerprint := ARequestIdentity.Leaf.FingerprintSha256;
  end;
  try
    while True do
    begin
      Dialing := False;
      NeedSelect := False;
      Retry := False;
      Conn := nil;
      FLock.Acquire;
      try
        // the wait of the last round ends: the checks below decide again
        if WaitDial <> nil then
        begin
          LeaveWait(WaitDial);
          WaitDial := nil;
        end;
        WasMarked := Marked;
        Key := BaseKey;
        if Selecting then
        begin
          if Resolved then
            Remembered := Fingerprint
          else if not FIdentityKeys.TryGetValue(BaseKey, Remembered) then
            Remembered := '';
          Key := BaseKey + ' id=' + Remembered;
        end
        else if Fixed then
          Key := BaseKey + ' id=' + Fingerprint;
        ReapClosed;
        ReapIdleLocked;
        Conn := PickEligible(Key);
        if (Conn = nil) and (DialingForBase(Key) = 0) and
          CanOpenNew(Key, not (Selecting and not Resolved)) then
        begin
          if Selecting and not Resolved then
          begin
            // ask the selector outside FLock; a concurrent request that is
            // already asking leaves the answer to it and waits for its dial
            if not FSelecting.ContainsKey(BaseKey) then
            begin
              NeedSelect := True;
              FSelecting.Add(BaseKey, True);
              Marked := True;
            end;
          end
          else
            Dialing := True;
        end;
        // last statement of the section that uses the mark of this round
        if WasMarked and not Dialing then
        begin
          FSelecting.Remove(BaseKey);
          SignalOrigin(Key);
          Marked := False;
        end;
        if Dialing then
          ReserveDial(Key)
        else if (Conn = nil) and not NeedSelect then
        begin
          WaitDial := EnterWait(Key, WaitGen);
          Retry := WaitDial = nil;
        end;
      finally
        FLock.Release;
      end;
      if not Dialing then
        CloseVictims;                  // what ReapIdleLocked took out, outside FLock
      if Retry then
      begin
        ThreadSwitch;
        Continue;
      end;
      if NeedSelect then
      begin
        Identity := ChooseClientIdentity(FIdentitySelector, AHost, APort);
        Fingerprint := '';
        if Identity <> nil then
          Fingerprint := Identity.Leaf.FingerprintSha256;
        Resolved := True;
        Continue;
      end;

      if Dialing then
      begin
        // the one transport choice: the Upgrade is never used, so an HTTP/1.1
        // dial stays a plain HTTP/1.1 connection (no h2c probe is written)
        Late := nil;
        DialOk := False;
        Sock := nil;
        try
          try
            CloseVictims;
            Sock := DialFor(AHost, APort, ARequest.Scheme, FConnectTimeoutMs,
              AProxy, Selecting or Fixed, Identity, Protocol);
            case Protocol of
              npHttp2Tls, npHttp2Cleartext:
                Conn := StartHttp2(Sock, AOrigin, True);
              npHttp1Tls, npHttp1Cleartext:
                Conn := WrapHttp1(Sock, AOrigin);
            end;
          except
            // a failure mid-handshake leaves the socket unusable
            if (Conn = nil) and (Sock <> nil) then
              Sock.Close;
            raise;
          end;
          DialOk := True;
        finally
          FLock.Acquire;
          try
            ReleaseDial(Key, True);
            if Marked then
            begin
              FSelecting.Remove(BaseKey);
              Marked := False;
            end;
            if Conn <> nil then
              if FClosed then
                Late := Conn
              else
              begin
                Register(Key, Conn);
                if DialOk and Selecting then
                  FIdentityKeys.AddOrSetValue(BaseKey, Fingerprint);
              end;
          finally
            FLock.Release;
          end;
          // the pool closed during the dial: the new connection closes
          if Late <> nil then
            Late.Drain;
        end;
        if Late <> nil then
          raise EHttpConnectionClosed.Create('client is closed');
      end;

      if Conn = nil then
      begin
        // no connection and no dial: wait for a slot, or for the dial in flight
        if FClosed then
          raise EHttpConnectionClosed.Create('client is closed');
        if GetTickCount64 >= Deadline then
          raise EHttpTimeout.Create(
            'timed out waiting for a connection slot ' +
            '(MaxConnectionsPerHost or MaxTotalConnections reached)');
        if WaitDial <> nil then
          WaitDial.WaitSlice(WaitGen, SliceMs(Deadline))
        else
          ThreadSwitch;
        Continue;
      end;

      // an HTTP/1.1 connection has no extended CONNECT. A cleartext WebSocket
      // speaks HTTP/1.1 unless the policy is prior knowledge (D3), so an HTTP/2
      // connection that an Upgrade left on this key is not used either
      if (Conn.Conn = nil) or ((ARequest.Scheme = 'http') and
        (FClearTextPolicy <> ctPriorKnowledge)) then
      begin
        AOutcome := toHttp1;
        Exit;
      end;

      // the answer of the peer's SETTINGS is read outside FLock
      H2 := Conn.Conn;
      Allowed := H2.WaitForPeerSettings(AHeaderTimeoutMs) and
        H2.PeerAllowsExtendedConnect;
      if not Allowed then
      begin
        if H2.State = csClosed then
          raise EHttpConnectionError.Create(
            'the connection closed before its SETTINGS');
        // the connection stays in the pool: other requests still use it
        AOutcome := toNoExtendedConnect;
        Exit;
      end;

      Lease := (Conn as THttpConnection).AcquireTunnelLease(ARequest,
        AHeaderTimeoutMs, Acquired, Keep, AStatus, AFields);
      if not Acquired then
      begin
        // the connection filled up or is closing: wait for a slot and go round
        if GetTickCount64 >= Deadline then
          raise EHttpTimeout.Create(
            'timed out waiting for a connection slot ' +
            '(MaxConnectionsPerHost or MaxTotalConnections reached)');
        FLock.Acquire;
        try
          WaitDial := EnterWait(Key, WaitGen);
        finally
          FLock.Release;
        end;
        if WaitDial <> nil then
          WaitDial.WaitSlice(WaitGen, SliceMs(Deadline))
        else
          ThreadSwitch;
        Continue;
      end;
      FLock.Acquire;
      try
        MarkUsed(Conn);
      finally
        FLock.Release;
      end;
      if AStatus = HttpStatusOk then
      begin
        Result := TPooledTunnel.Create(Conn,
          TLeaseTunnel.Create(Lease, H2));
        AOutcome := toTunnel;
      end
      else
      begin
        ARefusalBody := (Conn as THttpConnection).ReadTunnelRefusal(Lease,
          AHeaderTimeoutMs);
        AOutcome := toRefused;
      end;
      Exit;
    end;
  finally
    // the same cleanup as Acquire: a mark or a wait this call still holds
    if Marked or (WaitDial <> nil) then
    begin
      FLock.Acquire;
      try
        if WaitDial <> nil then
          LeaveWait(WaitDial);
        if Marked then
        begin
          FSelecting.Remove(BaseKey);
          SignalOrigin(BaseKey);
        end;
      finally
        FLock.Release;
      end;
    end;
  end;
end;

end.
