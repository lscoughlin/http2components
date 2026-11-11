{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.MessageObserver.Test;

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
  TMessageObserverTest = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    // 20.1
    procedure TestAttemptKindStreamAndReconnectSurviveTheCopies;
    // 20.4
    procedure TestReaderReportsThreeMessagesAndTheOutcomeShowsThem;
    procedure TestFrameAggregatesStandWhenTheReaderReportsNothing;
    procedure TestDecodingResponseForwardsTheProgress;
    procedure TestUnobservedResponseAnswersAndIgnores;
    // 20.7
    procedure TestCompositeForwardsOnlyToMembersThatWantTheKind;
    procedure TestCompositeAsksEachMemberOncePerAttempt;
    procedure TestCompositeSkipsAMessageObserverThatRaises;
  end;


implementation

const
  cGzipHello: array[0..24] of Byte = (31, 139, 8, 0, 0, 0, 0, 0, 2, 19,
    203, 72, 205, 201, 201, 7, 0, 134, 166, 16, 54, 5, 0, 0, 0);
  cStreamUrl = 'https://a.example/events';

function NewIntf(const A: array of IHttpClientObserver):
  TArray<IHttpClientObserver>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;




procedure TMessageObserverTest.TestAttemptKindStreamAndReconnectSurviveTheCopies;
var
  Ctx: IInterface;
  R: THttpRequest;
begin
  Ctx := TInterfacedObject.Create;
  R := SseRequest(cStreamUrl).WithContext(Ctx).WithStream(7, 2);
  AssertTrue('SseRequest marks it', R.AttemptKind = akSse);
  AssertEquals(7, R.StreamId);
  AssertEquals(2, R.Reconnect);
  AssertTrue('Clone keeps the kind', R.Clone.AttemptKind = akSse);
  AssertEquals('Clone keeps the id', 7, R.Clone.StreamId);
  AssertEquals('Clone keeps the count', 2, R.Clone.Reconnect);
  AssertTrue('WithUrl', R.WithUrl('https://b.example/').AttemptKind = akSse);
  AssertEquals('WithUrl id', 7, R.WithUrl('https://b.example/').StreamId);
  AssertTrue('DropBody', R.DropBody.AttemptKind = akSse);
  AssertEquals('DropBody count', 2, R.DropBody.Reconnect);
  AssertTrue('WithMethodToken', R.WithMethodToken('PURGE').AttemptKind = akSse);
  AssertEquals('WithMethodToken id', 7, R.WithMethodToken('PURGE').StreamId);
  AssertTrue('the context is still there', R.Clone.Context = Ctx);
  R := THttpRequest.Create(hmGet, cStreamUrl);
  AssertTrue('a plain request is akRequest', R.AttemptKind = akRequest);
  AssertEquals(0, R.StreamId);
  AssertEquals(0, R.Reconnect);
end;

procedure TMessageObserverTest.TestReaderReportsThreeMessagesAndTheOutcomeShowsThem;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  P: IAttemptProgress;
  O: THttpOutcome;
  Buf: array[0..63] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', BytesOf('abcdefg'),
    True)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRequestObserver(ObsRef).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertTrue('the response exposes the progress',
    Supports(R, IAttemptProgress, P));
  AssertTrue('nobody asked for messages', P.WantedKinds = []);
  P.ReportMessage(mkSseEvent, mdIn, 1000100, 3, nil);
  P.ReportMessage(mkSseEvent, mdIn, 1000400, 2, nil);
  P.ReportMessage(mkSseEvent, mdIn, 1000450, 2, nil);
  P.ReportMessage(mkWsPing, mdIn, 1000460, 0, nil);   // not a data message
  P.ReportMessage(mkWsText, mdOut, 1000470, 4, nil);
  while R.Body.Read(Buf, SizeOf(Buf)) > 0 do ;
  AssertTrue('the attempt ended', Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('three messages in (the single frame would say one)', 3,
    O.MessagesIn);
  AssertEquals('first', 100, O.FirstMessageUs);
  AssertEquals('last', 450, O.LastMessageUs);
  AssertEquals('largest gap', 300, O.MaxGapUs);
  AssertEquals('summed gaps', 350, O.SumGapUs);
  AssertEquals('one data message out', 1, O.MessagesOut);
  AssertEquals('the codec still counts the bytes', 7, O.BytesIn);
  R := nil;
  P := nil;
  Client.Close;
end;

procedure TMessageObserverTest.TestFrameAggregatesStandWhenTheReaderReportsNothing;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Buf: array[0..63] of Byte;
begin
  // the counterpart: a reader that reports nothing leaves the codec's frame
  // aggregates in force
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', BytesOf('abcdefg'),
    True)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRequestObserver(ObsRef).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  while R.Body.Read(Buf, SizeOf(Buf)) > 0 do ;
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('one frame, one message', 1, Obs.Outcome(0).O.MessagesIn);
  AssertEquals(0, Obs.Outcome(0).O.MessagesOut);
  R := nil;
  Client.Close;
end;

procedure TMessageObserverTest.TestDecodingResponseForwardsTheProgress;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  P: IAttemptProgress;
  Gz: TBytes;
  Buf: array[0..63] of Byte;
  N, Total: LongInt;
begin
  Gz := nil;
  SetLength(Gz, Length(cGzipHello));
  for N := 0 to High(cGzipHello) do
    Gz[N] := cGzipHello[N];
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([WithContentType(
    HdrSpec('200', '', Gz, True), 'text/plain', 'gzip')]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000000;
  SetNowUsHook(ScriptedClock);
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRequestObserver(ObsRef).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertTrue('the decoding wrapper answers for the response it wraps',
    Supports(R, IAttemptProgress, P));
  P.ReportMessage(mkSseEvent, mdIn, 1000100, 1, nil);
  P.ReportMessage(mkSseEvent, mdIn, 1000200, 1, nil);
  Total := 0;
  repeat
    N := R.Body.Read(Buf, SizeOf(Buf));
    if N > 0 then
      Inc(Total, N);
  until N <= 0;
  AssertEquals('the body was decoded', 5, Total);
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('the reports reached the attempt', 2,
    Obs.Outcome(0).O.MessagesIn);
  R := nil;
  P := nil;
  Client.Close;
end;

procedure TMessageObserverTest.TestUnobservedResponseAnswersAndIgnores;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  P: IAttemptProgress;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', BytesOf('x'), True)]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertTrue(Supports(R, IAttemptProgress, P));
  AssertTrue(P.WantedKinds = []);
  P.ReadBegin;
  P.ReportMessage(mkSseEvent, mdIn, 5, 1, nil);
  P.ReadEnd;
  P.Finish(1);
  R := nil;
  Client.Close;
end;

procedure TMessageObserverTest.TestCompositeForwardsOnlyToMembersThatWantTheKind;
var
  A, B, C: TMessageRecordingObserver;
  Comp: IHttpClientObserver;
  MO: IHttpMessageObserver;
  Gate: IHttpMessageGate;
  Att: THttpAttempt;
  Tok: IInterface;
  M: TMessageInfo;
begin
  A := TMessageRecordingObserver.Create([mkSseEvent]);
  B := TMessageRecordingObserver.Create([mkWsText]);
  C := TMessageRecordingObserver.Create([]);
  Comp := TCompositeObserver.Create(NewIntf([A, B, C]));
  AssertTrue(Supports(Comp, IHttpMessageObserver, MO));
  AssertTrue(Supports(Comp, IHttpMessageGate, Gate));
  FillChar(Att, SizeOf(Att), 0);
  Tok := Comp.OnAttemptStart(Att);
  AssertTrue('the gate is the union', Gate.WantedFor(Tok) = [mkSseEvent, mkWsText]);
  FillChar(M, SizeOf(M), 0);
  M.Kind := mkSseEvent;
  MO.OnMessage(Tok, M);
  AssertEquals('A wanted events', 1, A.MessageCount);
  AssertEquals('B did not', 0, B.MessageCount);
  AssertEquals('C wanted nothing', 0, C.MessageCount);
  M.Kind := mkWsText;
  MO.OnMessage(Tok, M);
  AssertEquals(1, A.MessageCount);
  AssertEquals('B wanted text', 1, B.MessageCount);
  M.Kind := mkWsPing;
  MO.OnMessage(Tok, M);
  AssertEquals(1, A.MessageCount);
  AssertEquals(1, B.MessageCount);
  AssertEquals(0, C.MessageCount);
end;

procedure TMessageObserverTest.TestCompositeAsksEachMemberOncePerAttempt;
var
  A, B: TMessageRecordingObserver;
  Comp: IHttpClientObserver;
  MO: IHttpMessageObserver;
  Att: THttpAttempt;
  T1, T2: IInterface;
  M: TMessageInfo;
  I: Integer;
begin
  A := TMessageRecordingObserver.Create([mkSseEvent]);
  B := TMessageRecordingObserver.Create([]);
  Comp := TCompositeObserver.Create(NewIntf([A, B]));
  Supports(Comp, IHttpMessageObserver, MO);
  FillChar(Att, SizeOf(Att), 0);
  T1 := Comp.OnAttemptStart(Att);
  T2 := Comp.OnAttemptStart(Att);
  FillChar(M, SizeOf(M), 0);
  M.Kind := mkSseEvent;
  for I := 1 to 5 do
  begin
    MO.OnMessage(T1, M);
    MO.OnMessage(T2, M);
  end;
  AssertEquals('A was asked once per attempt', 2, A.WantsCalls);
  AssertEquals('B too', 2, B.WantsCalls);
  AssertEquals(10, A.MessageCount);
end;

procedure TMessageObserverTest.TestCompositeSkipsAMessageObserverThatRaises;
var
  A, B: TMessageRecordingObserver;
  Logger: TRecordingLogger;
  LoggerRef: IHttpLogger;
  Comp: IHttpClientObserver;
  MO: IHttpMessageObserver;
  Att: THttpAttempt;
  Tok: IInterface;
  M: TMessageInfo;
begin
  A := TMessageRecordingObserver.Create([mkSseEvent]);
  A.RaiseOnMessage := True;
  B := TMessageRecordingObserver.Create([mkSseEvent]);
  Logger := TRecordingLogger.Create;
  LoggerRef := Logger;
  Comp := TCompositeObserver.Create(NewIntf([A, B]), LoggerRef);
  Supports(Comp, IHttpMessageObserver, MO);
  FillChar(Att, SizeOf(Att), 0);
  Tok := Comp.OnAttemptStart(Att);
  FillChar(M, SizeOf(M), 0);
  M.Kind := mkSseEvent;
  MO.OnMessage(Tok, M);
  MO.OnMessage(Tok, M);
  AssertEquals('A saw both', 2, A.MessageCount);
  AssertEquals('B was not affected', 2, B.MessageCount);
  AssertEquals('each failure was logged', 2, Logger.Count);
  AssertTrue(Pos('OnMessage', Logger.MessageAt(0)) > 0);
end;



procedure TMessageObserverTest.TearDown;
begin
  ResetNowUsHook;
  inherited TearDown;
end;

initialization
  RegisterTest(TMessageObserverTest);
end.
