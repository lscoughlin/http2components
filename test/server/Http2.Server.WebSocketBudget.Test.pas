{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, budget, queued bytes, sessions, early bytes, test
notes:
  - This test checks the server-wide byte budget, the session cap and the early
    byte limit of the WebSocket sessions.
---
}
unit Http2.Server.WebSocketBudget.Test;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Hpack, Http2.Server.Seam, Http2.Server.Duplex, Http2.Server.StreamPool,
  Http2.Server.Limits, Http2.Server.Observer, Http2.Server.Sse.Test,
  Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.Session, Http2.Server.WebSocket.Environment,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Budget,
  Http2.Server.Http1.SocketChannel;

type
  /// a thread that adds and releases one octet many times
  TBudgetWorker = class(TThread)
  private
    FBudget: TWsByteBudget;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABudget: TWsByteBudget);
  end;

  /// a server with a budget of its own, for the tests of the sessions
  TCappedRig = class
  private
    FPool: TStreamPool;
    FRegistryObj: TChannelRegistry;
  public
    Registry: IChannelRegistry;
    Env: TWsEnvironment;
    EnvRef: IInterface;
    constructor Create(const AOptions: TWsOptions; const AMaxBytes: Int64;
      const AMaxSessions: Integer);
    destructor Destroy; override;
    function NewChannel: TFakeWsChannel;
  end;

  /// the owner of an HTTP/1.1 channel that records the aborts
  TAbortOwner = class(TInterfacedObject, IH1UpgradeOwner)
  public
    Aborts: Integer;
    procedure OwnerEmit(const AData: TBytes);
    function OwnerBacklog: Int64;
    procedure OwnerUpgradeHead(const AStatus: Integer; const AHeaders: THeaderBlock);
    procedure OwnerComplete(const AStatus: Integer; const AHeaders: THeaderBlock;
      const ABody: TBytes);
    procedure OwnerCloseAfterOutput;
    procedure OwnerAbort;
    procedure OwnerWatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
  end;

  TWsBudgetTest = class(TTestCase)
  private
    function QuickOptions: TWsOptions;
    function StartSession(const ARig: TCappedRig; const AHandler: IWsHandler): TFakeWsChannel;
    function WaitActivated(const AChannel: TFakeWsChannel): Boolean;
    function WaitCompleted(const AChannel: TFakeWsChannel): Boolean;
    function WaitSessions(const ABudget: TWsByteBudget; const ACount: Integer): Boolean;
    function WaitBytes(const ABudget: TWsByteBudget; const ACount: Int64): Boolean;
  published
    procedure TestAddAndRelease;
    procedure TestFailedAddChangesNothing;
    procedure TestTwoThreadsEndAtZero;
    procedure TestSessionsStopAtTheCap;
    procedure TestQueuedBytesCloseWith1008;
    procedure TestPeerCloseReturnsTheSlot;
    procedure TestProtocolErrorReturnsTheSlot;
    procedure TestPeerDropReturnsTheSlot;
    procedure TestRejectedInitReturnsTheSlot;
    procedure TestInitTimeoutReturnsTheSlot;
    procedure TestHandlerFailureReturnsTheSlot;
    procedure TestSessionCapRefusesWith503;
    procedure TestEarlyBytesOverTheLimitAbort;
    procedure TestEarlyBytesAtTheLimitWait;
  end;

implementation

{ TBudgetWorker }

constructor TBudgetWorker.Create(const ABudget: TWsByteBudget);
begin
  FBudget := ABudget;
  inherited Create(False);
end;

procedure TBudgetWorker.Execute;
var
  I: Integer;
begin
  for I := 1 to 100000 do
    if FBudget.TryAddBytes(1) then
      FBudget.ReleaseBytes(1);
end;

{ TCappedRig }

constructor TCappedRig.Create(const AOptions: TWsOptions; const AMaxBytes: Int64;
  const AMaxSessions: Integer);
begin
  inherited Create;
  FPool := TStreamPool.Create(1);
  FRegistryObj := TChannelRegistry.Create(100000, 262144, 65536);
  FRegistryObj.SourceProvider := FPool.NewSource;
  Registry := FRegistryObj;
  Env := TWsEnvironment.Create(AOptions, TMonotonicClock.Create, nil, AMaxBytes, AMaxSessions);
  EnvRef := Env;
  FRegistryObj.Environment := EnvRef;
end;

destructor TCappedRig.Destroy;
begin
  Env.Stop;
  FRegistryObj.SourceProvider := nil;
  FPool.Free;
  FRegistryObj.Environment := nil;
  EnvRef := nil;
  Registry := nil;
  inherited Destroy;
end;

function TCappedRig.NewChannel: TFakeWsChannel;
var
  Ch: IDuplexChannel;
begin
  Result := TFakeWsChannel.Create(Registry);
  Ch := Result;
  Registry.TryAcquire;
  Registry.Add(Ch);
end;

{ TAbortOwner }

procedure TAbortOwner.OwnerEmit(const AData: TBytes);
begin
end;

function TAbortOwner.OwnerBacklog: Int64;
begin
  Result := 0;
end;

procedure TAbortOwner.OwnerUpgradeHead(const AStatus: Integer; const AHeaders: THeaderBlock);
begin
end;

procedure TAbortOwner.OwnerComplete(const AStatus: Integer; const AHeaders: THeaderBlock;
  const ABody: TBytes);
begin
end;

procedure TAbortOwner.OwnerCloseAfterOutput;
begin
end;

procedure TAbortOwner.OwnerAbort;
begin
  Inc(Aborts);
end;

procedure TAbortOwner.OwnerWatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
begin
end;

{ TWsBudgetTest }

function TWsBudgetTest.QuickOptions: TWsOptions;
begin
  Result := TWsOptions.Create
    .WithPingIntervalMs(0)
    .WithCloseTimeoutMs(300)
    .WithInitTimeoutMs(5000);
end;

function TWsBudgetTest.StartSession(const ARig: TCappedRig;
  const AHandler: IWsHandler): TFakeWsChannel;
var
  Req: TFakeRequest;
  H: TFakeHandshake;
begin
  Result := ARig.NewChannel;
  Req := TFakeRequest.Create;
  H := TFakeHandshake.Create;
  WsStartSession(Result, Req, AHandler, H, nil);
end;

function TWsBudgetTest.WaitActivated(const AChannel: TFakeWsChannel): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to 500 do
  begin
    if AChannel.Activated then
      Exit(True);
    Sleep(10);
  end;
end;

function TWsBudgetTest.WaitCompleted(const AChannel: TFakeWsChannel): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to 500 do
  begin
    if AChannel.Completed then
      Exit(True);
    Sleep(10);
  end;
end;

function TWsBudgetTest.WaitSessions(const ABudget: TWsByteBudget;
  const ACount: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to 500 do
  begin
    if ABudget.Sessions = ACount then
      Exit(True);
    Sleep(10);
  end;
end;

function TWsBudgetTest.WaitBytes(const ABudget: TWsByteBudget; const ACount: Int64): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to 500 do
  begin
    if ABudget.Bytes = ACount then
      Exit(True);
    Sleep(10);
  end;
end;

procedure TWsBudgetTest.TestAddAndRelease;
var
  Budget: TWsByteBudget;
begin
  Budget := TWsByteBudget.Create(1000, 10);
  try
    AssertTrue('the first add fits', Budget.TryAddBytes(400));
    AssertTrue('the second add fits', Budget.TryAddBytes(600));
    AssertEquals('the total is the sum', Int64(1000), Budget.Bytes);
    Budget.ReleaseBytes(400);
    AssertEquals('the release subtracts', Int64(600), Budget.Bytes);
  finally
    Budget.Free;
  end;
end;

procedure TWsBudgetTest.TestFailedAddChangesNothing;
var
  Budget: TWsByteBudget;
begin
  Budget := TWsByteBudget.Create(1000, 10);
  try
    AssertTrue('the add of 900 fits', Budget.TryAddBytes(900));
    AssertFalse('the add of 200 passes the maximum', Budget.TryAddBytes(200));
    AssertEquals('a failed add leaves the total', Int64(900), Budget.Bytes);
    AssertTrue('an add up to the maximum passes', Budget.TryAddBytes(100));
    AssertEquals('the total is the maximum', Int64(1000), Budget.Bytes);
  finally
    Budget.Free;
  end;
end;

procedure TWsBudgetTest.TestTwoThreadsEndAtZero;
var
  Budget: TWsByteBudget;
  A, B: TBudgetWorker;
begin
  Budget := TWsByteBudget.Create(1000000, 10);
  try
    A := TBudgetWorker.Create(Budget);
    B := TBudgetWorker.Create(Budget);
    try
      A.WaitFor;
      B.WaitFor;
    finally
      A.Free;
      B.Free;
    end;
    AssertEquals('every add has its release', Int64(0), Budget.Bytes);
  finally
    Budget.Free;
  end;
end;

procedure TWsBudgetTest.TestSessionsStopAtTheCap;
var
  Budget: TWsByteBudget;
  I: Integer;
begin
  Budget := TWsByteBudget.Create(1000, 3);
  try
    for I := 1 to 3 do
      AssertTrue('session ' + IntToStr(I) + ' is admitted', Budget.TryOpenSession);
    AssertFalse('session 4 is refused', Budget.TryOpenSession);
    AssertEquals('a refused session is not counted', 3, Budget.Sessions);
    Budget.CloseSession;
    AssertEquals('a closed session leaves the count', 2, Budget.Sessions);
    AssertTrue('a freed slot is admitted', Budget.TryOpenSession);
  finally
    Budget.Free;
  end;
end;

procedure TWsBudgetTest.TestQueuedBytesCloseWith1008;
var
  Rig: TCappedRig;
  Budget: TWsByteBudget;
  Gate: PRTLEvent;
  H, H2: TRecordingHandler;
  Ch, Ch2: TFakeWsChannel;
  Sent: TBytes;
  I: Integer;
  Found: Boolean;
begin
  Rig := TCappedRig.Create(QuickOptions, 4096, 0);
  Gate := RTLEventCreate;
  try
    Budget := Rig.Env.Budget;
    H := TRecordingHandler.Create;
    H.Gate := Gate;
    Ch := StartSession(Rig, H);
    AssertTrue('the session opens', WaitActivated(Ch));
    // the first message waits in the handler, and its octets stay in the budget
    Ch.Deliver(ClientText(StringOfChar('a', 3000)));
    AssertTrue('the first message is counted', WaitBytes(Budget, 3000));
    // the second message would pass 4096 octets: the session closes with 1008
    Ch.Deliver(ClientText(StringOfChar('b', 3000)));
    AssertTrue('the session ends', WaitSessions(Budget, 0));
    Sent := Ch.SentBytes;
    Found := False;
    for I := 0 to High(Sent) - 3 do
      if (Sent[I] = $88) and (Sent[I + 2] = $03) and (Sent[I + 3] = $F0) then
        Found := True;
    AssertTrue('the session closes with 1008', Found);
    AssertEquals('the end gives back the octets that wait', Int64(0), Budget.Bytes);
    // the handler finishes the first message: nothing is given back twice
    RTLEventSetEvent(Gate);
    AssertTrue('the budget stays at zero', WaitBytes(Budget, 0));
    // another session of the same server is not affected
    H2 := TRecordingHandler.Create;
    Ch2 := StartSession(Rig, H2);
    AssertTrue('the other session opens', WaitActivated(Ch2));
    Ch2.Deliver(ClientText('small'));
    AssertTrue('the other session stays open', not Ch2.IsClosed);
    AssertEquals('the other session is counted', 1, Budget.Sessions);
  finally
    RTLEventSetEvent(Gate);
    RTLEventDestroy(Gate);
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestPeerCloseReturnsTheSlot;
var
  Rig: TCappedRig;
  Ch: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions, High(Int64), 1);
  try
    Ch := StartSession(Rig, TRecordingHandler.Create);
    AssertTrue('the session opens', WaitActivated(Ch));
    AssertEquals('the session holds the slot', 1, Rig.Env.Budget.Sessions);
    Ch.Deliver(ClientClose(WsCloseNormal));
    AssertTrue('a peer Close returns the slot', WaitSessions(Rig.Env.Budget, 0));
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestProtocolErrorReturnsTheSlot;
var
  Rig: TCappedRig;
  Ch: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions, High(Int64), 1);
  try
    Ch := StartSession(Rig, TRecordingHandler.Create);
    AssertTrue('the session opens', WaitActivated(Ch));
    // opcode 3 is reserved: the session fails the connection
    Ch.Deliver(ClientFrame(3, True, BytesOf('x')));
    AssertTrue('a protocol error returns the slot', WaitSessions(Rig.Env.Budget, 0));
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestPeerDropReturnsTheSlot;
var
  Rig: TCappedRig;
  Ch: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions, High(Int64), 1);
  try
    Ch := StartSession(Rig, TRecordingHandler.Create);
    AssertTrue('the session opens', WaitActivated(Ch));
    Ch.DeliverPeerClosed(False);
    AssertTrue('a dropped peer returns the slot', WaitSessions(Rig.Env.Budget, 0));
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestRejectedInitReturnsTheSlot;
var
  Rig: TCappedRig;
  H: TRecordingHandler;
  Ch: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions, High(Int64), 1);
  try
    H := TRecordingHandler.Create;
    H.InitResult := TWsInitResult.Rejected(403);
    Ch := StartSession(Rig, H);
    AssertTrue('the upgrade is answered', WaitCompleted(Ch));
    AssertEquals('Init refused with 403', 403, Ch.CompletedStatus);
    AssertEquals('a refused Init returns the slot', 0, Rig.Env.Budget.Sessions);
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestInitTimeoutReturnsTheSlot;
var
  Rig: TCappedRig;
  H: TRecordingHandler;
  Ch: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions.WithInitTimeoutMs(100), High(Int64), 1);
  try
    H := TRecordingHandler.Create;
    H.InitSleepMs := 800;
    Ch := StartSession(Rig, H);
    AssertTrue('the upgrade is answered', WaitCompleted(Ch));
    AssertEquals('the time limit answers 503', 503, Ch.CompletedStatus);
    AssertEquals('the time limit returns the slot', 0, Rig.Env.Budget.Sessions);
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestHandlerFailureReturnsTheSlot;
var
  Rig: TCappedRig;
  H: TRecordingHandler;
  Ch: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions, High(Int64), 1);
  try
    H := TRecordingHandler.Create;
    H.MessageRaises := True;
    Ch := StartSession(Rig, H);
    AssertTrue('the session opens', WaitActivated(Ch));
    Ch.Deliver(ClientText('boom'));
    AssertTrue('a failed handler returns the slot', WaitSessions(Rig.Env.Budget, 0));
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestSessionCapRefusesWith503;
var
  Rig: TCappedRig;
  Ch1, Ch2, Ch3: TFakeWsChannel;
begin
  Rig := TCappedRig.Create(QuickOptions, High(Int64), 1);
  try
    Ch1 := StartSession(Rig, TRecordingHandler.Create);
    AssertTrue('the first session opens', WaitActivated(Ch1));
    Ch2 := StartSession(Rig, TRecordingHandler.Create);
    AssertTrue('the second session is answered', WaitCompleted(Ch2));
    AssertEquals('the second session gets 503', 503, Ch2.CompletedStatus);
    AssertEquals('the refused session is not counted', 1, Rig.Env.Budget.Sessions);
    Ch1.Deliver(ClientClose(WsCloseNormal));
    AssertTrue('the first session ends', WaitSessions(Rig.Env.Budget, 0));
    Ch3 := StartSession(Rig, TRecordingHandler.Create);
    AssertTrue('a freed slot admits a session', WaitActivated(Ch3));
  finally
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestEarlyBytesOverTheLimitAbort;
var
  Rig: TCappedRig;
  Owner: TAbortOwner;
  OwnerRef: IH1UpgradeOwner;
  Ch: TH1SocketChannel;
  ChRef: IDuplexChannel;
  Data: TBytes;
begin
  Rig := TCappedRig.Create(QuickOptions.WithWsEarlyBytes(4096), High(Int64), 0);
  Owner := TAbortOwner.Create;
  OwnerRef := Owner;
  Ch := TH1SocketChannel.Create(OwnerRef, Rig.Registry);
  ChRef := Ch;
  Rig.Registry.TryAcquire;
  Rig.Registry.Add(ChRef);
  try
    SetLength(Data, 4097);
    Ch.Inbound(Data[0], Length(Data));
    AssertEquals('the octets past the limit abort the connection', 1, Owner.Aborts);
    AssertTrue('the channel is closed', ChRef.State = csClosed);
  finally
    ChRef := nil;
    Ch := nil;
    OwnerRef := nil;
    Rig.Free;
  end;
end;

procedure TWsBudgetTest.TestEarlyBytesAtTheLimitWait;
var
  Rig: TCappedRig;
  Owner: TAbortOwner;
  OwnerRef: IH1UpgradeOwner;
  Ch: TH1SocketChannel;
  ChRef: IDuplexChannel;
  Data: TBytes;
begin
  Rig := TCappedRig.Create(QuickOptions.WithWsEarlyBytes(4096), High(Int64), 0);
  Owner := TAbortOwner.Create;
  OwnerRef := Owner;
  Ch := TH1SocketChannel.Create(OwnerRef, Rig.Registry);
  ChRef := Ch;
  Rig.Registry.TryAcquire;
  Rig.Registry.Add(ChRef);
  try
    SetLength(Data, 4096);
    Ch.Inbound(Data[0], Length(Data));
    AssertEquals('the octets up to the limit wait', 0, Owner.Aborts);
    AssertTrue('the channel stays open', ChRef.State <> csClosed);
  finally
    ChRef := nil;
    Ch := nil;
    OwnerRef := nil;
    Rig.Free;
  end;
end;

initialization
  RegisterTest(TWsBudgetTest);

end.
