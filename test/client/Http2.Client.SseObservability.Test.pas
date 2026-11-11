{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.SseObservability.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Redirects.Test,
  Http2.Client.ClearText.Support, Http2.Client.Http1, Http2.Client.Http1.Test, Http2.Client.Sse, Http2.Client.RequestObserver.Support;

type
  TSseObservabilityTest = class(TTestCase)
  private
    function Build(const AFactory: TFakeFrameFactory;
      const AObserver: IHttpClientObserver;
      const ALogger: IHttpLogger = nil): IHttpClient;
    procedure Barrier(const ASocket: TFakeFrameSocket);
    procedure Push(const ASocket: TFakeFrameSocket; const AText: string;
      const AEndStream: Boolean; const AStampUs: Int64);
    function OpenFactory: TFakeFrameFactory;
  protected
    procedure TearDown; override;
  published
    // 20.1
    procedure TestSseRequestIsReportedAsSseAndAPlainOneIsNot;
    // 20.2 / 20.3
    procedure TestReconnectingStreamSharesOneStreamIdAndCountsReconnects;
    procedure TestEveryReconnectCarriesTheContext;
    procedure TestTwoLoopsGetTwoStreamIds;
    // 20.5 / 20.6
    procedure TestEventsTakeTheStampOfTheChunkThatCompletedThem;
    procedure TestEventsInOneFrameShareItsStamp;
    procedure TestTheLastFrameOfTheBodyIsCountedBeforeTheEnd;
    procedure TestCommentsAndKeepAlivesAreNotMessages;
    // 20.8 / 20.9
    procedure TestObserverThatWantsNothingReceivesNothing;
    procedure TestObserverReceivesEveryEventWithItsDetail;
    procedure TestWantsMessagesIsAskedOncePerAttempt;
    // 20.10
    procedure TestCloseMidStreamEndsOnceAndNotAbandoned;
    procedure TestDroppingTheSourceUnreadIsAbandoned;
    procedure TestReadingToTheEndEndsOnceNotAbandoned;
    // 20.12
    procedure TestSlowConsumerDoesNotChangeTheStamps;
    procedure TestRaisingOnMessageDoesNotBreakTheStream;
  end;


  TSseHttp1ObservabilityTest = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    // 20.11
    procedure TestEventsTakeTheStampOfTheTransportReadThatCompletedThem;
    procedure TestChunkedStreamKeepsTheSameStamps;
  end;


implementation

{ Server-Sent Events observation }

const
  /// gzip of 'hello'
  cGzipHello: array[0..24] of Byte = (31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 203,
    72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0);
  cEventStreamType = 'text/event-stream';
  cStreamUrl = 'https://a.example/events';

/// a 200 event-stream head that stays open
function SseOpenSpec: TRespSpec;
begin
  Result := WithContentType(HdrSpec('200', '', nil, False), cEventStreamType);
end;

/// a 200 event-stream response whose body ends the stream
function SseBodySpec(const ABody: string): TRespSpec;
begin
  Result := WithContentType(HdrSpec('200', '', BytesOf(ABody), True),
    cEventStreamType);
end;

/// a 200 event-stream response with a body and the stream left open
function SseOpenBodySpec(const ABody: string): TRespSpec;
begin
  Result := WithOpenBody(SseBodySpec(ABody));
end;


{ TSseObservabilityTest }

procedure TSseObservabilityTest.TearDown;
begin
  ResetNowUsHook;
  inherited TearDown;
end;

function TSseObservabilityTest.Build(const AFactory: TFakeFrameFactory;
  const AObserver: IHttpClientObserver;
  const ALogger: IHttpLogger): IHttpClient;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create.WithSocketFactory(AFactory);
  if AObserver <> nil then
    F := F.WithRequestObserver(AObserver);
  if ALogger <> nil then
    F := F.WithLogger(ALogger);
  Result := F.Build;
end;

function TSseObservabilityTest.OpenFactory: TFakeFrameFactory;
begin
  Result := TFakeFrameFactory.Create;
  Result.SetDialScript(0, SpecArray([SseOpenSpec]));
end;

procedure TSseObservabilityTest.Barrier(const ASocket: TFakeFrameSocket);
var
  Before: Integer;
  Deadline: QWord;
begin
  // frames are read and routed in order, so the ACK of a PING queued behind
  // them proves the reader thread is done with every earlier frame
  Before := CountPingAcks(ASocket.WrittenFrames);
  ASocket.InjectFrame(BuildPingFrame(BytesOf('barrier!'), False));
  Deadline := GetTickCount64 + 5000;
  repeat
    if CountPingAcks(ASocket.WrittenFrames) > Before then
      Exit;
    Sleep(1);   // bounded poll on the peer's written bytes
  until GetTickCount64 >= Deadline;
  Fail('the barrier PING was never acknowledged');
end;

procedure TSseObservabilityTest.Push(const ASocket: TFakeFrameSocket;
  const AText: string; const AEndStream: Boolean; const AStampUs: Int64);
begin
  GScriptedUs := AStampUs;
  ASocket.InjectFrame(BuildDataFrame(1, BytesOf(AText), AEndStream));
  Barrier(ASocket);
end;
procedure TSseObservabilityTest.TestSseRequestIsReportedAsSseAndAPlainOneIsNot;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R1, R2: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([SseOpenSpec, HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R1 := Client.Send(SseRequest(cStreamUrl));
  R2 := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertTrue('SseRequest is akSse', Obs.Attempt(0).Kind = akSse);
  AssertTrue('a plain request is akRequest', Obs.Attempt(1).Kind = akRequest);
  AssertEquals('no stream id without a loop', 0, Obs.Attempt(0).StreamId);
  AssertEquals(0, Obs.Attempt(0).Reconnect);
  R1 := nil;
  R2 := nil;
  Client.Close;
end;

/// run a reconnect loop through three connections, one event each
procedure RunThreeConnections(const AClient: IHttpClient;
  const ARequest: THttpRequest; out AStreamId: Int64);
var
  Loop: TSseReconnectLoop;
  Ev: TSseEvent;
  I: Integer;
begin
  Loop := TSseReconnectLoop.Create(AClient, ARequest, 10);
  try
    AStreamId := Loop.StreamId;
    for I := 1 to 3 do
      if not Loop.Next(Ev) then
        raise Exception.Create('the loop ended early');
    Loop.Close;
  finally
    Loop.Free;
  end;
end;

function ThreeStreamFactory: TFakeFrameFactory;
begin
  Result := TFakeFrameFactory.Create;
  // `retry: 1` keeps the reconnect delay at a millisecond
  Result.SetDialScript(0, SpecArray([
    SseBodySpec('retry: 1'#10'id: 1'#10'data: a'#10#10),
    SseBodySpec('retry: 1'#10'id: 2'#10'data: b'#10#10),
    SseBodySpec('retry: 1'#10'id: 3'#10'data: c'#10#10)]));
end;

procedure TSseObservabilityTest.TestReconnectingStreamSharesOneStreamIdAndCountsReconnects;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Id: Int64;
  I: Integer;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(ThreeStreamFactory, ObsRef);
  RunThreeConnections(Client, SseRequest(cStreamUrl), Id);
  AssertTrue('three ends', Obs.WaitForEnds(3, 5000));
  AssertEquals('three attempts', 3, Obs.StartCount);
  AssertTrue('the library chose an id', Id <> 0);
  for I := 0 to 2 do
  begin
    AssertTrue('akSse', Obs.Attempt(I).Kind = akSse);
    AssertEquals('one stream id', Id, Obs.Attempt(I).StreamId);
    AssertEquals('reconnect count', I, Obs.Attempt(I).Reconnect);
  end;
  Client.Close;
end;

procedure TSseObservabilityTest.TestEveryReconnectCarriesTheContext;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Ctx: IInterface;
  Id: Int64;
  I: Integer;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Ctx := TInterfacedObject.Create;
  Client := Build(ThreeStreamFactory, ObsRef);
  RunThreeConnections(Client, SseRequest(cStreamUrl).WithContext(Ctx), Id);
  AssertTrue(Obs.WaitForEnds(3, 5000));
  for I := 0 to 2 do
    AssertTrue('the same context in attempt ' + IntToStr(I),
      Obs.Attempt(I).Context = Ctx);
  Client.Close;
end;

procedure TSseObservabilityTest.TestTwoLoopsGetTwoStreamIds;
var
  Client: IHttpClient;
  A, B: TSseReconnectLoop;
begin
  Client := Build(TFakeFrameFactory.Create, nil);
  A := TSseReconnectLoop.Create(Client, SseRequest(cStreamUrl));
  B := TSseReconnectLoop.Create(Client, SseRequest(cStreamUrl));
  try
    AssertTrue('ids are never 0', (A.StreamId <> 0) and (B.StreamId <> 0));
    AssertTrue('and differ', A.StreamId <> B.StreamId);
  finally
    A.Free;
    B.Free;
  end;
  Client.Close;
end;

procedure TSseObservabilityTest.TestEventsTakeTheStampOfTheChunkThatCompletedThem;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Sock: TFakeFrameSocket;
  Ev: TSseEvent;
  O: THttpOutcome;
  I: Integer;
begin
  Factory := OpenFactory;
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000000;           // the attempt starts here
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Sock := Factory.SocketAt(0);
  // the second event is split across the frames: it completes in the second
  Push(Sock, 'data: one'#10#10'data: tw', False, 1000100);
  Push(Sock, 'o'#10#10'data: three'#10#10, False, 1000400);
  Push(Sock, '', True, 1000500);
  Src := TSseSource.Create(R);
  for I := 1 to 3 do
    AssertTrue('event ' + IntToStr(I), Src.ReadEvent(Ev));
  AssertFalse('the stream ended', Src.ReadEvent(Ev));
  AssertTrue('the attempt ended', Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('three events', 3, O.MessagesIn);
  AssertEquals('first event', 100, O.FirstMessageUs);
  AssertEquals('last event', 400, O.LastMessageUs);
  AssertEquals('largest gap', 300, O.MaxGapUs);
  AssertEquals('summed gaps', 300, O.SumGapUs);
  AssertEquals('bytes on the wire', 19 + 16, O.BytesIn);
  AssertFalse(O.Abandoned);
  AssertEquals(200, O.StatusCode);
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestEventsInOneFrameShareItsStamp;
var
  Factory: TFakeFrameFactory;
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  I: Integer;
  M: TMessageInfo;
begin
  Factory := OpenFactory;
  Obs := TMessageRecordingObserver.Create([mkSseEvent]);
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Push(Factory.SocketAt(0), 'data: a'#10#10'data: bb'#10#10'data: ccc'#10#10 +
    'data: dddd'#10#10, False, 1000250);
  Push(Factory.SocketAt(0), '', True, 1000300);
  Src := TSseSource.Create(R);
  for I := 1 to 4 do
    AssertTrue(Src.ReadEvent(Ev));
  AssertFalse(Src.ReadEvent(Ev));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('four events', 4, Obs.Outcome(0).O.MessagesIn);
  AssertEquals('no gap inside a frame', 0, Obs.Outcome(0).O.MaxGapUs);
  AssertEquals(0, Obs.Outcome(0).O.SumGapUs);
  AssertEquals(250, Obs.Outcome(0).O.FirstMessageUs);
  AssertEquals(250, Obs.Outcome(0).O.LastMessageUs);
  AssertEquals('four callbacks', 4, Obs.MessageCount);
  for I := 0 to 3 do
  begin
    M := Obs.MessageAt(I);
    AssertEquals('index', I, M.Index);
    AssertEquals('size of event ' + IntToStr(I), I + 1, M.Size);
    AssertEquals('the chunk''s stamp', 250, M.ArrivedUs);
    AssertEquals('no gap', 0, M.SinceLastUs);
    AssertTrue('inbound', M.Direction = mdIn);
    AssertTrue('an event', M.Kind = mkSseEvent);
  end;
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestTheLastFrameOfTheBodyIsCountedBeforeTheEnd;
var
  Factory: TFakeFrameFactory;
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  O: THttpOutcome;
begin
  Factory := OpenFactory;
  Obs := TMessageRecordingObserver.Create([mkSseEvent]);
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Push(Factory.SocketAt(0), 'data: a'#10#10, False, 1000100);
  // the final event rides the frame that carries END_STREAM, so the codec
  // ends the exchange inside the very Read that returns it
  Push(Factory.SocketAt(0), 'data: b'#10#10, True, 1000300);
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  AssertTrue(Src.ReadEvent(Ev));
  AssertTrue('the attempt ended', Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('both events are in the outcome', 2, O.MessagesIn);
  AssertEquals(300, O.LastMessageUs);
  AssertEquals(200, O.MaxGapUs);
  AssertEquals('and were delivered before the end', 2, Obs.MessageCount);
  AssertFalse(O.Abandoned);
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestCommentsAndKeepAlivesAreNotMessages;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  O: THttpOutcome;
begin
  Factory := OpenFactory;
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Push(Factory.SocketAt(0), ': keep-alive'#10#10, False, 1000100);
  Push(Factory.SocketAt(0), 'data: x'#10#10, False, 1000900);
  Push(Factory.SocketAt(0), '', True, 1000950);
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  AssertFalse(Src.ReadEvent(Ev));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('an event is a message, a frame is not', 1, O.MessagesIn);
  AssertEquals('the event''s stamp', 900, O.FirstMessageUs);
  AssertEquals(0, O.MaxGapUs);
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestObserverThatWantsNothingReceivesNothing;
var
  Factory: TFakeFrameFactory;
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  P: IAttemptProgress;
  Src: IHttpSseSource;
  Ev: TSseEvent;
begin
  Factory := OpenFactory;
  Obs := TMessageRecordingObserver.Create([]);
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  AssertTrue(Supports(R, IAttemptProgress, P));
  AssertTrue('the attempt wants no messages', P.WantedKinds = []);
  Push(Factory.SocketAt(0), 'data: a'#10#10'data: b'#10#10, False, 5);
  Push(Factory.SocketAt(0), '', True, 6);
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  AssertTrue(Src.ReadEvent(Ev));
  AssertFalse(Src.ReadEvent(Ev));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('asked once', 1, Obs.WantsCalls);
  AssertEquals('no callbacks', 0, Obs.MessageCount);
  AssertEquals('the aggregates are collected anyway', 2,
    Obs.Outcome(0).O.MessagesIn);
  P := nil;
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestObserverReceivesEveryEventWithItsDetail;
var
  Factory: TFakeFrameFactory;
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  P: IAttemptProgress;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  M: TMessageInfo;
begin
  Factory := OpenFactory;
  Obs := TMessageRecordingObserver.Create([mkSseEvent]);
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  AssertTrue(Supports(R, IAttemptProgress, P));
  AssertTrue('the attempt wants events', mkSseEvent in P.WantedKinds);
  Push(Factory.SocketAt(0), 'event: tick'#10'id: 7'#10'data: hello'#10#10 +
    'data: second'#10#10, False, 1000100);
  Push(Factory.SocketAt(0), 'id: 8'#10'data: third'#10#10, False, 1000600);
  Push(Factory.SocketAt(0), '', True, 1000700);
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  AssertTrue(Src.ReadEvent(Ev));
  AssertTrue(Src.ReadEvent(Ev));
  AssertFalse(Src.ReadEvent(Ev));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('one callback per event', 3, Obs.MessageCount);
  M := Obs.MessageAt(0);
  AssertEquals('type', 'tick', M.EventType);
  AssertEquals('id', '7', M.EventId);
  AssertEquals('size', 5, M.Size);
  AssertEquals('index', 0, M.Index);
  AssertEquals('arrival', 100, M.ArrivedUs);
  AssertEquals('first has no gap', 0, M.SinceLastUs);
  AssertEquals('the event data was readable in the callback', 'hello',
    Obs.DataAt(0));
  M := Obs.MessageAt(1);
  AssertEquals('default type', 'message', M.EventType);
  AssertEquals('the id in force', '7', M.EventId);
  AssertEquals('size', 6, M.Size);
  AssertEquals('same frame, same stamp', 100, M.ArrivedUs);
  AssertEquals('so no gap', 0, M.SinceLastUs);
  AssertEquals('second', Obs.DataAt(1));
  M := Obs.MessageAt(2);
  AssertEquals('index', 2, M.Index);
  AssertEquals('new id', '8', M.EventId);
  AssertEquals('arrival', 600, M.ArrivedUs);
  AssertEquals('gap since the previous frame', 500, M.SinceLastUs);
  AssertEquals('third', Obs.DataAt(2));
  P := nil;
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestWantsMessagesIsAskedOncePerAttempt;
var
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Id: Int64;
begin
  Obs := TMessageRecordingObserver.Create([mkSseEvent]);
  ObsRef := Obs;
  Client := Build(ThreeStreamFactory, ObsRef);
  RunThreeConnections(Client, SseRequest(cStreamUrl), Id);
  AssertTrue(Obs.WaitForEnds(3, 5000));
  AssertEquals('once for each of the three attempts', 3, Obs.WantsCalls);
  AssertEquals('one event per connection', 3, Obs.MessageCount);
  Client.Close;
end;

procedure TSseObservabilityTest.TestCloseMidStreamEndsOnceAndNotAbandoned;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Loop: TSseReconnectLoop;
  Ev: TSseEvent;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([SseOpenBodySpec('id: 1'#10'data: a'#10#10)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  Loop := TSseReconnectLoop.Create(Client, SseRequest(cStreamUrl), 0);
  try
    AssertTrue(Loop.Next(Ev));
    Loop.Close;
    AssertTrue('Close ended the attempt', Obs.WaitForEnds(1, 5000));
    AssertFalse('a deliberate Close is not an abandonment',
      Obs.Outcome(0).O.Abandoned);
    AssertTrue('and not an error', Obs.Outcome(0).ErrorClass = '');
    AssertEquals(1, Obs.Outcome(0).O.MessagesIn);
  finally
    Loop.Free;
  end;
  Client.Close;
  AssertEquals('releasing the response did not end it again', 1, Obs.EndCount);
end;

procedure TSseObservabilityTest.TestDroppingTheSourceUnreadIsAbandoned;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([SseOpenBodySpec('data: a'#10#10)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  R := nil;
  Src := nil;                     // the last reference to the response
  AssertTrue('the drop ended the attempt', Obs.WaitForEnds(1, 5000));
  AssertTrue('abandoned', Obs.Outcome(0).O.Abandoned);
  AssertEquals(1, Obs.EndCount);
  Client.Close;
end;

procedure TSseObservabilityTest.TestReadingToTheEndEndsOnceNotAbandoned;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([SseBodySpec('data: a'#10#10)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  AssertFalse(Src.ReadEvent(Ev));
  Src.Close;
  R := nil;
  Src := nil;
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertFalse(Obs.Outcome(0).O.Abandoned);
  AssertEquals('once however it ended', 1, Obs.EndCount);
  Client.Close;
end;

procedure TSseObservabilityTest.TestSlowConsumerDoesNotChangeTheStamps;
var
  Factory: TFakeFrameFactory;
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  I: Integer;
  O: THttpOutcome;
begin
  Factory := OpenFactory;
  Obs := TMessageRecordingObserver.Create([mkSseEvent]);
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(SseRequest(cStreamUrl));
  for I := 1 to 3 do
    Push(Factory.SocketAt(0), 'data: n'#10#10, False, 1000000 + Int64(I) * 100);
  Push(Factory.SocketAt(0), '', True, 1000350);
  Src := TSseSource.Create(R);
  for I := 1 to 3 do
  begin
    // the consumer is a second behind the wire on every event
    GScriptedUs := 2000000 + Int64(I) * 1000000;
    AssertTrue(Src.ReadEvent(Ev));
  end;
  AssertFalse(Src.ReadEvent(Ev));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals(3, O.MessagesIn);
  AssertEquals('the wire gap, not the consumer''s', 100, O.MaxGapUs);
  AssertEquals(200, O.SumGapUs);
  AssertEquals(100, Obs.MessageAt(0).ArrivedUs);
  AssertEquals(300, Obs.MessageAt(2).ArrivedUs);
  AssertEquals(100, Obs.MessageAt(2).SinceLastUs);
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseObservabilityTest.TestRaisingOnMessageDoesNotBreakTheStream;
var
  Factory: TFakeFrameFactory;
  Obs: TMessageRecordingObserver;
  ObsRef: IHttpClientObserver;
  Logger: TRecordingLogger;
  LoggerRef: IHttpLogger;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
begin
  Factory := OpenFactory;
  Obs := TMessageRecordingObserver.Create([mkSseEvent]);
  Obs.RaiseOnMessage := True;
  ObsRef := Obs;
  Logger := TRecordingLogger.Create;
  LoggerRef := Logger;
  Client := Build(Factory, ObsRef, LoggerRef);
  R := Client.Send(SseRequest(cStreamUrl));
  Push(Factory.SocketAt(0), 'data: a'#10#10'data: b'#10#10, False, 5);
  Push(Factory.SocketAt(0), 'data: c'#10#10, True, 9);
  Src := TSseSource.Create(R);
  AssertTrue(Src.ReadEvent(Ev));
  AssertEquals('a', Ev.Data);
  AssertTrue(Src.ReadEvent(Ev));
  AssertEquals('b', Ev.Data);
  AssertTrue(Src.ReadEvent(Ev));
  AssertEquals('c', Ev.Data);
  AssertFalse(Src.ReadEvent(Ev));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('every event reached the observer', 3, Obs.MessageCount);
  AssertEquals('the aggregates are intact', 3, Obs.Outcome(0).O.MessagesIn);
  AssertEquals('each failure was logged', 3, Logger.Count);
  Src := nil;
  R := nil;
  Client.Close;
end;

{ TSseHttp1ObservabilityTest }

type
  /// hands out one staged socket whatever is dialled
  TStagedFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FSocket: IHttp2Socket;
  public
    constructor Create(const ASocket: IHttp2Socket);
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
  end;

constructor TStagedFactory.Create(const ASocket: IHttp2Socket);
begin
  inherited Create;
  FSocket := ASocket;
end;

function TStagedFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  Result := FSocket;
end;

function TStagedFactory.DialProtocol(const AHost: string; const APort: Word;
  const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  AProtocol := npHttp1Tls;
  Result := FSocket;
end;

procedure TSseHttp1ObservabilityTest.TearDown;
begin
  ResetNowUsHook;
  inherited TearDown;
end;

/// read the three events of the staged stream and return the outcome
function ReadStagedStream(const ASocket: TStagedSocket;
  out AOutcome: THttpOutcome): Boolean;
var
  SockRef: IHttp2Socket;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  I: Integer;
begin
  SockRef := ASocket;
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := THttpClientFactory.Create
    .WithSocketFactory(TStagedFactory.Create(SockRef))
    .WithHttp1Fallback.WithClearText(ctReject)
    .WithRequestObserver(ObsRef).Build;
  R := Client.Send(SseRequest(cStreamUrl));
  Src := TSseSource.Create(R);
  Result := True;
  for I := 1 to 3 do
    Result := Result and Src.ReadEvent(Ev);
  Result := Result and (not Src.ReadEvent(Ev));
  Result := Result and Obs.WaitForEnds(1, 5000);
  AOutcome := Obs.Outcome(0).O;
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TSseHttp1ObservabilityTest.TestEventsTakeTheStampOfTheTransportReadThatCompletedThem;
var
  Sock: TStagedSocket;
  O: THttpOutcome;
begin
  Sock := TStagedSocket.Create;
  Sock.Add('HTTP/1.1 200 OK'#13#10'Content-Type: text/event-stream'#13#10 +
    'Connection: close'#13#10#13#10, 1000050);
  Sock.Add('data: one'#10#10'data: tw', 1000100);
  Sock.Add('o'#10#10'data: three'#10#10, 1000400);
  AssertTrue('three events, then the end', ReadStagedStream(Sock, O));
  AssertEquals('three events', 3, O.MessagesIn);
  AssertEquals('first', 100, O.FirstMessageUs);
  AssertEquals('last', 400, O.LastMessageUs);
  AssertEquals('largest gap', 300, O.MaxGapUs);
  AssertEquals('summed gaps', 300, O.SumGapUs);
  AssertEquals(19 + 16, O.BytesIn);
  AssertFalse(O.Abandoned);
end;

procedure TSseHttp1ObservabilityTest.TestChunkedStreamKeepsTheSameStamps;
var
  Sock: TStagedSocket;
  O: THttpOutcome;
  P1, P2: string;
begin
  P1 := 'data: one'#10#10'data: tw';
  P2 := 'o'#10#10'data: three'#10#10;
  Sock := TStagedSocket.Create;
  Sock.Add('HTTP/1.1 200 OK'#13#10'Content-Type: text/event-stream'#13#10 +
    'Transfer-Encoding: chunked'#13#10#13#10, 1000050);
  Sock.Add(IntToHex(Length(P1), 1) + #13#10 + P1 + #13#10, 1000100);
  Sock.Add(IntToHex(Length(P2), 1) + #13#10 + P2 + #13#10'0'#13#10#13#10,
    1000400);
  AssertTrue('three events, then the end', ReadStagedStream(Sock, O));
  AssertEquals('three events', 3, O.MessagesIn);
  AssertEquals('first', 100, O.FirstMessageUs);
  AssertEquals('last', 400, O.LastMessageUs);
  AssertEquals('largest gap', 300, O.MaxGapUs);
  AssertFalse(O.Abandoned);
end;
initialization
  RegisterTest(TSseObservabilityTest);
  RegisterTest(TSseHttp1ObservabilityTest);
end.
