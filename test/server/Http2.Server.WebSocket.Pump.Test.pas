{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket_pump, test, fpcunit
notes:
  - These tests drive the pump of Http2.Server.WebSocket.Pump with a fake host and a
    scripted writer. The fake host runs a Step only when a test calls it, except in the
    thread test, where two worker threads run the scheduled steps.
  - A global flag tells a test that the pump released the writer or the host.
---
}
/// Tests of the pump of a streamed WebSocket message
unit Http2.Server.WebSocket.Pump.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Common.Body, Http2.Common.Errors, Http2.Server.Duplex,
  Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Pump,
  Http2.Server.WsHardening.Test;

type
  EPumpTestError = class(Exception);

  /// a hook that the writer calls at the start of call number ACall
  TCallHook = procedure(const ACall: Integer) of object;

  TWriteRec = record
    Wire: TBytes;
    Fin: Boolean;
    Result: TSendResult;
  end;

  /// the host of the pump; every call is recorded
  TFakeHost = class(TInterfacedObject, IWsPumpHost)
  private
    FLock: TCriticalSection;
    FResults: TList<TSendResult>;
  public
    Writes: TList<TWriteRec>;
    Counted: Integer;
    ScheduleCount, AfterCount, EndedCount, DefectCount: Integer;
    LastAfterDelay: Integer;
    ScheduleResult, AfterResult: Boolean;
    EndedClass, EndedMessage, DefectText: string;
    EndedIsHttpError: Boolean;
    /// runs inside PumpWrite, after the write is recorded and before the result returns
    OnWrite: TProc_;
    /// PumpCount or PumpSchedule raises after it did its work
    RaiseInCount, RaiseInSchedule: Boolean;
    WriteCalls: Integer;
    /// every Nth write answers srFull (0 means never)
    EveryNthFull: Integer;
    /// the steps that a test thread still has to run
    PendingSteps: Integer;
    WorkEvent: TEvent;
    constructor Create;
    destructor Destroy; override;
    /// the next results of PumpWrite; srQueued when the list is empty
    procedure Script(const AResult: TSendResult);
    function TakeStep: Boolean;
    function PumpWrite(const AWire: TBytes; const AFin: Boolean): TSendResult;
    procedure PumpCount(const APayload: Integer);
    function PumpSchedule: Boolean;
    function PumpScheduleAfter(const ADelayMs: Integer): Boolean;
    procedure PumpEnded(const AFailure: Exception);
    procedure PumpDefect(const AText: string);
  end;

  /// a writer that answers from a script, or that makes numbered chunks
  TScriptWriter = class(TInterfacedObject, IBodyWriter)
  private
    FData: TList<string>;
    FMore: TList<Boolean>;
    FCalls: Integer;
  public
    /// the call that raises (0 means none)
    RaiseAt: Integer;
    OnCall: TCallHook;
    /// when over 0 the writer gives this many chunks "1", "2", ... and then ends
    Generate: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AData: string; const AMore: Boolean);
    function NextChunk(const ABuffer: TStream): Boolean;
  end;

  TWsPumpTest = class(TTestCase)
  private
    FHost: TFakeHost;
    FHostRef: IWsPumpHost;
    FPump: IWsPump;
    FWriter: TScriptWriter;
    FStop: TEvent;
    FHookCalls: Integer;
    FDestroyedInCall: Boolean;
    procedure NewWriter;
    procedure Start(const AText: Boolean = True; const AMaxChunk: Int64 = 1000;
      const AStepChunks: Integer = 16);
    function Op(const I: Integer): Byte;
    function Fin(const I: Integer): Boolean;
    function Payload(const I: Integer): string;
    procedure CheckFrame(const I: Integer; const AOp: Byte; const AFin: Boolean;
      const APayload: string);
    procedure ParkOnce;
    procedure WakeOnFirstWrite;
    procedure StepOnFirstWrite;
    procedure StopInCall(const ACall: Integer);
    procedure WorkerLoop;
    procedure WakerLoop;
    procedure RunConcurrentOnce;
    procedure EndAndCheckHostReleased(const AMode: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestChunksBecomeFragments;
    procedure TestLastChunkCarriesTheFin;
    procedure TestSingleCallStream;
    procedure TestEmptyStreamSendsOneFinFrame;
    procedure TestZeroLengthChunkIsSkipped;
    procedure TestBinaryUsesBinaryOpcode;
    procedure TestFullParksAndWakeResumes;
    procedure TestDrainBetweenRefusalAndParkIsNotLost;
    procedure TestWakeOnARunningPumpOnlySetsTheFlag;
    procedure TestWakeWhenParkedSchedulesOnce;
    procedure TestStaleTimerDoesNotStartASecondStep;
    procedure TestOnlyOneTimerIsPending;
    procedure TestOverlappingStepIsReportedNotRaised;
    procedure TestPumpReleasesItsHostAtTheEnd;
    procedure TestStepLimitSchedulesAgain;
    procedure TestClosedEndsQuietly;
    procedure TestWriterExceptionIsReported;
    procedure TestChunkOverTheLimitIsReported;
    procedure TestStopWhileParkedReleasesTheWriter;
    procedure TestStopDuringNextChunkReleasesAfterIt;
    procedure TestPoolStoppedEnds;
    procedure TestPoolStoppedAtParkEnds;
    procedure TestLateStepAfterTheEndDoesNothing;
    procedure TestPumpCountRaisingEndsThePump;
    procedure TestScheduleRaisingStopsThePump;
    procedure TestConcurrentWakeAndStep;
  end;

implementation

var
  GWriterDestroyed: Boolean;
  GHostDestroyed: Boolean;
  GWriterCalls: LongInt;

{ TFakeHost }

constructor TFakeHost.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FResults := TList<TSendResult>.Create;
  Writes := TList<TWriteRec>.Create;
  WorkEvent := TEvent.Create(nil, False, False, '');
  ScheduleResult := True;
  AfterResult := True;
end;

destructor TFakeHost.Destroy;
begin
  GHostDestroyed := True;
  WorkEvent.Free;
  Writes.Free;
  FResults.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeHost.Script(const AResult: TSendResult);
begin
  FLock.Acquire;
  try
    FResults.Add(AResult);
  finally
    FLock.Release;
  end;
end;

function TFakeHost.TakeStep: Boolean;
begin
  FLock.Acquire;
  try
    Result := PendingSteps > 0;
    if Result then
      Dec(PendingSteps);
  finally
    FLock.Release;
  end;
end;

function TFakeHost.PumpWrite(const AWire: TBytes; const AFin: Boolean): TSendResult;
var
  Rec: TWriteRec;
begin
  FLock.Acquire;
  try
    Inc(WriteCalls);
    Result := srQueued;
    if FResults.Count > 0 then
    begin
      Result := FResults[0];
      FResults.Delete(0);
    end
    else if (EveryNthFull > 0) and (WriteCalls mod EveryNthFull = 0) then
      Result := srFull;
    Rec.Wire := Copy(AWire);
    Rec.Fin := AFin;
    Rec.Result := Result;
    Writes.Add(Rec);
  finally
    FLock.Release;
  end;
  if Assigned(OnWrite) then
    OnWrite();
end;

procedure TFakeHost.PumpCount(const APayload: Integer);
begin
  FLock.Acquire;
  try
    Inc(Counted, APayload);
  finally
    FLock.Release;
  end;
  if RaiseInCount then
    raise EPumpTestError.Create('count');
end;

function TFakeHost.PumpSchedule: Boolean;
begin
  FLock.Acquire;
  try
    Inc(ScheduleCount);
    Inc(PendingSteps);
    Result := ScheduleResult;
  finally
    FLock.Release;
  end;
  WorkEvent.SetEvent;
  if RaiseInSchedule then
    raise EPumpTestError.Create('schedule');
end;

function TFakeHost.PumpScheduleAfter(const ADelayMs: Integer): Boolean;
begin
  FLock.Acquire;
  try
    Inc(AfterCount);
    LastAfterDelay := ADelayMs;
    Result := AfterResult;
  finally
    FLock.Release;
  end;
end;

procedure TFakeHost.PumpEnded(const AFailure: Exception);
begin
  FLock.Acquire;
  try
    Inc(EndedCount);
    if AFailure <> nil then
    begin
      // AFailure is valid for the length of the call only: copy what a test reads
      EndedClass := AFailure.ClassName;
      EndedMessage := AFailure.Message;
      EndedIsHttpError := AFailure is EHttpError;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TFakeHost.PumpDefect(const AText: string);
begin
  FLock.Acquire;
  try
    Inc(DefectCount);
    DefectText := AText;
  finally
    FLock.Release;
  end;
end;

{ TScriptWriter }

constructor TScriptWriter.Create;
begin
  inherited Create;
  FData := TList<string>.Create;
  FMore := TList<Boolean>.Create;
end;

destructor TScriptWriter.Destroy;
begin
  GWriterDestroyed := True;
  FMore.Free;
  FData.Free;
  inherited Destroy;
end;

procedure TScriptWriter.Add(const AData: string; const AMore: Boolean);
begin
  FData.Add(AData);
  FMore.Add(AMore);
end;

function TScriptWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  Text: string;
begin
  Inc(FCalls);
  InterlockedIncrement(GWriterCalls);
  if Assigned(OnCall) then
    OnCall(FCalls);
  if (RaiseAt > 0) and (FCalls = RaiseAt) then
    raise EPumpTestError.Create('boom');
  if Generate > 0 then
  begin
    Result := FCalls <= Generate;
    if Result then
      ChunkAppendText(ABuffer, UTF8String(IntToStr(FCalls)));
    Exit;
  end;
  if FCalls > FData.Count then
    Exit(False);
  Text := FData[FCalls - 1];
  ChunkAppendText(ABuffer, UTF8String(Text));
  Result := FMore[FCalls - 1];
end;

{ TWsPumpTest }

procedure TWsPumpTest.SetUp;
begin
  GWriterDestroyed := False;
  GHostDestroyed := False;
  GWriterCalls := 0;
  FHookCalls := 0;
  FDestroyedInCall := False;
  FStop := TEvent.Create(nil, True, False, '');
  NewWriter;
end;

procedure TWsPumpTest.TearDown;
begin
  FPump := nil;
  FHostRef := nil;
  FHost := nil;
  FStop.Free;
  FStop := nil;
end;

procedure TWsPumpTest.NewWriter;
begin
  FWriter := TScriptWriter.Create;
end;

procedure TWsPumpTest.Start(const AText: Boolean; const AMaxChunk: Int64;
  const AStepChunks: Integer);
begin
  FHost := TFakeHost.Create;
  FHostRef := FHost;
  // the pump holds the only reference of the writer from here on
  FPump := TWsStreamPump.Create(FWriter, AText, 1000, AMaxChunk, AStepChunks, FHostRef);
  FWriter := nil;
end;

function TWsPumpTest.Op(const I: Integer): Byte;
begin
  Result := FHost.Writes[I].Wire[0] and $0F;
end;

function TWsPumpTest.Fin(const I: Integer): Boolean;
begin
  Result := (FHost.Writes[I].Wire[0] and $80) <> 0;
end;

function TWsPumpTest.Payload(const I: Integer): string;
var
  Wire: TBytes;
begin
  // the chunks of these tests are short: one frame with a one octet length
  Wire := FHost.Writes[I].Wire;
  Result := '';
  if Wire[1] > 0 then
    SetString(Result, PAnsiChar(@Wire[2]), Wire[1]);
end;

procedure TWsPumpTest.CheckFrame(const I: Integer; const AOp: Byte; const AFin: Boolean;
  const APayload: string);
begin
  AssertEquals('opcode of write ' + IntToStr(I), AOp, Op(I));
  AssertEquals('FIN of write ' + IntToStr(I), AFin, Fin(I));
  AssertEquals('payload of write ' + IntToStr(I), APayload, Payload(I));
end;

procedure TWsPumpTest.ParkOnce;
begin
  FHost.Script(srFull);
  FPump.Step;
end;

procedure TWsPumpTest.TestChunksBecomeFragments;
begin
  FWriter.Add('a', True);
  FWriter.Add('bb', True);
  FWriter.Add('', False);
  Start;
  FPump.Step;
  AssertEquals(3, FHost.Writes.Count);
  CheckFrame(0, WsOpText, False, 'a');
  CheckFrame(1, WsOpContinuation, False, 'bb');
  CheckFrame(2, WsOpContinuation, True, '');
  AssertTrue(FPump.State = psDone);
  AssertTrue('writer released', GWriterDestroyed);
  AssertEquals(3, FHost.Counted);
  AssertEquals(0, FHost.EndedCount);
end;

procedure TWsPumpTest.TestLastChunkCarriesTheFin;
begin
  FWriter.Add('a', True);
  FWriter.Add('bb', False);
  Start;
  FPump.Step;
  AssertEquals('no empty frame follows', 2, FHost.Writes.Count);
  CheckFrame(0, WsOpText, False, 'a');
  CheckFrame(1, WsOpContinuation, True, 'bb');
  AssertTrue(FPump.State = psDone);
end;

procedure TWsPumpTest.TestSingleCallStream;
begin
  FWriter.Add('abc', False);
  Start;
  FPump.Step;
  AssertEquals(1, FHost.Writes.Count);
  CheckFrame(0, WsOpText, True, 'abc');
  AssertTrue(FPump.State = psDone);
end;

procedure TWsPumpTest.TestEmptyStreamSendsOneFinFrame;
begin
  FWriter.Add('', False);
  Start;
  FPump.Step;
  AssertEquals(1, FHost.Writes.Count);
  CheckFrame(0, WsOpText, True, '');
  AssertEquals(2, Length(FHost.Writes[0].Wire));
  AssertTrue(FPump.State = psDone);
end;

procedure TWsPumpTest.TestZeroLengthChunkIsSkipped;
begin
  FWriter.Add('a', True);
  FWriter.Add('', True);
  FWriter.Add('b', True);
  FWriter.Add('', False);
  Start;
  FPump.Step;
  AssertEquals(3, FHost.Writes.Count);
  CheckFrame(0, WsOpText, False, 'a');
  CheckFrame(1, WsOpContinuation, False, 'b');
  CheckFrame(2, WsOpContinuation, True, '');
end;

procedure TWsPumpTest.TestBinaryUsesBinaryOpcode;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start(False);
  FPump.Step;
  CheckFrame(0, WsOpBinary, False, 'a');
  CheckFrame(1, WsOpContinuation, True, 'b');
end;

procedure TWsPumpTest.TestFullParksAndWakeResumes;
var
  W0, W1: TBytes;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  ParkOnce;
  AssertTrue(FPump.State = psParked);
  AssertEquals('one timer request', 1, FHost.AfterCount);
  AssertEquals(cWsPumpParkPollMs, FHost.LastAfterDelay);
  AssertEquals('one wire, refused', 1, FHost.Writes.Count);
  AssertEquals('the writer is asked once', 1, GWriterCalls);
  FPump.Wake;
  AssertEquals(1, FHost.ScheduleCount);
  AssertTrue(FPump.State = psRunning);
  FPump.Step;
  AssertEquals(3, FHost.Writes.Count);
  W0 := FHost.Writes[0].Wire;
  W1 := FHost.Writes[1].Wire;
  AssertEquals(Length(W0), Length(W1));
  AssertTrue('the same octets again', CompareMem(@W0[0], @W1[0], Length(W0)));
  CheckFrame(1, WsOpText, False, 'a');
  CheckFrame(2, WsOpContinuation, True, 'b');
  AssertEquals('the writer is asked twice in all', 2, GWriterCalls);
  AssertEquals('the refused wire is counted once', 2, FHost.Counted);
  AssertTrue(FPump.State = psDone);
end;

procedure TWsPumpTest.WakeOnFirstWrite;
begin
  Inc(FHookCalls);
  if FHookCalls = 1 then
    FPump.Wake;
end;

procedure TWsPumpTest.TestDrainBetweenRefusalAndParkIsNotLost;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  FHost.Script(srFull);
  FHost.OnWrite := WakeOnFirstWrite;
  FPump.Step;
  AssertEquals('refusal, retry and the next chunk', 3, FHost.Writes.Count);
  AssertTrue(FHost.Writes[0].Result = srFull);
  AssertTrue(FHost.Writes[1].Result = srQueued);
  AssertEquals(Length(FHost.Writes[0].Wire), Length(FHost.Writes[1].Wire));
  CheckFrame(1, WsOpText, False, 'a');
  AssertEquals('never parked: no timer', 0, FHost.AfterCount);
  AssertEquals('the Wake started no step', 0, FHost.ScheduleCount);
  AssertTrue('never parked, and ended', FPump.State = psDone);
end;

procedure TWsPumpTest.TestWakeOnARunningPumpOnlySetsTheFlag;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  FPump.Wake;
  AssertEquals(0, FHost.ScheduleCount);
  AssertTrue(FPump.State = psRunning);
  FHost.Script(srFull);
  FPump.Step;
  AssertEquals('refused, written again, then the next chunk', 3, FHost.Writes.Count);
  AssertEquals(0, FHost.AfterCount);
  AssertTrue(FPump.State = psDone);
end;

procedure TWsPumpTest.TestWakeWhenParkedSchedulesOnce;
begin
  FWriter.Add('a', False);
  Start;
  ParkOnce;
  FPump.Wake;
  FPump.Wake;
  AssertEquals(1, FHost.ScheduleCount);
end;

procedure TWsPumpTest.TestStaleTimerDoesNotStartASecondStep;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  ParkOnce;
  AssertEquals(1, FHost.AfterCount);
  FPump.Wake;
  AssertEquals(1, FHost.ScheduleCount);
  FPump.TimerFired;
  AssertEquals('the timer starts no second step', 1, FHost.ScheduleCount);
  AssertTrue(FPump.State = psRunning);
  FHost.Script(srFull);
  FHost.Script(srFull);
  FPump.Step;
  // the flag that the timer set gave one extra write; the second refusal parks
  AssertEquals(3, FHost.Writes.Count);
  AssertTrue(FPump.State = psParked);
  AssertEquals('a new timer request', 2, FHost.AfterCount);
end;

procedure TWsPumpTest.TestOnlyOneTimerIsPending;
var
  I: Integer;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  for I := 1 to 5 do
    FHost.Script(srFull);
  for I := 1 to 5 do
  begin
    FPump.Step;
    AssertTrue(FPump.State = psParked);
    FPump.Wake;
  end;
  AssertEquals('one timer request, not five', 1, FHost.AfterCount);
  FPump.TimerFired;
  FHost.Script(srFull);
  FHost.Script(srFull);
  FPump.Step;
  AssertTrue(FPump.State = psParked);
  AssertEquals('after TimerFired the next park asks again', 2, FHost.AfterCount);
end;

procedure TWsPumpTest.StepOnFirstWrite;
begin
  Inc(FHookCalls);
  if FHookCalls = 1 then
    FPump.Step;
end;

procedure TWsPumpTest.TestOverlappingStepIsReportedNotRaised;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  FHost.OnWrite := StepOnFirstWrite;
  FPump.Step;
  AssertEquals(1, FHost.DefectCount);
  AssertEquals('two pump steps', FHost.DefectText);
  AssertEquals('the first step goes on', 2, FHost.Writes.Count);
  AssertTrue(FPump.State = psDone);
end;

procedure TWsPumpTest.EndAndCheckHostReleased(const AMode: Integer);
begin
  GHostDestroyed := False;
  NewWriter;
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  if AMode = 2 then
    FWriter.RaiseAt := 2;
  Start;
  case AMode of
    0: FPump.Step;
    1:
      begin
        ParkOnce;
        FPump.Stop;
      end;
    2: FPump.Step;
  end;
  AssertTrue('the pump ended, mode ' + IntToStr(AMode), FPump.State = psDone);
  // the test drops its own reference: the pump must hold none
  FHost := nil;
  FHostRef := nil;
  AssertTrue('the host is released, mode ' + IntToStr(AMode), GHostDestroyed);
  FPump := nil;
end;

procedure TWsPumpTest.TestPumpReleasesItsHostAtTheEnd;
begin
  // the setup made a writer; the first run uses it
  FWriter.Free;
  FWriter := nil;
  EndAndCheckHostReleased(0);
  EndAndCheckHostReleased(1);
  EndAndCheckHostReleased(2);
end;

procedure TWsPumpTest.TestStepLimitSchedulesAgain;
var
  I: Integer;
begin
  for I := 1 to 40 do
    FWriter.Add('c', True);
  FWriter.Add('', False);
  Start(True, 1000, 16);
  FPump.Step;
  AssertEquals(16, FHost.Writes.Count);
  AssertEquals(1, FHost.ScheduleCount);
  AssertTrue(FPump.State = psRunning);
  FPump.Step;
  AssertEquals(32, FHost.Writes.Count);
  AssertEquals(2, FHost.ScheduleCount);
  FPump.Step;
  AssertEquals('40 chunks and the final frame', 41, FHost.Writes.Count);
  AssertEquals(2, FHost.ScheduleCount);
  AssertTrue(FPump.State = psDone);
  CheckFrame(0, WsOpText, False, 'c');
  CheckFrame(39, WsOpContinuation, False, 'c');
  CheckFrame(40, WsOpContinuation, True, '');
end;

procedure TWsPumpTest.TestClosedEndsQuietly;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', True);
  FWriter.Add('c', False);
  Start;
  FHost.Script(srQueued);
  FHost.Script(srClosed);
  FPump.Step;
  AssertEquals(2, FHost.Writes.Count);
  AssertTrue(FPump.State = psDone);
  AssertEquals('no PumpEnded call', 0, FHost.EndedCount);
  AssertTrue(GWriterDestroyed);
end;

procedure TWsPumpTest.TestWriterExceptionIsReported;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  FWriter.RaiseAt := 2;
  Start;
  FPump.Step;
  AssertEquals(1, FHost.EndedCount);
  AssertEquals('EPumpTestError', FHost.EndedClass);
  AssertEquals('boom', FHost.EndedMessage);
  AssertEquals(1, FHost.Writes.Count);
  AssertTrue(FPump.State = psDone);
  AssertTrue(GWriterDestroyed);
end;

procedure TWsPumpTest.TestChunkOverTheLimitIsReported;
begin
  FWriter.Add('abcdefghijk', True);
  Start(True, 10);
  FPump.Step;
  AssertEquals(1, FHost.EndedCount);
  AssertTrue(FHost.EndedIsHttpError);
  AssertEquals('no frame for that chunk', 0, FHost.Writes.Count);
  AssertTrue(FPump.State = psDone);
  AssertTrue(GWriterDestroyed);
end;

procedure TWsPumpTest.TestStopWhileParkedReleasesTheWriter;
begin
  FWriter.Add('a', False);
  Start;
  ParkOnce;
  AssertFalse(GWriterDestroyed);
  FPump.Stop;
  AssertTrue(GWriterDestroyed);
  FPump.Wake;
  AssertEquals(0, FHost.ScheduleCount);
  AssertTrue(FPump.State = psDone);
  FPump.Stop;
  AssertEquals('Stop never calls PumpEnded', 0, FHost.EndedCount);
end;

procedure TWsPumpTest.StopInCall(const ACall: Integer);
begin
  if ACall = 1 then
  begin
    FPump.Stop;
    FDestroyedInCall := GWriterDestroyed;
  end;
end;

procedure TWsPumpTest.TestStopDuringNextChunkReleasesAfterIt;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  FWriter.OnCall := StopInCall;
  Start;
  FPump.Step;
  AssertFalse('the writer lives while NextChunk runs', FDestroyedInCall);
  AssertTrue('the writer is released when Step returns', GWriterDestroyed);
  AssertEquals('exactly one write follows the Stop', 1, FHost.Writes.Count);
  AssertTrue(FPump.State = psDone);
  AssertEquals('no second chunk is asked', 1, GWriterCalls);
end;

procedure TWsPumpTest.TestPoolStoppedEnds;
begin
  FWriter.Add('a', False);
  Start;
  ParkOnce;
  FHost.ScheduleResult := False;
  FPump.Wake;
  AssertTrue(FPump.State = psDone);
  AssertTrue(GWriterDestroyed);
end;

procedure TWsPumpTest.TestPoolStoppedAtParkEnds;
begin
  FWriter.Add('a', False);
  Start;
  FHost.AfterResult := False;
  ParkOnce;
  AssertTrue(FPump.State = psDone);
  AssertTrue(GWriterDestroyed);
end;

procedure TWsPumpTest.TestLateStepAfterTheEndDoesNothing;
begin
  FWriter.Add('a', False);
  Start;
  FPump.Step;
  AssertEquals(1, FHost.Writes.Count);
  FPump.Step;
  AssertEquals(1, FHost.Writes.Count);
  AssertEquals(0, FHost.DefectCount);
end;

procedure TWsPumpTest.TestPumpCountRaisingEndsThePump;
begin
  FWriter.Add('a', True);
  FWriter.Add('b', False);
  Start;
  FHost.RaiseInCount := True;
  FPump.Step;
  AssertEquals(1, FHost.EndedCount);
  AssertEquals('EPumpTestError', FHost.EndedClass);
  AssertEquals('count', FHost.EndedMessage);
  AssertTrue(FPump.State = psDone);
  AssertTrue(GWriterDestroyed);
  // the pump does not stay owned: a later Wake and Step do nothing
  FPump.Wake;
  FPump.Step;
  AssertEquals(1, FHost.Writes.Count);
  AssertEquals(0, FHost.ScheduleCount);
  AssertEquals(0, FHost.DefectCount);
end;

procedure TWsPumpTest.TestScheduleRaisingStopsThePump;
var
  I: Integer;
begin
  for I := 1 to 5 do
    FWriter.Add('c', True);
  Start(True, 1000, 2);
  FHost.RaiseInSchedule := True;
  FPump.Step;
  AssertEquals('the step limit asked for a schedule', 1, FHost.ScheduleCount);
  AssertTrue(FPump.State = psDone);
  AssertTrue(GWriterDestroyed);
  AssertEquals('Stop never calls PumpEnded', 0, FHost.EndedCount);
  AssertEquals(2, FHost.Writes.Count);
end;

procedure TWsPumpTest.WorkerLoop;
begin
  while FStop.WaitFor(0) <> wrSignaled do
    if FHost.TakeStep then
      FPump.Step
    else
      FHost.WorkEvent.WaitFor(5);
end;

procedure TWsPumpTest.WakerLoop;
begin
  while FStop.WaitFor(0) <> wrSignaled do
  begin
    FPump.Wake;
    FPump.TimerFired;
    Sleep(0);
  end;
end;

procedure TWsPumpTest.RunConcurrentOnce;
const
  cChunks = 2000;
var
  Threads: array[0..4] of TProcThread;
  I, N, Sum: Integer;
  Deadline: QWord;
  Rec: TWriteRec;
begin
  FStop.ResetEvent;
  GWriterCalls := 0;
  GWriterDestroyed := False;
  NewWriter;
  FWriter.Generate := cChunks;
  Start;
  FHost.EveryNthFull := 7;
  Threads[0] := TProcThread.Create(WorkerLoop);
  Threads[1] := TProcThread.Create(WorkerLoop);
  Threads[2] := TProcThread.Create(WakerLoop);
  Threads[3] := TProcThread.Create(WakerLoop);
  Threads[4] := TProcThread.Create(WakerLoop);
  try
    // the first schedule of the session
    FHost.PumpSchedule;
    Deadline := GetTickCount64 + 10000;
    while (FPump.State <> psDone) and (GetTickCount64 < Deadline) do
      Sleep(1);
    AssertTrue('the pump ends within 10 seconds', FPump.State = psDone);
  finally
    FStop.SetEvent;
    for I := 0 to 4 do
    begin
      Threads[I].Done.WaitFor(10000);
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
  end;
  // the FInStep guard of Enter reports a second Step as a defect before it can write
  AssertEquals('no two steps overlapped (no defect)', 0, FHost.DefectCount);
  AssertEquals('each chunk is asked once, and the end', cChunks + 1, GWriterCalls);
  N := 0;
  Sum := 0;
  for I := 0 to FHost.Writes.Count - 1 do
  begin
    Rec := FHost.Writes[I];
    if Rec.Result <> srQueued then
      Continue;
    if N = 0 then
      CheckFrame(I, WsOpText, False, IntToStr(N + 1))
    else if N < cChunks then
      CheckFrame(I, WsOpContinuation, False, IntToStr(N + 1))
    else
      CheckFrame(I, WsOpContinuation, True, '');
    Inc(N);
    if N <= cChunks then
      Inc(Sum, Length(IntToStr(N)));
  end;
  AssertEquals('the chunks and the final frame', cChunks + 1, N);
  AssertTrue('the last write is the final frame', FHost.Writes[FHost.Writes.Count - 1].Fin);
  AssertEquals('each payload octet is counted once', Sum, FHost.Counted);
  FPump := nil;
  FHostRef := nil;
  FHost := nil;
end;

procedure TWsPumpTest.TestConcurrentWakeAndStep;
var
  Run: Integer;
begin
  // the setup made a writer that this test does not use
  FWriter.Free;
  FWriter := nil;
  for Run := 1 to 50 do
    RunConcurrentOnce;
end;

initialization
  RegisterTest(TWsPumpTest);
end.
