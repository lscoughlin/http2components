{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// WebSocket observability tests (doc/design/request-observability.md,
/// section "WebSocket")
// - the sessions run against the scripted loopback server of
//   Http2.Client.WebSocketClient.Support through a client with a recording request
//   observer; the cases that need an exact clock install a scripted one.
// - non-vacuous by construction: header injection is asserted from the
//   handshake bytes the server received, the end of a session from the
//   outcomes a recording observer saw, and every end is counted, so a missing
//   or duplicated OnAttemptEnd fails a test.
// - no test sleeps to wait for another thread: the script threads and the
//   tests hand each other events and wait on them with bounded timeouts.
unit Http2.Client.WebSocketObservability.Lifecycle.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Common.Headers, Http2.Client.Messages, Http2.Client.Http1,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection, Http2.Client.MockSocket,
  Http2.Client.RequestObserver.Test, Http2.Client.WebSocketClient.Support, Http2.Client.WebSocketObservability.Support;
type
  TWsObservabilityLifecycleTest = class(TWsObservabilityTestBase)
  published
    procedure TestReleasedUnstartedConnectionEndsAbandoned;
    procedure TestEndAfterAbortDoesNotReportAgainOnRelease;
    procedure TestEndingPathsRacingEachOtherEndOnce;
    procedure TestCountersSeparateMessagesFromPingsAndBytes;
    procedure TestConcurrentSendersLoseNoCounts;
    procedure TestWireStampsGiveTheAggregates;
    procedure TestFragmentedMessageTakesTheStampOfItsLastRead;
    procedure TestOptedInObserverSeesEveryKindInOrder;
    procedure TestEmptySetAndOtherKindsSeeNothing;
    procedure TestStampsIncludeTheConsumersWaitWithoutDemand;
    procedure TestAutoRequestKeepsTheConsumersWaitOutOfTheStamps;
    procedure TestRaisingObserverNeverBreaksTheSession;
  end;

implementation

procedure TWsObservabilityLifecycleTest.TestReleasedUnstartedConnectionEndsAbandoned;
var
  Fake: TFakeWsAttempt;
  FakeRef: IWebSocketAttempt;
  W: IWebSocket;
begin
  Fake := TFakeWsAttempt.Create;
  FakeRef := Fake;
  W := NewDirectConnection(FakeRef);
  AssertEquals('open session, no end', 0, Fake.Ends);
  W := nil;                          // released with no close, abort or failure
  AssertEquals('one end', 1, Fake.Ends);
  AssertTrue('abandoned', Fake.Last.Abandoned);
  AssertTrue('nobody closed it', Fake.Last.ClosedBy = ciNone);
end;

procedure TWsObservabilityLifecycleTest.TestEndAfterAbortDoesNotReportAgainOnRelease;
var
  Fake: TFakeWsAttempt;
  FakeRef: IWebSocketAttempt;
  W: IWebSocket;
begin
  Fake := TFakeWsAttempt.Create;
  FakeRef := Fake;
  W := NewDirectConnection(FakeRef);
  W.Abort;
  W.Abort;
  AssertEquals('one end after two aborts', 1, Fake.Ends);
  AssertTrue('abort', Fake.Last.ClosedBy = ciAbort);
  W := nil;
  AssertEquals('release adds nothing', 1, Fake.Ends);
  AssertFalse('a deliberate end', Fake.Last.Abandoned);
end;

procedure TWsObservabilityLifecycleTest.TestEndingPathsRacingEachOtherEndOnce;
const
  cRounds = 12;
var
  I: Integer;
  Srv: TWsTestServer;
  Rec: TRecorder;
  RecRef: IWebSocketListener;
  Obs: TWsObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  Sock: IWebSocket;
  Start1: TEvent;
  Th1, Th2: TWsActThread;
begin
  for I := 1 to cRounds do
  begin
    Srv := TWsTestServer.Create(ScriptHold);
    Srv.Start;
    Rec := TRecorder.Create(0);
    RecRef := Rec;
    Obs := TWsObserver.Create([]);
    ObsRef := Obs;
    Client := THttpClientFactory.Create.WithRequestObserver(ObsRef).Build;
    Start1 := TEvent.Create(nil, True, False, '');
    try
      Sock := Client.Send(TWebSocketRequest.Create(
        'ws://127.0.0.1:' + IntToStr(Srv.Port) + '/race', RecRef)
        .WithAutoRequest.WithCloseTimeoutMs(50));
      AssertTrue('open', Rec.WaitCount(1));
      // Abort and Close race on two threads while the server drops the
      // connection and this thread releases the socket
      Th1 := TWsActThread.Create(Sock, 0, Start1);
      Th2 := TWsActThread.Create(Sock, 1, Start1);
      Start1.SetEvent;
      try
        case I mod 3 of
          0: Sock.Abort;
          1: Sock.Close(1000, 'r');
        else
          Srv.CloseConnection;
        end;
      except
        // see TWsActThread
      end;
      Sock.Abort;
      Th1.WaitFor;
      Th2.WaitFor;
      Th1.Free;
      Th2.Free;
      Sock := nil;
      AssertTrue('ended in round ' + IntToStr(I), Obs.WaitForEnds(1, 5000));
      AssertEquals('one start', 1, Obs.StartCount);
      AssertEquals('exactly one end in round ' + IntToStr(I), 1, Obs.EndCount);
    finally
      Start1.Free;
      Srv.Terminate;
      Srv.Release.SetEvent;
      Srv.CloseConnection;
      Srv.ShutdownListener;
      Srv.Done.WaitFor(3000);
      Srv.Free;
    end;
  end;
end;

{ 21.7 }

procedure TWsObservabilityLifecycleTest.TestCountersSeparateMessagesFromPingsAndBytes;
var
  Sock: IWebSocket;
  I: Integer;
  O: THttpOutcome;
begin
  Start(ScriptSeven, []);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  for I := 1 to 10 do
    Sock.SendText('xyz');
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0).O;
  AssertEquals('seven messages in, two pings not counted', 7, O.MessagesIn);
  AssertEquals('ten messages out', 10, O.MessagesOut);
  AssertEquals('bytes in are the data payloads', 14, O.BytesIn);
  AssertEquals('bytes out are the data payloads', 30, O.BytesOut);
  AssertTrue('remote close', O.ClosedBy = ciRemote);
  AssertEquals('done', 'done', O.CloseReason);
end;

procedure TWsObservabilityLifecycleTest.TestConcurrentSendersLoseNoCounts;
const
  cThreads = 4;
  cEach = 50;
var
  Sock: IWebSocket;
  Threads: array[0..cThreads - 1] of TWsSendThread;
  Go: TEvent;
  I: Integer;
  O: THttpOutcome;
begin
  Start(ScriptCountFrames, []);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Go := TEvent.Create(nil, True, False, '');
  try
    for I := 0 to cThreads - 1 do
      Threads[I] := TWsSendThread.Create(Sock, cEach, Go);
    Go.SetEvent;
    for I := 0 to cThreads - 1 do
    begin
      Threads[I].WaitFor;
      AssertEquals('sender ' + IntToStr(I), '', Threads[I].Failure);
      Threads[I].Free;
    end;
  finally
    Go.Free;
  end;
  Sock.Close(1000, '');
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0).O;
  AssertEquals('every message counted', cThreads * cEach, O.MessagesOut);
  AssertEquals('every byte counted', cThreads * cEach * 3, O.BytesOut);
  AssertEquals('and the server received them all', cThreads * cEach, FSrvTexts);
  AssertEquals(cThreads * cEach * 3, FSrvBytes);
end;

{ 21.8 }

procedure TWsObservabilityLifecycleTest.TestWireStampsGiveTheAggregates;
const
  T0 = 1000000;
var
  Sock: IWebSocket;
  O: THttpOutcome;
begin
  GFakeNowUs := T0;
  SetNowUsHook(FakeNow);
  Start(ScriptStamps, [mkWsText]);
  Sock := Open;
  // each message is read at the clock the test holds when the server sends it
  AssertTrue('m1', FObs.WaitMessages(1, 5000));
  GFakeNowUs := T0 + 250;
  FGo.SetEvent;
  AssertTrue('m2', FObs.WaitMessages(2, 5000));
  GFakeNowUs := T0 + 260;
  FGo.SetEvent;
  AssertTrue('m3', FObs.WaitMessages(3, 5000));
  AssertEquals('first has no predecessor', 0, FObs.MessageAt(0).SinceLastUs);
  AssertEquals('first arrival', 0, FObs.MessageAt(0).ArrivedUs);
  AssertEquals('second gap', 250, FObs.MessageAt(1).SinceLastUs);
  AssertEquals('second arrival', 250, FObs.MessageAt(1).ArrivedUs);
  AssertEquals('third gap', 10, FObs.MessageAt(2).SinceLastUs);
  AssertEquals('indexes', 2, FObs.MessageAt(2).Index);
  AssertEquals('size', 2, FObs.MessageAt(2).Size);
  GFakeNowUs := T0 + 400;
  Sock.Abort;
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0).O;
  AssertEquals('three messages', 3, O.MessagesIn);
  AssertEquals('first message time', 0, O.FirstMessageUs);
  AssertEquals('last message time', 260, O.LastMessageUs);
  AssertEquals('largest gap', 250, O.MaxGapUs);
  AssertEquals('summed gaps', 260, O.SumGapUs);
  AssertEquals('end time', 400, O.EndUs);
end;

procedure TWsObservabilityLifecycleTest.TestFragmentedMessageTakesTheStampOfItsLastRead;
const
  T0 = 2000000;
var
  Sock: IWebSocket;
  O: THttpOutcome;
begin
  GFakeNowUs := T0;
  SetNowUsHook(FakeNow);
  Start(ScriptFragmentStamp, [mkWsText]);
  Sock := Open;
  AssertTrue('first fragment sent', FSeen.WaitFor(5000) = wrSignaled);
  // the first fragment arrived at T0; the message completes 300 us later
  GFakeNowUs := T0 + 300;
  FGo.SetEvent;
  AssertTrue('message', FObs.WaitMessages(1, 5000));
  AssertEquals('one message for two fragments', 1, FObs.MessageCount);
  AssertEquals('stamp of the final frame', 300, FObs.MessageAt(0).ArrivedUs);
  AssertEquals('size is the whole message', 4, FObs.MessageAt(0).Size);
  Sock.Abort;
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0).O;
  AssertEquals('counted once', 1, O.MessagesIn);
  AssertEquals(4, O.BytesIn);
end;

{ 21.9 }

procedure TWsObservabilityLifecycleTest.TestOptedInObserverSeesEveryKindInOrder;
var
  Sock: IWebSocket;
  I, N: Integer;
  Prev: Int64;
  M: TMessageInfo;
  O: THttpOutcome;
begin
  Start(ScriptKinds, [mkWsText, mkWsBinary, mkWsPing, mkWsPong, mkWsClose]);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.SendText('hi');
  Sock.SendBinary(BytesOf('abc'));
  AssertTrue('ended', Ended);
  AssertEquals('what arrived, in wire order', 'text,binary,ping,pong,close',
    KindsOf(mdIn));
  // outbound: the two data messages, the automatic pong and the echoed close
  AssertTrue('data out in order',
    (Pos('text', KindsOf(mdOut)) > 0) and
    (Pos('text', KindsOf(mdOut)) < Pos('binary', KindsOf(mdOut))));
  AssertTrue('the pong for the ping', Pos('pong', KindsOf(mdOut)) > 0);
  AssertTrue('the echoed close ends the outbound side',
    Copy(KindsOf(mdOut), Length(KindsOf(mdOut)) - 4, 5) = 'close');
  // per direction: index counts every kind, sizes are payload bytes
  N := 0;
  Prev := -1;
  for I := 0 to FObs.MessageCount - 1 do
  begin
    M := FObs.MessageAt(I);
    if M.Direction <> mdIn then
      Continue;
    AssertEquals('inbound index ' + IntToStr(N), N, M.Index);
    if N = 0 then
      AssertEquals('first inbound has no predecessor', 0, M.SinceLastUs)
    else
      AssertTrue('stamps never go backwards', M.ArrivedUs >= Prev);
    Prev := M.ArrivedUs;
    case N of
      0: AssertEquals('text size', 3, M.Size);
      1: AssertEquals('binary size', 2, M.Size);
      2: AssertEquals('ping size', 1, M.Size);
      3: AssertEquals('pong size', 1, M.Size);
      4: AssertEquals('close size: code and reason', 5, M.Size);
    end;
    Inc(N);
  end;
  AssertEquals('five inbound messages', 5, N);
  O := FObs.Outcome(0).O;
  AssertEquals('ping, pong and close are not data messages', 2, O.MessagesIn);
  AssertEquals('two data messages out', 2, O.MessagesOut);
  AssertTrue('remote close', O.ClosedBy = ciRemote);
end;

procedure TWsObservabilityLifecycleTest.TestEmptySetAndOtherKindsSeeNothing;
var
  Sock: IWebSocket;
  O: THttpOutcome;
  I: Integer;
begin
  // an observer that wants nothing sees no message, but the aggregates stand
  Start(ScriptKinds, []);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.SendText('hi');
  Sock.SendBinary(BytesOf('abc'));
  AssertTrue('ended', Ended);
  AssertEquals('no OnMessage with an empty set', 0, FObs.MessageCount);
  O := FObs.Outcome(0).O;
  AssertEquals('aggregates in', 2, O.MessagesIn);
  AssertEquals('aggregates out', 2, O.MessagesOut);
  StopServer;
  FRec.Socket := nil;
  FObsRef := nil;
  FObs := nil;
  FClient := nil;
  // an observer that wants text only is not called for the other kinds
  Start(ScriptKinds, [mkWsText]);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.SendText('hi');
  Sock.SendBinary(BytesOf('abc'));
  AssertTrue('ended', Ended);
  AssertEquals('text in and text out only', 'text', KindsOf(mdIn));
  AssertEquals('text out', 'text', KindsOf(mdOut));
  AssertEquals('two messages', 2, FObs.MessageCount);
  // the two reports come from two threads (the reader and the sender), so
  // their order in the record is not fixed: look each up by direction.  The
  // automatic pong for the server's ping is outbound too, and takes index 0
  // when it is written before the text is, so the text is 0 or 1 and the
  // inbound text, the server's first message, is always 0
  AssertTrue('one in and one out',
    FObs.MessageAt(0).Direction <> FObs.MessageAt(1).Direction);
  for I := 0 to 1 do
    if FObs.MessageAt(I).Direction = mdIn then
      AssertEquals('inbound text is the first inbound message', 0,
        FObs.MessageAt(I).Index)
    else
      AssertTrue('outbound text comes first or just after the pong',
        FObs.MessageAt(I).Index in [0, 1]);
end;

{ 21.11 }

procedure TWsObservabilityLifecycleTest.TestStampsIncludeTheConsumersWaitWithoutDemand;
const
  T0 = 3000000;
var
  Sock: IWebSocket;
begin
  GFakeNowUs := T0;
  SetNowUsHook(FakeNow);
  Start(ScriptPingThenText, [mkWsPing, mkWsText]);
  // no WithAutoRequest and no Request(n): the reader reads the ping, answers
  // it, and parks until the consumer asks for the notification
  Sock := Open(TWebSocketRequest.Create(Url, FRecRef));
  AssertTrue('the server saw the pong', FSeen.WaitFor(5000) = wrSignaled);
  AssertTrue('the ping was reported at the wire', FObs.WaitMessages(1, 5000));
  AssertEquals('the text has not been read yet', 1, FObs.MessageCount);
  // the text is already on the socket, but the reader will not read it until
  // the consumer has made demand, and the consumer is slow
  GFakeNowUs := T0 + 500;
  Sock.Request(2);
  AssertTrue('the text', FObs.WaitMessages(2, 5000));
  AssertEquals('kinds in order', 'ping,text', KindsOf(mdIn));
  AssertEquals('the text carries the consumer''s wait', 500,
    FObs.MessageAt(1).SinceLastUs);
  Sock.Abort;
end;

procedure TWsObservabilityLifecycleTest.TestAutoRequestKeepsTheConsumersWaitOutOfTheStamps;
const
  T0 = 4000000;
var
  Sock: IWebSocket;
begin
  GFakeNowUs := T0;
  SetNowUsHook(FakeNow);
  Start(ScriptPingThenText, [mkWsPing, mkWsText]);
  Sock := Open;                      // WithAutoRequest
  AssertTrue('the server saw the pong', FSeen.WaitFor(5000) = wrSignaled);
  // the reader keeps reading: the text is stamped when it arrives, so the
  // slow consumer (the clock moving afterwards) changes nothing
  AssertTrue('ping and text reported', FObs.WaitMessages(2, 5000));
  GFakeNowUs := T0 + 500;
  AssertEquals('kinds in order', 'ping,text', KindsOf(mdIn));
  AssertEquals('no gap between the two arrivals', 0,
    FObs.MessageAt(1).SinceLastUs);
  Sock.Abort;
end;

{ 21.12 }

procedure TWsObservabilityLifecycleTest.TestRaisingObserverNeverBreaksTheSession;
var
  Sock: IWebSocket;
begin
  Start(ScriptEchoClose, [mkWsText, mkWsClose]);
  FObs.RaiseOn := 'OnResponseHeaders,OnAttemptEnd';
  FObs.RaiseOnMessage := True;
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.SendText('echo me');
  AssertTrue('the echo reaches the listener', FRec.WaitCount(2));
  AssertEquals('text:echo me:1', FRec.Item(1));
  Sock.Close(1000, 'ok');
  AssertTrue('the listener still gets the close', FRec.WaitCount(3));
  AssertEquals('close:1000:ok', FRec.Item(2));
  AssertTrue('and the attempt ends', Ended);
  AssertEquals('once', 1, FObs.EndCount);
  AssertTrue('local', FObs.Outcome(0).O.ClosedBy = ciLocal);
end;

initialization
  RegisterTest(TWsObservabilityLifecycleTest);
end.
