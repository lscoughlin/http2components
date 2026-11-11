{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.RequestObserver.Core.Test;

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
  TClockCoreTest = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    procedure TestNowUsNeverDecreases;
    procedure TestNowUsMeasuresElapsedTime;
  end;


  TRequestContextTest = class(TTestCase)
  published
    procedure TestContextSurvivesCloneWithUrlDropBodyAndMethodToken;
    procedure TestHeaderSinkSetValueReplaces;
  end;


  TRequestObserverTest = class(TTestCase)
  private
    function Build(const AFactory: TFakeFrameFactory;
      const AObserver: IHttpClientObserver;
      const ALogger: IHttpLogger = nil): IHttpClient;
    function ReadToEnd(const AResponse: IHttpResponse): Integer;
  published
    // 18.5 / 18.6 / 18.7
    procedure TestCompositeRunsStartInOrderAndEndInReverse;
    procedure TestCompositeSkipsAMemberThatRaises;
    procedure TestFactoryAccumulatesObserversAndForksStayApart;
    procedure TestRaisingObserverDoesNotFailSendAndIsLogged;
    // 18.8 / 18.9 / 18.14
    procedure TestRedirectChainYieldsOneAttemptPerHop;
    procedure TestContextReachesEveryHop;
    procedure TestCallerAndObserverHeadersCoexistAsOneValue;
    procedure TestRefusedStreamRetryIsItsOwnAttempt;
    procedure TestNoObserverClonesNothing;
    procedure TestRequestFailureBeforeSendStillEnds;
    procedure TestCancelledRequestReportsCancelled;
    // 18.10 / 18.12 / 18.13
    procedure TestBodyEofEndsTheAttemptOnce;
    procedure TestSecondRequestReportsAReusedConnection;
    procedure TestBodylessResponseEndsAtOnce;
    procedure TestResetStreamEndsWithTheError;
    procedure TestConnectionLossEndsWithTheError;
    procedure TestUnreadResponseDroppedEndsAbandoned;
    procedure TestRequestBodySizeIsReported;
    procedure TestEndsRacingConnectionFailureFireOnce;
  end;


implementation

procedure TClockCoreTest.TestNowUsNeverDecreases;
var
  I: Integer;
  Prev, Cur: Int64;
begin
  Prev := NowUs;
  for I := 1 to 1000000 do
  begin
    Cur := NowUs;
    if Cur < Prev then
      Fail('the clock stepped backwards at read ' + IntToStr(I));
    Prev := Cur;
  end;
end;

procedure TClockCoreTest.TestNowUsMeasuresElapsedTime;
var
  A, B: Int64;
begin
  A := NowUs;
  Sleep(10);      // the sleep is the thing measured, not a wait on a thread
  B := NowUs;
  AssertTrue('at least 9 ms elapsed', B - A >= 9000);
  // a loaded host can oversleep; the bound only has to separate ms from s
  AssertTrue('well under a second elapsed', B - A <= 1000000);
end;

{ TRequestContextTest }

procedure TRequestContextTest.TestContextSurvivesCloneWithUrlDropBodyAndMethodToken;
var
  Ctx: IInterface;
  R: THttpRequest;
begin
  Ctx := TInterfacedObject.Create;
  R := THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('x')).WithContext(Ctx);
  AssertTrue('context is set', R.Context = Ctx);
  AssertTrue('Clone keeps it', R.Clone.Context = Ctx);
  AssertTrue('WithUrl keeps it', R.WithUrl('https://b.example/').Context = Ctx);
  AssertTrue('DropBody keeps it', R.DropBody.Context = Ctx);
  AssertTrue('WithMethodToken keeps it', R.WithMethodToken('PURGE').Context = Ctx);
  AssertTrue('a fresh request has none',
    THttpRequest.Create(hmGet, 'https://a.example/').Context = nil);
end;

procedure TRequestContextTest.TestHeaderSinkSetValueReplaces;
var
  H: IHttpHeaders;
  Sink: IHeaderSink;
begin
  H := NewHttpHeaders;
  H.Add('traceparent', 'caller-1');
  H.Add('traceparent', 'caller-2');
  Sink := THeaderSink.Create(H);
  AssertEquals('the sink reads the first value', 'caller-1',
    Sink.GetFirst('traceparent'));
  Sink.SetValue('traceparent', 'observer');
  AssertEquals('one value remains', 1, Length(H.GetValues('traceparent')));
  AssertEquals('it is the observer''s', 'observer', H.GetFirst('traceparent'));
  Sink.SetValue('baggage', 'k=v');
  AssertEquals('a new header is added', 'k=v', H.GetFirst('baggage'));
end;

{ TRequestObserverTest }

function TRequestObserverTest.Build(const AFactory: TFakeFrameFactory;
  const AObserver: IHttpClientObserver; const ALogger: IHttpLogger): IHttpClient;
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

function TRequestObserverTest.ReadToEnd(const AResponse: IHttpResponse): Integer;
var
  Buf: array[0..255] of Byte;
  N: LongInt;
begin
  Result := 0;
  repeat
    N := AResponse.Body.Read(Buf, SizeOf(Buf));
    if N > 0 then
      Inc(Result, N);
  until N <= 0;
end;

procedure TRequestObserverTest.TestCompositeRunsStartInOrderAndEndInReverse;
var
  Log: TEventLog;
  A, B, C: IHttpClientObserver;
  Comp: IHttpClientObserver;
  Att: THttpAttempt;
  Tok: IInterface;
  O: THttpOutcome;
begin
  Log := TEventLog.Create;
  try
    A := TRecordingRequestObserver.Create(Log, 'A');
    B := TRecordingRequestObserver.Create(Log, 'B');
    C := TRecordingRequestObserver.Create(Log, 'C');
    Comp := TCompositeObserver.Create([A, B, C]);
    FillChar(Att, SizeOf(Att), 0);
    Att.Headers := nil;
    Tok := Comp.OnAttemptStart(Att);
    Comp.OnResponseHeaders(Tok, nil);
    FillChar(O, SizeOf(O), 0);
    Comp.OnAttemptEnd(Tok, O);
    AssertEquals('start and headers in registration order, end reversed',
      'A.S B.S C.S A.H B.H C.H C.E B.E A.E', Log.Text);
  finally
    Log.Free;
  end;
end;

procedure TRequestObserverTest.TestCompositeSkipsAMemberThatRaises;
var
  Log: TEventLog;
  Logger: TRecordingLogger;
  LoggerRef: IHttpLogger;
  A, B, C: TRecordingRequestObserver;
  IA, IB, IC: IHttpClientObserver;
  Comp: IHttpClientObserver;
  Att: THttpAttempt;
  Tok: IInterface;
  O: THttpOutcome;
begin
  Log := TEventLog.Create;
  try
    Logger := TRecordingLogger.Create;
    LoggerRef := Logger;
    A := TRecordingRequestObserver.Create(Log, 'A');
    B := TRecordingRequestObserver.Create(Log, 'B');
    C := TRecordingRequestObserver.Create(Log, 'C');
    IA := A; IB := B; IC := C;
    FillChar(Att, SizeOf(Att), 0);
    FillChar(O, SizeOf(O), 0);

    // a member whose start raises gets no further callback
    B.RaiseOn := 'OnAttemptStart';
    Comp := TCompositeObserver.Create([IA, IB, IC], LoggerRef);
    Tok := Comp.OnAttemptStart(Att);
    Comp.OnAttemptEnd(Tok, O);
    AssertEquals('the raising member is skipped', 'A.S B.S C.S C.E A.E',
      Log.Text);
    AssertEquals('one warning', 1, Logger.Count);
    AssertTrue('at warn level', Logger.LevelAt(0) = llWarn);
    AssertTrue('naming the callback',
      Pos('OnAttemptStart', Logger.MessageAt(0)) > 0);

    // a member that raises later does not stop the rest
    Tok := nil;
    B.RaiseOn := 'OnResponseHeaders,OnAttemptEnd';
    Tok := Comp.OnAttemptStart(Att);
    Comp.OnResponseHeaders(Tok, nil);
    Comp.OnAttemptEnd(Tok, O);
    AssertEquals('later members still run',
      'A.S B.S C.S C.E A.E A.S B.S C.S A.H B.H C.H C.E B.E A.E', Log.Text);
    AssertEquals('two more warnings', 3, Logger.Count);
  finally
    Log.Free;
  end;
end;

procedure TRequestObserverTest.TestFactoryAccumulatesObserversAndForksStayApart;
var
  F0, F1, F2, F3: THttpClientFactory;
  O1, O2, O3: IHttpClientObserver;
begin
  O1 := TBaseRequestObserver.Create;
  O2 := TBaseRequestObserver.Create;
  O3 := TBaseRequestObserver.Create;
  F0 := THttpClientFactory.Create;
  AssertEquals('an unset factory has none', 0, Length(F0.RequestObservers));
  F1 := F0.WithRequestObserver(O1);
  F2 := F1.WithRequestObserver(O2);
  F3 := F1.WithRequestObserver(O3);
  AssertEquals('the base is untouched', 0, Length(F0.RequestObservers));
  AssertEquals('one call installs one', 1, Length(F1.RequestObservers));
  AssertEquals('two calls install two', 2, Length(F2.RequestObservers));
  AssertTrue('in registration order', F2.RequestObservers[0] = O1);
  AssertTrue('second is the second', F2.RequestObservers[1] = O2);
  AssertEquals('a fork has its own list', 2, Length(F3.RequestObservers));
  AssertTrue('a fork does not see its sibling', F3.RequestObservers[1] = O3);
  AssertTrue('the sibling kept its own', F2.RequestObservers[1] = O2);
end;

procedure TRequestObserverTest.TestRaisingObserverDoesNotFailSendAndIsLogged;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Logger: TRecordingLogger;
  LoggerRef: IHttpLogger;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Obs.RaiseOn := 'OnAttemptStart';
  Logger := TRecordingLogger.Create;
  LoggerRef := Logger;
  Client := Build(Factory, ObsRef, LoggerRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the request succeeded', 200, R.StatusCode);
  AssertEquals('one warning', 1, Logger.Count);
  AssertTrue('at warn level', Logger.LevelAt(0) = llWarn);
  AssertTrue('naming the callback',
    Pos('OnAttemptStart', Logger.MessageAt(0)) > 0);
  Client.Close;
end;

procedure TRequestObserverTest.TestRedirectChainYieldsOneAttemptPerHop;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Req: THttpRequest;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/b'), HdrSpec('302', '/c'), HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Obs.InjectName := 'traceparent';
  Obs.InjectPrefix := 'tp';
  Client := Build(Factory, ObsRef);
  Req := THttpRequest.Create(hmGet, 'https://a.example/a')
    .WithHeader('x-caller', 'yes');
  R := Client.Send(Req);
  AssertEquals('final status', 200, R.StatusCode);
  AssertEquals('three starts', 3, Obs.StartCount);
  AssertEquals('three ends', 3, Obs.EndCount);
  AssertEquals('hop 0', 0, Obs.Attempt(0).Hop);
  AssertEquals('hop 1', 1, Obs.Attempt(1).Hop);
  AssertEquals('hop 2', 2, Obs.Attempt(2).Hop);
  AssertEquals('hop 1 url', 'https://a.example/b', Obs.Attempt(1).Url);
  AssertEquals('host', 'a.example', Obs.Attempt(0).Host);
  AssertEquals('port', 443, Obs.Attempt(0).Port);
  AssertEquals('method', 'GET', Obs.Attempt(0).Method);
  AssertTrue('a plain request', Obs.Attempt(0).Kind = akRequest);
  AssertEquals('the callbacks interleave as the design gives',
    'S0 H0 R0 E0 S1 H1 R1 E1 S2 H2 E2', Obs.Order);
  Sock := Factory.SocketAt(0);
  AssertTrue('three requests were sent', Sock.WaitForRequests(3, 2000));
  AssertTrue('hop 0 carried a fresh value',
    Pos('traceparent: tp-1', Sock.RequestAt(0).HeaderLines) > 0);
  AssertTrue('hop 1 carried a fresh value',
    Pos('traceparent: tp-2', Sock.RequestAt(1).HeaderLines) > 0);
  AssertTrue('hop 2 carried a fresh value',
    Pos('traceparent: tp-3', Sock.RequestAt(2).HeaderLines) > 0);
  AssertTrue('hop 1 did not carry hop 0''s value',
    Pos('tp-1', Sock.RequestAt(1).HeaderLines) = 0);
  AssertTrue('no hop saw a header before the observer set it',
    (Obs.SeenBefore.Count = 3) and (Obs.SeenBefore[0] = '') and
    (Obs.SeenBefore[1] = '') and (Obs.SeenBefore[2] = ''));
  AssertTrue('the caller header travelled on every hop',
    Pos('x-caller: yes', Sock.RequestAt(2).HeaderLines) > 0);
  AssertFalse('the caller''s request is unchanged',
    Req.Headers.Contains('traceparent'));
  AssertEquals('the caller still has one header', 1, Length(Req.Headers.Names));
  AssertEquals('hop 0 status', 302, Obs.Outcome(0).O.StatusCode);
  AssertFalse('hop 0 dialled', Obs.Outcome(0).O.ConnectionReused);
  AssertTrue('hop 1 reused the connection', Obs.Outcome(1).O.ConnectionReused);
  AssertTrue('over TLS HTTP/2', Obs.Outcome(0).O.Protocol = npHttp2Tls);
  Client.Close;
end;

type
  TContextProbe = class(TInterfacedObject)
  end;

procedure TRequestObserverTest.TestContextReachesEveryHop;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Ctx: IInterface;
  R: IHttpResponse;
  I: Integer;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/b'), HdrSpec('307', '/c'), HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  Ctx := TContextProbe.Create;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/a')
    .WithContext(Ctx));
  AssertEquals(200, R.StatusCode);
  for I := 0 to 2 do
    AssertTrue('hop ' + IntToStr(I) + ' carries the context',
      Obs.Attempt(I).Context = Ctx);
  Client.Close;
end;

procedure TRequestObserverTest.TestCallerAndObserverHeadersCoexistAsOneValue;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Req: THttpRequest;
  Lines: string;
  First, Second: Integer;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Obs.InjectName := 'traceparent';
  Obs.InjectPrefix := 'obs';
  Client := Build(Factory, ObsRef);
  Req := THttpRequest.Create(hmGet, 'https://a.example/x')
    .WithHeader('traceparent', 'from-caller')
    .WithHeader('baggage', 'k=v');
  Client.Send(Req);
  AssertTrue('the sink saw the caller''s value first',
    (Obs.SeenBefore.Count = 1) and (Obs.SeenBefore[0] = 'from-caller'));
  AssertTrue('the request was sent',
    Factory.SocketAt(0).WaitForRequests(1, 2000));
  Lines := Factory.SocketAt(0).RequestAt(0).HeaderLines;
  First := Pos('traceparent:', Lines);
  AssertTrue('traceparent is on the wire', First > 0);
  Second := Pos('traceparent:', Copy(Lines, First + 1, MaxInt));
  AssertEquals('exactly one traceparent', 0, Second);
  AssertTrue('and it is the observer''s', Pos('traceparent: obs-1', Lines) > 0);
  AssertTrue('the caller''s other header coexists', Pos('baggage: k=v', Lines) > 0);
  AssertEquals('the caller''s own request keeps its value', 'from-caller',
    Req.Headers.GetFirst('traceparent'));
  Client.Close;
end;

procedure TRequestObserverTest.TestRefusedStreamRetryIsItsOwnAttempt;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([RstSpec(ecRefusedStream), HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the retry succeeded', 200, R.StatusCode);
  AssertEquals('two attempts', 2, Obs.StartCount);
  AssertEquals('retry counter, first', 0, Obs.Attempt(0).Retry);
  AssertEquals('retry counter, second', 1, Obs.Attempt(1).Retry);
  AssertEquals('both on hop 0', 0, Obs.Attempt(1).Hop);
  AssertEquals('retry fires before the failed attempt ends',
    'S0 T0 E0 S1 H1 E1', Obs.Order);
  AssertEquals('the refused attempt has no status', 0,
    Obs.Outcome(0).O.StatusCode);
  AssertEquals('it failed with the stream error', 'EHttpStreamError',
    Obs.Outcome(0).ErrorClass);
  AssertEquals('the retry ended clean', '', Obs.Outcome(1).ErrorClass);
  Client.Close;
end;

procedure TRequestObserverTest.TestNoObserverClonesNothing;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Plain, Observed: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Plain := Build(Factory, nil);
  Plain.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('no observer, no clone', 0, (Plain as THttpClient).ClonedAttempts);
  Plain.Close;
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Obs := TBaseRequestObserver.Create;
  Observed := Build(Factory, Obs);
  Observed.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('an observer clones once per attempt', 1,
    (Observed as THttpClient).ClonedAttempts);
  Observed.Close;
end;

procedure TRequestObserverTest.TestRequestFailureBeforeSendStillEnds;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Raised: Boolean;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  // the strict cleartext default refuses the request before any dial
  Client := THttpClientFactory.Create.WithSocketFactory(TNeverDialFactory.Create)
    .WithRequestObserver(ObsRef).Build;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'http://plain.example/x'));
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('the request failed', Raised);
  AssertEquals('a start is paired with one end', 'S0 E0', Obs.Order);
  AssertEquals('no status', 0, Obs.Outcome(0).O.StatusCode);
  AssertEquals('the error reached the outcome', 'EHttpProtocolError',
    Obs.Outcome(0).ErrorClass);
  Client.Close;
end;

procedure TRequestObserverTest.TestCancelledRequestReportsCancelled;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Token: TCancellationToken;
  TokenRef: ICancellationToken;
  Raised: Boolean;
begin
  Factory := TFakeFrameFactory.Create;
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  Token := TCancellationToken.Create;
  TokenRef := Token;
  Token.Cancel;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x')
      .WithCancelToken(TokenRef));
  except
    on E: EHttpStreamError do Raised := True;
  end;
  AssertTrue('the request was cancelled', Raised);
  AssertEquals('S0 E0', Obs.Order);
  AssertTrue('the outcome says cancelled', Obs.Outcome(0).O.Cancelled);
  Client.Close;
end;

procedure TRequestObserverTest.TestBodyEofEndsTheAttemptOnce;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  O: THttpOutcome;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('200', '', BytesOf('hello'), True)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the body is unread, so the attempt is open', 0, Obs.EndCount);
  AssertEquals('five bytes', 5, ReadToEnd(R));
  AssertEquals('EOF ended the attempt', 1, Obs.EndCount);
  AssertEquals('order', 'S0 H0 E0', Obs.Order);
  O := Obs.Outcome(0).O;
  AssertEquals('status', 200, O.StatusCode);
  AssertEquals('bytes in', 5, O.BytesIn);
  AssertEquals('no request body', 0, O.BytesOut);
  AssertFalse('read to the end', O.Abandoned);
  AssertFalse('not cancelled', O.Cancelled);
  AssertEquals('no error', '', Obs.Outcome(0).ErrorClass);
  AssertFalse('a fresh connection', O.ConnectionReused);
  AssertTrue('HTTP/2 over TLS', O.Protocol = npHttp2Tls);
  AssertTrue('request written before headers', O.RequestSentUs <= O.HeadersUs);
  AssertTrue('headers before the end', O.HeadersUs <= O.EndUs);
  R := nil;
  AssertEquals('releasing the finished response adds no second end', 1,
    Obs.EndCount);
  Client.Close;
end;

procedure TRequestObserverTest.TestSecondRequestReportsAReusedConnection;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/1'));
  Client.Send(THttpRequest.Create(hmGet, 'https://a.example/2'));
  AssertFalse('first dialled', Obs.Outcome(0).O.ConnectionReused);
  AssertTrue('second reused', Obs.Outcome(1).O.ConnectionReused);
  Client.Close;
end;

procedure TRequestObserverTest.TestBodylessResponseEndsAtOnce;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('204')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('nothing is left to read: the attempt ended', 1, Obs.EndCount);
  AssertEquals('headers precede the end', 'S0 H0 E0', Obs.Order);
  AssertFalse('not abandoned', Obs.Outcome(0).O.Abandoned);
  AssertEquals('status', 204, Obs.Outcome(0).O.StatusCode);
  R := nil;
  AssertEquals('release adds nothing', 1, Obs.EndCount);
  Client.Close;
end;

procedure TRequestObserverTest.TestResetStreamEndsWithTheError;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Buf: array[0..15] of Byte;
  Raised: Boolean;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrRstSpec(ecInternalError)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('headers arrived, the attempt is open', 0, Obs.EndCount);
  Raised := False;
  try
    R.Body.Read(Buf, SizeOf(Buf));
  except
    on E: EHttpStreamError do Raised := True;
  end;
  AssertTrue('the read failed', Raised);
  AssertEquals('one end', 1, Obs.EndCount);
  AssertEquals('the stream error', 'EHttpStreamError',
    Obs.Outcome(0).ErrorClass);
  AssertEquals('headers had arrived', 200, Obs.Outcome(0).O.StatusCode);
  AssertFalse('an error is not abandonment', Obs.Outcome(0).O.Abandoned);
  AssertFalse('not a cancel', Obs.Outcome(0).O.Cancelled);
  R := nil;
  AssertEquals('release adds nothing', 1, Obs.EndCount);
  Client.Close;
end;

procedure TRequestObserverTest.TestConnectionLossEndsWithTheError;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  // a response head that never ends: the body stays open
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('open while the body is pending', 0, Obs.EndCount);
  Factory.SocketAt(0).Close;
  AssertTrue('the connection failure ends the attempt',
    Obs.WaitForEnds(1, 5000));
  AssertTrue('with an error', Obs.Outcome(0).ErrorClass <> '');
  AssertEquals('headers had arrived', 200, Obs.Outcome(0).O.StatusCode);
  R := nil;
  AssertEquals('release adds nothing', 1, Obs.EndCount);
  Client.Close;
end;

procedure TRequestObserverTest.TestUnreadResponseDroppedEndsAbandoned;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('200', '', BytesOf('unread body'), True)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('open while held', 0, Obs.EndCount);
  R := nil;
  AssertEquals('release ends it', 1, Obs.EndCount);
  AssertTrue('abandoned', Obs.Outcome(0).O.Abandoned);
  AssertEquals('no error', '', Obs.Outcome(0).ErrorClass);
  Client.Close;
end;

procedure TRequestObserverTest.TestRequestBodySizeIsReported;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('payload')));
  AssertEquals('seven body bytes went out', 7, Obs.Outcome(0).O.BytesOut);
  Client.Close;
end;

type
  TBodyReaderThread = class(TThread)
  private
    FBody: IHttpBodyStream;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABody: IHttpBodyStream);
  end;

constructor TBodyReaderThread.Create(const ABody: IHttpBodyStream);
begin
  FBody := ABody;
  inherited Create(False);
end;

procedure TBodyReaderThread.Execute;
var
  Buf: array[0..63] of Byte;
  N: LongInt;
begin
  try
    repeat
      N := FBody.Read(Buf, SizeOf(Buf));
    until N <= 0;
  except
    // the connection may fail under the reader: that is the race under test
  end;
end;

procedure TRequestObserverTest.TestEndsRacingConnectionFailureFireOnce;
var
  I: Integer;
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  T: TBodyReaderThread;
begin
  for I := 1 to 40 do
  begin
    Factory := TFakeFrameFactory.Create;
    Factory.SetDialScript(0, SpecArray([
      HdrSpec('200', '', BytesOf('some body bytes'), True)]));
    Obs := TRecordingRequestObserver.Create;
    ObsRef := Obs;
    Client := Build(Factory, ObsRef);
    R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
    // the body is read on one thread while the connection fails and the
    // response is released on this one
    T := TBodyReaderThread.Create(R.Body);
    Factory.SocketAt(0).Close;
    T.WaitFor;
    T.Free;
    R := nil;
    AssertTrue('an end arrived', Obs.WaitForEnds(1, 5000));
    Client.Close;
    AssertEquals('exactly one end per start (round ' + IntToStr(I) + ')',
      Obs.StartCount, Obs.EndCount);
    Client := nil;
    ObsRef := nil;
  end;
end;


procedure TClockCoreTest.TearDown;
begin
  ResetNowUsHook;
  inherited TearDown;
end;
initialization
  RegisterTest(TClockCoreTest);
  RegisterTest(TRequestContextTest);
  RegisterTest(TRequestObserverTest);
end.
