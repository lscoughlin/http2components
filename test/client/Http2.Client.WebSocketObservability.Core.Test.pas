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
unit Http2.Client.WebSocketObservability.Core.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Common.Headers, Http2.Client.Messages, Http2.Client.Http1,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames,
  Http2.Client.RequestObserver.Support, Http2.Client.WebSocketClient.Support, Http2.Client.WebSocketObservability.Support;
type
  TWsRequestContextTest = class(TTestCase)
  published
    procedure TestContextIsReturnedAndTheOriginalIsUnchanged;
    procedure TestContextSurvivesTheOtherWithMethods;
  end;

  TWsObservabilityCoreTest = class(TWsObservabilityTestBase)
  published
    procedure TestInjectedHeaderReachesTheHandshakeAndReplacesTheCallers;
    procedure TestTheSinkRefusesTheNamesTheHandshakeOwns;
    procedure TestAttemptStartsBeforeTheHandshakeIsWritten;
    procedure TestAcceptReportsTheHeadersTheSubprotocolAndAnUnpooledSession;
    procedure TestRefusedHandshakeEndsWithTheStatusAndTheError;
    procedure TestFailedDialPairsStartWithOneEnd;
    procedure TestLocalCloseEndsOnceWithTheServersCode;
    procedure TestRemoteCloseEndsOnceEvenWithNoDemand;
    procedure TestAbortEndsOnceAsAbort;
    procedure TestDroppedConnectionEndsAsAnError;
    procedure TestProtocolErrorReportsTheCodeItClosedWith;
    procedure TestCloseWithoutAnswerEndsAsATimeout;
    procedure TestRaisingListenerEndsOnceWithItsException;
  end;

implementation

procedure TWsRequestContextTest.TestContextIsReturnedAndTheOriginalIsUnchanged;
var
  L: IWebSocketListener;
  R, R2: IWebSocketRequest;
  Tag: IInterface;
begin
  L := TWebSocketListener.Create;
  R := TWebSocketRequest.Create('ws://127.0.0.1:1/', L);
  AssertTrue('no context by default', R.Context = nil);
  Tag := TTag.Create;
  R2 := R.WithContext(Tag);
  AssertTrue('the new request carries it', R2.Context = Tag);
  AssertTrue('GetContext agrees', R2.GetContext = Tag);
  AssertTrue('the original is unchanged', R.Context = nil);
  AssertTrue('nil clears it', R2.WithContext(nil).Context = nil);
  AssertTrue('and leaves R2 alone', R2.Context = Tag);
end;

procedure TWsRequestContextTest.TestContextSurvivesTheOtherWithMethods;
var
  L: IWebSocketListener;
  R: IWebSocketRequest;
  Tag: IInterface;
begin
  L := TWebSocketListener.Create;
  Tag := TTag.Create;
  R := TWebSocketRequest.Create('ws://127.0.0.1:1/', L).WithContext(Tag)
    .WithHeader('x-a', '1').WithSubprotocol('chat').WithAutoRequest
    .WithPingIntervalMs(1000).WithCloseTimeoutMs(10).WithMaxMessageBytes(10)
    .WithConnectTimeoutMs(10);
  AssertTrue('context kept through every copy', R.Context = Tag);
  AssertEquals('headers kept', 1, Length(R.Headers));
end;

{ TWsObservabilityTest }

procedure TWsObservabilityCoreTest.
  TestInjectedHeaderReachesTheHandshakeAndReplacesTheCallers;
var
  Sock: IWebSocket;
  Lines: TStringList;
  I, Seen: Integer;
  Original: IWebSocketRequest;
begin
  Start(ScriptHold, []);
  FObs.InjectName := 'traceparent';
  FObs.InjectPrefix := 'injected';
  Original := Req.WithHeader('traceparent', 'from-the-caller')
    .WithHeader('x-keep', 'yes');
  Sock := Open(Original);
  AssertTrue('open', FRec.WaitCount(1));
  Lines := TStringList.Create;
  try
    Lines.Text := FServer.Head;
    Seen := 0;
    for I := 0 to Lines.Count - 1 do
      if SameText(Copy(Lines[I], 1, 12), 'traceparent:') then
        Inc(Seen);
  finally
    Lines.Free;
  end;
  AssertEquals('exactly one traceparent line', 1, Seen);
  AssertEquals('the injected value won', 'injected-1',
    FServer.HeaderValue('traceparent'));
  AssertEquals('the caller header stays', 'yes', FServer.HeaderValue('x-keep'));
  AssertEquals('the observer saw the caller value first', 'from-the-caller',
    FObs.SeenBefore[0]);
  AssertEquals('the caller request is untouched', 2, Length(Original.Headers));
  AssertEquals('from-the-caller', Original.Headers[0].Value);
  Sock.Abort;
end;

procedure TWsObservabilityCoreTest.TestTheSinkRefusesTheNamesTheHandshakeOwns;
var
  Sock: IWebSocket;
begin
  Start(ScriptHold, []);
  FObs.TryNames.CommaText := 'Upgrade,connection,Host,Sec-WebSocket-Key,' +
    'sec-websocket-protocol,Sec-WebSocket-Version,Content-Length';
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  AssertEquals('every name was tried', 7, FObs.Rejected.Count);
  AssertEquals('upgrade', 'EHttpWebSocketError', FObs.Rejected[0]);
  AssertEquals('connection', 'EHttpWebSocketError', FObs.Rejected[1]);
  AssertEquals('host', 'EHttpWebSocketError', FObs.Rejected[2]);
  AssertEquals('sec-websocket-key', 'EHttpWebSocketError', FObs.Rejected[3]);
  AssertEquals('sec-websocket-protocol', 'EHttpWebSocketError',
    FObs.Rejected[4]);
  AssertEquals('sec-websocket-version', 'EHttpWebSocketError',
    FObs.Rejected[5]);
  AssertEquals('content-length', 'EHttpWebSocketError', FObs.Rejected[6]);
  AssertEquals('the handshake still has its own upgrade', 'websocket',
    FServer.HeaderValue('Upgrade'));
  AssertEquals('and its own host', '127.0.0.1:' + IntToStr(FServer.Port),
    FServer.HeaderValue('Host'));
  Sock.Abort;
end;

{ 21.3 }

procedure TWsObservabilityCoreTest.TestAttemptStartsBeforeTheHandshakeIsWritten;
var
  Sock: IWebSocket;
  A: THttpAttempt;
  Ctx: IInterface;
begin
  Start(ScriptHeadCheck, []);
  Ctx := TTag.Create;
  Sock := Open(Req.WithContext(Ctx));
  AssertTrue('open', FRec.WaitCount(1));
  AssertTrue('the start ran before the server read the head',
    FStartedBeforeHead);
  AssertEquals('one start', 1, FObs.StartCount);
  A := FObs.Attempt(0);
  AssertTrue('kind', A.Kind = akWebSocket);
  AssertEquals('method', 'GET', A.Method);
  AssertEquals('url', Url, A.Url);
  AssertEquals('host', '127.0.0.1', A.Host);
  AssertEquals('port', Integer(FServer.Port), Integer(A.Port));
  AssertEquals('hop', 0, A.Hop);
  AssertEquals('retry', 0, A.Retry);
  AssertTrue('context', A.Context = Ctx);
  AssertTrue('a header sink', A.Headers <> nil);
  Sock.Abort;
end;

{ 21.4, 21.10 }

procedure TWsObservabilityCoreTest.
  TestAcceptReportsTheHeadersTheSubprotocolAndAnUnpooledSession;
var
  Sock: IWebSocket;
  O: THttpOutcome;
begin
  Start(ScriptHoldSubprotocol, []);
  Sock := Open(Req.WithSubprotocol('chat'));
  AssertTrue('open', FRec.WaitCount(1));
  AssertEquals('headers reported once', 1, FObs.SeenHeaders);
  AssertEquals('at the 101', 101, FObs.SeenStatus);
  AssertEquals('with the subprotocol known', 'chat', FObs.SeenSubprotocol);
  AssertEquals('not ended yet', 0, FObs.EndCount);
  Sock.Abort;
  AssertTrue('ended', Ended);
  AssertEquals('order', 'S0 H0 E0', Flow);
  O := FObs.Outcome(0).O;
  AssertEquals('status', 101, O.StatusCode);
  AssertEquals('subprotocol', 'chat', O.Subprotocol);
  AssertTrue('HTTP/1.1', O.Protocol = npHttp1Cleartext);
  AssertFalse('never a pooled connection', O.ConnectionReused);
  AssertTrue('headers came after the request was sent',
    (O.RequestSentUs > 0) and (O.HeadersUs >= O.RequestSentUs));
  AssertTrue('the session outlasts the handshake', O.EndUs >= O.HeadersUs);
end;

procedure TWsObservabilityCoreTest.TestRefusedHandshakeEndsWithTheStatusAndTheError;
var
  Raised: string;
  O: TRecordedOutcome;
begin
  Start(ScriptRefuse403, []);
  Raised := '';
  try
    Open;
    Fail('a refused handshake must raise');
  except
    on E: EHttpWebSocketHandshakeError do
      Raised := E.ClassName;
  end;
  AssertEquals('EHttpWebSocketHandshakeError', Raised);
  AssertTrue('ended', Ended);
  AssertEquals('one start, one end, no headers callback', 'S0 E0', Flow);
  O := FObs.Outcome(0);
  AssertEquals('status of the refusal', 403, O.O.StatusCode);
  AssertEquals('error class', 'EHttpWebSocketHandshakeError', O.ErrorClass);
  AssertTrue('closed by error', O.O.ClosedBy = ciError);
  AssertFalse('not abandoned', O.O.Abandoned);
  AssertEquals('no session', 0, O.O.MessagesIn);
end;

procedure TWsObservabilityCoreTest.TestFailedDialPairsStartWithOneEnd;
var
  Raised: Boolean;
  O: TRecordedOutcome;
  Closed: IWebSocketRequest;
begin
  // a loopback port with no listener: the server object is shut down first
  Start(ScriptHold, []);
  Closed := TWebSocketRequest.Create(Url, FRecRef);
  StopServer;
  Raised := False;
  try
    FClient.Send(Closed);
  except
    on Exception do
      Raised := True;
  end;
  AssertTrue('the dial failed', Raised);
  AssertTrue('ended', Ended);
  AssertEquals('S0 E0', Flow);
  O := FObs.Outcome(0);
  AssertEquals('no status', 0, O.O.StatusCode);
  AssertTrue('an error', O.ErrorClass <> '');
  AssertTrue('closed by error', O.O.ClosedBy = ciError);
end;

{ 21.5, 21.6 }

procedure TWsObservabilityCoreTest.TestLocalCloseEndsOnceWithTheServersCode;
var
  Sock: IWebSocket;
  O: THttpOutcome;
begin
  Start(ScriptEchoClose, []);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.Close(1000, 'bye');
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0).O;
  AssertTrue('local', O.ClosedBy = ciLocal);
  AssertEquals('code', 1000, O.CloseCode);
  AssertEquals('reason', 'bye', O.CloseReason);
  AssertFalse('deliberate, not abandoned', O.Abandoned);
  AssertTrue('no error', FObs.Outcome(0).ErrorClass = '');
  Sock.Abort;                        // after the end: nothing more
  AssertEquals('exactly one end', 1, FObs.EndCount);
end;

procedure TWsObservabilityCoreTest.TestRemoteCloseEndsOnceEvenWithNoDemand;
var
  O: THttpOutcome;
begin
  Start(ScriptRemoteClose, []);
  // no demand: OnClose is never delivered, the attempt still ends
  Open(TWebSocketRequest.Create(Url, FRecRef));
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0).O;
  AssertTrue('remote', O.ClosedBy = ciRemote);
  AssertEquals('code', 1001, O.CloseCode);
  AssertEquals('reason', 'going', O.CloseReason);
  AssertFalse('not abandoned', O.Abandoned);
  AssertEquals('exactly one end', 1, FObs.EndCount);
end;

procedure TWsObservabilityCoreTest.TestAbortEndsOnceAsAbort;
var
  Sock: IWebSocket;
  O: THttpOutcome;
begin
  Start(ScriptHold, []);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.Abort;
  AssertTrue('ended', Ended);
  Sock.Abort;
  O := FObs.Outcome(0).O;
  AssertTrue('abort', O.ClosedBy = ciAbort);
  AssertEquals('abnormal', cWsCloseAbnormal, O.CloseCode);
  AssertEquals('no reason', '', O.CloseReason);
  AssertFalse('a deliberate end', O.Abandoned);
  AssertEquals('exactly one end', 1, FObs.EndCount);
end;

procedure TWsObservabilityCoreTest.TestDroppedConnectionEndsAsAnError;
var
  O: TRecordedOutcome;
begin
  Start(ScriptDrop, []);
  Open;
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0);
  AssertTrue('error', O.O.ClosedBy = ciError);
  AssertEquals('EHttpConnectionError', O.ErrorClass);
  AssertEquals('abnormal', cWsCloseAbnormal, O.O.CloseCode);
  AssertFalse('not abandoned', O.O.Abandoned);
  AssertEquals('exactly one end', 1, FObs.EndCount);
end;

procedure TWsObservabilityCoreTest.TestProtocolErrorReportsTheCodeItClosedWith;
var
  O: TRecordedOutcome;
begin
  Start(ScriptBadUtf8, []);
  Open;
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0);
  AssertTrue('error', O.O.ClosedBy = ciError);
  AssertEquals('EHttpWebSocketProtocolError', O.ErrorClass);
  AssertEquals('the 1007 it closed with', cWsCloseBadData, O.O.CloseCode);
end;

procedure TWsObservabilityCoreTest.TestCloseWithoutAnswerEndsAsATimeout;
var
  Sock: IWebSocket;
  O: TRecordedOutcome;
begin
  Start(ScriptNoReply, []);
  Sock := Open(Req.WithCloseTimeoutMs(200));
  AssertTrue('open', FRec.WaitCount(1));
  Sock.Close(1000, 'x');
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0);
  AssertTrue('error', O.O.ClosedBy = ciError);
  AssertEquals('EHttpTimeout', O.ErrorClass);
  AssertEquals('abnormal', cWsCloseAbnormal, O.O.CloseCode);
  AssertEquals('exactly one end', 1, FObs.EndCount);
end;

procedure TWsObservabilityCoreTest.TestRaisingListenerEndsOnceWithItsException;
var
  O: TRecordedOutcome;
begin
  Start(ScriptOneText, []);
  FRecRef := TRaisingListener.Create;
  Open;
  AssertTrue('ended', Ended);
  O := FObs.Outcome(0);
  AssertTrue('error, not abort', O.O.ClosedBy = ciError);
  AssertEquals('the listener exception', 'EListError', O.ErrorClass);
  AssertEquals('the message', 'the listener failed', O.ErrorMessage);
  AssertEquals('exactly one end', 1, FObs.EndCount);
end;

initialization
  RegisterTest(TWsRequestContextTest);
  RegisterTest(TWsObservabilityCoreTest);
end.
