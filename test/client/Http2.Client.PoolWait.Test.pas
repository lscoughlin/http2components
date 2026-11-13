{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, pool, dial, wait
notes:
  - this tests that a caller that waits for a dial of its origin waits on an
    event and not in a polling loop
  - the wait seam PoolWaitHook of the pool state unit replaces the wait of one
    slice, so the tests decide when a slice ends
---
}
unit Http2.Client.PoolWait.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client, Http2.Client.Core, Http2.Client.Pool.State,
  Http2.Client.ClearText.Support, Http2.Client.PoolDial.Test;

type
  /// a socket factory whose dials each wait for one release from the test;
  /// the first FailDials dials fail after the release, the others succeed
  TStepDialFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FLock: TCriticalSection;
    FStep: TEvent;
    FStarted: Integer;
    FInFlight: Integer;
    FMaxInFlight: Integer;
    FFailDials: Integer;
    FSockets: TList<IHttp2Socket>;
  public
    constructor Create(const AFailDials: Integer);
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    /// lets one blocked dial go on
    procedure Release;
    function Started: Integer;
    function MaxInFlight: Integer;
  end;

  /// a sender whose wait slices the test ends by hand (see TickHook)
  TTickSender = class(TDialSender)
  public
    Tick: PRTLEvent;
    Entries: Integer;
    constructor Create(const AClient: IHttpClient; const AUrl: string;
      const AToken: ICancellationToken = nil);
    destructor Destroy; override;
  end;

  TPoolWaitTest = class(TTestCase)
  private
    function Build(const AFactory: IHttp2SocketFactory): IHttpClient;
    procedure Pump(const AFactory: TStepDialFactory;
      const ASenders: array of TDialSender);
  protected
    procedure TearDown; override;
  published
    procedure TestWaitersEndTheirSlicesByHandAndDoNotPoll;
    procedure TestEachFailedDialChangesTheGenerationAndWakesTheWaiters;
    procedure TestCancelTokenStopsAWaiterWhileTheDialIsBlocked;
    procedure TestFailedDialWakesTheWaitersAndOneDialsAgain;
  end;

implementation

const
  cOneResponse = 'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello';
  cThreads = 20;
  cPollMs = 10000;

var
  GEntries: Integer;
  GGeneration: Cardinal;

{ the hook of the tests that end a slice by hand: the sender thread counts its
  entry and waits for its own tick }
procedure TickHook(const ADial: TOriginDial; const ASliceMs: Integer);
var
  T: TThread;
begin
  T := TThread.CurrentThread;
  if T is TTickSender then
  begin
    InterlockedIncrement(TTickSender(T).Entries);
    RTLEventWaitFor(TTickSender(T).Tick, 30000);
  end
  else
    RTLEventWaitFor(ADial.Event, ASliceMs);
end;

{ the hook of the tests that wake by the real event: the wait ends only when
  the pool sets the event }
procedure EventHook(const ADial: TOriginDial; const ASliceMs: Integer);
begin
  InterlockedExchange(GGeneration, ADial.Generation);
  InterlockedIncrement(GEntries);
  RTLEventWaitFor(ADial.Event, 30000);
end;

{ TStepDialFactory }

constructor TStepDialFactory.Create(const AFailDials: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FStep := TEvent.Create(nil, False, False, '');
  FSockets := TList<IHttp2Socket>.Create;
  FFailDials := AFailDials;
end;

destructor TStepDialFactory.Destroy;
begin
  FSockets.Free;
  FStep.Free;
  FLock.Free;
  inherited Destroy;
end;

function TStepDialFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  P: TNegotiatedProtocol;
begin
  Result := DialProtocol(AHost, APort, 'https', True, ctReject, ATimeoutMs, P);
end;

function TStepDialFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  S: TScriptSocket;
  Index, I: Integer;
begin
  AProtocol := npHttp1Tls;
  FLock.Acquire;
  try
    Inc(FStarted);
    Index := FStarted;
    Inc(FInFlight);
    if FInFlight > FMaxInFlight then
      FMaxInFlight := FInFlight;
  finally
    FLock.Release;
  end;
  try
    FStep.WaitFor(30000);
    if Index <= FFailDials then
      raise EHttpConnectionError.Create('scripted dial failure');
    S := TScriptSocket.Create;
    for I := 1 to cThreads do
      S.Feed(cOneResponse);
    Result := S;
    FLock.Acquire;
    try
      FSockets.Add(Result);
    finally
      FLock.Release;
    end;
  finally
    FLock.Acquire;
    try
      Dec(FInFlight);
    finally
      FLock.Release;
    end;
  end;
end;

procedure TStepDialFactory.Release;
begin
  FStep.SetEvent;
end;

function TStepDialFactory.Started: Integer;
begin
  FLock.Acquire;
  try
    Result := FStarted;
  finally
    FLock.Release;
  end;
end;

function TStepDialFactory.MaxInFlight: Integer;
begin
  FLock.Acquire;
  try
    Result := FMaxInFlight;
  finally
    FLock.Release;
  end;
end;

{ TTickSender }

constructor TTickSender.Create(const AClient: IHttpClient;
  const AUrl: string; const AToken: ICancellationToken);
begin
  // the thread starts in the inherited constructor, so the tick exists first
  Tick := RTLEventCreate;
  inherited Create(AClient, AUrl, AToken);
end;

destructor TTickSender.Destroy;
begin
  inherited Destroy;
  RTLEventDestroy(Tick);
end;

{ TPoolWaitTest }

function TPoolWaitTest.Build(const AFactory: IHttp2SocketFactory): IHttpClient;
begin
  Result := THttpClientFactory.Create
    .WithSocketFactory(AFactory)
    .WithHttp1Fallback
    .WithMaxConnectionsPerHost(4)
    .WithMaxTotalConnections(8)
    .WithConnectTimeout(30000).WithHeaderTimeout(30000)
    .Build;
end;

procedure TPoolWaitTest.TearDown;
begin
  PoolWaitHook := nil;
  inherited TearDown;
end;

{ releases the dials one by one until every sender is done }
procedure TPoolWaitTest.Pump(const AFactory: TStepDialFactory;
  const ASenders: array of TDialSender);
var
  Limit: QWord;
  Released, I: Integer;
  All: Boolean;
begin
  Limit := GetTickCount64 + cPollMs;
  Released := 0;
  repeat
    All := True;
    for I := 0 to High(ASenders) do
      if not ASenders[I].WaitDone(0) then
        All := False;
    if not All then
      if AFactory.Started > Released then
      begin
        AFactory.Release;
        Inc(Released);
      end
      else
        Sleep(1);
  until All or (GetTickCount64 > Limit);
  AssertTrue('every sender ended', All);
end;

procedure TPoolWaitTest.TestWaitersEndTheirSlicesByHandAndDoNotPoll;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  W: array[0..cThreads - 1] of TTickSender;
  I, Slice, Waiting: Integer;
  Limit: QWord;
  All: Boolean;
begin
  PoolWaitHook := TickHook;
  Factory := TBlockingDialFactory.Create;
  Client := Build(Factory);
  for I := 0 to cThreads - 1 do
    W[I] := nil;
  try
    W[0] := TTickSender.Create(Client, 'https://slow.test/x');
    AssertTrue('the dial started', Factory.WaitStarted(cPollMs));
    for I := 1 to cThreads - 1 do
      W[I] := TTickSender.Create(Client, 'https://slow.test/x');
    // the 19 other callers enter the wait once
    Limit := GetTickCount64 + cPollMs;
    repeat
      Waiting := 0;
      for I := 0 to cThreads - 1 do
        if W[I].Entries > 0 then
          Inc(Waiting);
      if Waiting < cThreads - 1 then
        Sleep(1);
    until (Waiting >= cThreads - 1) or (GetTickCount64 > Limit);
    AssertEquals('every other caller waits', cThreads - 1, Waiting);
    // three slices end by hand, with the gate closed
    for Slice := 1 to 3 do
    begin
      for I := 0 to cThreads - 1 do
        if W[I].Entries > 0 then
          RTLEventSetEvent(W[I].Tick);
      Limit := GetTickCount64 + cPollMs;
      repeat
        All := True;
        for I := 0 to cThreads - 1 do
          if (W[I].Entries > 0) and (W[I].Entries < 1 + Slice) then
            All := False;
        if not All then
          Sleep(1);
      until All or (GetTickCount64 > Limit);
      AssertTrue('every waiter went round again', All);
    end;
    for I := 0 to cThreads - 1 do
      if W[I].Entries > 0 then
        AssertEquals('a waiter entered the wait once and then once for each ' +
          'slice; a waiter that polls by itself shows more', 4, W[I].Entries);
    AssertEquals('one dial in flight', 1, Factory.Dials);
    // the gate opens: the end of the dial wakes the waiters
    Factory.OpenGate;
    Limit := GetTickCount64 + cPollMs;
    repeat
      All := True;
      for I := 0 to cThreads - 1 do
        if not W[I].WaitDone(0) then
        begin
          All := False;
          RTLEventSetEvent(W[I].Tick);
        end;
      if not All then
        Sleep(1);
    until All or (GetTickCount64 > Limit);
    AssertTrue('every caller ended after the gate opened', All);
  finally
    Factory.OpenGate;
    Client.Close;
    for I := 0 to cThreads - 1 do
      if W[I] <> nil then
      begin
        RTLEventSetEvent(W[I].Tick);
        W[I].WaitFor;
        W[I].Free;
      end;
  end;
end;

procedure TPoolWaitTest.TestEachFailedDialChangesTheGenerationAndWakesTheWaiters;
var
  Factory: TStepDialFactory;
  Client: IHttpClient;
  W: array[0..cThreads - 1] of TDialSender;
  I, Released: Integer;
  Before: Cardinal;
  Limit: QWord;
  All: Boolean;
begin
  PoolWaitHook := EventHook;
  GEntries := 0;
  GGeneration := 0;
  Factory := TStepDialFactory.Create(1000);
  Client := Build(Factory);
  for I := 0 to cThreads - 1 do
    W[I] := nil;
  try
    W[0] := TDialSender.Create(Client, 'https://slow.test/x');
    Limit := GetTickCount64 + cPollMs;
    while (Factory.Started < 1) and (GetTickCount64 < Limit) do
      Sleep(1);
    for I := 1 to cThreads - 1 do
      W[I] := TDialSender.Create(Client, 'https://slow.test/x');
    Limit := GetTickCount64 + cPollMs;
    while (GEntries < cThreads - 1) and (GetTickCount64 < Limit) do
      Sleep(1);
    AssertEquals('every other caller waits', cThreads - 1, GEntries);
    Released := 0;
    Limit := GetTickCount64 + 3 * cPollMs;
    repeat
      // one dial ends: its failure changes the generation, and the real
      // event wakes the waiters (the hook waits for nothing else)
      Before := GGeneration;
      Factory.Release;
      Inc(Released);
      if Released = 1 then
      begin
        while (GGeneration = Before) and (GetTickCount64 < Limit) do
          Sleep(1);
        AssertTrue('the end of a dial changed the generation',
          GGeneration <> Before);
      end;
      // a waiter wakes and dials: the next dial starts
      All := False;
      while (Factory.Started <= Released) and not All and
        (GetTickCount64 < Limit) do
      begin
        All := True;
        for I := 0 to cThreads - 1 do
          if not W[I].WaitDone(0) then
            All := False;
        if not All then
          Sleep(1);
      end;
      All := True;
      for I := 0 to cThreads - 1 do
        if not W[I].WaitDone(0) then
          All := False;
    until All or (GetTickCount64 > Limit);
    AssertTrue('every caller ended', All);
    AssertEquals('one dial in flight for the origin', 1,
      Factory.MaxInFlight);
    for I := 0 to cThreads - 1 do
      AssertEquals('a caller got the error of a dial',
        EHttpConnectionError.ClassName, W[I].ErrorClass);
  finally
    PoolWaitHook := nil;
    Client.Close;
    for I := 0 to cThreads - 1 do
      if W[I] <> nil then
      begin
        W[I].WaitFor;
        W[I].Free;
      end;
  end;
end;

procedure TPoolWaitTest.TestCancelTokenStopsAWaiterWhileTheDialIsBlocked;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  Token: TCancellationToken;
  Hold: ICancellationToken;
  A: TDialSender;
  B: TTickSender;
  Limit: QWord;
begin
  PoolWaitHook := TickHook;
  Factory := TBlockingDialFactory.Create;
  Client := Build(Factory);
  Token := TCancellationToken.Create;
  Hold := Token;
  A := TDialSender.Create(Client, 'https://slow.test/x');
  B := nil;
  try
    AssertTrue('the dial started', Factory.WaitStarted(cPollMs));
    B := TTickSender.Create(Client, 'https://slow.test/x', Hold);
    Limit := GetTickCount64 + cPollMs;
    while (B.Entries < 1) and (GetTickCount64 < Limit) do
      Sleep(1);
    AssertEquals('the waiter entered the wait', 1, B.Entries);
    // the token fires; the waiter sees it at the end of the slice
    Token.Cancel;
    RTLEventSetEvent(B.Tick);
    AssertTrue('the waiter ended', B.WaitDone(cPollMs));
    AssertEquals('the waiter raised the cancel error',
      EHttpStreamError.ClassName, B.ErrorClass);
    AssertFalse('the dial is still blocked', A.WaitDone(0));
    AssertEquals('the dial is the only one', 1, Factory.Dials);
  finally
    Factory.OpenGate;
    Client.Close;
    A.WaitFor;
    A.Free;
    if B <> nil then
    begin
      B.WaitFor;
      B.Free;
    end;
  end;
end;

procedure TPoolWaitTest.TestFailedDialWakesTheWaitersAndOneDialsAgain;
const
  cCallers = 5;
var
  Factory: TStepDialFactory;
  Client: IHttpClient;
  W: array[0..cCallers - 1] of TDialSender;
  I: Integer;
  Limit: QWord;
begin
  Factory := TStepDialFactory.Create(1);
  Client := Build(Factory);
  for I := 0 to cCallers - 1 do
    W[I] := nil;
  try
    W[0] := TDialSender.Create(Client, 'https://slow.test/x');
    Limit := GetTickCount64 + cPollMs;
    while (Factory.Started < 1) and (GetTickCount64 < Limit) do
      Sleep(1);
    for I := 1 to cCallers - 1 do
      W[I] := TDialSender.Create(Client, 'https://slow.test/x');
    // the first dial fails once the waiters wait; each waiter gets the error
    // or a dial of its own, one dial at a time
    Pump(Factory, [W[0], W[1], W[2], W[3], W[4]]);
    AssertTrue('a new dial followed the failed one', Factory.Started >= 2);
    AssertEquals('one dial in flight for the origin', 1,
      Factory.MaxInFlight);
    AssertEquals('no reservation is left', 0,
      (Client as THttpClient).Pool.DialingCount);
    for I := 0 to cCallers - 1 do
      AssertTrue('a caller got a response or the error of the dial',
        (W[I].Status = 200) or
        (W[I].ErrorClass = EHttpConnectionError.ClassName));
  finally
    Client.Close;
    for I := 0 to cCallers - 1 do
      if W[I] <> nil then
      begin
        W[I].WaitFor;
        W[I].Free;
      end;
  end;
end;

initialization
  RegisterTest(TPoolWaitTest);

end.
