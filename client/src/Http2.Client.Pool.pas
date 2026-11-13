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
  Http2.Client.SocketFactory.Types;


type
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
    function TryH2cUpgrade(const Sock: IHttp2Socket;
      const ARequest: TStreamRequest; out AStatusLine: string): Boolean;
  public
    function Acquire(const AOrigin, AHost: string; const APort: Word;
      const ARequest: TStreamRequest; const AHeaderTimeoutMs: Integer;
      const AToken: ICancellationToken = nil;
      const AProxy: IProxy = nil;
      const ARequestIdentity: IClientIdentity = nil): IHttpResponse;
  end;

implementation

uses
  Http2.Client.Pool.Http1, Http2.Client.Pool.Http2, Http2.Client.Upgrade, Http2.Client.Identity, Http2.Client.Defaults;

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
begin
  // the HTTP/1.1 codec reads in 16 KiB fills; an exact-count transport would
  // block on a keep-alive peer, so single-read the underlying socket here
  H1 := THttp1Connection.Create(TSingleReadSocket.Create(Sock),
    FHeaderTimeoutMs);
  Result := THttp1PooledConnection.Create(H1, AOrigin);
end;

function TConnectionPool.TryH2cUpgrade(const Sock: IHttp2Socket;
  const ARequest: TStreamRequest; out AStatusLine: string): Boolean;
var
  Raw: TBytes;
  Ofs, N: Integer;
  Line, Version, Reason: string;
  Status, Lines: Integer;
begin
  // write the Upgrade request and read the response head byte by byte, so a
  // 101 leaves the HTTP/2 frames that FOLLOW the head untouched in the
  // socket.  The Upgrade and Connection headers cannot travel through
  // TStreamRequest.Headers (the shared map forbids connection-specific
  // fields), so the wire bytes are built here (doc/design/fallback.md
  // "h2c upgrade procedure").
  AStatusLine := '';
  Raw := BuildH2cUpgradeRequest(ARequest);
  Ofs := 0;
  while Ofs < Length(Raw) do
  begin
    N := Sock.Write(Raw[Ofs], Length(Raw) - Ofs);
    if N <= 0 then
      raise EHttpConnectionClosed.Create('h2c upgrade request write failed');
    Inc(Ofs, N);
  end;
  // the probe carries the request, so this is the moment it was written; the
  // declined and accepted paths report again after the response head was read
  if ARequest.Exchange <> nil then
    ARequest.Exchange.RequestWritten(Length(ARequest.Body.Data));
  if not ReadHeadLineBytewise(Sock, Line) then
    raise EHttpProtocolError.Create('peer closed during the h2c upgrade',
      ecProtocolError);
  ParseStatusLine(Line, Version, Status, Reason);
  Result := Status = 101;
  if not Result then
  begin
    AStatusLine := Line;
    Exit;
  end;
  // the 101 head continues with Upgrade/Connection fields and the mandatory
  // empty line; consume them all before the socket becomes an HTTP/2
  // transport, else the connection thread frames those bytes as HTTP/2
  Lines := 0;
  while True do
  begin
    if not ReadHeadLineBytewise(Sock, Line) then
      raise EHttpProtocolError.Create('truncated 101 response head',
        ecProtocolError);
    if Line = '' then
      Break;
    Inc(Lines);
    if Lines > 64 then
      raise EHttpProtocolError.Create('101 response head is too large',
        ecProtocolError);
  end;
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
  Identity: IClientIdentity;
  ContextKeyFactory: ITlsContextPoolKey;
begin
  Marked := False;
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
      FLock.Acquire;
      try
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
        if (Conn = nil) and CanOpenNew(Key, not (Selecting and not Resolved)) then
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
          Marked := False;
        end;
        if Dialing then
          ReserveDial(Key);
      finally
        FLock.Release;
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
            ReleaseDial(Key);
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
        Sleep(1);
      end
      else
      begin
        if FClosed then
          raise EHttpConnectionClosed.Create('client is closed');
        if GetTickCount64 >= Deadline then
          raise EHttpTimeout.Create(
            'timed out waiting for a connection slot ' +
            '(MaxConnectionsPerHost or MaxTotalConnections reached)');
        Sleep(2);
      end;
    end;
  finally
    if Waiting or Marked then
    begin
      FLock.Acquire;
      try
        if Marked then
          FSelecting.Remove(BaseKey);
        if Waiting then
          AddPendingLocked(PendingKey, -1);
      finally
        FLock.Release;
      end;
    end;
  end;
end;

end.
