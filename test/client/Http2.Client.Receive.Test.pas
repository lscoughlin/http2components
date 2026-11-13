{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, receive_queue, unknown_stream
notes:
  - this checks the byte cap of a stream receive queue and the rule for frames on unknown streams
---
}
unit Http2.Client.Receive.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Connection,
  Http2.Client.Stream.Receive, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.Frames;

type
  /// a stream lease that only counts the frames that the connection routes to it
  TCountingLease = class(TInterfacedObject, IConnectionStream)
  private
    FFrames: Integer;
  public
    procedure OnConnectionFailed(const AMessage: string;
      const ACode: THttp2ErrorCode);
    procedure OnConnectionGoAway(const ALastStreamId: LongWord);
    procedure OnStreamFrame(const AFrame: TFrame);
    property Frames: Integer read FFrames;
  end;

  /// a thread that waits on a receive queue and records the result
  TQueueWaiter = class(TThread)
  private
    FQueue: TByteBoundedFrameQueue;
    FGot: Boolean;
    FDone: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AQueue: TByteBoundedFrameQueue);
    property Got: Boolean read FGot;
    property Done: Boolean read FDone;
  end;

  /// the reader role: pushes DATA frames and records the largest byte count
  TQueueProducer = class(TThread)
  private
    FQueue: TByteBoundedFrameQueue;
    FCount: Integer;
    FPayload: Integer;
    FMaxSeen: Int64;
    FMinSeen: Int64;
    FRefused: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AQueue: TByteBoundedFrameQueue;
      const ACount, APayload: Integer);
    property MaxSeen: Int64 read FMaxSeen;
    property MinSeen: Int64 read FMinSeen;
    property Refused: Integer read FRefused;
  end;

  /// the byte cap of a stream receive queue
  TByteBoundedFrameQueueTest = class(TTestCase)
  published
    procedure TestBytesAddOnPushAndSubtractOnPop;
    procedure TestPushOverLimitRaises;
    procedure TestShutdownWakesWaiter;
    procedure TestPushAfterShutdownIsDropped;
    procedure TestFrameCapRaisesForEmptyFrames;
    procedure TestFrameCapFreesWithPop;
    procedure TestProducerAndConsumerKeepBytesInRange;
  end;

  /// the rule for a frame on a stream that has no lease
  TUnknownStreamTest = class(TTestCase)
  private
    function WaitForPingAck(const ASock: TMockSocket;
      const ATimeoutMs: Integer): Boolean;
  published
    procedure TestDataOnClosedStreamIsDiscarded;
    procedure TestDataOnIdleOddStreamClosesConnection;
    procedure TestDataOnEvenStreamClosesConnection;
  end;

implementation

{ TCountingLease }

procedure TCountingLease.OnConnectionFailed(const AMessage: string;
  const ACode: THttp2ErrorCode);
begin
end;

procedure TCountingLease.OnConnectionGoAway(const ALastStreamId: LongWord);
begin
end;

procedure TCountingLease.OnStreamFrame(const AFrame: TFrame);
begin
  Inc(FFrames);
end;

{ TQueueWaiter }

constructor TQueueWaiter.Create(const AQueue: TByteBoundedFrameQueue);
begin
  inherited Create(False);
  FQueue := AQueue;
  FreeOnTerminate := False;
end;

procedure TQueueWaiter.Execute;
begin
  FGot := FQueue.WaitForItem(5000);
  FDone := True;
end;

{ TQueueProducer }

constructor TQueueProducer.Create(const AQueue: TByteBoundedFrameQueue;
  const ACount, APayload: Integer);
begin
  inherited Create(False);
  FQueue := AQueue;
  FCount := ACount;
  FPayload := APayload;
  FMinSeen := 0;
  FreeOnTerminate := False;
end;

procedure TQueueProducer.Execute;
var
  I: Integer;
  Data: TBytes;
  Bytes: Int64;
begin
  SetLength(Data, FPayload);
  for I := 1 to FCount do
  begin
    // a refused push (the cap) is retried after the consumer made room
    while True do
    begin
      try
        FQueue.Push(BuildDataFrame(1, Data, False));
        Break;
      except
        on E: EHttpStreamError do
        begin
          Inc(FRefused);
          Sleep(0);
        end;
      end;
    end;
    Bytes := FQueue.QueuedBytes;
    if Bytes > FMaxSeen then
      FMaxSeen := Bytes;
    if Bytes < FMinSeen then
      FMinSeen := Bytes;
  end;
end;

{ TByteBoundedFrameQueueTest }

procedure TByteBoundedFrameQueueTest.TestFrameCapRaisesForEmptyFrames;
var
  Q: TByteBoundedFrameQueue;
  I: Integer;
  Raised: Boolean;
  Code: THttp2ErrorCode;
begin
  Q := TByteBoundedFrameQueue.Create(1000000);
  try
    for I := 1 to cReceiveQueueFrameCap do
      Q.Push(BuildHeadersFrame(1, nil, False, False));
    Raised := False;
    Code := ecNoError;
    try
      Q.Push(BuildHeadersFrame(1, nil, False, False));
    except
      on E: EHttpStreamError do
      begin
        Raised := True;
        Code := E.ErrorCode;
      end;
    end;
    AssertTrue('a push past the frame cap raises', Raised);
    AssertEquals('the error is a flow-control error', Ord(ecFlowControlError),
      Ord(Code));
    AssertEquals('empty frames add no bytes', 0, Q.QueuedBytes);
  finally
    Q.Free;
  end;
end;

procedure TByteBoundedFrameQueueTest.TestFrameCapFreesWithPop;
var
  Q: TByteBoundedFrameQueue;
  Data: TBytes;
  Item: TFrame;
  I: Integer;
  Raised: Boolean;
begin
  Q := TByteBoundedFrameQueue.Create(1000000);
  try
    SetLength(Data, 1);
    for I := 1 to cReceiveQueueFrameCap do
      Q.Push(BuildDataFrame(1, Data, False));
    Raised := False;
    try
      Q.Push(BuildDataFrame(1, Data, False));
    except
      on E: EHttpStreamError do
        Raised := True;
    end;
    AssertTrue('the full queue refuses', Raised);
    AssertEquals('a refused push returns its bytes', cReceiveQueueFrameCap,
      Q.QueuedBytes);
    AssertTrue('pop one frame', Q.TryPop(Item));
    Q.Push(BuildDataFrame(1, Data, False));
    AssertEquals('the queue is full again', cReceiveQueueFrameCap,
      Q.QueuedBytes);
  finally
    Q.Free;
  end;
end;

procedure TByteBoundedFrameQueueTest.TestProducerAndConsumerKeepBytesInRange;
const
  cFrames = 20000;
  cPayload = 100;
  cCap = 5000;
var
  Q: TByteBoundedFrameQueue;
  P: TQueueProducer;
  Item: TFrame;
  Got: Integer;
  Spins: Integer;
begin
  Q := TByteBoundedFrameQueue.Create(cCap);
  P := TQueueProducer.Create(Q, cFrames, cPayload);
  try
    Got := 0;
    Spins := 0;
    // the consumer role runs on this thread; a bounded poll ends a failure
    while Got < cFrames do
    begin
      if Q.TryPop(Item) then
      begin
        Inc(Got);
        Spins := 0;
        AssertTrue('the count is never negative', Q.QueuedBytes >= 0);
        AssertTrue('the count never passes the cap', Q.QueuedBytes <= cCap);
      end
      else
      begin
        Q.WaitForItem(10);
        Inc(Spins);
        AssertTrue('the producer delivers all frames', Spins < 1000);
      end;
    end;
    P.WaitFor;
    AssertTrue('the producer never saw a count over the cap', P.MaxSeen <= cCap);
    AssertTrue('the producer never saw a negative count', P.MinSeen >= 0);
    AssertEquals('the queue ends at zero bytes', 0, Q.QueuedBytes);
    AssertFalse('the queue is empty', Q.TryPop(Item));
  finally
    P.Free;
    Q.Free;
  end;
end;

procedure TByteBoundedFrameQueueTest.TestBytesAddOnPushAndSubtractOnPop;
var
  Q: TByteBoundedFrameQueue;
  Data: TBytes;
  Item: TFrame;
begin
  Q := TByteBoundedFrameQueue.Create(1000);
  try
    SetLength(Data, 40);
    Q.Push(BuildDataFrame(1, Data, False));
    Q.Push(BuildDataFrame(1, Data, False));
    AssertEquals('two DATA frames of 40 bytes', 80, Q.QueuedBytes);
    Q.Push(BuildHeadersFrame(1, nil, True, False));
    AssertEquals('a HEADERS frame adds no bytes', 80, Q.QueuedBytes);
    AssertTrue('pop a DATA frame', Q.TryPop(Item));
    AssertEquals('pop subtracts its DATA bytes', 40, Q.QueuedBytes);
    AssertTrue('pop the second DATA frame', Q.TryPop(Item));
    AssertEquals('bytes after the second pop', 0, Q.QueuedBytes);
    AssertTrue('pop the HEADERS frame', Q.TryPop(Item));
    AssertEquals('HEADERS pop leaves the bytes', 0, Q.QueuedBytes);
    AssertFalse('queue is empty', Q.TryPop(Item));
  finally
    Q.Free;
  end;
end;

procedure TByteBoundedFrameQueueTest.TestPushOverLimitRaises;
var
  Q: TByteBoundedFrameQueue;
  Data: TBytes;
  Raised: Boolean;
  Code: THttp2ErrorCode;
begin
  Q := TByteBoundedFrameQueue.Create(100);
  try
    SetLength(Data, 60);
    Q.Push(BuildDataFrame(7, Data, False));
    SetLength(Data, 40);
    Q.Push(BuildDataFrame(7, Data, False));
    AssertEquals('the queue holds exactly the cap', 100, Q.QueuedBytes);
    SetLength(Data, 1);
    Raised := False;
    Code := ecNoError;
    try
      Q.Push(BuildDataFrame(7, Data, False));
    except
      on E: EHttpStreamError do
      begin
        Raised := True;
        Code := E.ErrorCode;
      end;
    end;
    AssertTrue('a push past the cap raises', Raised);
    AssertEquals('the error is a flow-control error', Ord(ecFlowControlError),
      Ord(Code));
    AssertEquals('a refused push adds no bytes', 100, Q.QueuedBytes);
  finally
    Q.Free;
  end;
end;

procedure TByteBoundedFrameQueueTest.TestShutdownWakesWaiter;
var
  Q: TByteBoundedFrameQueue;
  W: TQueueWaiter;
  Waited: Integer;
begin
  Q := TByteBoundedFrameQueue.Create(100);
  W := TQueueWaiter.Create(Q);
  try
    Waited := 0;
    while (not W.Done) and (Waited < 200) do
    begin
      Sleep(5);
      Inc(Waited);
    end;
    Q.Shutdown;
    W.WaitFor;
    AssertTrue('the waiter returned after Shutdown', W.Done);
    AssertFalse('the waiter got no item', W.Got);
    AssertTrue('the queue reports shutdown', Q.IsShutdown);
  finally
    W.Free;
    Q.Free;
  end;
end;

procedure TByteBoundedFrameQueueTest.TestPushAfterShutdownIsDropped;
var
  Q: TByteBoundedFrameQueue;
  Data: TBytes;
  Item: TFrame;
begin
  Q := TByteBoundedFrameQueue.Create(10);
  try
    Q.Shutdown;
    SetLength(Data, 60);
    Q.Push(BuildDataFrame(1, Data, False));
    AssertEquals('a dropped push adds no bytes', 0, Q.QueuedBytes);
    AssertFalse('nothing is queued', Q.TryPop(Item));
  finally
    Q.Free;
  end;
end;

{ TUnknownStreamTest }

function TUnknownStreamTest.WaitForPingAck(const ASock: TMockSocket;
  const ATimeoutMs: Integer): Boolean;
var
  Frames: TArray<TFrame>;
  I, Waited: Integer;
begin
  Waited := 0;
  while Waited < ATimeoutMs do
  begin
    Frames := ParseFrameSequence(ASock.WrittenBytes, True);
    for I := 0 to High(Frames) do
      if (Frames[I].Header.FrameType = ftPing) and Frames[I].IsAck then
        Exit(True);
    Sleep(10);
    Inc(Waited, 10);
  end;
  Result := False;
end;

procedure TUnknownStreamTest.TestDataOnClosedStreamIsDiscarded;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: IConnectionStream;
  Data: TBytes;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Lease := TCountingLease.Create;
    Conn.RegisterStream(1, Lease);
    Conn.UnregisterStream(1);
    SetLength(Data, 10);
    Sock.FeedFrame(BuildDataFrame(1, Data, False));
    Sock.FeedFrame(BuildPingFrame(nil, False));
    AssertTrue('the peer ping is answered after the DATA', WaitForPingAck(Sock, 2000));
    AssertTrue('the connection stays open', Conn.State = csOpen);
  finally
    Conn.Free;
  end;
end;

procedure TUnknownStreamTest.TestDataOnIdleOddStreamClosesConnection;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Data: TBytes;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    SetLength(Data, 10);
    Sock.FeedFrame(BuildDataFrame(101, Data, False));
    AssertTrue('connection closes', Conn.WaitForState(csClosed, 2000));
    AssertEquals('the error is a protocol error', Ord(ecProtocolError),
      Ord(Conn.ErrorCode));
  finally
    Conn.Free;
  end;
end;

procedure TUnknownStreamTest.TestDataOnEvenStreamClosesConnection;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Data: TBytes;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    SetLength(Data, 10);
    Sock.FeedFrame(BuildDataFrame(2, Data, False));
    AssertTrue('connection closes', Conn.WaitForState(csClosed, 2000));
    AssertEquals('the error is a protocol error', Ord(ecProtocolError),
      Ord(Conn.ErrorCode));
  finally
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TByteBoundedFrameQueueTest);
  RegisterTest(TUnknownStreamTest);
end.
