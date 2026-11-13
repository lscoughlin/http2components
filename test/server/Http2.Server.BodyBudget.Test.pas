{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body budget, in flight, test, fpcunit
notes:
  - This test checks the server-wide budget of the body octets that the HTTP/1.1
    exchanges hold before a handler reads them.
  - The tests use small budgets and small counts. They never allocate a large buffer.
---
}
/// Tests of the server-wide body budget
unit Http2.Server.BodyBudget.Test;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server.Http1.BodyBudget;

type
  TBodyBudgetTest = class(TTestCase)
  published
    procedure TestAddUpToTheLimitIsAccepted;
    procedure TestAddCrossingTheLimitIsRefused;
    procedure TestRefusedAddLeavesInFlightAsItWas;
    procedure TestReleaseLowersInFlight;
    procedure TestZeroLimitAcceptsEveryAdd;
    procedure TestConcurrentAddAndReleaseEndsAtZero;
  end;

implementation

type
  /// one thread that adds and releases the same count of octets many times
  TBudgetWorker = class(TThread)
  private
    FBudget: TBodyBudget;
    FRounds: Integer;
    FRefused: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABudget: TBodyBudget; const ARounds: Integer);
    property Refused: Integer read FRefused;
  end;

constructor TBudgetWorker.Create(const ABudget: TBodyBudget; const ARounds: Integer);
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
  Budget: TBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('the first add of 512 octets', Budget.TryAdd(512));
    AssertTrue('the second add reaches the limit', Budget.TryAdd(512));
    AssertTrue('the in flight count is the limit', Budget.InFlight = 1024);
  finally
    Budget.Free;
  end;
end;

procedure TBodyBudgetTest.TestAddCrossingTheLimitIsRefused;
var
  Budget: TBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('an add of 1000 octets', Budget.TryAdd(1000));
    AssertFalse('an add that passes the limit is refused', Budget.TryAdd(100));
  finally
    Budget.Free;
  end;
end;

procedure TBodyBudgetTest.TestRefusedAddLeavesInFlightAsItWas;
var
  Budget: TBodyBudget;
begin
  Budget := TBodyBudget.Create(1024);
  try
    AssertTrue('an add of 1000 octets', Budget.TryAdd(1000));
    AssertFalse('an add that passes the limit is refused', Budget.TryAdd(100));
    AssertTrue('a refused add does not count', Budget.InFlight = 1000);
  finally
    Budget.Free;
  end;
end;

procedure TBodyBudgetTest.TestReleaseLowersInFlight;
var
  Budget: TBodyBudget;
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
    Budget.Free;
  end;
end;

procedure TBodyBudgetTest.TestZeroLimitAcceptsEveryAdd;
var
  Budget: TBodyBudget;
begin
  Budget := TBodyBudget.Create(0);
  try
    AssertTrue('a limit of 0 accepts a large add', Budget.TryAdd(Int64(1) shl 40));
    AssertTrue('a limit of 0 accepts a second add', Budget.TryAdd(1024));
    Budget.Release(Int64(1) shl 40);
    Budget.Release(1024);
    AssertTrue('the count still returns to 0', Budget.InFlight = 0);
  finally
    Budget.Free;
  end;
end;

procedure TBodyBudgetTest.TestConcurrentAddAndReleaseEndsAtZero;
var
  Budget: TBodyBudget;
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
    Budget.Free;
  end;
end;

initialization
  RegisterTest(TBodyBudgetTest);
end.
