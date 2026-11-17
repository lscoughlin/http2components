{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, sendstream, threads, test, fpcunit
notes:
  - These thread tests run the race between SendStream, Send, Drain and Close on real
    threads. Each test repeats its scenario cThreadTestRuns times. Each wait has a
    deadline, so a hang fails the test and does not block the suite.
  - Every run checks that no overlapping pump step was reported (the event
    seHandlerException counts the reports of PumpDefect).
---
}
/// Thread tests of the streamed WebSocket message (SendStream)
unit Http2.Server.WebSocket.Stream.Threads.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.os,
  Http2.Common.Body, Http2.Server.Errors, Http2.Server.Duplex, Http2.Server.Seam,
  Http2.Server.Observer, Http2.Server.Sse.Test, Http2.Server.WebSocket.Options,
  Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.Session, Http2.Server.WsHardening.Test,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Stream.Test;

const
  /// the number of times that each thread test repeats its scenario
  cThreadTestRuns = 50;
  /// the sessions that one run of the close test opens
  cCloseSessions = 100;
  /// the messages that the sender thread sends
  cSenderMessages = 200;
  /// the chunks of the stream that the sender test starts
  cSenderChunks = 200;
  /// the chunks of the stream of each session in the close test
  cCloseChunks = 20;

type
  /// the thread tests of SendStream; each test repeats its scenario cThreadTestRuns times
  TWsStreamThreadTest = class(TWsStreamBase)
  private
    FStart: TEvent;
    FSessions: TArray<IWsSession>;
    FChans: TArray<TFakeWsChannel>;
    FChanRefs: TArray<IDuplexChannel>;
    procedure SenderLoop;
    procedure CloseLoop;
    procedure DrainAndWait;
    function AllActivated: Boolean;
    procedure ClearSessions;
    procedure CheckNoSplit(const L: TArray<TRawFrame>);
    procedure CheckNoOverlap;
  protected
    procedure TearDown; override;
  published
    procedure TestSendWaitingForTheLockCannotSplitAStream;
    procedure TestDrainAndTimerTogetherRunOneStep;
    procedure TestCloseWhileAWriteIsInFlight;
  end;

implementation

{ TWsStreamThreadTest }

procedure TWsStreamThreadTest.TearDown;
begin
  ClearSessions;
  inherited TearDown;
end;

procedure TWsStreamThreadTest.ClearSessions;
begin
  FSessions := nil;
  FChanRefs := nil;
  FChans := nil;
end;

procedure TWsStreamThreadTest.SenderLoop;
var
  I: Integer;
begin
  for I := 1 to cSenderMessages do
    FSession.Send(BytesOf('m'), True);
end;

procedure TWsStreamThreadTest.CloseLoop;
var
  I: Integer;
begin
  for I := 0 to High(FSessions) do
    FSessions[I].Close(1000, '');
end;

procedure TWsStreamThreadTest.DrainAndWait;
begin
  // both threads start at the same moment, and each waits 250 ms after its drain
  FStart.WaitFor(5000);
  FChannel.Drain;
  Sleep(250);
end;

function TWsStreamThreadTest.AllActivated: Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FChans) do
    if not FChans[I].Activated then
      Exit(False);
  Result := True;
end;

procedure TWsStreamThreadTest.CheckNoSplit(const L: TArray<TRawFrame>);
var
  First, Last, I: Integer;
begin
  // the first fragment of the stream: a text frame with the payload of the chunk 'S'
  First := -1;
  for I := 0 to High(L) do
    if (First < 0) and (L[I].Opcode = WsOpText) and (not L[I].Fin) and
      (Length(L[I].Payload) = 1) and (L[I].Payload[0] = Ord('S')) then
      First := I;
  AssertTrue('the stream started', First >= 0);
  // the FIN frame of the stream: the first continuation frame with FIN after it
  Last := -1;
  for I := First + 1 to High(L) do
    if L[I].Fin and (L[I].Opcode = WsOpContinuation) then
    begin
      Last := I;
      Break;
    end;
  AssertTrue('the stream has its FIN frame', Last > First);
  // a message of Send has the opcode text, and it cannot appear inside the stream
  for I := First + 1 to Last do
    AssertTrue('no data frame of another message inside the stream, frame ' + IntToStr(I),
      L[I].Opcode = WsOpContinuation);
  AssertEquals('every chunk and the final frame', cSenderChunks + 1, Last - First + 1);
end;

procedure TWsStreamThreadTest.CheckNoOverlap;
begin
  AssertEquals('no overlapping pump step was reported', 0,
    FRig.EventCount(seHandlerException));
end;

procedure TWsStreamThreadTest.TestSendWaitingForTheLockCannotSplitAStream;
var
  Sender: TProcThread;
  Run: Integer;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    GWriterCalls := 0;
    GWriterDestroyed := 0;
    Build(Quick);
    Sender := TProcThread.Create(SenderLoop);
    AssertTrue('the stream is queued',
      FSession.SendStream(TStreamWriter.Create(RepeatedChunks('S', cSenderChunks)), True) = srQueued);
    if Sender.Done.WaitFor(10000) <> wrSignaled then
      Fail('run ' + IntToStr(Run) + ': the sender thread does not end');
    Sender.WaitFor;
    Sender.Free;
    FWantFins := 1;
    AssertTrue('run ' + IntToStr(Run) + ': the stream completes', WaitUntil(FinCountReached, 10000));
    CheckNoSplit(OutFrames);
    CheckNoOverlap;
    DropRig;
  end;
end;

procedure TWsStreamThreadTest.TestDrainAndTimerTogetherRunOneStep;
var
  T1, T2: TProcThread;
  Run: Integer;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    GWriterCalls := 0;
    GWriterDestroyed := 0;
    Build(Quick);
    FChannel.Full := True;
    AssertTrue('run ' + IntToStr(Run) + ': the stream is queued',
      FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
    FWantCalls := 1;
    AssertTrue('run ' + IntToStr(Run) + ': the writer is asked for one chunk',
      WaitUntil(CallsReached));
    // the stream parks: the refused fragment waits for the drain or the park timer
    Sleep(50);
    FStart := TEvent.Create(nil, True, False, '');
    T1 := TProcThread.Create(DrainAndWait);
    T2 := TProcThread.Create(DrainAndWait);
    FStart.SetEvent;
    if T1.Done.WaitFor(10000) <> wrSignaled then
      Fail('run ' + IntToStr(Run) + ': the first drain does not end');
    if T2.Done.WaitFor(10000) <> wrSignaled then
      Fail('run ' + IntToStr(Run) + ': the second drain does not end');
    T1.WaitFor;
    T1.Free;
    T2.WaitFor;
    T2.Free;
    FreeAndNil(FStart);
    AssertTrue('run ' + IntToStr(Run) + ': the message completes', WaitUntil(StreamDone, 5000));
    CheckRowFragments(OutFrames);
    AssertEquals('run ' + IntToStr(Run) + ': each chunk is asked once', 4, GWriterCalls);
    CheckNoOverlap;
    DropRig;
  end;
end;

procedure TWsStreamThreadTest.TestCloseWhileAWriteIsInFlight;
var
  Closer: TProcThread;
  Run, I: Integer;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    GWriterCalls := 0;
    GWriterDestroyed := 0;
    // one rig with many sessions; the echo of each Close arrives after the closer ends
    FRig := TWsRig.Create(Quick.WithCloseTimeoutMs(10000));
    FHandler := TRecordingHandler.Create;
    FInnerRef := FHandler;
    FHandlerRef := FInnerRef;
    FRequest := TFakeRequest.Create;
    FRequestRef := FRequest;
    SetLength(FChans, cCloseSessions);
    SetLength(FChanRefs, cCloseSessions);
    SetLength(FSessions, cCloseSessions);
    for I := 0 to cCloseSessions - 1 do
    begin
      FChans[I] := FRig.NewChannel;
      FChanRefs[I] := FChans[I];
      FSessions[I] := WsStartSession(FChanRefs[I], FRequestRef, FHandlerRef,
        TFakeHandshake.Create, nil);
    end;
    AssertTrue('run ' + IntToStr(Run) + ': every session opened', WaitUntil(AllActivated, 20000));
    for I := 0 to cCloseSessions - 1 do
      AssertTrue('run ' + IntToStr(Run) + ': a stream is queued',
        FSessions[I].SendStream(TStreamWriter.Create(RepeatedChunks('x', cCloseChunks)), True) = srQueued);
    Closer := TProcThread.Create(CloseLoop);
    if Closer.Done.WaitFor(20000) <> wrSignaled then
      Fail('run ' + IntToStr(Run) + ': the closer does not end');
    Closer.WaitFor;
    Closer.Free;
    // the echo of each Close frame of the peer
    for I := 0 to cCloseSessions - 1 do
      FChans[I].Deliver(ClientClose(1000, ''));
    FWantCount := cCloseSessions;
    AssertTrue('run ' + IntToStr(Run) + ': every session closes', WaitUntil(CleanClosesReached, 20000));
    AssertEquals('run ' + IntToStr(Run) + ': every close is clean with code 1000',
      cCloseSessions, CleanCloseCount);
    CheckNoOverlap;
    ClearSessions;
    DropRig;
  end;
end;

initialization
  RegisterTest(TWsStreamThreadTest);
end.
