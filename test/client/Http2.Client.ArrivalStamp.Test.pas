{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.ArrivalStamp.Test;

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
  TArrivalStampTest = class(TTestCase)
  private
    function Build(const AFactory: TFakeFrameFactory;
      const AObserver: IHttpClientObserver): IHttpClient;
    procedure Barrier(const ASocket: TFakeFrameSocket);
    procedure Push(const ASocket: TFakeFrameSocket; const AText: string;
      const AEndStream: Boolean; const AStampUs: Int64);
  protected
    procedure TearDown; override;
  published
    // 19.1 - 19.4
    procedure TestBuiltFramesCarryNoStamp;
    procedure TestReaderStampsFramesFromTheClock;
    procedure TestStampSurvivesTheQueue;
    procedure TestEachReadMapsToOneFrameAndOneStamp;
    procedure TestAReadInsideOneFrameKeepsItsStamp;
    // 19.6 / 19.7
    procedure TestPlainResponseAggregatesComeFromWireStamps;
    procedure TestUnreadResponseReportsNoMessages;
    procedure TestSlowConsumerDoesNotChangeTheGaps;
    procedure TestSlowConsumerOnTheRealClock;
  end;


implementation

{ TArrivalStampTest }

procedure TArrivalStampTest.TearDown;
begin
  ResetNowUsHook;
  inherited TearDown;
end;

function TArrivalStampTest.Build(const AFactory: TFakeFrameFactory;
  const AObserver: IHttpClientObserver): IHttpClient;
begin
  Result := THttpClientFactory.Create.WithSocketFactory(AFactory)
    .WithRequestObserver(AObserver).Build;
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

procedure TArrivalStampTest.Barrier(const ASocket: TFakeFrameSocket);
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

procedure TArrivalStampTest.Push(const ASocket: TFakeFrameSocket;
  const AText: string; const AEndStream: Boolean; const AStampUs: Int64);
begin
  GScriptedUs := AStampUs;
  ASocket.InjectFrame(BuildDataFrame(1, BytesOf(AText), AEndStream));
  Barrier(ASocket);
end;
procedure TArrivalStampTest.TestBuiltFramesCarryNoStamp;
var
  F: TFrame;
begin
  F := TFrame.Create(ftData, [], 1, BytesOf('x'));
  AssertEquals('Create', 0, F.ArrivedUs);
  AssertEquals('data builder', 0, BuildDataFrame(1, BytesOf('x'), True).ArrivedUs);
  AssertEquals('ping builder', 0,
    BuildPingFrame(BytesOf('12345678'), False).ArrivedUs);
end;

procedure TArrivalStampTest.TestReaderStampsFramesFromTheClock;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
  Stamped: IStampedBodyStream;
  Buf: array[0..15] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  GScriptedUs := 1000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, Obs);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Sock := Factory.SocketAt(0);
  AssertTrue('the body is stamped', Supports(R.Body, IStampedBodyStream, Stamped));
  AssertEquals('nothing read yet', 0, Stamped.LastReadArrivedUs);
  Push(Sock, 'aaa', False, 5000);
  AssertEquals('3 bytes', 3, R.Body.Read(Buf, SizeOf(Buf)));
  AssertEquals('stamp of the first frame', 5000, Stamped.LastReadArrivedUs);
  Push(Sock, 'bb', False, 7500);
  AssertEquals('2 bytes', 2, R.Body.Read(Buf, SizeOf(Buf)));
  AssertEquals('stamp of the second frame', 7500, Stamped.LastReadArrivedUs);
  GScriptedUs := 99999;   // the consumer's clock must not matter
  R := nil;
  Client.Close;
end;

procedure TArrivalStampTest.TestStampSurvivesTheQueue;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Stamped: IStampedBodyStream;
  Buf: array[0..15] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  GScriptedUs := 1000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, Obs);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Push(Factory.SocketAt(0), 'queued', False, 4242);
  // the frame sits in the lease's queue while time passes; the delay is the
  // thing under test, not a wait on another thread
  Sleep(200);
  GScriptedUs := 4242 + 200000;
  AssertTrue(Supports(R.Body, IStampedBodyStream, Stamped));
  AssertEquals('6 bytes', 6, R.Body.Read(Buf, SizeOf(Buf)));
  AssertEquals('the arrival stamp, not the read time', 4242,
    Stamped.LastReadArrivedUs);
  R := nil;
  Client.Close;
end;

procedure TArrivalStampTest.TestEachReadMapsToOneFrameAndOneStamp;
var
  Factory: TFakeFrameFactory;
  Obs: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
  Stamped: IStampedBodyStream;
  Buf: array[0..63] of Byte;
  Stamps: array of Int64;
  Sizes: array of Integer;
  N: LongInt;
begin
  Stamps := nil;
  Sizes := nil;
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  GScriptedUs := 1000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, Obs);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Sock := Factory.SocketAt(0);
  Push(Sock, 'one', False, 2000);
  Push(Sock, 'three', False, 2600);
  Push(Sock, '', True, 3000);
  AssertTrue(Supports(R.Body, IStampedBodyStream, Stamped));
  // a buffer large enough for both frames still gets one frame per Read
  repeat
    N := R.Body.Read(Buf, SizeOf(Buf));
    if N > 0 then
    begin
      SetLength(Stamps, Length(Stamps) + 1);
      SetLength(Sizes, Length(Sizes) + 1);
      Stamps[High(Stamps)] := Stamped.LastReadArrivedUs;
      Sizes[High(Sizes)] := N;
    end;
  until N <= 0;
  AssertEquals('two Reads returned bytes', 2, Length(Stamps));
  AssertEquals('first frame size', 3, Sizes[0]);
  AssertEquals('second frame size', 5, Sizes[1]);
  AssertEquals('first stamp', 2000, Stamps[0]);
  AssertEquals('second stamp', 2600, Stamps[1]);
  R := nil;
  Client.Close;
end;

procedure TArrivalStampTest.TestAReadInsideOneFrameKeepsItsStamp;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Stamped: IStampedBodyStream;
  Buf: array[0..1] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Push(Factory.SocketAt(0), 'abcde', False, 3000);
  Push(Factory.SocketAt(0), '', True, 3500);
  AssertTrue(Supports(R.Body, IStampedBodyStream, Stamped));
  // 5 bytes in a 2-byte buffer: three Reads of one frame, one stamp
  AssertEquals(2, R.Body.Read(Buf, 2));
  AssertEquals(3000, Stamped.LastReadArrivedUs);
  AssertEquals(2, R.Body.Read(Buf, 2));
  AssertEquals(3000, Stamped.LastReadArrivedUs);
  AssertEquals(1, R.Body.Read(Buf, 2));
  AssertEquals(3000, Stamped.LastReadArrivedUs);
  AssertEquals('EOF', 0, R.Body.Read(Buf, 2));
  R := nil;
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('one frame is one message', 1, Obs.Outcome(0).O.MessagesIn);
  AssertEquals('so no gap', 0, Obs.Outcome(0).O.MaxGapUs);
  Client.Close;
end;

procedure TArrivalStampTest.TestPlainResponseAggregatesComeFromWireStamps;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
  O: THttpOutcome;
  Buf: array[0..63] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 1000000;           // the attempt starts here
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Sock := Factory.SocketAt(0);
  Push(Sock, 'aaaa', False, 1000100);
  Push(Sock, 'bb', False, 1000400);
  Push(Sock, 'c', False, 1000450);
  Push(Sock, '', True, 1000500);
  GScriptedUs := 1000600;
  while R.Body.Read(Buf, SizeOf(Buf)) > 0 do ;
  AssertTrue('the attempt ended', Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('bytes', 7, O.BytesIn);
  AssertEquals('three messages', 3, O.MessagesIn);
  AssertEquals('first message', 100, O.FirstMessageUs);
  AssertEquals('last message', 450, O.LastMessageUs);
  AssertEquals('largest gap', 300, O.MaxGapUs);
  AssertEquals('summed gaps', 350, O.SumGapUs);
  R := nil;
  Client.Close;
end;

procedure TArrivalStampTest.TestUnreadResponseReportsNoMessages;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('200', '', BytesOf('never read'), True)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  R := nil;
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertTrue(Obs.Outcome(0).O.Abandoned);
  AssertEquals('nothing was consumed', 0, Obs.Outcome(0).O.MessagesIn);
  AssertEquals(0, Obs.Outcome(0).O.FirstMessageUs);
  Client.Close;
end;

procedure TArrivalStampTest.TestSlowConsumerDoesNotChangeTheGaps;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
  I: Integer;
  Buf: array[0..63] of Byte;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 0;
  SetNowUsHook(ScriptedClock);
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Sock := Factory.SocketAt(0);
  // ten frames, 10 ms apart on the wire, all queued before the consumer
  // reads a byte (fewer than the queue's 128)
  for I := 1 to 10 do
    Push(Sock, 'frame', False, Int64(I) * 10000);
  Push(Sock, '', True, 100500);
  for I := 1 to 10 do
  begin
    // the consumer is 100 ms behind the wire on every frame
    GScriptedUs := 100500 + Int64(I) * 100000;
    AssertEquals(5, R.Body.Read(Buf, SizeOf(Buf)));
  end;
  AssertEquals(0, R.Body.Read(Buf, SizeOf(Buf)));
  AssertTrue(Obs.WaitForEnds(1, 5000));
  AssertEquals('ten messages', 10, Obs.Outcome(0).O.MessagesIn);
  AssertEquals('the wire gap, not the consumer gap', 10000,
    Obs.Outcome(0).O.MaxGapUs);
  AssertEquals(90000, Obs.Outcome(0).O.SumGapUs);
  R := nil;
  Client.Close;
end;

type
  /// reads a body with a pause after every Read, like a slow consumer
  TSlowReaderThread = class(TThread)
  private
    FBody: IHttpBodyStream;
    FPauseMs: Integer;
    FDone: PRTLEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABody: IHttpBodyStream; const APauseMs: Integer;
      const ADone: PRTLEvent);
  end;

constructor TSlowReaderThread.Create(const ABody: IHttpBodyStream;
  const APauseMs: Integer; const ADone: PRTLEvent);
begin
  FBody := ABody;
  FPauseMs := APauseMs;
  FDone := ADone;
  inherited Create(False);
end;

procedure TSlowReaderThread.Execute;
var
  Buf: array[0..63] of Byte;
  N: LongInt;
begin
  try
    repeat
      N := FBody.Read(Buf, SizeOf(Buf));
      Sleep(FPauseMs);   // the consumer's lateness, not a wait on a thread
    until N <= 0;
  except
  end;
  RTLEventSetEvent(FDone);
end;

procedure TArrivalStampTest.TestSlowConsumerOnTheRealClock;
var
  Factory: TFakeFrameFactory;
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
  Done: PRTLEvent;
  T: TSlowReaderThread;
  I: Integer;
  O: THttpOutcome;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '', nil, False)]));
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := Build(Factory, ObsRef);
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  Sock := Factory.SocketAt(0);
  Done := RTLEventCreate;
  T := TSlowReaderThread.Create(R.Body, 100, Done);
  try
    for I := 1 to 6 do
    begin
      Sock.InjectFrame(BuildDataFrame(1, BytesOf('frame'), False));
      Barrier(Sock);
      Sleep(10);   // scripted 10 ms wire spacing
    end;
    Sock.InjectFrame(BuildDataFrame(1, nil, True));
    RTLEventWaitFor(Done, 15000);   // bounded; the end is asserted below
    T.WaitFor;
  finally
    T.Free;
    RTLEventDestroy(Done);
  end;
  AssertTrue(Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('six messages', 6, O.MessagesIn);
  // the consumer lags 100 ms per frame; the wire spacing is about 10 ms. The
  // upper bound sits below the consumer's lag, not tight against the wire
  // spacing, so scheduler jitter on a loaded machine cannot fail it while a
  // gap measured at the consumer (100 ms or more) still would.
  AssertTrue('gap reflects the wire, not the consumer: ' + IntToStr(O.MaxGapUs),
    (O.MaxGapUs >= 9000) and (O.MaxGapUs < 90000));
  R := nil;
  Client.Close;
end;


initialization
  RegisterTest(TArrivalStampTest);
end.
