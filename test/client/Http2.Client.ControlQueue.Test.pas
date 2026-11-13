{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, control_queue, token_bucket, reader
notes:
  - this checks the control frame queue and the peer rate limits of the client reader
  - a hostile peer floods frames over a mock socket, so the client reads them as wire bytes
---
}
unit Http2.Client.ControlQueue.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Common.Errors, Http2.Common.Frames, Http2.Client.Connection,
  Http2.Client.Connection.Control, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.Frames, Http2.Client.MockSocket.Hostile;

type
  TControlFrameQueueTest = class(TTestCase)
  published
    procedure TestPostAcceptsUpToLimit;
    procedure TestPopReturnsFramesInOrder;
    procedure TestOverflowIsRecorded;
    procedure TestBucketAllowsCapacityThenRefuses;
    procedure TestBucketRefillsOverTime;
    procedure TestBucketRefillIsCappedAtCapacity;
    procedure TestPeerRateLimitsPingBurstAndAcksPass;
  end;

  /// posts one WINDOW_UPDATE on the test thread's behalf, as the reader does
  TTrackThread = class(TThread)
  private
    FConn: TConnection;
    FStreamId: LongWord;
    FLength: LongWord;
    FDone: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConn: TConnection; const AStreamId, ALength: LongWord);
    function Finished: Boolean;
  end;

  TReaderFloodTest = class(TTestCase)
  published
    procedure TestPingFloodClosesWithEnhanceYourCalm;
    procedure TestWindowUpdateIsSentWithFullDataQueue;
  end;

implementation

const
  // the data queue capacity of a connection (cDefaultQueueCapacity)
  cDataQueueCapacity = 128;

{ TControlFrameQueueTest }

procedure TControlFrameQueueTest.TestPostAcceptsUpToLimit;
var
  Queue: TControlFrameQueue;
  Frame: TFrame;
  I: Integer;
begin
  Queue := TControlFrameQueue.Create;
  try
    Frame := BuildPingFrame(nil, True);
    for I := 1 to cControlQueueLimit do
      AssertTrue('frame ' + IntToStr(I) + ' is queued', Queue.TryPost(Frame));
    AssertEquals('count at the limit', cControlQueueLimit, Queue.Count);
    AssertFalse('the frame over the limit is refused', Queue.TryPost(Frame));
    AssertEquals('the refused frame is not counted', cControlQueueLimit,
      Queue.Count);
  finally
    Queue.Free;
  end;
end;

procedure TControlFrameQueueTest.TestPopReturnsFramesInOrder;
var
  Queue: TControlFrameQueue;
  Out1, Out2: TFrame;
begin
  Queue := TControlFrameQueue.Create;
  try
    AssertFalse('an empty queue has nothing to pop', Queue.TryPop(Out1));
    AssertTrue('first post', Queue.TryPost(BuildWindowUpdateFrame(1, 10)));
    AssertTrue('second post', Queue.TryPost(BuildWindowUpdateFrame(3, 20)));
    AssertTrue('first pop', Queue.TryPop(Out1));
    AssertTrue('second pop', Queue.TryPop(Out2));
    AssertEquals('first in, first out', LongWord(1), Out1.Header.StreamId);
    AssertEquals('second frame', LongWord(3), Out2.Header.StreamId);
    AssertEquals('queue is empty again', 0, Queue.Count);
  finally
    Queue.Free;
  end;
end;

procedure TControlFrameQueueTest.TestOverflowIsRecorded;
var
  Queue: TControlFrameQueue;
  Frame: TFrame;
  I: Integer;
begin
  Queue := TControlFrameQueue.Create;
  try
    Frame := BuildPingFrame(nil, True);
    for I := 1 to cControlQueueLimit do
      Queue.TryPost(Frame);
    AssertFalse('no overflow at the limit', Queue.Overflowed);
    AssertFalse('the frame over the limit is refused', Queue.TryPost(Frame));
    AssertTrue('the overflow is recorded', Queue.Overflowed);
  finally
    Queue.Free;
  end;
end;

procedure TControlFrameQueueTest.TestBucketAllowsCapacityThenRefuses;
var
  Bucket: TTokenBucket;
begin
  // capacity 3, one token per second, full at time 0
  Bucket.Init(3, 1, 0);
  AssertTrue('take 1', Bucket.TryTake(1, 0));
  AssertTrue('take 2', Bucket.TryTake(1, 0));
  AssertTrue('take 3', Bucket.TryTake(1, 0));
  AssertFalse('take 4 is refused', Bucket.TryTake(1, 0));
  AssertFalse('still refused 999 ms later', Bucket.TryTake(1, 999));
  AssertTrue('one token after one second', Bucket.TryTake(1, 1000));
  AssertFalse('no second token yet', Bucket.TryTake(1, 1000));
end;

procedure TControlFrameQueueTest.TestBucketRefillsOverTime;
var
  Bucket: TTokenBucket;
begin
  // capacity 100, ten tokens per second
  Bucket.Init(100, 10, 0);
  AssertTrue('drain the burst', Bucket.TryTake(100, 0));
  AssertFalse('empty at time 0', Bucket.TryTake(1, 0));
  AssertFalse('no token after 99 ms', Bucket.TryTake(1, 99));
  AssertTrue('one token after 100 ms', Bucket.TryTake(1, 100));
  AssertFalse('the token is spent', Bucket.TryTake(1, 100));
  AssertTrue('two tokens after 1000 ms more', Bucket.TryTake(2, 1100));
end;

procedure TControlFrameQueueTest.TestBucketRefillIsCappedAtCapacity;
var
  Bucket: TTokenBucket;
begin
  Bucket.Init(3, 1000, 0);
  // a long idle time refills the bucket only up to its capacity
  AssertTrue('take 1', Bucket.TryTake(1, 10000000));
  AssertTrue('take 2', Bucket.TryTake(1, 10000000));
  AssertTrue('take 3', Bucket.TryTake(1, 10000000));
  AssertFalse('take 4 is refused', Bucket.TryTake(1, 10000000));
end;

procedure TControlFrameQueueTest.TestPeerRateLimitsPingBurstAndAcksPass;
var
  Limits: TPeerRateLimits;
  Ping, Ack: TFrame;
  I: Integer;
  Payload: TBytes;
begin
  Limits.Init(0);
  SetLength(Payload, 8);
  Ping := BuildPingFrame(Payload, False);
  Ack := BuildPingFrame(Payload, True);
  for I := 1 to 100 do
    AssertTrue('ping ' + IntToStr(I) + ' is within the burst',
      Limits.Allow(Ping, 0));
  AssertFalse('ping 101 is refused', Limits.Allow(Ping, 0));
  AssertTrue('an acknowledgement is never limited', Limits.Allow(Ack, 0));
end;

{ TTrackThread }

constructor TTrackThread.Create(const AConn: TConnection;
  const AStreamId, ALength: LongWord);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConn := AConn;
  FStreamId := AStreamId;
  FLength := ALength;
  FDone := 0;
  Start;
end;

procedure TTrackThread.Execute;
begin
  FConn.TrackReceivedData(FStreamId, FLength);
  InterlockedExchange(FDone, 1);
end;

function TTrackThread.Finished: Boolean;
begin
  Result := InterlockedExchangeAdd(FDone, 0) <> 0;
end;

{ TReaderFloodTest }

procedure TReaderFloodTest.TestPingFloodClosesWithEnhanceYourCalm;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Conn: TConnection;
  Payload: TBytes;
  I: Integer;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    SetLength(Payload, 8);
    // the burst is 100 pings and the refill is 10 a second, so 1000 pings
    // in one run close the connection without any dependence on the clock
    for I := 1 to 1000 do
      Peer.SendFrame(BuildPingFrame(Payload, False));
    AssertTrue('connection closes', Conn.WaitForState(csClosed, 5000));
    AssertEquals('error code: ' + Conn.ErrorMessage, Ord(ecEnhanceYourCalm),
      Ord(Conn.ErrorCode));
  finally
    Conn.Free;
    Peer.Free;
    Srv.Free;
  end;
end;

procedure TReaderFloodTest.TestWindowUpdateIsSentWithFullDataQueue;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Filler: TFrame;
  Track: TTrackThread;
  I: Integer;
  Waited: Integer;
  Out1: TFrame;
begin
  // the connection is not started: no worker drains the data queue, so the
  // data queue stays at its capacity
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Track := nil;
  try
    Filler := BuildPingFrame(nil, True);
    for I := 1 to cDataQueueCapacity do
      Conn.Outbound.Push(Filler);
    // 40000 bytes of DATA reach the connection window batch (32768)
    Track := TTrackThread.Create(Conn, 1, 40000);
    Waited := 0;
    while (not Track.Finished) and (Waited < 2000) do
    begin
      Sleep(10);
      Inc(Waited, 10);
    end;
    if not Track.Finished then
      // the reader is blocked on the full data queue: release it so the
      // test can end, then report the failure
      Conn.Outbound.Shutdown;
    AssertTrue('the reader does not block on the full data queue',
      Track.Finished);
    AssertEquals('the WINDOW_UPDATE waits in the control queue', 1,
      Conn.ControlQueue.Count);
    AssertTrue('the control frame is a WINDOW_UPDATE',
      Conn.ControlQueue.TryPop(Out1) and
      (Out1.Header.FrameType = ftWindowUpdate));
  finally
    if Track <> nil then
    begin
      Track.WaitFor;
      Track.Free;
    end;
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TControlFrameQueueTest);
  RegisterTest(TReaderFloodTest);

end.
