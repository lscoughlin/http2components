{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, sendstream, producer, threads, test, fpcunit
notes:
  - This thread test runs a producer on a streaming pool thread against a thread that
    refuses and drains the channel. The scenario runs once.
  - The wait has a deadline, so a hang fails the test and does not block the suite.
  - The test checks that the fragments arrive in order with FIN on the last one, that the
    octets are complete, and that no overlapping pump step was reported.
---
}
/// Thread test of SendStream with a producer
unit Http2.Server.WebSocket.Producer.Threads.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Body, Http2.Server.Duplex, Http2.Server.Observer, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Stream.Test,
  Http2.Server.WsHardening.Test, Http2.Server.WebSocket.Producer.Test;

const
  /// the rows that the producer writes; each row is one octet and one fragment
  cProducerRows = 300;

type
  /// the thread test of a producer; the scenario runs once
  TWsProducerThreadTest = class(TWsStreamBase)
  private
    FStop: Integer;
    FFixture: TRowProducer;
    procedure DrainLoop;
    function Expected: TBytes;
    function MessageDone: Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestProducerAgainstADrainingThread;
  end;

implementation

{ TWsProducerThreadTest }

procedure TWsProducerThreadTest.TearDown;
var
  Waited: Integer;
begin
  inherited TearDown;
  Waited := 0;
  while (FFixture <> nil) and (FFixture.Running > 0) and (Waited < 5000) do
  begin
    Sleep(10);
    Inc(Waited, 10);
  end;
  if (FFixture <> nil) and (FFixture.Running = 0) then
    FreeAndNil(FFixture);
  FFixture := nil;
end;

procedure TWsProducerThreadTest.DrainLoop;
begin
  // refuse the next write, wait a moment, and drain: the sink waits and wakes again
  // - the refusal and the drain take turns, so the sink always finds room after a drain
  while InterlockedCompareExchange(FStop, 0, 0) = 0 do
  begin
    FChannel.SetFullCount(1);
    Sleep(1);
    FChannel.Drain;
    Sleep(2);
  end;
end;

function TWsProducerThreadTest.Expected: TBytes;
var
  I: Integer;
begin
  SetLength(Result, cProducerRows);
  for I := 0 to cProducerRows - 1 do
    Result[I] := Byte(65 + (I mod 26));
end;

function TWsProducerThreadTest.MessageDone: Boolean;
var
  L: TArray<TRawFrame>;
begin
  L := OutFrames;
  Result := (Length(L) > 0) and L[High(L)].Fin;
end;

procedure TWsProducerThreadTest.TestProducerAgainstADrainingThread;
var
  Rows: TArray<TBytes>;
  Want: TBytes;
  Drainer: TProcThread;
  L: TArray<TRawFrame>;
  Got: TBytes;
  I: Integer;
begin
  Build(Quick);
  Want := Expected;
  SetLength(Rows, cProducerRows);
  for I := 0 to cProducerRows - 1 do
    Rows[I] := OneOctet(Want[I]);
  FFixture := TRowProducer.Create(Rows);
  Drainer := TProcThread.Create(DrainLoop);
  try
    AssertTrue('the stream is queued',
      FSession.SendStream(RowWriter(FFixture, 1), True) = srQueued);
    AssertTrue('the message completes', WaitUntil(MessageDone, 20000));
  finally
    InterlockedExchange(FStop, 1);
    if Drainer.Done.WaitFor(10000) <> wrSignaled then
      Fail('the draining thread does not end');
    Drainer.WaitFor;
    Drainer.Free;
  end;
  L := OutFrames;
  AssertEquals('one fragment for each row', cProducerRows, Length(L));
  AssertEquals('the first fragment has the text opcode', Integer(WsOpText), Integer(L[0].Opcode));
  for I := 1 to High(L) do
    AssertEquals('continuation ' + IntToStr(I), Integer(WsOpContinuation), Integer(L[I].Opcode));
  for I := 0 to High(L) - 1 do
    AssertFalse('no FIN before the end, fragment ' + IntToStr(I), L[I].Fin);
  AssertTrue('FIN on the last fragment', L[High(L)].Fin);
  Got := JoinedData(L);
  AssertEquals('the octets are complete', TextOf(Want), TextOf(Got));
  AssertEquals('no overlapping pump step was reported', 0, FRig.EventCount(seHandlerException));
  AssertEquals('no Write raised', '', FFixture.ErrorClass);
end;

initialization
  RegisterTest(TWsProducerThreadTest);
end.
