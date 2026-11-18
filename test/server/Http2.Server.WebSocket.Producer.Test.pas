{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, sendstream, producer, test, fpcunit
notes:
  - These tests drive SendStream of the WebSocket session with a writer that is an
    IBodyProducer. The producer runs on the streaming pool thread, and the sink waits
    there while the channel is full.
  - A row of the producers has the size of the chunk, so each row is one fragment. The
    stream keeps one chunk back, so the last row carries FIN and no empty frame follows.
  - Full refuses every Send. SetFullCount refuses only the next Send, so a Close frame
    goes out while the sink waits.
  - TProbeWriter reports its release to the global counter of Http2.Server.WebSocket.Stream.Test.
  - The thread test is in Http2.Server.WebSocket.Producer.Threads.Test.
---
}
/// Session level tests of SendStream with a producer
unit Http2.Server.WebSocket.Producer.Test;

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
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Stream.Test;

type
  /// the code that a producer body runs; each call of a Write counts in GWriterCalls
  TRowProducer = class
  private
    FRows: TArray<TBytes>;
    FRaiseAfter: Integer;
    FHoldAfter: Integer;
    FReached: TEvent;
    FHold: TEvent;
    FRunning: Integer;
    FFinished: Integer;
    FErrorClass: string;
  public
    /// the rows that WriteRows writes; each row is one Write
    constructor Create(const ARows: TArray<TBytes>);
    /// write the rows, one Write each
    // - a Write that raises is noted in ErrorClass and raised again
    // - after RaiseAfter rows (when it is above 0) the method raises its own exception
    procedure WriteRows(const AOut: TStream);
    /// write nothing
    procedure WriteNothing(const AOut: TStream);
    property RaiseAfter: Integer read FRaiseAfter write FRaiseAfter;
    /// after the Write of this row (1 based) the producer sets Reached and then waits on
    /// Hold (at most 10 seconds); it holds the producer in its own code
    property HoldAfter: Integer read FHoldAfter write FHoldAfter;
    property Reached: TEvent read FReached write FReached;
    property Hold: TEvent read FHold write FHold;
    /// the class name of the exception that a Write raised; empty when none
    property ErrorClass: string read FErrorClass;
    /// 1 when the producer method has left
    property Finished: Integer read FFinished;
    /// 1 while the producer method runs
    property Running: Integer read FRunning;
  end;

  /// a writer that is a producer, and that reports its release
  TProbeWriter = class(TInterfacedObject, IBodyWriter, IBodyProducer)
  private
    FInner: IBodyWriter;
  public
    constructor Create(const AInner: IBodyWriter);
    destructor Destroy; override;
    function NextChunk(const ABuffer: TStream): Boolean;
    procedure Produce(const ASink: IBodyChunkSink);
  end;

  /// the helpers of the session tests of SendStream with a producer; no tests of its own
  TWsProducerBase = class(TWsStreamBase)
  protected
    FFixture: TRowProducer;
    function Rows3: TRowProducer;
    /// SendStream with a producer writer of AFixture; no reference to the writer stays in the test
    function StreamFixture(const AFixture: TRowProducer): TSendResult;
    function FixtureFinished: Boolean;
    function CloseFrames: Integer;
    function FailedLines: Integer;
    function FrameCountReached: Boolean;
    procedure ParkOnFull;
    procedure TearDown; override;
  end;

  /// the session tests of SendStream with a producer
  TWsProducerTest = class(TWsProducerBase)
  published
    procedure TestRowsArriveAsFragmentsWithFin;
    procedure TestFullParksTheThreadAndDrainResumes;
    procedure TestFullResumesThroughThePollWithoutDrain;
    procedure TestEndOfSessionWhileTheSinkWaitsRaisesInTheProducer;
    procedure TestEmptyProducerSendsOneEmptyTextFrame;
    procedure TestProducerExceptionFailsTheSessionOnce;
    procedure TestSendDuringTheProducerIsRefused;
    procedure TestCloseByTheApplicationKeepsTheCleanClose;
    procedure TestChunkOverMaxMessageSizeFailsTheSession;
  end;

/// a body writer for AFixture: one chunk of ARowBytes octets for each row
function RowWriter(const AFixture: TRowProducer; const ARowBytes: Integer): IBodyWriter;

implementation

{ TRowProducer }

constructor TRowProducer.Create(const ARows: TArray<TBytes>);
begin
  inherited Create;
  FRows := ARows;
end;

procedure TRowProducer.WriteRows(const AOut: TStream);
var
  I: Integer;
begin
  InterlockedIncrement(FRunning);
  try
    for I := 0 to High(FRows) do
    begin
      try
        if Length(FRows[I]) > 0 then
          AOut.WriteBuffer(FRows[I][0], Length(FRows[I]));
      except
        on E: Exception do
        begin
          FErrorClass := E.ClassName;
          raise;
        end;
      end;
      InterlockedIncrement(GWriterCalls);
      if (FHoldAfter > 0) and (I + 1 = FHoldAfter) then
      begin
        if FReached <> nil then
          FReached.SetEvent;
        if FHold <> nil then
          FHold.WaitFor(10000);
      end;
      if (FRaiseAfter > 0) and (I + 1 = FRaiseAfter) then
        raise Exception.Create('boom');
    end;
  finally
    InterlockedDecrement(FRunning);
    InterlockedIncrement(FFinished);
  end;
end;

procedure TRowProducer.WriteNothing(const AOut: TStream);
begin
  InterlockedIncrement(FFinished);
end;

{ TProbeWriter }

constructor TProbeWriter.Create(const AInner: IBodyWriter);
begin
  inherited Create;
  FInner := AInner;
end;

destructor TProbeWriter.Destroy;
begin
  FInner := nil;
  InterlockedIncrement(GWriterDestroyed);
  inherited Destroy;
end;

function TProbeWriter.NextChunk(const ABuffer: TStream): Boolean;
begin
  Result := FInner.NextChunk(ABuffer);
end;

procedure TProbeWriter.Produce(const ASink: IBodyChunkSink);
var
  P: IBodyProducer;
begin
  if not Supports(FInner, IBodyProducer, P) then
    raise Exception.Create('the inner writer is no producer');
  P.Produce(ASink);
end;

function RowWriter(const AFixture: TRowProducer; const ARowBytes: Integer): IBodyWriter;
begin
  Result := TProbeWriter.Create(BodyWriterFromStream(AFixture.WriteRows, ARowBytes));
end;

{ TWsProducerBase }

procedure TWsProducerBase.TearDown;
var
  Waited: Integer;
begin
  // the end of the session wakes a sink that waits; the producer must leave before the
  // fixture goes
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

function TWsProducerBase.Rows3: TRowProducer;
begin
  FFixture := TRowProducer.Create(TextChunks(['row1;', 'row2;', 'row3;']));
  Result := FFixture;
end;

function TWsProducerBase.StreamFixture(const AFixture: TRowProducer): TSendResult;
var
  W: IBodyWriter;
begin
  // a function result that is passed on stays alive until the end of the routine that
  // called it, so the reference lives in this small routine and ends here
  W := RowWriter(AFixture, 5);
  Result := FSession.SendStream(W, True);
  W := nil;
end;

function TWsProducerBase.FixtureFinished: Boolean;
begin
  Result := FFixture.Finished >= 1;
end;

function TWsProducerBase.CloseFrames: Integer;
var
  L: TArray<TRawFrame>;
  I: Integer;
begin
  L := OutFrames;
  Result := 0;
  for I := 0 to High(L) do
    if L[I].Opcode = WsOpClose then
      Inc(Result);
end;

function TWsProducerBase.FailedLines: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FHandler.Count - 1 do
    if Pos('failed ', FHandler.Line(I)) = 1 then
      Inc(Result);
end;

function TWsProducerBase.FrameCountReached: Boolean;
begin
  Result := Length(OutFrames) >= FWantCount;
end;

procedure TWsProducerBase.ParkOnFull;
begin
  // the first row is held back, and the write of the second row refuses: the sink waits
  FChannel.Full := True;
  AssertTrue('the stream is queued',
    StreamFixture(Rows3) = srQueued);
  FWantCalls := 1;
  AssertTrue('the producer wrote its first row', WaitUntil(CallsReached));
  // the second Write blocks in the sink, so the count stays at 1
  Sleep(100);
end;

{ TWsProducerTest }

procedure TWsProducerTest.TestRowsArriveAsFragmentsWithFin;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  AssertTrue('the stream is queued',
    StreamFixture(Rows3) = srQueued);
  FWantCount := 3;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  L := OutFrames;
  AssertEquals('three rows, no empty final frame', 3, Length(L));
  CheckFrame(L[0], WsOpText, False, 'row1;');
  CheckFrame(L[1], WsOpContinuation, False, 'row2;');
  CheckFrame(L[2], WsOpContinuation, True, 'row3;');
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertTrue('the next message can go out', FSession.Send(BytesOf('y'), True) = srQueued);
end;

procedure TWsProducerTest.TestFullParksTheThreadAndDrainResumes;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  ParkOnFull;
  Sleep(400);
  AssertEquals('the producer waits in its second Write', 1, GWriterCalls);
  AssertEquals('no fragment went out', 0, Length(OutFrames));
  AssertEquals('the producer thread is inside the producer', 1, FFixture.Running);
  FChannel.Drain;
  FWantCount := 3;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  L := OutFrames;
  AssertEquals('three fragments', 3, Length(L));
  CheckFrame(L[0], WsOpText, False, 'row1;');
  CheckFrame(L[1], WsOpContinuation, False, 'row2;');
  CheckFrame(L[2], WsOpContinuation, True, 'row3;');
  AssertTrue('the producer ends', WaitUntil(FixtureFinished));
  AssertEquals('no Write raised', '', FFixture.ErrorClass);
end;

procedure TWsProducerTest.TestFullResumesThroughThePollWithoutDrain;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  ParkOnFull;
  // no Drain call: only the re-check of the sink can find the room
  FChannel.Full := False;
  FWantCount := 3;
  AssertTrue('the poll completes the message within 2 seconds',
    WaitUntil(FrameCountReached, 2000));
  L := OutFrames;
  AssertEquals('three fragments', 3, Length(L));
  CheckFrame(L[0], WsOpText, False, 'row1;');
  CheckFrame(L[2], WsOpContinuation, True, 'row3;');
end;

procedure TWsProducerTest.TestEndOfSessionWhileTheSinkWaitsRaisesInTheProducer;
begin
  Build(Quick);
  ParkOnFull;
  FSession.Abort;
  AssertTrue('the producer leaves', WaitUntil(FixtureFinished, 5000));
  AssertEquals('the Write of the producer raised EStreamCancelled', 'EStreamCancelled',
    FFixture.ErrorClass);
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('the cancel is quiet: the handler hears no Failed', 0, FailedLines);
end;

procedure TWsProducerTest.TestEmptyProducerSendsOneEmptyTextFrame;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  FFixture := TRowProducer.Create(nil);
  AssertTrue('the stream is queued',
    FSession.SendStream(TProbeWriter.Create(BodyWriterFromStream(FFixture.WriteNothing)),
      True) = srQueued);
  FWantCount := 1;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  L := OutFrames;
  AssertEquals('one frame', 1, Length(L));
  CheckFrame(L[0], WsOpText, True, '');
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertTrue('the next message can go out', FSession.Send(BytesOf('y'), True) = srQueued);
end;

procedure TWsProducerTest.TestProducerExceptionFailsTheSessionOnce;
begin
  Build(Quick);
  Rows3.RaiseAfter := 2;
  AssertTrue('the stream is queued',
    StreamFixture(FFixture) = srQueued);
  AssertTrue('the handler hears Failed', WaitHandler('failed boom', 5000));
  FWantCode := 1011;
  AssertTrue('the channel gets a Close frame of code 1011', WaitUntil(CloseCodeOut, 5000));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  Sleep(300);
  AssertEquals('one Failed call', 1, FailedLines);
  AssertEquals('one Close frame', 1, CloseFrames);
end;

procedure TWsProducerTest.TestSendDuringTheProducerIsRefused;
begin
  Build(Quick);
  ParkOnFull;
  AssertTrue('Send is refused while the producer runs',
    FSession.Send(BytesOf('x'), True) = srFull);
  AssertTrue('SendStream is refused while the producer runs',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['z'])), True) = srFull);
  FChannel.Full := False;
  FChannel.Drain;
  FWantCount := 3;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  FWantGone := 2;
  AssertTrue('both writers are released', WaitUntil(WriterGone));
  AssertTrue('Send is queued after the stream', FSession.Send(BytesOf('y'), True) = srQueued);
end;

procedure TWsProducerTest.TestCloseByTheApplicationKeepsTheCleanClose;
var
  L: TArray<TRawFrame>;
  I: Integer;
  Seen: Boolean;
begin
  Build(Quick.WithCloseTimeoutMs(5000));
  // the write of the first fragment refuses once, and the sink waits for 250 ms before it
  // sends the fragment again; the Close frame goes out in that time
  FChannel.SetFullCount(1);
  AssertTrue('the stream is queued',
    StreamFixture(Rows3) = srQueued);
  FWantCalls := 1;
  AssertTrue('the producer wrote its first row', WaitUntil(CallsReached));
  Sleep(50);
  FSession.Close(1000, '');
  AssertTrue('the producer leaves', WaitUntil(FixtureFinished, 5000));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  L := OutFrames;
  Seen := False;
  for I := 0 to High(L) do
    if L[I].Opcode = WsOpClose then
      Seen := True
    else if Seen and (L[I].Opcode <= WsOpBinary) then
      Fail('a data frame follows the Close frame');
  AssertTrue('the Close frame went out', Seen);
  FChannel.Deliver(ClientClose(1000, ''));
  AssertTrue('the handler gets Closed with code 1000', WaitHandler('closed 1000 ', 5000));
  AssertTrue('the close is clean', Pos('clean=True', FHandler.AllText) > 0);
  AssertEquals('the application close is no failure', 0, FailedLines);
end;

procedure TWsProducerTest.TestChunkOverMaxMessageSizeFailsTheSession;
begin
  // a row of 5 octets is over the limit of 4
  Build(Quick.WithMaxFrameSize(4).WithMaxMessageSize(4));
  Rows3;
  AssertTrue('the stream is queued',
    StreamFixture(FFixture) = srQueued);
  AssertTrue('the handler hears Failed', WaitHandler('failed ', 5000));
  FWantCode := 1011;
  AssertTrue('the channel gets a Close frame of code 1011', WaitUntil(CloseCodeOut, 5000));
  AssertEquals('no data frame went out', 0, Length(OutFrames) - CloseFrames);
end;

initialization
  RegisterTest(TWsProducerTest);
end.
