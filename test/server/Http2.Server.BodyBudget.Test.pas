{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body budget, in flight, test, fpcunit
notes:
  - This test checks the server-wide budget of the body octets that the HTTP/1.1
    exchanges hold before a handler reads them.
  - The unit tests use small numbers. The live tests use a 1 MiB budget and 512 KiB
    bodies, the smallest budget that the option accepts.
---
}
/// Tests of the server-wide body budget
unit Http2.Server.BodyBudget.Test;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Server, Http2.Server.Runtime, Http2.Server.Seam, Http2.Server.Http1.Exchange,
  Http2.Server.Http1.RawClient, Http2.Server.Http1.BodyBudget;

type
  /// a handler that holds a /hold request until the gate opens, then reads the body
  THoldHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FGate: TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    procedure Open;
  end;

  TBodyBudgetTest = class(TTestCase)
  private
    FHold: THoldHandler;
    FHoldRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function Budget: IBodyBudget;
    function WaitForInFlight(const AValue: Int64): Boolean;
    procedure RunLiveBudget(const ALimit: Int64);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestBudgetRefusesTheCrossingBodyAndKeepsTheOthers;
    procedure TestBudgetZeroChangesNothing;
    procedure TestAddUpToTheLimitIsAccepted;
    procedure TestAddCrossingTheLimitIsRefused;
    procedure TestRefusedAddLeavesInFlightAsItWas;
    procedure TestReleaseLowersInFlight;
    procedure TestZeroLimitAcceptsEveryAdd;
    procedure TestConcurrentAddAndReleaseEndsAtZero;
  end;

implementation

const
  cHalfMiB = 524288;

constructor THoldHandler.Create;
begin
  inherited Create;
  FGate := TEvent.Create(nil, True, False, '');
end;

destructor THoldHandler.Destroy;
begin
  FGate.Free;
  inherited Destroy;
end;

procedure THoldHandler.Open;
begin
  FGate.SetEvent;
end;

procedure THoldHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: TBytes;
  H: THeaderBlock;
  Ok: TBytes;
  N: Integer;
begin
  if ARequest.Path = '/hold' then
    FGate.WaitFor(ResponseMs);
  SetLength(Buf, 65536);
  repeat
    N := ARequest.Read(Buf[0], Length(Buf));
  until N = 0;
  SetLength(H, 1);
  H[0].Name := 'content-length';
  H[0].Value := '2';
  SetLength(Ok, 2);
  Ok[0] := Ord('o');
  Ok[1] := Ord('k');
  AResponse.SendHeaders(200, H, False);
  AResponse.Write(Ok);
  AResponse.Finish;
end;

{ TBodyBudgetTest live fixture }

procedure TBodyBudgetTest.SetUp;
begin
  inherited SetUp;
  FHold := THoldHandler.Create;
  FHoldRef := FHold;
end;

procedure TBodyBudgetTest.TearDown;
begin
  if FHold <> nil then
    FHold.Open;
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHoldRef := nil;
  FHold := nil;
  inherited TearDown;
end;

procedure TBodyBudgetTest.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function TBodyBudgetTest.Budget: IBodyBudget;
begin
  Result := (FServer as THttp2Server).Async.Handlers.BodyBudget;
end;

function TBodyBudgetTest.WaitForInFlight(const AValue: Int64): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + ResponseMs;
  while (Budget.InFlight <> AValue) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := Budget.InFlight = AValue;
end;

procedure TBodyBudgetTest.RunLiveBudget(const ALimit: Int64);
begin
  // the factory is built by each test; this helper keeps the shared fixture small
  StartServer(LiveFactory(FHoldRef).WithHandlerThreads(4).WithServerLimits(
    TServerLimits.Create.WithMaxBodyBytesInFlight(ALimit)));
end;

procedure TBodyBudgetTest.TestBudgetRefusesTheCrossingBodyAndKeepsTheOthers;
var
  C1, C2, C3, C4: TRawHttp;
  R: TRawResponse;
  Payload: RawByteString;
begin
  RunLiveBudget(1024 * 1024);
  Payload := StringOfChar('x', cHalfMiB);
  C1 := TRawHttp.Create(FServer.Port);
  C2 := TRawHttp.Create(FServer.Port);
  C3 := TRawHttp.Create(FServer.Port);
  C4 := TRawHttp.Create(FServer.Port);
  try
    // two held bodies fill the budget exactly
    C1.Send('POST /hold HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 524288' + CRLF + CRLF + Payload);
    C2.Send('POST /hold HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 524288' + CRLF + CRLF + Payload);
    AssertTrue('the two bodies fill the budget', WaitForInFlight(1024 * 1024));
    // the third body crosses the budget: 503 and the connection closes
    C3.Send('POST /hold HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 524288' + CRLF + CRLF +
      Copy(Payload, 1, 16384));
    AssertTrue('the crossing request gets an answer', C3.ReadResponse(False, ResponseMs, R));
    AssertEquals('the crossing request gets 503', 503, R.Status);
    AssertTrue('the crossing connection closes', C3.WaitClosed(ResponseMs));
    AssertTrue('the refused body is not counted', Budget.InFlight = 1024 * 1024);
    // the held requests finish and give back their octets
    FHold.Open;
    AssertTrue('the first held request finishes', C1.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertTrue('the second held request finishes', C2.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertTrue('the budget returns to 0', WaitForInFlight(0));
    // a later request fits again
    C4.Send('POST /hold HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 524288' + CRLF + CRLF + Payload);
    AssertTrue('the later request finishes', C4.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertTrue('the budget ends at 0', WaitForInFlight(0));
  finally
    C1.Free;
    C2.Free;
    C3.Free;
    C4.Free;
  end;
end;

procedure TBodyBudgetTest.TestBudgetZeroChangesNothing;
var
  C: TRawHttp;
  R: TRawResponse;
  I: Integer;
  Payload: RawByteString;
begin
  RunLiveBudget(0);
  FHold.Open;
  Payload := StringOfChar('x', cHalfMiB);
  for I := 1 to 4 do
  begin
    C := TRawHttp.Create(FServer.Port);
    try
      C.Send('POST /open HTTP/1.1' + CRLF + 'Host: a' + CRLF + 'Content-Length: 524288' + CRLF + CRLF + Payload);
      AssertTrue('request answered', C.ReadResponse(False, ResponseMs, R));
      AssertEquals('a budget of 0 answers 200', 200, R.Status);
    finally
      C.Free;
    end;
  end;
  AssertTrue('the count returns to 0', WaitForInFlight(0));
end;

type
  /// one thread that adds and releases the same count of octets many times
  TBudgetWorker = class(TThread)
  private
    FBudget: IBodyBudget;
    FRounds: Integer;
    FRefused: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABudget: IBodyBudget; const ARounds: Integer);
    property Refused: Integer read FRefused;
  end;

constructor TBudgetWorker.Create(const ABudget: IBodyBudget; const ARounds: Integer);
begin
  inherited Create(False);
  FreeOnTerminate := False;
  FBudget := ABudget;
  FRounds := ARounds;
end;

procedure TBudgetWorker.Execute;
var
  I: Integer;
begin
  for I := 1 to FRounds do
  begin
    if FBudget.TryAdd(16) then
      FBudget.Release(16)
    else
      Inc(FRefused);
  end;
end;

procedure TBodyBudgetTest.TestAddUpToTheLimitIsAccepted;
var
  Budget: IBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('the first add of 512 octets', Budget.TryAdd(512));
    AssertTrue('the second add reaches the limit', Budget.TryAdd(512));
    AssertTrue('the in flight count is the limit', Budget.InFlight = 1024);
  finally
  end;
end;

procedure TBodyBudgetTest.TestAddCrossingTheLimitIsRefused;
var
  Budget: IBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('an add of 1000 octets', Budget.TryAdd(1000));
    AssertFalse('an add that passes the limit is refused', Budget.TryAdd(100));
  finally
  end;
end;

procedure TBodyBudgetTest.TestRefusedAddLeavesInFlightAsItWas;
var
  Budget: IBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('an add of 1000 octets', Budget.TryAdd(1000));
    AssertFalse('an add that passes the limit is refused', Budget.TryAdd(100));
    AssertTrue('a refused add does not count', Budget.InFlight = 1000);
  finally
  end;
end;

procedure TBodyBudgetTest.TestReleaseLowersInFlight;
var
  Budget: IBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('an add of 600 octets', Budget.TryAdd(600));
    Budget.Release(200);
    AssertTrue('the release lowers the count', Budget.InFlight = 400);
    Budget.Release(400);
    AssertTrue('the count returns to 0', Budget.InFlight = 0);
    AssertTrue('the released room accepts an add', Budget.TryAdd(1024));
  finally
  end;
end;

procedure TBodyBudgetTest.TestZeroLimitAcceptsEveryAdd;
var
  Budget: IBodyBudget;
begin
  Budget := TBodyBudget.Create(0);
  try
    AssertTrue('a limit of 0 accepts a large add', Budget.TryAdd(Int64(1) shl 40));
    AssertTrue('a limit of 0 accepts a second add', Budget.TryAdd(1024));
    Budget.Release(Int64(1) shl 40);
    Budget.Release(1024);
    AssertTrue('the count still returns to 0', Budget.InFlight = 0);
  finally
  end;
end;

procedure TBodyBudgetTest.TestConcurrentAddAndReleaseEndsAtZero;
var
  Budget: IBodyBudget;
  First, Second: TBudgetWorker;
begin
  // 1 MiB budget and 16-octet adds: two threads never reach the limit
  Budget := TBodyBudget.Create(1024 * 1024);
  First := TBudgetWorker.Create(Budget, 20000);
  Second := TBudgetWorker.Create(Budget, 20000);
  try
    First.WaitFor;
    Second.WaitFor;
    AssertTrue('no add is refused under the limit', (First.Refused = 0) and (Second.Refused = 0));
    AssertTrue('the count ends at 0', Budget.InFlight = 0);
  finally
    First.Free;
    Second.Free;
  end;
end;

initialization
  RegisterTest(TBodyBudgetTest);
end.
