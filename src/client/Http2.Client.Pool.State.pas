{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Pool.State;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils, Http2.Common.Frames,
  SyncObjs,
  Generics.Collections,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.Tls,
  Http2.Client.Observer,
  Http2.Client.ClientCert,
  Http2.Client.SocketFactory.Types,
  Http2.Client.Pool.Types,
  Http2.Client.Defaults,
  Http2.Client.Clock;


type
  TPoolState = class
  protected
    FLock: TCriticalSection;
    FByOrigin: TDictionary<string, TList<IPooledConnection>>;
    FFactory: IHttp2SocketFactory;
    FMaxConnectionsPerHost: Integer;
    FMaxTotalConnections: Integer;
    FMaxStreamsPerConnection: Integer;
    FConnectTimeoutMs: Integer;
    FHeaderTimeoutMs: Integer;
    FIdleTimeoutMs: Integer;
    FTotalConnections: Integer;
    FClosed: Boolean;
    FObserver: IHttp2Observer;
    /// ALPN fallback and cleartext policy, applied to every request by scheme
    /// (doc/design/fallback.md)
    FHttp1Fallback: Boolean;
    FClearTextPolicy: TClearTextPolicy;
    /// last time a pooled connection was used, keyed by IPooledConnection.Key
    FIdleSince: TDictionary<Pointer, QWord>;
    /// when a pooled connection was registered, keyed like FIdleSince
    FCreatedAt: TDictionary<Pointer, QWord>;
    /// callers parked in Acquire waiting for a slot, per origin key
    FPending: TDictionary<string, Integer>;
    /// the selector that chooses the origin identity of each new TLS
    /// connection (nil = the factory's fixed identity); set once by Build
    FIdentitySelector: IClientIdentitySelector;
    /// the fingerprint the last dial to a pool key presented, so a request
    /// finds its connections without calling the selector; guarded by FLock
    FIdentityKeys: TDictionary<string, string>;
    /// origins (route included) whose selector is being asked right now by one
    /// request, so a concurrent request waits for that dial instead of asking
    /// again; guarded by FLock
    FSelecting: TDictionary<string, Boolean>;
    /// the TCP+TLS-or-cleartext dial for ARequest's scheme (fallback on https,
    /// the policy on http); out AProtocol names the negotiated wire protocol.
    /// Uses the extended ICleartextSocketFactory contract when the factory
    /// supports it, else the legacy Dial (npHttp2Tls) so an injected test
    /// factory keeps working
    // - AUseIdentity True hands AIdentity (the selector's answer, possibly
    //   nil) to a factory that takes the identity per dial
    /// wrap Sock as an HTTP/2 pooled connection.  AStart True runs the thread
    /// and waits for csOpen (preface + SETTINGS written by DoPreface); False
    /// leaves it unstarted so the h2c upgrade can adopt stream 1 before any
    /// inbound frame is read
    /// online the HTTP/1.1 codec over a socket and pool it
    /// the one transport-selection point (plan S13 tasks 13.2/13.3/13.5):
    /// dial, choose the codec from the negotiated protocol, run the h2c
    /// Upgrade when the policy asks for it, and register the result under
    /// AOrigin.  AUpgraded is True when the connection is an unstarted HTTP/2
    /// connection on which the caller must adopt stream 1 via AcquireUpgraded.
    /// AFirst is the response of a declined upgrade, already drawn from the
    /// pooled HTTP/1.1 connection by the request the probe carried.
    /// write the h2c Upgrade request on Sock and read the whole response head
    /// byte by byte.  True => 101 and the socket sits exactly at the HTTP/2
    /// boundary; False => the peer declined, AStatusLine is the status line it
    /// answered with and the socket sits right after it, so the pool carries
    /// on with the HTTP/1.1 codec on the same socket (the request is never
    /// written twice).
    // (RFC 7540 section 3.2 / doc/design/fallback.md "h2c upgrade procedure")
    procedure ReapClosed;
    procedure ReapIdleLocked;
    procedure MarkUsed(const C: IPooledConnection);
    /// adjust the parked-caller count for AOrigin; the caller holds FLock
    procedure AddPendingLocked(const AOrigin: string; const ADelta: Integer);
    function ListFor(const AOrigin: string): TList<IPooledConnection>;
    function PickEligible(const AOrigin: string): IPooledConnection;
    /// the origin and route part of a pool key, without the identity suffix
    class function BaseOfKey(const AKey: string): string; static;
    /// connections to the origin and route ABase across every identity
    function CountForBase(const ABase: string): Integer;
    /// the oldest idle connection to ABase whose key is not AKey (another
    /// identity), or nil
    function FindEvictable(const AKey, ABase: string;
      out AList: TList<IPooledConnection>): IPooledConnection;
    /// drain AConn and drop it from the pool, freeing its cap slot
    procedure Evict(const AList: TList<IPooledConnection>;
      const AConn: IPooledConnection);
    /// can a new connection be opened for the key AKey?  The per-host cap
    /// counts the origin and route across all identities, so False when that
    /// origin is at MaxConnectionsPerHost or the pool is at
    /// MaxTotalConnections.  AEvict True makes room by closing the oldest idle
    /// connection of another identity to the same origin when a cap is
    /// reached; False only asks whether that would be needed.
    function CanOpenNew(const AKey: string; const AEvict: Boolean): Boolean;
    procedure Register(const AOrigin: string;
      const AConn: IPooledConnection);
  public
    constructor Create(const AFactory: IHttp2SocketFactory;
      const AMaxConnectionsPerHost, AMaxTotalConnections,
      AMaxStreamsPerConnection, AConnectTimeoutMs, AHeaderTimeoutMs,
      AIdleTimeoutMs: Integer; const AObserver: IHttp2Observer = nil;
      const AHttp1Fallback: Boolean = False;
      const AClearTextPolicy: TClearTextPolicy = ctReject);
    destructor Destroy; override;
    /// acquire a lease on the least-loaded eligible connection, opening a new
    /// one or waiting for a slot per doc/design/client-api.md. When AToken is
    /// non-nil the wait is cancellable (plan S10 task 10.8).  The request's
    /// scheme selects TLS vs cleartext and the HTTP/2 vs HTTP/1.1 codec.
    /// AOrigin is the pool key (the plain origin when direct, origin plus the
    /// proxy route otherwise); AProxy is the route to dial on a new connection.
    /// With an identity selector installed an https request is keyed by the
    /// identity fingerprint as well, and the selector is asked (outside FLock)
    /// only when a new connection has to be dialled.  ARequestIdentity (the
    /// request's own origin identity, nil when none) wins over the selector:
    /// the key carries its fingerprint, the selector is not asked and the
    /// dial presents it to the origin
    /// close and remove connections idle for longer than IdleTimeoutMs, so
    /// the pool stays within MaxTotalConnections (plan S10 task 10.7).
    procedure ReapIdle;
    procedure Close;
    /// install the identity selector (called by Build, before any request)
    property IdentitySelector: IClientIdentitySelector
      read FIdentitySelector write FIdentitySelector;
    /// a snapshot of the counts, copied under FLock and returned by value
    function Stats: TPoolStats;
    // test seams
    function ConnectionCount: Integer;
    function ConnectionCountForOrigin(const AOrigin: string): Integer;
    function ActiveStreamsForOrigin(const AOrigin: string): TArray<Integer>;
    /// choose the least-loaded eligible connection for AOrigin (test seam)
    function PickForTest(const AOrigin: string): IPooledConnection;
    /// add an externally-built connection under AOrigin (test seam)
    procedure AddForTest(const AOrigin: string;
      const AConn: IPooledConnection);
  end;

implementation

constructor TPoolState.Create(const AFactory: IHttp2SocketFactory;
  const AMaxConnectionsPerHost, AMaxTotalConnections,
  AMaxStreamsPerConnection, AConnectTimeoutMs, AHeaderTimeoutMs,
  AIdleTimeoutMs: Integer; const AObserver: IHttp2Observer;
  const AHttp1Fallback: Boolean; const AClearTextPolicy: TClearTextPolicy);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FByOrigin := TDictionary<string, TList<IPooledConnection>>.Create;
  FIdleSince := TDictionary<Pointer, QWord>.Create;
  FCreatedAt := TDictionary<Pointer, QWord>.Create;
  FPending := TDictionary<string, Integer>.Create;
  FIdentityKeys := TDictionary<string, string>.Create;
  FSelecting := TDictionary<string, Boolean>.Create;
  FFactory := AFactory;
  FObserver := AObserver;
  FMaxConnectionsPerHost := AMaxConnectionsPerHost;
  FMaxTotalConnections := AMaxTotalConnections;
  FMaxStreamsPerConnection := AMaxStreamsPerConnection;
  FConnectTimeoutMs := AConnectTimeoutMs;
  FHeaderTimeoutMs := AHeaderTimeoutMs;
  FIdleTimeoutMs := AIdleTimeoutMs;
  FHttp1Fallback := AHttp1Fallback;
  FClearTextPolicy := AClearTextPolicy;
  FTotalConnections := 0;
  FClosed := False;
end;

procedure TPoolState.Register(const AOrigin: string;
  const AConn: IPooledConnection);
begin
  ListFor(AOrigin).Add(AConn);
  Inc(FTotalConnections);
  MarkUsed(AConn);
end;

destructor TPoolState.Destroy;
var
  L: TList<IPooledConnection>;
begin
  Close;
  for L in FByOrigin.Values do
    L.Free;
  FByOrigin.Free;
  FIdleSince.Free;
  FCreatedAt.Free;
  FPending.Free;
  FIdentityKeys.Free;
  FSelecting.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPoolState.ReapClosed;
var
  Origin: string;
  L: TList<IPooledConnection>;
  I: Integer;
  C: IPooledConnection;
begin
  for Origin in FByOrigin.Keys do
  begin
    L := FByOrigin[Origin];
    for I := L.Count - 1 downto 0 do
    begin
      C := L[I];
      if C.Closed and (C.ActiveStreams = 0) then
      begin
        FIdleSince.Remove(C.Key);
        FCreatedAt.Remove(C.Key);
        L.Delete(I);
        Dec(FTotalConnections);
      end;
    end;
  end;
end;

procedure TPoolState.MarkUsed(const C: IPooledConnection);
begin
  // the first use is registration, which stamps the connection's age
  FCreatedAt.TryAdd(C.Key, GetTickCount64);
  FIdleSince.AddOrSetValue(C.Key, GetTickCount64);
end;

procedure TPoolState.AddPendingLocked(const AOrigin: string;
  const ADelta: Integer);
var
  N: Integer;
begin
  if not FPending.TryGetValue(AOrigin, N) then
    N := 0;
  Inc(N, ADelta);
  if N > 0 then
    FPending.AddOrSetValue(AOrigin, N)
  else
    FPending.Remove(AOrigin);
end;

procedure TPoolState.ReapIdle;
begin
  FLock.Acquire;
  try
    ReapIdleLocked;
  finally
    FLock.Release;
  end;
end;

procedure TPoolState.ReapIdleLocked;
var
  Origin: string;
  L: TList<IPooledConnection>;
  I: Integer;
  C: IPooledConnection;
  Since: QWord;
  Now: QWord;
begin
  if FIdleTimeoutMs <= 0 then
    Exit;
  Now := GetTickCount64;
  for Origin in FByOrigin.Keys do
  begin
    L := FByOrigin[Origin];
    for I := L.Count - 1 downto 0 do
    begin
      C := L[I];
      if C.ActiveStreams > 0 then
        Continue;
      if not FIdleSince.TryGetValue(C.Key, Since) then
        Continue;
      if Now - Since < QWord(FIdleTimeoutMs) then
        Continue;
      C.Drain;                       // closes now, since it is idle
      FIdleSince.Remove(C.Key);
      FCreatedAt.Remove(C.Key);
      L.Delete(I);
      Dec(FTotalConnections);
    end;
  end;
end;

function TPoolState.ListFor(
  const AOrigin: string): TList<IPooledConnection>;
begin
  if not FByOrigin.TryGetValue(AOrigin, Result) then
  begin
    Result := TList<IPooledConnection>.Create;
    FByOrigin.Add(AOrigin, Result);
  end;
end;

class function TPoolState.BaseOfKey(const AKey: string): string;
var
  P: Integer;
begin
  P := Pos(' id=', AKey);
  if P = 0 then
    Result := AKey
  else
    Result := Copy(AKey, 1, P - 1);
end;

function TPoolState.CountForBase(const ABase: string): Integer;
var
  Key: string;
begin
  Result := 0;
  for Key in FByOrigin.Keys do
    if BaseOfKey(Key) = ABase then
      Inc(Result, FByOrigin[Key].Count);
end;

function TPoolState.FindEvictable(const AKey, ABase: string;
  out AList: TList<IPooledConnection>): IPooledConnection;
var
  Key: string;
  L: TList<IPooledConnection>;
  C: IPooledConnection;
  Born, BestBorn: QWord;
begin
  Result := nil;
  AList := nil;
  BestBorn := High(QWord);
  for Key in FByOrigin.Keys do
  begin
    if (Key = AKey) or (BaseOfKey(Key) <> ABase) then
      Continue;
    L := FByOrigin[Key];
    for C in L do
    begin
      if C.ActiveStreams > 0 then
        Continue;
      if not FCreatedAt.TryGetValue(C.Key, Born) then
        Born := 0;
      if (Result = nil) or (Born < BestBorn) then
      begin
        Result := C;
        AList := L;
        BestBorn := Born;
      end;
    end;
  end;
end;

procedure TPoolState.Evict(const AList: TList<IPooledConnection>;
  const AConn: IPooledConnection);
begin
  AConn.Drain;                       // closes now, since it is idle
  FIdleSince.Remove(AConn.Key);
  FCreatedAt.Remove(AConn.Key);
  AList.Remove(AConn);
  Dec(FTotalConnections);
end;

function TPoolState.CanOpenNew(const AKey: string;
  const AEvict: Boolean): Boolean;
var
  Base: string;
  Victim: IPooledConnection;
  VictimList: TList<IPooledConnection>;
begin
  if FClosed then
    Exit(False);
  Base := BaseOfKey(AKey);
  Result := (CountForBase(Base) < FMaxConnectionsPerHost) and
            (FTotalConnections < FMaxTotalConnections);
  if Result then
    Exit;
  // a cap is reached: an idle connection of another identity to this origin
  // gives its slot to the new identity (the cap protects the server, so the
  // origin never holds more than the cap across identities)
  Victim := FindEvictable(AKey, Base, VictimList);
  if Victim = nil then
    Exit(False);
  if AEvict then
    Evict(VictimList, Victim);
  Result := True;
end;

function TPoolState.PickEligible(
  const AOrigin: string): IPooledConnection;
var
  L: TList<IPooledConnection>;
  I, Load, BestLoad: Integer;
  C, Best: IPooledConnection;
begin
  Best := nil;
  BestLoad := MaxInt;
  L := ListFor(AOrigin);
  for I := 0 to L.Count - 1 do
  begin
    C := L[I];
    if not C.Eligible then
      Continue;
    Load := C.ActiveStreams;
    if Load < BestLoad then
    begin
      BestLoad := Load;
      Best := C;
    end;
  end;
  Result := Best;
end;

procedure TPoolState.Close;
var
  Origin: string;
  L: TList<IPooledConnection>;
  C: IPooledConnection;
begin
  FLock.Acquire;
  try
    if FClosed then
      Exit;
    FClosed := True;
    for Origin in FByOrigin.Keys do
    begin
      L := FByOrigin[Origin];
      for C in L do
        C.Drain;
    end;
  finally
    FLock.Release;
  end;
end;

function TPoolState.Stats: TPoolStats;
var
  Origin: string;
  L: TList<IPooledConnection>;
  C: IPooledConnection;
  O: TOriginStats;
  D: TConnectionStats;
  Peer: TConnectionSettings;
  Now, T: QWord;
  Pending, I, J: Integer;
  Tmp: TOriginStats;

  procedure AddOrigin;
  begin
    Inc(Result.Connections, O.Connections);
    Inc(Result.IdleConnections, O.IdleConnections);
    Inc(Result.ActiveStreams, O.ActiveStreams);
    Inc(Result.PendingAcquires, O.PendingAcquires);
    SetLength(Result.PerOrigin, Length(Result.PerOrigin) + 1);
    Result.PerOrigin[High(Result.PerOrigin)] := O;
  end;

begin
  Result := Default(TPoolStats);
  FLock.Acquire;
  try
    Now := GetTickCount64;
    for Origin in FByOrigin.Keys do
    begin
      L := FByOrigin[Origin];
      if not FPending.TryGetValue(Origin, Pending) then
        Pending := 0;
      if (L.Count = 0) and (Pending = 0) then
        Continue;
      O := Default(TOriginStats);
      O.Origin := Origin;
      O.PendingAcquires := Pending;
      SetLength(O.Details, L.Count);
      for I := 0 to L.Count - 1 do
      begin
        C := L[I];
        D := Default(TConnectionStats);
        D.ActiveStreams := C.ActiveStreams;
        if C.Conn <> nil then
        begin
          if Pos('http://', Origin) = 1 then
            D.Protocol := npHttp2Cleartext
          else
            D.Protocol := npHttp2Tls;
          D.State := C.Conn.State;
          Peer := C.Conn.PeerSettings;
          D.PeerMaxConcurrentStreams := Peer.MaxConcurrentStreams;
          D.PeerInitialWindowSize := Peer.InitialWindowSize;
          D.PeerMaxFrameSize := Peer.MaxFrameSize;
        end
        else
        begin
          if Pos('http://', Origin) = 1 then
            D.Protocol := npHttp1Cleartext
          else
            D.Protocol := npHttp1Tls;
          if C.Closed then
            D.State := csClosed
          else
            D.State := csOpen;
        end;
        if FCreatedAt.TryGetValue(C.Key, T) then
          D.AgeMs := Int64(Now - T);
        if (D.ActiveStreams = 0) and FIdleSince.TryGetValue(C.Key, T) then
          D.IdleMs := Int64(Now - T);
        O.Details[I] := D;
        Inc(O.Connections);
        Inc(O.ActiveStreams, D.ActiveStreams);
        if (D.ActiveStreams = 0) and (D.State <> csClosed) then
          Inc(O.IdleConnections);
      end;
      AddOrigin;
    end;
    // a caller can be parked on an origin that holds no list yet
    for Origin in FPending.Keys do
      if not FByOrigin.ContainsKey(Origin) then
      begin
        O := Default(TOriginStats);
        O.Origin := Origin;
        O.PendingAcquires := FPending[Origin];
        AddOrigin;
      end;
  finally
    FLock.Release;
  end;
  // a stable order for the caller (insertion sort: a handful of origins)
  for I := 1 to High(Result.PerOrigin) do
  begin
    Tmp := Result.PerOrigin[I];
    J := I - 1;
    while (J >= 0) and (Result.PerOrigin[J].Origin > Tmp.Origin) do
    begin
      Result.PerOrigin[J + 1] := Result.PerOrigin[J];
      Dec(J);
    end;
    Result.PerOrigin[J + 1] := Tmp;
  end;
end;

function TPoolState.ConnectionCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FTotalConnections;
  finally
    FLock.Release;
  end;
end;

function TPoolState.ConnectionCountForOrigin(
  const AOrigin: string): Integer;
var
  L: TList<IPooledConnection>;
begin
  FLock.Acquire;
  try
    if FByOrigin.TryGetValue(AOrigin, L) then
      Result := L.Count
    else
      Result := 0;
  finally
    FLock.Release;
  end;
end;

function TPoolState.ActiveStreamsForOrigin(
  const AOrigin: string): TArray<Integer>;
var
  L: TList<IPooledConnection>;
  I: Integer;
begin
  Result := nil;
  FLock.Acquire;
  try
    if FByOrigin.TryGetValue(AOrigin, L) then
    begin
      SetLength(Result, L.Count);
      for I := 0 to L.Count - 1 do
        Result[I] := L[I].ActiveStreams;
    end;
  finally
    FLock.Release;
  end;
end;

function TPoolState.PickForTest(
  const AOrigin: string): IPooledConnection;
begin
  FLock.Acquire;
  try
    Result := PickEligible(AOrigin);
  finally
    FLock.Release;
  end;
end;

procedure TPoolState.AddForTest(const AOrigin: string;
  const AConn: IPooledConnection);
begin
  FLock.Acquire;
  try
    ListFor(AOrigin).Add(AConn);
    Inc(FTotalConnections);
    FCreatedAt.AddOrSetValue(AConn.Key, GetTickCount64);
  finally
    FLock.Release;
  end;
end;

{ THttpClient }

end.
