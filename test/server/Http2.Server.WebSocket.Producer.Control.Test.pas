{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, sendstream, producer, control frames, stall, test, fpcunit
notes:
  - These tests cover the rules of the sink of a producer that are not in
    Http2.Server.WebSocket.Producer.Test: the rules of a chunk, the control replies between
    fragments, the outbound stall deadline, and the stop of the session at each place where
    the producer can be.
  - TScriptWriter is a producer that calls the sink by hand, so a test can send a chunk
    that the producer stream of the library never sends.
  - Each test waits on an event or on a condition with a deadline. No test relies on the
    length of a sleep for its result.
---
}
/// Tests of the control replies, the stall deadline and the stop of a producer
unit Http2.Server.WebSocket.Producer.Control.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.os,
  Http2.Common.Body, Http2.Common.Body.Producers, Http2.Server.Errors, Http2.Server.Duplex,
  Http2.Server.Observer, Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types,
  Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Session,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Stream.Test,
  Http2.Server.WebSocket.Producer.Test;

type
  /// a producer that calls the sink by hand
  TScriptWriter = class(TInterfacedObject, IBodyWriter, IBodyProducer)
  private
    FMode: Integer;
  public
    /// 1: a chunk of 6 octets that fails, caught, then a last chunk of 3 octets
    /// 2: an empty chunk that is not the last, then a last chunk of 3 octets
    constructor Create(const AMode: Integer);
    destructor Destroy; override;
    function NextChunk(const ABuffer: TStream): Boolean;
    procedure Produce(const ASink: IBodyChunkSink);
  end;

  TWsProducerControlTest = class(TWsProducerBase)
  private
    FReached: TEvent;
    FHold: TEvent;
    FSendGate: TEvent;
    FPoolGate: PRTLEvent;
    FStarted: QWord;
    function StreamScript(const AMode: Integer): TSendResult;
    function SendBlockedReached: Boolean;
    function PongIsOut: Boolean;
    function HeldRows3: TRowProducer;
    function ReasonOfClose: string;
  protected
    procedure TearDown; override;
  published
    procedure TestSwallowedFailureOfTheSinkStillFailsTheSession;
    procedure TestEmptyChunkThatIsNotLastIsSkipped;
    procedure TestPongGoesOutBetweenFragmentsWhileTheProducerRuns;
    procedure TestStalledChannelClosesWith1008AndEndsTheProducer;
    procedure TestChannelThatDrainsInTimeDoesNotClose;
    procedure TestChannelClosedDuringTheProducerEndsWith1006;
    procedure TestStopBetweenTwoWritesRaisesAtTheNextChunk;
    procedure TestStopBeforeTheStepEntersReleasesTheWriter;
  end;

implementation

{ TScriptWriter }

constructor TScriptWriter.Create(const AMode: Integer);
begin
  inherited Create;
  FMode := AMode;
end;

destructor TScriptWriter.Destroy;
begin
  InterlockedIncrement(GWriterDestroyed);
  inherited Destroy;
end;

function TScriptWriter.NextChunk(const ABuffer: TStream): Boolean;
begin
  raise Exception.Create('a script writer is a producer only');
end;

procedure TScriptWriter.Produce(const ASink: IBodyChunkSink);
var
  Big: array[0..5] of Byte;
  Small: array[0..2] of Byte;
  None: Byte;
begin
  FillChar(Big, SizeOf(Big), Ord('b'));
  FillChar(Small, SizeOf(Small), Ord('s'));
  None := 0;
  case FMode of
    1:
      begin
        try
          ASink.Chunk(Big, SizeOf(Big), False);
        except
          ;   // a producer that hides the failure of the sink
        end;
        ASink.Chunk(Small, SizeOf(Small), True);
      end;
    2:
      begin
        ASink.Chunk(None, 0, False);
        ASink.Chunk(Small, SizeOf(Small), True);
      end;
  end;
end;

{ TWsProducerControlTest }

function TWsProducerControlTest.StreamScript(const AMode: Integer): TSendResult;
var
  W: IBodyWriter;
begin
  W := TScriptWriter.Create(AMode);
  Result := FSession.SendStream(W, True);
  W := nil;
end;

procedure TWsProducerControlTest.TestSwallowedFailureOfTheSinkStillFailsTheSession;
begin
  // a chunk of 6 octets is over the limit of 4
  Build(Quick.WithMaxFrameSize(4).WithMaxMessageSize(4));
  AssertTrue('the stream is queued', StreamScript(1) = srQueued);
  AssertTrue('the handler hears Failed', WaitHandler('failed ', 5000));
  FWantCode := 1011;
  AssertTrue('the channel gets a Close frame of code 1011', WaitUntil(CloseCodeOut, 5000));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('one Failed call', 1, FailedLines);
  AssertEquals('the later chunk went out in no data frame', 0,
    Length(OutFrames) - CloseFrames);
end;

procedure TWsProducerControlTest.TestEmptyChunkThatIsNotLastIsSkipped;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  AssertTrue('the stream is queued', StreamScript(2) = srQueued);
  FWantCount := 1;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  L := OutFrames;
  AssertEquals('one frame: the empty chunk was skipped', 1, Length(L));
  CheckFrame(L[0], WsOpText, True, 'sss');
end;

procedure TWsProducerControlTest.TearDown;
begin
  // the rig goes first: its end wakes a sink that waits, and the producer leaves
  if FHold <> nil then
    FHold.SetEvent;
  if FSendGate <> nil then
    FSendGate.SetEvent;
  if FPoolGate <> nil then
    RTLEventSetEvent(FPoolGate);
  inherited TearDown;
  FreeAndNil(FReached);
  FreeAndNil(FHold);
  FreeAndNil(FSendGate);
  if FPoolGate <> nil then
    RTLEventDestroy(FPoolGate);
  FPoolGate := nil;
end;

function TWsProducerControlTest.SendBlockedReached: Boolean;
begin
  Result := FChannel.SendBlocked >= 1;
end;

function TWsProducerControlTest.PongIsOut: Boolean;
var
  L: TArray<TRawFrame>;
  I: Integer;
begin
  L := OutFrames;
  Result := False;
  for I := 0 to High(L) do
    if L[I].Opcode = WsOpPong then
      Result := True;
end;

function TWsProducerControlTest.HeldRows3: TRowProducer;
begin
  // the producer stops in its own code after its first Write
  Result := Rows3;
  FReached := TEvent.Create(nil, True, False, '');
  FHold := TEvent.Create(nil, True, False, '');
  Result.HoldAfter := 1;
  Result.Reached := FReached;
  Result.Hold := FHold;
end;

function TWsProducerControlTest.ReasonOfClose: string;
var
  L: TArray<TRawFrame>;
  I: Integer;
begin
  Result := '';
  L := OutFrames;
  for I := 0 to High(L) do
    if (L[I].Opcode = WsOpClose) and (Length(L[I].Payload) > 2) then
      Result := TextOf(Copy(L[I].Payload, 2, Length(L[I].Payload) - 2));
end;

procedure TWsProducerControlTest.TestPongGoesOutBetweenFragmentsWhileTheProducerRuns;
var
  L: TArray<TRawFrame>;
  I, PongAt: Integer;
begin
  Build(Quick);
  // the first write of the sink waits inside the channel, with the send lock held
  FSendGate := TEvent.Create(nil, True, False, '');
  FChannel.SendGate := FSendGate;
  AssertTrue('the stream is queued', StreamFixture(Rows3) = srQueued);
  AssertTrue('the sink holds the send lock', WaitUntil(SendBlockedReached));
  // the IO thread can not take the send lock, so it defers the Pong to the pool
  FChannel.Deliver(ClientFrame(WsOpPing, True, BytesOf('p')));
  FSendGate.SetEvent;
  FWantCount := 4;
  AssertTrue('the message and the Pong go out', WaitUntil(FrameCountReached));
  AssertTrue('the producer ends', WaitUntil(FixtureFinished));
  L := OutFrames;
  PongAt := -1;
  for I := 0 to High(L) do
    if L[I].Opcode = WsOpPong then
      PongAt := I;
  AssertTrue('a Pong went out', PongAt >= 0);
  AssertTrue('the Pong goes out before the last fragment', PongAt < High(L));
  AssertEquals('the Pong has the payload of the Ping', 'p', TextOf(L[PongAt].Payload));
  AssertTrue('the last frame carries FIN', L[High(L)].Fin);
end;

procedure TWsProducerControlTest.TestStalledChannelClosesWith1008AndEndsTheProducer;
begin
  Build(Quick.WithOutboundStallMs(500));
  // the channel takes control frames and refuses data frames
  FChannel.FullForData := True;
  FStarted := GetTickCount64;
  AssertTrue('the stream is queued', StreamFixture(Rows3) = srQueued);
  FWantCode := 1008;
  AssertTrue('a Close frame of code 1008 goes out', WaitUntil(CloseCodeOut, 10000));
  AssertTrue('the Close frame comes after the deadline', GetTickCount64 - FStarted >= 450);
  AssertEquals('the reason of the Close frame', 'the send stalled', ReasonOfClose);
  AssertTrue('the producer leaves', WaitUntil(FixtureFinished, 5000));
  AssertEquals('the Write of the producer raised EStreamCancelled', 'EStreamCancelled',
    FFixture.ErrorClass);
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('one Close frame', 1, CloseFrames);
  AssertEquals('no data frame went out', 0, Length(OutFrames) - CloseFrames);
  AssertEquals('the stall is quiet: no Failed', 0, FailedLines);
  // the pool thread is free again, so the Closed call of the handler can run
  FChannel.Deliver(ClientClose(1008, ''));
  AssertTrue('the handler gets Closed with code 1008', WaitHandler('closed 1008 ', 5000));
end;

procedure TWsProducerControlTest.TestChannelThatDrainsInTimeDoesNotClose;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick.WithOutboundStallMs(5000));
  ParkOnFull;
  FChannel.Drain;
  FWantCount := 3;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  L := OutFrames;
  AssertEquals('three fragments and no Close frame', 3, Length(L));
  AssertTrue('the last fragment carries FIN', L[2].Fin);
  AssertEquals('no Close frame', 0, CloseFrames);
end;

procedure TWsProducerControlTest.TestChannelClosedDuringTheProducerEndsWith1006;
begin
  Build(Quick);
  ParkOnFull;
  // the transport is gone: the next write answers srClosed
  FChannel.Close(ccAbort);
  FChannel.Drain;
  AssertTrue('the producer leaves', WaitUntil(FixtureFinished, 5000));
  AssertEquals('the Write of the producer raised EStreamCancelled', 'EStreamCancelled',
    FFixture.ErrorClass);
  AssertTrue('the handler gets Closed with code 1006', WaitHandler('closed 1006 ', 5000));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('no Failed', 0, FailedLines);
end;

procedure TWsProducerControlTest.TestStopBetweenTwoWritesRaisesAtTheNextChunk;
begin
  Build(Quick);
  HeldRows3;
  AssertTrue('the stream is queued', StreamFixture(FFixture) = srQueued);
  // the producer is in its own code after its first Write, and calls no sink
  AssertTrue('the producer reached its hold', FReached.WaitFor(5000) = wrSignaled);
  FSession.Abort;
  FHold.SetEvent;
  AssertTrue('the producer leaves', WaitUntil(FixtureFinished, 5000));
  AssertEquals('the next Write raised EStreamCancelled', 'EStreamCancelled',
    FFixture.ErrorClass);
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('no Failed', 0, FailedLines);
end;

procedure TWsProducerControlTest.TestStopBeforeTheStepEntersReleasesTheWriter;
begin
  Build(Quick);
  // the handler holds the pool thread of the session, so the step waits in the queue
  FPoolGate := RTLEventCreate;
  FHandler.Gate := FPoolGate;
  FChannel.Deliver(ClientText('hold'));
  AssertTrue('the stream is queued', StreamFixture(Rows3) = srQueued);
  FSession.Abort;
  FWantGone := 1;
  // the stop released the writer on its own thread; the step never ran
  AssertTrue('the writer is released', WaitUntil(WriterGone, 5000));
  AssertEquals('the producer never ran', 0, FFixture.Finished);
  AssertEquals('the handler is still held', 0, Pos('msg T hold', FHandler.AllText));
  RTLEventSetEvent(FPoolGate);
end;

initialization
  RegisterTest(TWsProducerControlTest);
end.
