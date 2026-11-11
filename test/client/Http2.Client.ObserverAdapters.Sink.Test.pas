{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
unit Http2.Client.ObserverAdapters.Sink.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Messages, Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Sse,
  Http2.Client.WebSocket, Http2.Client.WebSocket.Connection,
  Http2.Client.Redirects.Test, Http2.Client.RequestObserver.Support, Http2.Client.WebSocketClient.Support,
  observer_tracing, observer_metrics, observer_logging;

type
  TOrderSpy = class(TBaseRequestObserver)
  private
    FInner: IHttpClientObserver;
    FTag: string;
    FLog: TEventLog;
  public
    constructor Create(const AInner: IHttpClientObserver; const ATag: string;
      const ALog: TEventLog);
    function OnAttemptStart(const A: THttpAttempt): IInterface; override;
    procedure OnResponseHeaders(const AToken: IInterface;
      const AResponse: IHttpResponse); override;
    procedure OnAttemptEnd(const AToken: IInterface;
      const O: THttpOutcome); override;
  end;

  /// moves the scripted clock when an attempt starts, so the request is
  /// written (and the response headers arrive) AFTER the attempt began

  TClockTicker = class(TBaseRequestObserver)
  private
    FAtUs: Int64;
  public
    constructor Create(const AAtUs: Int64);
    function OnAttemptStart(const A: THttpAttempt): IInterface; override;
  end;

  TLoggingAdapterTest = class(TTestCase)
  private
    FLogger: TMemoryLogger;
    FLoggerRef: IHttpLogger;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRedirectLinesAreExact;
    procedure TestRetryLinesCarryTheReasonAndTheError;
    procedure TestAbandonedResponseIsAWarning;
    procedure TestStreamFailureIsAnError;
    procedure TestRequestRefusedBeforeSendIsAnError;
    procedure TestLogValueQuotesWhatNeedsIt;
  end;

  /// the three adapters installed together through WithRequestObserver

  TObserverCompositionTest = class(TTestCase)
  private
    FTracer: TTracer;
    FRegistry: TMetricRegistry;
    FLogger: TMemoryLogger;
    FLoggerRef: IHttpLogger;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestStartRunsInRegistrationOrderAndEndInReverse;
    procedure TestTracerRegisteredFirstSeesHeadersLaterObserversInject;
    procedure TestLaterObserversSeeWhatTheTracerInjected;
    procedure TestThreeAdaptersAgreeOnARedirectChain;
    procedure TestThreeAdaptersOnASseStreamWithAReconnect;
  end;

  TAdaptersWebSocketTest = class(TTestCase)
  private
    FServer: TWsTestServer;
    procedure ScriptTwoTextsThenEchoClose(const S: TWsTestServer);
  protected
    procedure TearDown; override;
  published
    procedure TestThreeAdaptersOnAWebSocketSession;
  end;

implementation

const
  cStreamUrl = 'https://a.example/events';
  cEventStream = 'text/event-stream';

var
  GScriptedUs: Int64;

function ScriptedClock: Int64;
begin
  Result := GScriptedUs;
end;

function BytesOf(const S: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Ord(S[I]);
end;

function CountOf(const ASub, AText: string): Integer;
var
  P: Integer;
  Rest: string;
begin
  Result := 0;
  Rest := AText;
  repeat
    P := Pos(ASub, Rest);
    if P > 0 then
    begin
      Inc(Result);
      Rest := Copy(Rest, P + Length(ASub), MaxInt);
    end;
  until P = 0;
end;

function StartsWith(const APrefix, AText: string): Boolean;
begin
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

/// a client over the scripted peer with the observers in registration order

function BuildClient(const AFactory: TFakeFrameFactory;
  const AObservers: array of IHttpClientObserver): IHttpClient;
var
  F: THttpClientFactory;
  I: Integer;
begin
  F := THttpClientFactory.Create.WithSocketFactory(AFactory);
  for I := 0 to High(AObservers) do
    F := F.WithRequestObserver(AObservers[I]);
  Result := F.Build;
end;

/// a 200 event-stream head that stays open

function SseOpen: TRespSpec;
begin
  Result := WithContentType(HdrSpec('200', '', nil, False), cEventStream);
end;

/// a 200 event-stream response whose body ends the stream

function SseBody(const ABody: string): TRespSpec;
begin
  Result := WithContentType(HdrSpec('200', '', BytesOf(ABody), True),
    cEventStream);
end;

function CountPingAcks(const AFrames: TArray<TFrame>): Integer;
var
  K: Integer;
begin
  Result := 0;
  for K := 0 to High(AFrames) do
    if (AFrames[K].Header.FrameType = ftPing) and AFrames[K].IsAck then
      Inc(Result);
end;

/// frames are read and routed in order, so the ACK of a PING queued behind them
/// proves the reader thread is done with every earlier frame

procedure Barrier(const ASocket: TFakeFrameSocket);
var
  Before: Integer;
  Deadline: QWord;
begin
  Before := CountPingAcks(ASocket.WrittenFrames);
  ASocket.InjectFrame(BuildPingFrame(BytesOf('barrier!'), False));
  Deadline := GetTickCount64 + 5000;
  repeat
    if CountPingAcks(ASocket.WrittenFrames) > Before then
      Exit;
    Sleep(1);   // bounded poll on the peer's written bytes
  until GetTickCount64 >= Deadline;
  raise Exception.Create('the barrier PING was never acknowledged');
end;

/// the peer delivers AText at the scripted instant AStampUs

procedure Push(const ASocket: TFakeFrameSocket; const AText: string;
  const AEndStream: Boolean; const AStampUs: Int64);
begin
  GScriptedUs := AStampUs;
  ASocket.InjectFrame(BuildDataFrame(1, BytesOf(AText), AEndStream));
  Barrier(ASocket);
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
    SseBody('retry: 1'#10'id: 1'#10'data: a'#10#10),
    SseBody('retry: 1'#10'id: 2'#10'data: b'#10#10),
    SseBody('retry: 1'#10'id: 3'#10'data: c'#10#10)]));
end;

{ TOrderSpy }

constructor TOrderSpy.Create(const AInner: IHttpClientObserver;
  const ATag: string; const ALog: TEventLog);
begin
  inherited Create;
  FInner := AInner;
  FTag := ATag;
  FLog := ALog;
end;

function TOrderSpy.OnAttemptStart(const A: THttpAttempt): IInterface;
begin
  FLog.Add(FTag + '.S');
  Result := FInner.OnAttemptStart(A);
end;

procedure TOrderSpy.OnResponseHeaders(const AToken: IInterface;
  const AResponse: IHttpResponse);
begin
  FLog.Add(FTag + '.H');
  FInner.OnResponseHeaders(AToken, AResponse);
end;

procedure TOrderSpy.OnAttemptEnd(const AToken: IInterface;
  const O: THttpOutcome);
begin
  FLog.Add(FTag + '.E');
  FInner.OnAttemptEnd(AToken, O);
end;

{ TClockTicker }

constructor TClockTicker.Create(const AAtUs: Int64);
begin
  inherited Create;
  FAtUs := AAtUs;
end;

function TClockTicker.OnAttemptStart(const A: THttpAttempt): IInterface;
begin
  GScriptedUs := FAtUs;
  Result := nil;
end;

{ TTracingAdapterTest }

procedure TLoggingAdapterTest.SetUp;
begin
  inherited SetUp;
  FLogger := TMemoryLogger.Create;
  FLoggerRef := FLogger;
  // a frozen clock makes every time in a line 0, so the lines are exact
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
end;

procedure TLoggingAdapterTest.TearDown;
begin
  ResetNowUsHook;
  FLoggerRef := nil;
  FLogger := nil;
  inherited TearDown;
end;

procedure TLoggingAdapterTest.TestRedirectLinesAreExact;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', '/b'), HdrSpec('200')]));
  Obs := TLoggingObserver.Create(FLoggerRef);
  Client := BuildClient(Factory, [Obs]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertEquals('seven lines', 7, FLogger.Count);
  AssertEquals('evt=attempt.start id=1 kind=request method=GET ' +
    'url=https://a.example/a hop=0 retry=0', FLogger.LineAt(0));
  AssertEquals('evt=attempt.headers id=1 status=302', FLogger.LineAt(1));
  AssertEquals('evt=attempt.redirect id=1 status=302 ' +
    'from=https://a.example/a to=https://a.example/b', FLogger.LineAt(2));
  AssertEquals('evt=attempt.end id=1 status=302 proto=h2 reused=false ' +
    'dur_us=0 bytes_out=0 bytes_in=0 msgs_in=0 msgs_out=0', FLogger.LineAt(3));
  AssertEquals('evt=attempt.start id=2 kind=request method=GET ' +
    'url=https://a.example/b hop=1 retry=0', FLogger.LineAt(4));
  AssertEquals('evt=attempt.headers id=2 status=200', FLogger.LineAt(5));
  AssertEquals('evt=attempt.end id=2 status=200 proto=h2 reused=true ' +
    'dur_us=0 bytes_out=0 bytes_in=0 msgs_in=0 msgs_out=0', FLogger.LineAt(6));
  AssertTrue('start is debug', FLogger.LevelAt(0) = llDebug);
  AssertTrue('a redirect is info', FLogger.LevelAt(2) = llInfo);
  AssertTrue('a clean end is info', FLogger.LevelAt(6) = llInfo);
  Client.Close;
end;

procedure TLoggingAdapterTest.TestRetryLinesCarryTheReasonAndTheError;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([RstSpec(ecRefusedStream), HdrSpec('200')]));
  Obs := TLoggingObserver.Create(FLoggerRef);
  Client := BuildClient(Factory, [Obs]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertEquals('start, retry, end, start, headers, end', 6, FLogger.Count);
  AssertTrue(StartsWith('evt=attempt.start id=1 ', FLogger.LineAt(0)));
  AssertTrue('the retry names the attempt it refers to',
    StartsWith('evt=attempt.retry id=1 reason=', FLogger.LineAt(1)));
  AssertTrue('a retry is a warning', FLogger.LevelAt(1) = llWarn);
  AssertTrue(StartsWith('evt=attempt.end id=1 status=0 ', FLogger.LineAt(2)));
  AssertTrue('the refused attempt carries the error',
    Pos(' error=EHttpStreamError message=', FLogger.LineAt(2)) > 0);
  AssertTrue('and is an error line', FLogger.LevelAt(2) = llError);
  AssertTrue('the retry is the next attempt, one retry in',
    Pos('id=2 kind=request method=GET url=https://a.example/a hop=0 retry=1',
      FLogger.LineAt(3)) > 0);
  AssertEquals('evt=attempt.headers id=2 status=200', FLogger.LineAt(4));
  AssertTrue('it ended clean', Pos(' error=', FLogger.LineAt(5)) = 0);
  Client.Close;
end;

procedure TLoggingAdapterTest.TestAbandonedResponseIsAWarning;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('200', '', BytesOf('unread body'), True)]));
  Obs := TLoggingObserver.Create(FLoggerRef);
  Client := BuildClient(Factory, [Obs]);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertEquals('no end line while the response is held', 2, FLogger.Count);
  R := nil;
  AssertEquals(3, FLogger.Count);
  AssertTrue(StartsWith('evt=attempt.end id=1 status=200 ', FLogger.LineAt(2)));
  AssertTrue('marked abandoned', Pos(' abandoned=true', FLogger.LineAt(2)) > 0);
  AssertTrue('and a warning', FLogger.LevelAt(2) = llWarn);
  Client.Close;
end;

procedure TLoggingAdapterTest.TestStreamFailureIsAnError;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Buf: array[0..15] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrRstSpec(ecInternalError)]));
  Obs := TLoggingObserver.Create(FLoggerRef);
  Client := BuildClient(Factory, [Obs]);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  try
    R.Body.Read(Buf, SizeOf(Buf));
    Fail('the read should fail');
  except
    on E: EHttpStreamError do ;
  end;
  AssertEquals(3, FLogger.Count);
  AssertTrue(StartsWith('evt=attempt.end id=1 status=200 ', FLogger.LineAt(2)));
  AssertTrue(Pos(' error=EHttpStreamError message=', FLogger.LineAt(2)) > 0);
  AssertTrue('an error is not an abandonment',
    Pos('abandoned', FLogger.LineAt(2)) = 0);
  AssertTrue(FLogger.LevelAt(2) = llError);
  R := nil;
  AssertEquals('release adds no line', 3, FLogger.Count);
  Client.Close;
end;

procedure TLoggingAdapterTest.TestRequestRefusedBeforeSendIsAnError;
var
  Obs: IHttpClientObserver;
  Client: IHttpClient;
begin
  Obs := TLoggingObserver.Create(FLoggerRef);
  // the strict cleartext default refuses the request before any dial
  Client := BuildClient(TFakeFrameFactory.Create, [Obs]);
  try
    Client.Send(THttpRequest.Create(hmGet, 'http://plain.example/x'));
    Fail('the request should be refused');
  except
    on E: EHttpProtocolError do ;
  end;
  AssertEquals('a start is paired with an end', 2, FLogger.Count);
  AssertTrue(StartsWith('evt=attempt.end id=1 status=0 ', FLogger.LineAt(1)));
  AssertTrue(Pos(' error=EHttpProtocolError message=', FLogger.LineAt(1)) > 0);
  AssertTrue(FLogger.LevelAt(1) = llError);
  Client.Close;
end;

procedure TLoggingAdapterTest.TestLogValueQuotesWhatNeedsIt;
begin
  AssertEquals('plain', 'https://a.example/x', LogValue('https://a.example/x'));
  AssertEquals('"a b"', LogValue('a b'));
  AssertEquals('"x=y"', LogValue('x=y'));
  AssertEquals('"say \"hi\""', LogValue('say "hi"'));
  AssertEquals('"line\nbreak"', LogValue('line'#10'break'));
  AssertEquals('empty', '""', LogValue(''));
end;

{ TObserverCompositionTest }

procedure TObserverCompositionTest.SetUp;
begin
  inherited SetUp;
  FTracer := TTracer.Create;
  FRegistry := TMetricRegistry.Create;
  FLogger := TMemoryLogger.Create;
  FLoggerRef := FLogger;
end;

procedure TObserverCompositionTest.TearDown;
begin
  ResetNowUsHook;
  FLoggerRef := nil;
  FLogger := nil;
  FRegistry.Free;
  FTracer.Free;
  inherited TearDown;
end;

procedure TObserverCompositionTest.TestStartRunsInRegistrationOrderAndEndInReverse;
var
  Log: TEventLog;
  Factory: TFakeFrameFactory;
  T, M, L: IHttpClientObserver;
  Client: IHttpClient;
begin
  Log := TEventLog.Create;
  try
    Factory := TFakeFrameFactory.Create;
    Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
    // each real adapter behind a spy that notes the callback in one shared log
    T := TOrderSpy.Create(TTracingObserver.Create(FTracer), 'tracing', Log);
    M := TOrderSpy.Create(TMetricsObserver.Create(FRegistry), 'metrics', Log);
    L := TOrderSpy.Create(TLoggingObserver.Create(FLoggerRef), 'logging', Log);
    Client := BuildClient(Factory, [T, M, L]);
    Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
    AssertEquals('start and headers in registration order, end reversed',
      'tracing.S metrics.S logging.S tracing.H metrics.H logging.H ' +
      'logging.E metrics.E tracing.E', Log.Text);
    // and each adapter did its own job behind its spy
    AssertEquals('a span', 1, FTracer.Count);
    AssertTrue('ended', FTracer.SpanAt(0).Ended);
    AssertEquals('a counted request', 1, FRegistry.Counter(
      'http_client_requests_total').Value('kind="request",status="200"'));
    AssertEquals('three log lines', 3, FLogger.Count);
    Client.Close;
  finally
    Log.Free;
  end;
end;

procedure TObserverCompositionTest.TestTracerRegisteredFirstSeesHeadersLaterObserversInject;
var
  Factory: TFakeFrameFactory;
  Tracing: TTracingObserver;
  T, Inject: IHttpClientObserver;
  Injector: TRecordingRequestObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Tracing := TTracingObserver.Create(FTracer);
  Tracing.RecordRequestHeader('x-correlation-id');
  T := Tracing;
  Injector := TRecordingRequestObserver.Create;
  Injector.InjectName := 'x-correlation-id';
  Injector.InjectPrefix := 'corr';
  Inject := Injector;
  // the tracer first: its start runs before the injector's, yet the span still
  // carries the header, because the tracer reads it once every start ran
  Client := BuildClient(Factory, [T, Inject]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertTrue('the request was sent', Factory.SocketAt(0).WaitForRequests(1, 2000));
  AssertTrue('the injector''s header is on the wire',
    Pos('x-correlation-id: corr-1', Factory.SocketAt(0).RequestAt(0).HeaderLines) > 0);
  AssertEquals('and on the span', 'corr-1',
    FTracer.SpanAt(0).GetAttribute('http.request.header.x-correlation-id'));
  AssertEquals('one traceparent too', 1,
    CountOf('traceparent:', Factory.SocketAt(0).RequestAt(0).HeaderLines));
  Client.Close;
end;

procedure TObserverCompositionTest.TestLaterObserversSeeWhatTheTracerInjected;
var
  Factory: TFakeFrameFactory;
  T, Inject: IHttpClientObserver;
  Injector: TRecordingRequestObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  T := TTracingObserver.Create(FTracer);
  // this one reads the first value of `traceparent` before it injects its own
  Injector := TRecordingRequestObserver.Create;
  Injector.InjectName := 'traceparent';
  Injector.InjectPrefix := 'later';
  Inject := Injector;
  Client := BuildClient(Factory, [T, Inject]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertEquals(1, Injector.SeenBefore.Count);
  AssertEquals('the sink already held the tracer''s traceparent',
    FTracer.SpanAt(0).Traceparent, Injector.SeenBefore[0]);
  Client.Close;
end;

procedure TObserverCompositionTest.TestThreeAdaptersAgreeOnARedirectChain;
var
  Factory: TFakeFrameFactory;
  Rec: TRecordingRequestObserver;
  RecRef, T, M, L: IHttpClientObserver;
  Client: IHttpClient;
  Root: ISpan;
  I: Integer;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/b'), HdrSpec('302', '/c'), HdrSpec('200')]));
  Rec := TRecordingRequestObserver.Create;
  RecRef := Rec;
  T := TTracingObserver.Create(FTracer);
  M := TMetricsObserver.Create(FRegistry);
  L := TLoggingObserver.Create(FLoggerRef);
  Client := BuildClient(Factory, [RecRef, T, M, L]);
  Root := FTracer.StartSpan('caller', nil);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a')
    .WithContext(Root));
  AssertTrue(Rec.WaitForEnds(3, 5000));
  AssertEquals('three hop spans and the caller', 4, FTracer.Count);
  for I := 1 to 3 do
    AssertTrue('hop span ended', FTracer.SpanAt(I).Ended);
  AssertEquals('metrics saw three attempts', 2, FRegistry.Counter(
    'http_client_requests_total').Value('kind="request",status="302"'));
  AssertEquals(1, FRegistry.Counter('http_client_requests_total').Value(
    'kind="request",status="200"'));
  AssertEquals('nothing in flight', 0,
    FRegistry.Gauge('http_client_in_flight').Value, 0.001);
  // 3 starts + 3 headers + 3 ends + 2 redirects
  AssertEquals('the log covers every callback', 11, FLogger.Count);
  Client.Close;
end;

procedure TObserverCompositionTest.TestThreeAdaptersOnASseStreamWithAReconnect;
var
  Rec: TRecordingRequestObserver;
  RecRef, T, M, L: IHttpClientObserver;
  Client: IHttpClient;
  Root: ISpan;
  Id: Int64;
  I, Ends: Integer;
begin
  Rec := TRecordingRequestObserver.Create;
  RecRef := Rec;
  T := TTracingObserver.Create(FTracer);
  M := TMetricsObserver.Create(FRegistry, True);
  L := TLoggingObserver.Create(FLoggerRef);
  Client := BuildClient(ThreeStreamFactory, [RecRef, T, M, L]);
  Root := FTracer.StartSpan('caller', nil);
  RunThreeConnections(Client, SseRequest(cStreamUrl).WithContext(Root), Id);
  AssertTrue(Rec.WaitForEnds(3, 5000));
  AssertEquals('one span per connection under the caller', 4, FTracer.Count);
  Ends := 0;
  for I := 1 to 3 do
    if FTracer.SpanAt(I).Ended then
      Inc(Ends);
  AssertEquals('every span ended', 3, Ends);
  AssertEquals('three SSE attempts counted', 3, FRegistry.Counter(
    'http_client_requests_total').Value('kind="sse",status="200"'));
  AssertEquals('the reconnect is in the log', 1,
    CountOf('reconnect=2', FLogger.Text));
  AssertEquals('each log line carries the stream id', 3,
    CountOf('stream=' + IntToStr(Id) + ' ', FLogger.Text));
  Client.Close;
end;

{ TAdaptersWebSocketTest }

procedure TAdaptersWebSocketTest.TearDown;
begin
  if FServer <> nil then
  begin
    FServer.Terminate;
    FServer.Release.SetEvent;
    FServer.CloseConnection;
    FServer.ShutdownListener;
    FServer.Done.WaitFor(3000);
    FServer.Free;
    FServer := nil;
  end;
  inherited TearDown;
end;

procedure TAdaptersWebSocketTest.ScriptTwoTextsThenEchoClose(
  const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  S.SendText('m1');
  S.SendText('m2');
  while S.TryReadFrame(F) do
    if F.Opcode = cWsOpClose then
    begin
      S.SendFrame(cWsOpClose, True, F.Payload);
      Break;
    end;
  S.CloseConnection;
end;

procedure TAdaptersWebSocketTest.TestThreeAdaptersOnAWebSocketSession;
var
  Tracer: TTracer;
  Registry: TMetricRegistry;
  Logger: TMemoryLogger;
  LoggerRef: IHttpLogger;
  Rec: TRecordingRequestObserver;
  RecRef, T, M, L: IHttpClientObserver;
  Listener: TRecorder;
  ListenerRef: IWebSocketListener;
  Client: IHttpClient;
  Sock: IWebSocket;
  Root: ISpan;
  Gaps: THistogram;
begin
  Tracer := TTracer.Create;
  Registry := TMetricRegistry.Create;
  Logger := TMemoryLogger.Create;
  LoggerRef := Logger;
  try
    FServer := TWsTestServer.Create(ScriptTwoTextsThenEchoClose);
    FServer.Start;
    Rec := TRecordingRequestObserver.Create;
    RecRef := Rec;
    T := TTracingObserver.Create(Tracer);
    M := TMetricsObserver.Create(Registry, True);
    L := TLoggingObserver.Create(LoggerRef);
    Client := THttpClientFactory.Create.WithRequestObserver(RecRef)
      .WithRequestObserver(T).WithRequestObserver(M)
      .WithRequestObserver(L).Build;
    Listener := TRecorder.Create(0);
    ListenerRef := Listener;
    Root := Tracer.StartSpan('caller', nil);
    Sock := Client.Send(TWebSocketRequest.Create('ws://127.0.0.1:' +
      IntToStr(FServer.Port) + '/obs', ListenerRef).WithAutoRequest
      .WithContext(Root));
    AssertTrue('open and both texts arrived', Listener.WaitCount(3));
    Sock.Close(1000, 'bye');
    AssertTrue('closed', Listener.WaitCount(4));
    AssertTrue('the attempt ended', Rec.WaitForEnds(1, 5000));
    // tracing: one span under the caller, the handshake status, the close
    AssertEquals(2, Tracer.Count);
    AssertEquals('child of the caller', Root.SpanId, Tracer.SpanAt(1).ParentSpanId);
    AssertEquals('WEBSOCKET', Tracer.SpanAt(1).Name);
    AssertEquals('101', Tracer.SpanAt(1).GetAttribute('http.response.status_code'));
    AssertEquals('1000', Tracer.SpanAt(1).GetAttribute('websocket.close_code'));
    AssertTrue('a clean close', Tracer.SpanAt(1).Status = ssOk);
    AssertTrue(Tracer.SpanAt(1).Ended);
    AssertEquals('the traceparent reached the handshake', 1,
      CountOf('traceparent: ' + Tracer.SpanAt(1).Traceparent,
        FServer.Head));
    // metrics: counted by kind and status, and the per-message gate fed the
    // inbound gap histogram (the second text has one gap)
    AssertEquals(1, Registry.Counter('http_client_requests_total').Value(
      'kind="websocket",status="101"'));
    Gaps := Registry.Histogram(GapHistogramName(akWebSocket), cLatencyBoundsUs);
    AssertEquals('one gap between two texts', 1, Gaps.Count);
    AssertEquals('nothing in flight', 0,
      Registry.Gauge('http_client_in_flight').Value, 0.001);
    // logging: the end line names who closed and with what
    AssertEquals('start, headers, end', 3, Logger.Count);
    AssertTrue('closed locally with 1000',
      Pos(' closed_by=local close_code=1000 close_reason=bye', Logger.LineAt(2)) > 0);
    AssertTrue('two messages in', Pos(' msgs_in=2 ', Logger.LineAt(2)) > 0);
    Sock := nil;
    Client.Close;
  finally
    Root := nil;
    LoggerRef := nil;
    Registry.Free;
    Tracer.Free;
  end;
end;

initialization
  RegisterTest(TLoggingAdapterTest);
  RegisterTest(TObserverCompositionTest);
  RegisterTest(TAdaptersWebSocketTest);
end.
