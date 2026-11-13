{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, budget, queued bytes, sessions, test
notes:
  - This test checks the server-wide byte budget and the session cap of the
    WebSocket sessions.
---
}
unit Http2.Server.WebSocketBudget.Test;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry, Http2.Server.WebSocket.Budget;

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

  TWsBudgetTest = class(TTestCase)
  published
    procedure TestAddAndRelease;
    procedure TestFailedAddChangesNothing;
    procedure TestTwoThreadsEndAtZero;
    procedure TestSessionsStopAtTheCap;
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

{ TWsBudgetTest }

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

initialization
  RegisterTest(TWsBudgetTest);

end.
