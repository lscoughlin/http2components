{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, pool, tunnel, websocket, extended connect
notes:
  - this tests AcquireTunnel of the pool: the outcome of each answer, one dial for
    several tunnels, the stream slot of a tunnel, and the rule that a tunnel never
    uses the h2c Upgrade
  - the mock sockets answer every request HEADERS, so the tunnel answer and the
    ordinary answer of the same connection are scripted by the factory
---
}
unit Http2.Client.Pool.Tunnel.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers,
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream,
  Http2.Client.Stream.Types, Http2.Client.Messages, Http2.Client.Pool,
  Http2.Client.Pool.Types, Http2.Client.Tunnel.Types, Http2.Client.WebSocket,
  Http2.Client.WebSocket.H2Handshake, Http2.Client.SocketFactory.Types,
  Http2.Client.MockSocket.Support;

type
  /// hands out a mock socket per dial. A cleartext dial gets the protocol of
  /// the test. An HTTP/2 socket answers the request HEADERS with the answer of
  /// the test and sends SETTINGS with the extended CONNECT setting when AConnect.
  TTunnelFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FProtocol: TNegotiatedProtocol;
    FConnect: Boolean;
    FStatus: string;
    FBody: TBytes;
    FEndStream: Boolean;
    FSockets: TList<IHttp2Socket>;
    FDials: Integer;
  public
    constructor Create(const AProtocol: TNegotiatedProtocol;
      const AConnect: Boolean; const AStatus: string; const ABody: TBytes;
      const AEndStream: Boolean);
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    /// the number of dials so far
    function Dials: Integer;
    /// the socket of the dial AIndex (0 is the first)
    function SocketAt(const AIndex: Integer): TMockSocket;
  end;

  TPoolTunnelTest = class(TTestCase)
  private
    FPool: TConnectionPool;
    FFactory: TTunnelFactory;
    /// keeps the factory (and its sockets) alive after the pool is freed
    FFactoryRef: IHttp2SocketFactory;
    procedure Build(const AProtocol: TNegotiatedProtocol; const AConnect: Boolean;
      const AStatus: string; const ABody: TBytes; const AEndStream: Boolean;
      const APolicy: TClearTextPolicy;
      const AMaxConnectionsPerHost, AMaxStreams: Integer);
    function OpenTunnel(out AOutcome: TTunnelOutcome; out AStatus: Integer;
      out ABody: string): IH2Tunnel;
    /// the pool key of the test origin for APolicy (no identity, no fallback)
    function PoolKey(const APolicy: TClearTextPolicy): string;
    /// wait up to ATimeoutMs until the socket of dial 0 wrote RST_STREAM for AStreamId
    function WaitForRst(const AStreamId: LongWord; const ATimeoutMs: Integer): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestAnswer200GivesTheTunnel;
    procedure TestRefusalGivesTheStatusAndTheBody;
    procedure TestPeerWithoutExtendedConnectGivesItsOutcome;
    procedure TestTwoTunnelsShareOneConnection;
    procedure TestTunnelAndRequestShareOneConnection;
    procedure TestReleasedTunnelFreesItsStreamSlot;
    procedure TestHttp1SocketGivesNilAndWritesNoUpgrade;
    procedure TestUpgradePolicyTurnsAnHttp2ConnectionIntoHttp1;
    procedure TestTunnelSendsAndReadsTheStream;
    procedure TestTunnelKeepsItsConnectionAfterThePoolIsFreed;
  end;

implementation

const
  cOrigin = 'http://tunnel.test:80';
  cHost = 'tunnel.test';
  cPort = 80;
  cWaitMs = 5000;

/// the octets of an ASCII text (one octet per character)
function ToBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

{ TTunnelFactory }

constructor TTunnelFactory.Create(const AProtocol: TNegotiatedProtocol;
  const AConnect: Boolean; const AStatus: string; const ABody: TBytes;
  const AEndStream: Boolean);
begin
  inherited Create;
  FProtocol := AProtocol;
  FConnect := AConnect;
  FStatus := AStatus;
  FBody := ABody;
  FEndStream := AEndStream;
  FSockets := TList<IHttp2Socket>.Create;
end;

destructor TTunnelFactory.Destroy;
begin
  FSockets.Free;
  inherited Destroy;
end;

function TTunnelFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  S: TMockSocket;
  Settings: TConnectionSettings;
begin
  S := TMockSocket.Create;
  S.AutoRespondToRequestHeaders(FStatus, FBody, FEndStream);
  Settings := TConnectionSettings.Defaults;
  Settings.EnableConnectProtocol := FConnect;
  S.EnqueueSettings(Settings);
  FSockets.Add(S);
  Inc(FDials);
  Result := S;
end;

function TTunnelFactory.DialProtocol(const AHost: string; const APort: Word;
  const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  S: TMockSocket;
begin
  AProtocol := FProtocol;
  if FProtocol = npHttp1Cleartext then
  begin
    // an HTTP/1.1 socket answers nothing by itself: the test writes no request
    S := TMockSocket.Create;
    FSockets.Add(S);
    Inc(FDials);
    Result := S;
  end
  else
    Result := Dial(AHost, APort, ATimeoutMs);
end;

function TTunnelFactory.Dials: Integer;
begin
  Result := FDials;
end;

function TTunnelFactory.SocketAt(const AIndex: Integer): TMockSocket;
begin
  Result := FSockets[AIndex] as TMockSocket;
end;

{ TPoolTunnelTest }

procedure TPoolTunnelTest.Build(const AProtocol: TNegotiatedProtocol;
  const AConnect: Boolean; const AStatus: string; const ABody: TBytes;
  const AEndStream: Boolean; const APolicy: TClearTextPolicy;
  const AMaxConnectionsPerHost, AMaxStreams: Integer);
begin
  FFactory := TTunnelFactory.Create(AProtocol, AConnect, AStatus, ABody,
    AEndStream);
  FFactoryRef := FFactory;
  FPool := TConnectionPool.Create(FFactory, AMaxConnectionsPerHost, 4,
    AMaxStreams, 1000, 1000, 0, nil, False, APolicy);
end;

function TPoolTunnelTest.PoolKey(const APolicy: TClearTextPolicy): string;
begin
  Result := cOrigin + ' tls= protocol=0:' + IntToStr(Ord(APolicy));
end;

function TPoolTunnelTest.WaitForRst(const AStreamId: LongWord;
  const ATimeoutMs: Integer): Boolean;
var
  Frames: TArray<TFrame>;
  I, Waited: Integer;
begin
  Result := False;
  Waited := 0;
  while (not Result) and (Waited <= ATimeoutMs) do
  begin
    Frames := FFactory.SocketAt(0).OutboundFrames(True);
    for I := 0 to High(Frames) do
      if (Frames[I].Header.FrameType = ftRstStream) and
        (Frames[I].Header.StreamId = AStreamId) then
        Result := True;
    if not Result then
    begin
      Sleep(5);
      Inc(Waited, 5);
    end;
  end;
end;

function TPoolTunnelTest.OpenTunnel(out AOutcome: TTunnelOutcome;
  out AStatus: Integer; out ABody: string): IH2Tunnel;
var
  Fields: TArray<TWsHeaderField>;
begin
  Result := FPool.AcquireTunnel(cOrigin, cHost, cPort,
    WsBuildH2Request(False, '/chat', cHost, nil, nil), cWaitMs, nil, nil,
    AOutcome, AStatus, Fields, ABody);
end;

procedure TPoolTunnelTest.TearDown;
begin
  FreeAndNil(FPool);
  FFactory := nil;
  FFactoryRef := nil;
  inherited TearDown;
end;

procedure TPoolTunnelTest.TestAnswer200GivesTheTunnel;
var
  T: IH2Tunnel;
  Outcome: TTunnelOutcome;
  Status: Integer;
  Body: string;
begin
  Build(npHttp2Cleartext, True, '200', nil, False, ctPriorKnowledge, 1, 8);
  T := OpenTunnel(Outcome, Status, Body);
  AssertEquals('the outcome is a tunnel', Ord(toTunnel), Ord(Outcome));
  AssertEquals('the status is 200', 200, Status);
  AssertTrue('the result is the tunnel', T <> nil);
  AssertFalse('the tunnel is open', T.IsEnded);
  AssertEquals('one dial', 1, FFactory.Dials);
  T.Release;
end;

procedure TPoolTunnelTest.TestRefusalGivesTheStatusAndTheBody;
var
  T: IH2Tunnel;
  Outcome: TTunnelOutcome;
  Status: Integer;
  Body: string;
  Counts: TArray<Integer>;
begin
  Build(npHttp2Cleartext, True, '404', ToBytes('nope'), True,
    ctPriorKnowledge, 1, 8);
  T := OpenTunnel(Outcome, Status, Body);
  AssertEquals('the outcome is a refusal', Ord(toRefused), Ord(Outcome));
  AssertEquals('the status is the refused status', 404, Status);
  AssertEquals('the body is kept', 'nope', Body);
  AssertTrue('there is no tunnel', T = nil);
  AssertEquals('the connection stays in the pool', 1, FPool.ConnectionCount);
  // the request never sent END_STREAM: the refused stream is reset, and no stream stays open
  AssertTrue('the refused stream gets RST_STREAM', WaitForRst(1, 2000));
  Counts := FPool.ActiveStreamsForOrigin(PoolKey(ctPriorKnowledge));
  AssertEquals('one connection for the origin', 1, Length(Counts));
  AssertEquals('no stream stays open', 0, Counts[0]);
end;

procedure TPoolTunnelTest.TestPeerWithoutExtendedConnectGivesItsOutcome;
var
  T: IH2Tunnel;
  Outcome: TTunnelOutcome;
  Status: Integer;
  Body: string;
begin
  Build(npHttp2Cleartext, False, '200', nil, False, ctPriorKnowledge, 1, 8);
  T := OpenTunnel(Outcome, Status, Body);
  AssertEquals('the outcome says no extended CONNECT',
    Ord(toNoExtendedConnect), Ord(Outcome));
  AssertTrue('there is no tunnel', T = nil);
  AssertEquals('the connection stays in the pool', 1, FPool.ConnectionCount);
end;

procedure TPoolTunnelTest.TestTwoTunnelsShareOneConnection;
var
  T1, T2: IH2Tunnel;
  O1, O2: TTunnelOutcome;
  S1, S2: Integer;
  B1, B2: string;
begin
  Build(npHttp2Cleartext, True, '200', nil, False, ctPriorKnowledge, 1, 8);
  T1 := OpenTunnel(O1, S1, B1);
  T2 := OpenTunnel(O2, S2, B2);
  AssertEquals('the first is a tunnel', Ord(toTunnel), Ord(O1));
  AssertEquals('the second is a tunnel', Ord(toTunnel), Ord(O2));
  AssertTrue('both tunnels exist', (T1 <> nil) and (T2 <> nil));
  AssertEquals('one dial for both', 1, FFactory.Dials);
  AssertEquals('one connection in the pool', 1, FPool.ConnectionCount);
  T1.Release;
  T2.Release;
end;

procedure TPoolTunnelTest.TestTunnelAndRequestShareOneConnection;
var
  T: IH2Tunnel;
  O: TTunnelOutcome;
  S: Integer;
  B: string;
  Req: TStreamRequest;
  Resp: IHttpResponse;
begin
  Build(npHttp2Cleartext, True, '200', nil, False, ctPriorKnowledge, 1, 8);
  T := OpenTunnel(O, S, B);
  AssertEquals('the tunnel is open', Ord(toTunnel), Ord(O));
  Req := TStreamRequest.Create('GET', cHost).WithScheme('http');
  Resp := FPool.Acquire(cOrigin, cHost, cPort, Req, cWaitMs);
  AssertEquals('the ordinary request gets its answer', 200, Resp.StatusCode);
  AssertEquals('one dial for both', 1, FFactory.Dials);
  T.Release;
end;

procedure TPoolTunnelTest.TestReleasedTunnelFreesItsStreamSlot;
var
  T1, T2: IH2Tunnel;
  O1, O2: TTunnelOutcome;
  S1, S2: Integer;
  B1, B2: string;
  Fields: TArray<TWsHeaderField>;
  Raised: Boolean;
begin
  // one stream per connection and one connection per host: the tunnel holds the slot
  Build(npHttp2Cleartext, True, '200', nil, False, ctPriorKnowledge, 1, 1);
  T1 := OpenTunnel(O1, S1, B1);
  AssertEquals('the first tunnel is open', Ord(toTunnel), Ord(O1));
  Raised := False;
  try
    FPool.AcquireTunnel(cOrigin, cHost, cPort,
      WsBuildH2Request(False, '/chat', cHost, nil, nil), 300, nil, nil,
      O2, S2, Fields, B2);
  except
    on EHttpTimeout do
      Raised := True;
  end;
  AssertTrue('a second tunnel waits for the slot and times out', Raised);
  T1.Release;
  T2 := OpenTunnel(O2, S2, B2);
  AssertEquals('after the release the slot is free', Ord(toTunnel), Ord(O2));
  AssertTrue('the second tunnel exists', T2 <> nil);
  AssertEquals('still one dial', 1, FFactory.Dials);
  T2.Release;
end;

procedure TPoolTunnelTest.TestHttp1SocketGivesNilAndWritesNoUpgrade;
var
  T: IH2Tunnel;
  Outcome: TTunnelOutcome;
  Status: Integer;
  Body: string;
begin
  // the policy asks for the h2c Upgrade: a tunnel must not send the probe
  Build(npHttp1Cleartext, False, '200', nil, False, ctUpgrade, 1, 8);
  T := OpenTunnel(Outcome, Status, Body);
  AssertEquals('the connection speaks HTTP/1.1', Ord(toHttp1), Ord(Outcome));
  AssertTrue('there is no tunnel', T = nil);
  AssertEquals('the socket got no bytes', 0,
    Length(FFactory.SocketAt(0).WrittenBytes));
  AssertEquals('the connection stays in the pool', 1, FPool.ConnectionCount);
end;

procedure TPoolTunnelTest.TestTunnelSendsAndReadsTheStream;
var
  T: IH2Tunnel;
  O: TTunnelOutcome;
  S: Integer;
  B: string;
  Buf: array[0..15] of Byte;
  N: Integer;
  Got: string;
begin
  Build(npHttp2Cleartext, True, '200', ToBytes('hello'), False,
    ctPriorKnowledge, 1, 8);
  T := OpenTunnel(O, S, B);
  AssertEquals('the tunnel is open', Ord(toTunnel), Ord(O));
  T.SendData(ToBytes('ping'));
  N := T.ReadSome(Buf, SizeOf(Buf), 1000);
  AssertEquals('the five octets of the answer arrive', 5, N);
  SetString(Got, PAnsiChar(@Buf[0]), N);
  AssertEquals('the octets are the answer', 'hello', Got);
  // the poll of the request (100 ms) finds nothing more: -1, not an error
  N := T.ReadSome(Buf, SizeOf(Buf), 100);
  AssertEquals('an empty poll gives -1', -1, N);
  AssertFalse('an empty poll does not end the tunnel', T.IsEnded);
  T.Release;
end;

procedure TPoolTunnelTest.TestUpgradePolicyTurnsAnHttp2ConnectionIntoHttp1;
var
  T: IH2Tunnel;
  Outcome: TTunnelOutcome;
  Status: Integer;
  Body: string;
begin
  // the dial gives HTTP/2 under the Upgrade policy: a WebSocket still speaks HTTP/1.1 (D3)
  Build(npHttp2Cleartext, True, '200', nil, False, ctUpgrade, 1, 8);
  T := OpenTunnel(Outcome, Status, Body);
  AssertEquals('the outcome is HTTP/1.1', Ord(toHttp1), Ord(Outcome));
  AssertTrue('there is no tunnel', T = nil);
end;

procedure TPoolTunnelTest.TestTunnelKeepsItsConnectionAfterThePoolIsFreed;
var
  T: IH2Tunnel;
  Outcome: TTunnelOutcome;
  Status: Integer;
  Body: string;
begin
  Build(npHttp2Cleartext, True, '200', nil, False, ctPriorKnowledge, 1, 8);
  T := OpenTunnel(Outcome, Status, Body);
  AssertEquals('the tunnel is open', Ord(toTunnel), Ord(Outcome));
  FreeAndNil(FPool);
  AssertFalse('the tunnel is open after the pool is freed', T.IsEnded);
  AssertTrue('the connection stays open while the tunnel lives',
    FFactory.SocketAt(0).GetConnected);
  T.Release;
  AssertFalse('the release closes the drained connection',
    FFactory.SocketAt(0).GetConnected);
  T := nil;
end;

initialization
  RegisterTest(TPoolTunnelTest);

end.
