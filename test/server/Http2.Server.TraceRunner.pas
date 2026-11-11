{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, trace, runner
notes:
  - This unit reports each server test start and end when trace is enabled.
  - The listener keeps the console runner progress and exit code behavior.
---
}
/// A console runner with optional per-test trace records
unit Http2.Server.TraceRunner;

{$mode delphi}{$H+}

interface

uses
  consoletestrunner, fpcunit;

type
  THttp2ServerTestRunner = class(TTestRunner)
  protected
    procedure DoTestRun(ATest: TTest); override;
  end;

implementation

uses
  Classes, SysUtils, fpcunitreport;

type
  TServerTestListener = class(TInterfacedObject, ITestListener)
  private
    FQuiet: Boolean;
    FTrace: Boolean;
    FSuccess: Boolean;
    FOutcome: string;
    FFailures: Integer;
    FErrors: Integer;
    FIgnored: Integer;
    FTestCount: Integer;
    FCurrentCase: Integer;
    FStartedAt: QWord;
    procedure Trace(const AEvent: string; const ATest: TTest;
      const AElapsedMs: QWord = 0);
    procedure WriteProgress(const AValue: Char);
  public
    constructor Create(const AShowProgress, ATrace: Boolean);
    function ExitCode: Integer;
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

constructor TServerTestListener.Create(const AShowProgress, ATrace: Boolean);
begin
  inherited Create;
  FQuiet := not AShowProgress;
  FTrace := ATrace;
  FSuccess := True;
  FOutcome := 'PASS';
  FFailures := 0;
  FErrors := 0;
  FIgnored := 0;
  FTestCount := 0;
  FCurrentCase := 0;
end;

procedure TServerTestListener.Trace(const AEvent: string; const ATest: TTest;
  const AElapsedMs: QWord);
var
  TestId: string;
begin
  if not FTrace then
    Exit;
  TestId := ATest.TestSuiteName + '.' + ATest.TestName;
  if AEvent = 'END' then
    WriteLn(StdErr, 'HTTP2_TEST_TRACE ', AEvent, ' case=', FCurrentCase,
      ' ', TestId,
      ' outcome=', FOutcome, ' elapsed_ms=', AElapsedMs)
  else
    WriteLn(StdErr, 'HTTP2_TEST_TRACE ', AEvent, ' case=', FCurrentCase,
      ' ', TestId);
  Flush(StdErr);
end;

procedure TServerTestListener.WriteProgress(const AValue: Char);
begin
  if FQuiet then
    Exit;
  Write(Output, AValue);
  Flush(Output);
end;

function TServerTestListener.ExitCode: Integer;
begin
  Result := Ord(FFailures > 0) or (Ord(FErrors > 0) shl 1);
end;

procedure TServerTestListener.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
  FSuccess := False;
  if AFailure.IsIgnoredTest then
  begin
    Inc(FIgnored);
    FOutcome := 'IGNORED';
  end
  else
  begin
    Inc(FFailures);
    FOutcome := 'FAIL';
  end;
  WriteProgress('F');
end;

procedure TServerTestListener.AddError(ATest: TTest; AError: TTestFailure);
begin
  FSuccess := False;
  Inc(FErrors);
  FOutcome := 'ERROR';
  WriteProgress('E');
end;

procedure TServerTestListener.StartTest(ATest: TTest);
begin
  FSuccess := True;
  FOutcome := 'PASS';
  Inc(FTestCount);
  FCurrentCase := FTestCount;
  FStartedAt := GetTickCount64;
  Trace('START', ATest);
end;

procedure TServerTestListener.EndTest(ATest: TTest);
begin
  if FSuccess then
    WriteProgress('.');
  Trace('END', ATest, GetTickCount64 - FStartedAt);
end;

procedure TServerTestListener.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TServerTestListener.EndTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure THttp2ServerTestRunner.DoTestRun(ATest: TTest);
var
  ResultsWriter: TCustomResultsWriter;
  ListenerObject: TServerTestListener;
  Listener: ITestListener;
  TestResult: TTestResult;
begin
  ResultsWriter := nil;
  Listener := nil;
  TestResult := TTestResult.Create;
  try
    ListenerObject := TServerTestListener.Create(ShowProgress,
      GetEnvironmentVariable('HTTP2_TEST_TRACE') <> '');
    Listener := ListenerObject;
    TestResult.AddListener(Listener);
    ResultsWriter := GetResultsWriter;
    ResultsWriter.FileName := FileName;
    TestResult.AddListener(ResultsWriter);
    ATest.Run(TestResult);
    ResultsWriter.WriteResult(TestResult);
  finally
    if Listener <> nil then
      ExitCode := ListenerObject.ExitCode;
    TestResult.Free;
    ResultsWriter.Free;
    Listener := nil;
  end;
end;

end.
