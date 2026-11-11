{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Server-Sent Events tests (plan story S14).
// - the parser tests are pure: no socket, no transport. The single most
//   important assertion is chunk-split invariance — the same byte stream fed
//   at EVERY offset must produce the same events (doc/design/
//   server-sent-events.md "Testing"). A parser that only works when a chunk
//   boundary happens to fall on a line break is the classic SSE defect.
// - the transport tests run against the real connection thread over a
//   TMockSocket, so credit flushing and frame routing are genuine; the
//   reconnect tests use a scripted IHttpClient and no transport at all.
unit Http2.Client.Sse.Reconnect.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.WebSocket,
  Http2.Client.Sse, Http2.Client.MockSocket, Http2.Client.RequestObserver, Http2.Client.Sse.Support;
type
  TSseReconnectTest = class(TTestCase)
  published
    procedure TestReconnectEchoesLastEventId;
    procedure TestReconnectDropsTheReplayedEvent;
    procedure TestRetryBoundRaises;
    procedure TestZeroBoundReconnectsForever;
    procedure TestProtocolErrorIsTerminal;
    procedure TestTransientFailureReconnects;
    procedure TestFirstConnectFailureIsReported;
    procedure TestHonoursServerRetry;
  end;

  TSseTransportTest = class(TTestCase)
  private
    function MakeLease(const AConn: TConnection;
      const ARequest: TStreamRequest; out AAlloc: TStreamIdAllocator;
      out ALease: TStreamLease; out AIL: IConnectionStream): Boolean;
  published
    // an idle event stream must NOT inherit the 30s header timeout
    procedure TestIdleBodyReadWaitsIndefinitely;
    // an explicit body-read deadline still fires (opt-in liveness)
    procedure TestExplicitBodyReadTimeoutRaises;
    // a blocked body read unblocks on Cancel and resets the stream
    procedure TestBlockedBodyReadCancelsWithRst;
    // flow control: a long-lived stream's data is credited back
    procedure TestSseStreamReturnsWindowCredit;
  end;

  /// remembers how the one attempt it observes ended

  TSseLiveTest = class(TTestCase)
  published
    procedure TestLiveStreamDeliversEventsAndResumes;
    procedure TestLiveEventGapsMatchTheServerInterval;
  end;

implementation

procedure TSseReconnectTest.TestReconnectEchoesLastEventId;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  First, Second: THttpRequest;
begin
  C := TScriptedClient.Create;
  C.AddBody(FastBody('id: 5' + #10 + 'data: a' + #10 + #10));
  C.AddBody(FastBody('data: b' + #10 + #10));
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('first event', Loop.Next(E));
    AssertEquals('the first payload', 'a', E.Data);
    AssertTrue('the event after the reconnect', Loop.Next(E));
    AssertEquals('the second payload', 'b', E.Data);
    AssertEquals('a second request was issued', 2, C.RequestCount);
    First := C.RequestAt(0);
    Second := C.RequestAt(1);
    AssertEquals('the first request carries no last-event-id', '',
      First.Headers.GetFirst(HeaderLastEventId));
    AssertEquals('the reconnect echoes last-event-id', '5',
      Second.Headers.GetFirst(HeaderLastEventId));
    AssertEquals('one reconnect was counted', 1, Loop.Reconnects);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestReconnectDropsTheReplayedEvent;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
begin
  C := TScriptedClient.Create;
  // the server resumes unhelpfully and replays the same id
  C.AddBody(FastBody('id: 1' + #10 + 'data: first' + #10 + #10));
  C.AddBody(FastBody('id: 1' + #10 + 'data: first' + #10 + #10 +
    'id: 2' + #10 + 'data: second' + #10 + #10));
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('first event', Loop.Next(E));
    AssertEquals('the payload', 'first', E.Data);
    AssertTrue('the next distinct event', Loop.Next(E));
    AssertEquals('the replayed event was dropped', 'second', E.Data);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestRetryBoundRaises;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  Raised: Boolean;
  I: Integer;
begin
  C := TScriptedClient.Create;
  for I := 0 to 9 do
    C.AddBody(FastBody('data: x' + #10 + #10));
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 2);
  try
    AssertTrue('first event', Loop.Next(E));
    AssertTrue('event after the first reconnect', Loop.Next(E));
    AssertTrue('event after the second reconnect', Loop.Next(E));
    Raised := False;
    try
      Loop.Next(E);           // the third reconnect is over the bound
    except
      on Ex: EHttpTooManySseRetries do Raised := True;
    end;
    AssertTrue('the retry bound raises EHttpTooManySseRetries', Raised);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestZeroBoundReconnectsForever;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  I: Integer;
begin
  C := TScriptedClient.Create;
  for I := 0 to 5 do
    C.AddBody(FastBody('data: x' + #10 + #10));
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 0);
  try
    for I := 0 to 4 do
      AssertTrue('event ' + IntToStr(I), Loop.Next(E));
    AssertTrue('a zero bound keeps going', Loop.Next(E));
    AssertTrue('more reconnects than any finite bound would allow',
      Loop.Reconnects > 3);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestProtocolErrorIsTerminal;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  Raised: Boolean;
begin
  C := TScriptedClient.Create;
  C.AddBody(FastBody('data: x' + #10 + #10));
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('first event', Loop.Next(E));
    C.RejectResponse;      // the peer now answers with the wrong content type
    Raised := False;
    try
      Loop.Next(E);
    except
      on Ex: EHttpProtocolError do Raised := True;
    end;
    AssertTrue('a protocol error propagates and does not reconnect', Raised);
    AssertEquals('no further request was made', 2, C.RequestCount);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestTransientFailureReconnects;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
begin
  C := TScriptedClient.Create;
  C.AddBody(FastBody('data: a' + #10 + #10));
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('first event', Loop.Next(E));
    // one reconnect fails at the transport, the next succeeds: the loop must
    // retry rather than give up, and must still deliver the next event
    C.FailNextRequests(1);
    C.AddBody(FastBody('data: b' + #10 + #10));
    AssertTrue('an event arrives after the transient failure', Loop.Next(E));
    AssertEquals('and it is the recovered event', 'b', E.Data);
    AssertTrue('the session was re-established', Loop.Reconnects >= 2);
    AssertEquals('the failed attempt was counted too', 3, C.RequestCount);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestFirstConnectFailureIsReported;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  Raised: Boolean;
begin
  C := TScriptedClient.Create;
  C.RefuseConnection;
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    Raised := False;
    try
      Loop.Next(E);
    except
      on Ex: EHttpError do Raised := True;
    end;
    AssertTrue('a failing FIRST connection is reported to the caller',
      Raised);
    AssertEquals('exactly one attempt was made', 1, C.RequestCount);
    AssertEquals('and it is not counted as a reconnect', 0, Loop.Reconnects);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseReconnectTest.TestHonoursServerRetry;
var
  C: TScriptedClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  T0: QWord;
  Elapsed: Int64;
begin
  C := TScriptedClient.Create;
  C.AddBody('retry: 150' + #10 + 'data: a' + #10 + #10);
  C.AddBody('data: b' + #10 + #10);
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('first event', Loop.Next(E));
    AssertEquals('the server retry is adopted', 150, Loop.RetryMs);
    T0 := GetTickCount64;
    AssertTrue('event after the reconnect', Loop.Next(E));
    Elapsed := Int64(GetTickCount64 - T0);
    AssertTrue('the loop waited about the server delay, not the default',
      Elapsed >= 120);
    AssertTrue('and not the 3000 ms default', Elapsed < cSseDefaultRetryMs);
  finally
    Loop.Free;
    C.Free;
  end;
end;

{ TSseRequestTest }

function TSseTransportTest.MakeLease(const AConn: TConnection;
  const ARequest: TStreamRequest; out AAlloc: TStreamIdAllocator;
  out ALease: TStreamLease; out AIL: IConnectionStream): Boolean;
begin
  AAlloc := TStreamIdAllocator.Create;
  ALease := TStreamLease.Create(AConn, AAlloc, ARequest);
  AIL := ALease;
  AConn.ApplyPeerSettingsValue(AConn.PeerSettings);
  Result := True;
end;

procedure TSseTransportTest.TestIdleBodyReadWaitsIndefinitely;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Driver: TSseReadDriver;
begin
  // This is the central SSE transport defect: the body read inherited the
  // 30 s header timeout, so a quiet-but-alive stream died. A request that
  // sets its OWN deadline of 0 must not see a timeout at all.
  // Non-vacuous: the pre-fix code raised EHttpTimeout after Lease.TimeoutMs,
  // so the "still blocked" assertion below fails if the deadline returns.
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Req := TStreamRequest.WithMethod(hmGet, 'api.example')
      .WithBodyReadTimeout(0);
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Sock.FeedFrame(ResponseHeadersFor(Enc, '200', Lease.StreamId,
          False));
      finally
        Enc.Free;
      end;
      AssertTrue('headers arrived', Lease.WaitForResponseHeader(2000));
      Lease.TimeoutMs := 60;          // the legacy deadline
      Driver := TSseReadDriver.Create(Lease);
      try
        Driver.Start;
        AssertFalse('the read is still parked well past the legacy deadline',
          Driver.WaitDone(400));
        Sock.FeedFrame(DataFrameOf(Lease.StreamId, 'x', True));
        AssertTrue('the read completes once data arrives',
          Driver.WaitDone(2000));
        AssertFalse('and it did not fail', Driver.Raised);
        AssertEquals('one byte was read', 1, Driver.Bytes);
      finally
        Driver.WaitFor;
        Driver.Free;
      end;
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TSseTransportTest.TestExplicitBodyReadTimeoutRaises;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Buf: array[0..7] of Byte;
  Raised: Boolean;
begin
  // liveness is still available when asked for: an explicit body deadline
  // fires even though the legacy timeout would not
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Req := TStreamRequest.WithMethod(hmGet, 'api.example')
      .WithBodyReadTimeout(80);
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Sock.FeedFrame(ResponseHeadersFor(Enc, '200', Lease.StreamId,
          False));
      finally
        Enc.Free;
      end;
      AssertTrue('headers arrived', Lease.WaitForResponseHeader(2000));
      Raised := False;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpTimeout do Raised := True;
      end;
      AssertTrue('an explicit body deadline raises EHttpTimeout', Raised);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TSseTransportTest.TestBlockedBodyReadCancelsWithRst;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Driver: TSseCancelDriver;
  Token: TCancellationToken;
  Buf: array[0..7] of Byte;
  IsCancel: Boolean;
  IsTimeout: Boolean;
  Frames: TArray<TFrame>;
  I, J: Integer;
  SawRst: Boolean;
  RstCode: LongWord;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Token := TCancellationToken.Create;
    // indefinite body read: only the token can end it
    Req := TStreamRequest.WithMethod(hmGet, 'api.example')
      .WithBodyReadTimeout(0)
      .WithCancelToken(Token);
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Sock.FeedFrame(ResponseHeadersFor(Enc, '200', Lease.StreamId,
          False));
      finally
        Enc.Free;
      end;
      AssertTrue('headers arrived', Lease.WaitForResponseHeader(2000));
      Driver := TSseCancelDriver.Create(Token, 120);
      try
        Driver.Start;
        IsCancel := False;
        IsTimeout := False;
        try
          Lease.ReadBody(Buf, SizeOf(Buf));
        except
          on E: EHttpStreamError do
            IsCancel := E.ErrorCode = ecCancel;
          on E: EHttpTimeout do IsTimeout := True;
        end;
      finally
        Driver.WaitFor;
        Driver.Free;
      end;
      AssertFalse('a cancel is not reported as a timeout', IsTimeout);
      AssertTrue('the cancel surfaces as EHttpStreamError(ecCancel)',
        IsCancel);
      // the stream must be reset, not orphaned
      SawRst := False;
      RstCode := 0;
      for J := 1 to 40 do
      begin
        Frames := Sock.OutboundFrames;
        for I := 0 to High(Frames) do
          if Frames[I].Header.FrameType = ftRstStream then
          begin
            SawRst := True;
            if Length(Frames[I].Payload) >= 4 then
              RstCode := U32BE(Frames[I].Payload, 0);
          end;
        if SawRst then
          Break;
        Sleep(25);
      end;
      AssertTrue('the cancelled read resets the stream', SawRst);
      AssertEquals('with CANCEL', Ord(ecCancel), RstCode);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TSseTransportTest.TestSseStreamReturnsWindowCredit;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  S: IHttpSseSource;
  Resp: IHttpResponse;
  E: TSseEvent;
  Frames: TArray<TFrame>;
  I, J, F: Integer;
  WindowUpdates: Integer;
  Payload: string;
  Last: Boolean;
begin
  // a long-lived stream must keep the peer's send window open: the DATA it
  // consumes has to come back as WINDOW_UPDATE, or the server stalls forever.
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Req := TStreamRequest.WithMethod(hmGet, 'api.example')
      .WithBodyReadTimeout(0);
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Sock.FeedFrame(ResponseHeadersFor(Enc, '200', Lease.StreamId,
          False));
      finally
        Enc.Free;
      end;
      AssertTrue('headers arrived', Lease.WaitForResponseHeader(2000));
      // 40 KiB of events in ten 4 KiB DATA frames, well past the 32768-byte
      // credit batch, each frame inside the default 16384-byte frame limit
      for F := 0 to 9 do
      begin
        Payload := '';
        for I := 1 to 130 do
          Payload := Payload + 'data: ' + StringOfChar('x', 25) + #10 + #10;
        // trim to a whole number of events within the frame budget
        Last := F = 9;
        Sock.FeedFrame(DataFrameOf(Lease.StreamId, Payload, Last));
      end;
      Resp := TStubResponse.Create(200,
        NewHeaders([HeaderContentType, cSseContentType]), Lease.Body);
      S := TSseSource.Create(Resp);
      try
        AssertTrue('an event arrived', S.ReadEvent(E));
        AssertTrue('and another', S.ReadEvent(E));
      finally
        S.Close;
      end;
      WindowUpdates := 0;
      for J := 1 to 60 do
      begin
        Frames := Sock.OutboundFrames;
        WindowUpdates := 0;
        for I := 0 to High(Frames) do
          if Frames[I].Header.FrameType = ftWindowUpdate then
            Inc(WindowUpdates);
        if WindowUpdates > 0 then
          Break;
        Sleep(25);
      end;
      AssertTrue('a long-lived stream returns WINDOW_UPDATE credit',
        WindowUpdates > 0);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

{ TOutcomeObserver }

procedure TSseLiveTest.TestLiveStreamDeliversEventsAndResumes;
var
  Url: string;
  F: THttpClientFactory;
  Client: IHttpClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  Seen: TStringList;
  Limit: Integer;
begin
  // opt-in: point SSE_TEST_URL at tools/validate/sse_server.py; the default
  // suite stays hermetic. The scripted stream ends after id 3 and answers a
  // resumed request (last-event-id: 3) with a single id 4 event, so the test
  // proves delivery, reconnect, resume, and retry: adoption in one run.
  Url := GetEnvironmentVariable('SSE_TEST_URL');
  if Url = '' then
    Exit;

  F := THttpClientFactory.Create
    .WithMaxConnectionsPerHost(1)
    .WithMaxTotalConnections(2)
    .WithMaxStreamsPerConnection(100);
  // the reference server is cleartext on localhost; h2c upgrade is the
  // supported cleartext mode (prior knowledge needs a server that speaks it)
  if Pos('http://', LowerCase(Url)) = 1 then
    F := F.WithClearText(ctUpgrade).WithHttp1Fallback(True);
  Client := F.Build;

  Seen := TStringList.Create;
  try
    Loop := TSseReconnectLoop.Create(Client, SseRequest(Url), 3);
    try
      Limit := 0;
      while Limit < 12 do
      begin
        try
          if not Loop.Next(E) then
            Break;
        except
          // reaching the reconnect bound is a normal terminal state for this
          // scripted server (it closes the stream after id 3), not a failure
          on E2: EHttpTooManySseRetries do
            Break;
        end;
        Inc(Limit);
        Seen.Add(E.Id + '=' + E.EventType + ':' + E.Data);
      end;
      AssertTrue('the live stream delivered events', Seen.Count > 0);
      AssertTrue('the multi-line greeting arrived',
        Seen.IndexOf('=greeting:hello'#10'world') >= 0);
      AssertTrue('the id 1 event arrived',
        Seen.IndexOf('1=message:first') >= 0);
      AssertTrue('the UTF-8 event arrived',
        Seen.IndexOf('2=message:café — naïve') >= 0);
      AssertTrue('the id 3 event arrived',
        Seen.IndexOf('3=message:last') >= 0);
      // resume: the reconnect echoed last-event-id: 3 and the scripted server
      // answered with only the id 4 event, which a stale resume could not get
      AssertTrue('the reconnect resumed past the last id',
        Seen.IndexOf('4=message:after-resume') >= 0);
      AssertTrue('a reconnect actually happened', Loop.Reconnects >= 1);
      AssertEquals('the server retry: value was adopted', 250, Loop.RetryMs);
    finally
      Loop.Free;
    end;
  finally
    Client.Close;
    Seen.Free;
  end;
end;

procedure TSseLiveTest.TestLiveEventGapsMatchTheServerInterval;
const
  cIntervalMs = 100;
  cCount = 8;
var
  Url, Base: string;
  F: THttpClientFactory;
  Client: IHttpClient;
  Obs: TOutcomeObserver;
  ObsRef: IHttpClientObserver;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  I: Integer;
  MeanGapUs: Int64;
begin
  // opt-in like the case above: the server emits cCount events cIntervalMs
  // apart on /cadence, and the gaps the client measured at the wire must match
  // that interval within a generous tolerance for a loaded machine
  Url := GetEnvironmentVariable('SSE_TEST_URL');
  if Url = '' then
    Exit;
  Base := Url;
  if (Length(Base) > 7) and (Copy(Base, Length(Base) - 6, 7) = '/events') then
    SetLength(Base, Length(Base) - 7);
  Url := Base + '/cadence?interval_ms=' + IntToStr(cIntervalMs) + '&count=' +
    IntToStr(cCount);

  Obs := TOutcomeObserver.Create;
  ObsRef := Obs;
  F := THttpClientFactory.Create.WithRequestObserver(ObsRef);
  if Pos('http://', LowerCase(Url)) = 1 then
    F := F.WithClearText(ctUpgrade).WithHttp1Fallback(True);
  Client := F.Build;
  try
    Loop := TSseReconnectLoop.Create(Client, SseRequest(Url), 1);
    try
      for I := 1 to cCount do
        AssertTrue('event ' + IntToStr(I), Loop.Next(E));
      AssertEquals('the last event', 'tick ' + IntToStr(cCount), E.Data);
      Loop.Close;
    finally
      Loop.Free;
    end;
    AssertTrue('the attempt ended', Obs.WaitForEnd(5000));
    AssertTrue('the attempt is an SSE attempt', Obs.Kind = akSse);
    AssertTrue('and belongs to a loop', Obs.StreamId <> 0);
    AssertEquals('every event was counted', cCount, Obs.Outcome.MessagesIn);
    MeanGapUs := Obs.Outcome.SumGapUs div (cCount - 1);
    AssertTrue('mean gap near the interval: ' + IntToStr(MeanGapUs) + ' us',
      (MeanGapUs >= (cIntervalMs - 10) * 1000) and
      (MeanGapUs <= (cIntervalMs + 40) * 1000));
    AssertTrue('no stall beyond the interval: ' +
      IntToStr(Obs.Outcome.MaxGapUs) + ' us',
      Obs.Outcome.MaxGapUs <= (cIntervalMs + 150) * 1000);
    AssertTrue('the stream lasted about (count - 1) intervals',
      Obs.Outcome.LastMessageUs - Obs.Outcome.FirstMessageUs >=
        Int64(cCount - 1) * (cIntervalMs - 10) * 1000);
  finally
    Client.Close;
  end;
end;

initialization
  RegisterTest(TSseReconnectTest);
  RegisterTest(TSseTransportTest);
  RegisterTest(TSseLiveTest);
end.
