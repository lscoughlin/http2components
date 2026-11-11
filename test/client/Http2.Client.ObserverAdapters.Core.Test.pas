{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
unit Http2.Client.ObserverAdapters.Core.Test;

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
  Http2.Client.Redirects.Test, Http2.Client.RequestObserver.Test, Http2.Client.WebSocketClient.Test,
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

  TTracingAdapterTest = class(TTestCase)
  private
    FTracer: TTracer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRedirectHopsAreSiblingsUnderTheCallersSpan;
    procedure TestEachHopSendsExactlyOneTraceparentNamingItsSpan;
    procedure TestWithoutAParentTheAttemptStartsATrace;
    procedure TestServerErrorStatusSetsTheSpanStatus;
    procedure TestStreamFailureSetsErrorAndEndsTheSpan;
    procedure TestRetryIsASiblingSpanWithAnEvent;
    procedure TestSseReconnectsAreSiblingsOfOneStream;
    procedure TestAbandonedResponseIsMarkedOnTheSpan;
  end;

  TMetricsAdapterTest = class(TTestCase)
  private
    FRegistry: TMetricRegistry;
    FRec: TRecordingRequestObserver;
    FRecRef: IHttpClientObserver;
    FOutcome: THttpOutcome;
    FWanted: TMessageKinds;
    FInFlightDuring: Double;
    procedure RunScriptedStream(const APerEvent: Boolean);
    procedure AssertHist(const AName: string; const ACount: Int64;
      const ASum: Double);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestScriptedStreamTimesAreDerivedExactly;
    procedure TestScriptedStreamRatesAndTotalsAreDerivedExactly;
    procedure TestInFlightGaugeAndCountByStatus;
    procedure TestRequestCountsByStatusAcrossARedirectChain;
    procedure TestErrorsAndAbandonedAreCounted;
    procedure TestPerEventHistogramMatchesTheScriptedGaps;
    procedure TestHistogramIsEmptyWhileTheGateIsOff;
    procedure TestPoolStatsGaugeReadsOneSnapshotPerCollection;
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

procedure TTracingAdapterTest.SetUp;
begin
  inherited SetUp;
  FTracer := TTracer.Create;
end;

procedure TTracingAdapterTest.TearDown;
begin
  FTracer.Free;
  inherited TearDown;
end;

procedure TTracingAdapterTest.TestRedirectHopsAreSiblingsUnderTheCallersSpan;
var
  Factory: TFakeFrameFactory;
  Root: ISpan;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  I, J: Integer;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/b'), HdrSpec('302', '/c'), HdrSpec('200')]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  Root := FTracer.StartSpan('caller', nil);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a')
    .WithContext(Root));
  AssertEquals('final status', 200, R.StatusCode);
  AssertEquals('the caller span and one span per hop', 4, FTracer.Count);
  for I := 1 to 3 do
  begin
    AssertEquals('hop ' + IntToStr(I - 1) + ' is a child of the caller',
      Root.SpanId, FTracer.SpanAt(I).ParentSpanId);
    AssertEquals('same trace', Root.TraceId, FTracer.SpanAt(I).TraceId);
    AssertTrue('the hop span ended', FTracer.SpanAt(I).Ended);
    for J := 1 to I - 1 do
      AssertTrue('siblings have distinct ids',
        FTracer.SpanAt(I).SpanId <> FTracer.SpanAt(J).SpanId);
  end;
  AssertEquals('a hop is not the parent of the next',
    Root.SpanId, FTracer.SpanAt(3).ParentSpanId);
  AssertEquals('hop 0 status', '302',
    FTracer.SpanAt(1).GetAttribute('http.response.status_code'));
  AssertEquals('hop 2 status', '200',
    FTracer.SpanAt(3).GetAttribute('http.response.status_code'));
  AssertEquals('hop numbers', '1',
    FTracer.SpanAt(2).GetAttribute('http.request.hop'));
  AssertEquals('one redirect event on a finished hop', 1,
    FTracer.SpanAt(1).EventCount);
  AssertEquals('redirect event', 'redirect 302 to https://a.example/b',
    FTracer.SpanAt(1).EventAt(0));
  AssertEquals('the last hop was not redirected', 0, FTracer.SpanAt(3).EventCount);
  AssertTrue('redirects are not errors', FTracer.SpanAt(1).Status = ssOk);
  AssertFalse('the caller owns its span', Root.Ended);
  R := nil;
  Client.Close;
end;

procedure TTracingAdapterTest.TestEachHopSendsExactlyOneTraceparentNamingItsSpan;
var
  Factory: TFakeFrameFactory;
  Root: ISpan;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  Sock: TFakeFrameSocket;
  Lines: string;
  I: Integer;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/b'), HdrSpec('307', '/c'), HdrSpec('200')]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  Root := FTracer.StartSpan('caller', nil);
  // a traceparent the caller set must not travel next to the adapter's
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a')
    .WithHeader('traceparent', '00-caller-header-01')
    .WithHeader('x-caller', 'yes').WithContext(Root));
  Sock := Factory.SocketAt(0);
  AssertTrue('three requests were sent', Sock.WaitForRequests(3, 2000));
  for I := 0 to 2 do
  begin
    Lines := Sock.RequestAt(I).HeaderLines;
    AssertEquals('one traceparent on hop ' + IntToStr(I), 1,
      CountOf('traceparent:', Lines));
    AssertTrue('it names the hop''s own span',
      Pos('traceparent: ' + FTracer.SpanAt(I + 1).Traceparent, Lines) > 0);
    AssertEquals('the caller''s value was replaced', 0,
      CountOf('caller-header', Lines));
    AssertTrue('other headers are untouched', Pos('x-caller: yes', Lines) > 0);
  end;
  AssertTrue('version 00, 32 hex trace id, 16 hex span id, sampled flag',
    (Length(FTracer.SpanAt(1).Traceparent) = 55) and
    (Copy(FTracer.SpanAt(1).Traceparent, 1, 3) = '00-') and
    (Copy(FTracer.SpanAt(1).Traceparent, 53, 3) = '-01'));
  Client.Close;
end;

procedure TTracingAdapterTest.TestWithoutAParentTheAttemptStartsATrace;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200'), HdrSpec('200')]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/b'));
  AssertEquals(2, FTracer.Count);
  AssertEquals('a root has no parent', '', FTracer.SpanAt(0).ParentSpanId);
  AssertTrue('unrelated requests are separate traces',
    FTracer.SpanAt(0).TraceId <> FTracer.SpanAt(1).TraceId);
  AssertEquals('named after the method', 'GET', FTracer.SpanAt(0).Name);
  AssertEquals('server.address', 'a.example',
    FTracer.SpanAt(0).GetAttribute('server.address'));
  AssertEquals('server.port', '443',
    FTracer.SpanAt(0).GetAttribute('server.port'));
  Client.Close;
end;

procedure TTracingAdapterTest.TestServerErrorStatusSetsTheSpanStatus;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('503')]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertTrue('error status', FTracer.SpanAt(0).Status = ssError);
  AssertEquals('message', 'HTTP 503', FTracer.SpanAt(0).StatusMessage);
  AssertEquals('status attribute', '503',
    FTracer.SpanAt(0).GetAttribute('http.response.status_code'));
  AssertTrue('ended', FTracer.SpanAt(0).Ended);
  Client.Close;
end;

procedure TTracingAdapterTest.TestStreamFailureSetsErrorAndEndsTheSpan;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Buf: array[0..15] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrRstSpec(ecInternalError)]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertFalse('open while the body is unread', FTracer.SpanAt(0).Ended);
  try
    R.Body.Read(Buf, SizeOf(Buf));
    Fail('the read should fail');
  except
    on E: EHttpStreamError do ;
  end;
  AssertTrue('ended by the failure', FTracer.SpanAt(0).Ended);
  AssertTrue('error status', FTracer.SpanAt(0).Status = ssError);
  AssertTrue('the message came from the exception',
    FTracer.SpanAt(0).StatusMessage <> '');
  AssertEquals('error type', 'EHttpStreamError',
    FTracer.SpanAt(0).GetAttribute('error.type'));
  AssertEquals('headers had arrived', '200',
    FTracer.SpanAt(0).GetAttribute('http.response.status_code'));
  R := nil;
  Client.Close;
end;

procedure TTracingAdapterTest.TestRetryIsASiblingSpanWithAnEvent;
var
  Factory: TFakeFrameFactory;
  Root: ISpan;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([RstSpec(ecRefusedStream), HdrSpec('200')]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  Root := FTracer.StartSpan('caller', nil);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a')
    .WithContext(Root));
  AssertEquals('caller, refused attempt, retry', 3, FTracer.Count);
  AssertEquals('both under the caller', Root.SpanId,
    FTracer.SpanAt(1).ParentSpanId);
  AssertEquals(Root.SpanId, FTracer.SpanAt(2).ParentSpanId);
  AssertEquals('first attempt', '0',
    FTracer.SpanAt(1).GetAttribute('http.request.resend_count'));
  AssertEquals('the retry', '1',
    FTracer.SpanAt(2).GetAttribute('http.request.resend_count'));
  AssertEquals('retry event on the refused attempt', 1,
    FTracer.SpanAt(1).EventCount);
  AssertTrue(StartsWith('retry: ', FTracer.SpanAt(1).EventAt(0)));
  AssertTrue('the refused attempt failed', FTracer.SpanAt(1).Status = ssError);
  AssertTrue('and ended', FTracer.SpanAt(1).Ended);
  AssertTrue('the retry succeeded', FTracer.SpanAt(2).Status = ssOk);
  Client.Close;
end;

procedure TTracingAdapterTest.TestSseReconnectsAreSiblingsOfOneStream;
var
  Rec: TRecordingRequestObserver;
  RecRef, Obs: IHttpClientObserver;
  Client: IHttpClient;
  Root: ISpan;
  Id: Int64;
  I: Integer;
begin
  Rec := TRecordingRequestObserver.Create;
  RecRef := Rec;
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(ThreeStreamFactory, [RecRef, Obs]);
  Root := FTracer.StartSpan('caller', nil);
  RunThreeConnections(Client, SseRequest(cStreamUrl).WithContext(Root), Id);
  AssertTrue('three ends', Rec.WaitForEnds(3, 5000));
  AssertEquals(4, FTracer.Count);
  for I := 1 to 3 do
  begin
    AssertEquals('sibling', Root.SpanId, FTracer.SpanAt(I).ParentSpanId);
    AssertEquals('one stream id', IntToStr(Id),
      FTracer.SpanAt(I).GetAttribute('sse.stream_id'));
    AssertEquals('reconnect count', IntToStr(I - 1),
      FTracer.SpanAt(I).GetAttribute('sse.reconnect'));
    AssertEquals('kind', 'sse', FTracer.SpanAt(I).GetAttribute('http.attempt.kind'));
    AssertTrue('ended', FTracer.SpanAt(I).Ended);
    AssertEquals('one event each', '1',
      FTracer.SpanAt(I).GetAttribute('messaging.received'));
  end;
  Client.Close;
end;

procedure TTracingAdapterTest.TestAbandonedResponseIsMarkedOnTheSpan;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('200', '', BytesOf('unread body'), True)]));
  Obs := TTracingObserver.Create(FTracer);
  Client := BuildClient(Factory, [Obs]);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertFalse('open while held', FTracer.SpanAt(0).Ended);
  R := nil;
  AssertTrue('release ended it', FTracer.SpanAt(0).Ended);
  AssertEquals('abandoned', 'true',
    FTracer.SpanAt(0).GetAttribute('http.response.abandoned'));
  AssertTrue('an abandonment alone is not an error',
    FTracer.SpanAt(0).Status = ssOk);
  Client.Close;
end;

{ TMetricsAdapterTest }

procedure TMetricsAdapterTest.SetUp;
begin
  inherited SetUp;
  FRegistry := TMetricRegistry.Create;
end;

procedure TMetricsAdapterTest.TearDown;
begin
  ResetNowUsHook;
  FRecRef := nil;
  FRec := nil;
  FRegistry.Free;
  inherited TearDown;
end;

procedure TMetricsAdapterTest.AssertHist(const AName: string;
  const ACount: Int64; const ASum: Double);
begin
  AssertTrue(AName + ' exists', FRegistry.HasHistogram(AName));
  AssertEquals(AName + ' count', ACount,
    FRegistry.Histogram(AName, cLatencyBoundsUs).Count);
  AssertEquals(AName + ' sum', ASum,
    FRegistry.Histogram(AName, cLatencyBoundsUs).Sum, 0.001);
end;

/// one SSE attempt under the scripted clock.  The attempt starts at 1000000,
/// the ticker moves the clock to 1000050 (request written, headers received),
/// then the peer delivers three events:
///   1000100  'data: one' and the start of the second event
///   1000400  the rest of the second event and the whole third event
///   1000500  the end of the stream

procedure TMetricsAdapterTest.RunScriptedStream(const APerEvent: Boolean);
var
  Factory: TFakeFrameFactory;
  Metrics, Ticker: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  P: IAttemptProgress;
  Src: IHttpSseSource;
  Ev: TSseEvent;
  I: Integer;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([SseOpen]));
  FRec := TRecordingRequestObserver.Create;
  FRecRef := FRec;
  Metrics := TMetricsObserver.Create(FRegistry, APerEvent);
  Ticker := TClockTicker.Create(1000050);
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := BuildClient(Factory, [FRecRef, Metrics, Ticker]);
  R := Client.Send(SseRequest(cStreamUrl));
  FInFlightDuring := FRegistry.Gauge('http_client_in_flight').Value;
  AssertTrue(Supports(R, IAttemptProgress, P));
  FWanted := P.WantedKinds;
  P := nil;
  Push(Factory.SocketAt(0), 'data: one'#10#10'data: tw', False, 1000100);
  Push(Factory.SocketAt(0), 'o'#10#10'data: three'#10#10, False, 1000400);
  Push(Factory.SocketAt(0), '', True, 1000500);
  Src := TSseSource.Create(R);
  for I := 1 to 3 do
    AssertTrue('event ' + IntToStr(I), Src.ReadEvent(Ev));
  AssertFalse('the stream ended', Src.ReadEvent(Ev));
  AssertTrue('the attempt ended', FRec.WaitForEnds(1, 5000));
  FOutcome := FRec.Outcome(0).O;
  Src := nil;
  R := nil;
  Client.Close;
end;

procedure TMetricsAdapterTest.TestScriptedStreamTimesAreDerivedExactly;
begin
  RunScriptedStream(False);
  AssertEquals('the request was written after the attempt began', 50,
    FOutcome.RequestSentUs);
  AssertEquals('headers arrived then too', 50, FOutcome.HeadersUs);
  AssertEquals('three events', 3, FOutcome.MessagesIn);
  // time to first byte: HeadersUs - RequestSentUs
  AssertHist('http_sse_ttfb_us', 1, 0);
  // time to first event: FirstMessageUs (100) - RequestSentUs (50)
  AssertHist('http_sse_first_message_us', 1, 50);
  // mean inter-event latency: SumGapUs (300) / (MessagesIn - 1)
  AssertHist('http_sse_mean_gap_us', 1, 150);
  // the stall: the largest gap
  AssertHist('http_sse_max_gap_us', 1, 300);
  // stream duration: LastMessageUs (400) - FirstMessageUs (100)
  AssertHist('http_sse_stream_duration_us', 1, 300);
  // total latency: EndUs
  AssertHist('http_sse_total_us', 1, 500);
  AssertHist('http_sse_request_bytes', 1, 0);
  AssertFalse('an event stream stays out of the request-latency histograms',
    FRegistry.HasHistogram('http_request_total_us'));
end;

procedure TMetricsAdapterTest.TestScriptedStreamRatesAndTotalsAreDerivedExactly;
begin
  RunScriptedStream(False);
  AssertEquals('bytes on the wire', 35, FOutcome.BytesIn);
  // event rate: (MessagesIn - 1) / (LastMessageUs - FirstMessageUs), per second
  AssertHist('http_sse_message_rate_per_s', 1, 2 * 1000000.0 / 300);
  // byte rate: BytesIn / (EndUs - HeadersUs), per second
  AssertHist('http_sse_byte_rate_per_s', 1, 35 * 1000000.0 / 450);
end;

procedure TMetricsAdapterTest.TestInFlightGaugeAndCountByStatus;
begin
  RunScriptedStream(False);
  AssertEquals('one attempt in flight while the stream is open', 1,
    FInFlightDuring, 0.001);
  AssertEquals('none after it ended', 0,
    FRegistry.Gauge('http_client_in_flight').Value, 0.001);
  AssertEquals('counted by kind and status', 1,
    FRegistry.Counter('http_client_requests_total').Value(
      'kind="sse",status="200"'));
  AssertEquals('only that one', 0,
    FRegistry.Counter('http_client_requests_total').Value(
      'kind="request",status="200"'));
end;

procedure TMetricsAdapterTest.TestRequestCountsByStatusAcrossARedirectChain;
var
  Factory: TFakeFrameFactory;
  Metrics: IHttpClientObserver;
  Client: IHttpClient;
  C: TCounter;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/b'), HdrSpec('302', '/c'), HdrSpec('404'),
    HdrSpec('500')]));
  Metrics := TMetricsObserver.Create(FRegistry);
  Client := BuildClient(Factory, [Metrics]);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/z'));
  C := FRegistry.Counter('http_client_requests_total');
  AssertEquals('each redirect hop is an attempt', 2,
    C.Value('kind="request",status="302"'));
  AssertEquals(1, C.Value('kind="request",status="404"'));
  AssertEquals(1, C.Value('kind="request",status="500"'));
  AssertEquals('nothing else', 0, C.Value('kind="request",status="200"'));
  AssertEquals('all done', 0, FRegistry.Gauge('http_client_in_flight').Value,
    0.001);
  Client.Close;
end;

procedure TMetricsAdapterTest.TestErrorsAndAbandonedAreCounted;
var
  Factory: TFakeFrameFactory;
  Metrics: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Buf: array[0..15] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrRstSpec(ecInternalError), HdrSpec('200', '', BytesOf('unread'), True)]));
  Metrics := TMetricsObserver.Create(FRegistry);
  Client := BuildClient(Factory, [Metrics]);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  AssertEquals('in flight while open', 1,
    FRegistry.Gauge('http_client_in_flight').Value, 0.001);
  try
    R.Body.Read(Buf, SizeOf(Buf));
    Fail('the read should fail');
  except
    on E: EHttpStreamError do ;
  end;
  R := nil;
  AssertEquals('the failure was counted by class', 1,
    FRegistry.Counter('http_client_errors_total').Value(
      'kind="request",type="EHttpStreamError"'));
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/b'));
  AssertEquals('not abandoned while held', 0,
    FRegistry.Counter('http_client_abandoned_total').Value('kind="request"'));
  R := nil;
  AssertEquals('released unread', 1,
    FRegistry.Counter('http_client_abandoned_total').Value('kind="request"'));
  AssertEquals('in flight is back to zero', 0,
    FRegistry.Gauge('http_client_in_flight').Value, 0.001);
  Client.Close;
end;

procedure TMetricsAdapterTest.TestPerEventHistogramMatchesTheScriptedGaps;
var
  H: THistogram;
  I: Integer;
begin
  RunScriptedStream(True);
  AssertTrue('the attempt asked for events', mkSseEvent in FWanted);
  // events arrive at 100, 400 and 400: the first has no gap, then 300 and 0
  AssertTrue(FRegistry.HasHistogram(GapHistogramName(akSse)));
  H := FRegistry.Histogram(GapHistogramName(akSse), cLatencyBoundsUs);
  AssertEquals('two gaps', 2, H.Count);
  AssertEquals('their sum', 300, H.Sum, 0.001);
  AssertEquals('the largest', 300, H.Max, 0.001);
  AssertEquals('the 0 gap is in the first bucket (<= 100)', 1, H.CountAt(0));
  AssertEquals('the 300 gap is in the second bucket (<= 500)', 1, H.CountAt(1));
  for I := 2 to H.BucketCount - 1 do
    AssertEquals('bucket ' + IntToStr(I) + ' is empty', 0, H.CountAt(I));
  // the aggregates are unaffected by the gate
  AssertHist('http_sse_mean_gap_us', 1, 150);
end;

procedure TMetricsAdapterTest.TestHistogramIsEmptyWhileTheGateIsOff;
begin
  RunScriptedStream(False);
  AssertTrue('the attempt asked for nothing', FWanted = []);
  AssertFalse('so the histogram was never fed',
    FRegistry.HasHistogram(GapHistogramName(akSse)));
  AssertHist('http_sse_max_gap_us', 1, 300);
end;

procedure TMetricsAdapterTest.TestPoolStatsGaugeReadsOneSnapshotPerCollection;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Lines: TStringList;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('200', '', BytesOf('held'), True)]));
  Client := BuildClient(Factory, []);
  FRegistry.AddCollector(TPoolStatsCollector.Create(Client));
  FRegistry.Collect;
  AssertEquals('no connection yet', 0,
    FRegistry.Gauge('http_pool_connections').Value, 0.001);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a'));
  FRegistry.Collect;
  AssertEquals('one connection', 1,
    FRegistry.Gauge('http_pool_connections').Value, 0.001);
  AssertEquals('with a stream in flight', 1,
    FRegistry.Gauge('http_pool_active_streams').Value, 0.001);
  AssertEquals('so it is not idle', 0,
    FRegistry.Gauge('http_pool_idle_connections').Value, 0.001);
  Lines := TStringList.Create;
  try
    FRegistry.Dump(Lines);
    AssertTrue('the dump collects first and lists the gauge',
      Lines.IndexOf('http_pool_active_streams 1') >= 0);
  finally
    Lines.Free;
  end;
  R := nil;
  FRegistry.Collect;
  AssertEquals('the stream was released', 0,
    FRegistry.Gauge('http_pool_active_streams').Value, 0.001);
  AssertEquals('and the connection is idle', 1,
    FRegistry.Gauge('http_pool_idle_connections').Value, 0.001);
  Client.Close;
end;

{ TLoggingAdapterTest }

initialization
  RegisterTest(TTracingAdapterTest);
  RegisterTest(TMetricsAdapterTest);
end.
