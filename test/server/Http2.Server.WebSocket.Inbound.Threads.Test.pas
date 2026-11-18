{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, inbound, streamed message, threads, race, test, fpcunit
notes:
  - These thread tests run the races of a streamed inbound message on real threads: the
    IO thread that delivers frames, the pool thread of the handler that reads, and a
    third thread that aborts the session or closes the peer. Each test repeats its
    scenario cThreadTestRuns times with a new session each time.
  - Each wait has a deadline, so a hang fails the test and does not block the suite.
  - The fake channel runs the sink on the thread of the caller, as an IO thread does.
---
}
/// Thread tests of the streamed inbound message of a WebSocket session
unit Http2.Server.WebSocket.Inbound.Threads.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Server.Duplex, Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Inbound.Session.Test;

const
  /// the number of times that each thread test repeats its scenario
  cThreadTestRuns = 50;

type
  /// delivers frames to a channel from its own thread, as an IO thread does
  TDeliverThread = class(TThread)
  private
    FChannel: TFakeWsChannel;
    FFrames: TArray<TBytes>;
    FPauseMs: Integer;
  protected
    procedure Execute; override;
  public
    Error: string;
    constructor Create(const AChannel: TFakeWsChannel; const AFrames: TArray<TBytes>;
      const APauseMs: Integer);
  end;

  TWsInboundThreadTest = class(TInboundFixture)
  private
    function Delivered(const AFrames: TArray<TBytes>): Int64;
    function HandlerDone: Boolean;
    function Settled: Boolean;
  published
    procedure TestIoThreadStreamsWhileTheHandlerReads;
    procedure TestAbortRacesWithTheDelivery;
    procedure TestPeerClosedWakesABlockedRead;
    procedure TestStallRacesWithALateFragment;
  end;

implementation

{ TDeliverThread }

constructor TDeliverThread.Create(const AChannel: TFakeWsChannel; const AFrames: TArray<TBytes>;
  const APauseMs: Integer);
begin
  FChannel := AChannel;
  FFrames := AFrames;
  FPauseMs := APauseMs;
  inherited Create(False);
end;

procedure TDeliverThread.Execute;
var
  I: Integer;
begin
  try
    for I := 0 to High(FFrames) do
    begin
      FChannel.Deliver(FFrames[I]);
      if FPauseMs > 0 then
        Sleep(FPauseMs);
    end;
  except
    on E: Exception do
      Error := E.ClassName + ': ' + E.Message;
  end;
end;

{ TWsInboundThreadTest }

function TWsInboundThreadTest.Delivered(const AFrames: TArray<TBytes>): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AFrames) do
    Inc(Result, Length(AFrames[I]));
end;

function TWsInboundThreadTest.HandlerDone: Boolean;
begin
  Result := FHandler.Has('got') or FHandler.Has('cancelled');
end;

function TWsInboundThreadTest.Settled: Boolean;
begin
  // the session was aborted: the channel is closed, and a handler that began has
  // returned. A message that the abort dropped never reached the handler
  Result := FChannel.IsClosed and (not FHandler.Has('begin') or HandlerDone);
end;

procedure TWsInboundThreadTest.TestIoThreadStreamsWhileTheHandlerReads;
var
  Run: Integer;
  Frames: TArray<TBytes>;
  Io: TDeliverThread;
  Total: Int64;
  Deadline: QWord;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    Build(Quick.WithInlineLimit(5000));
    Frames := MessageFrames(WsOpBinary, 100000, 997);
    Total := Delivered(Frames);
    Io := TDeliverThread.Create(FChannel, Frames, 0);
    try
      Io.WaitFor;
      AssertEquals('the delivery raised nothing', '', Io.Error);
      AssertTrue('run ' + IntToStr(Run) + ': the handler got the message', WaitHandler('got 100000'));
      AssertTrue('the octets are in order', SamePattern(FHandler.Received));
      Deadline := GetTickCount64 + 5000;
      while (FChannel.CreditSoFar <> Total) and (GetTickCount64 < Deadline) do
        Sleep(1);
      AssertEquals('every octet is credited once', Total, FChannel.CreditSoFar);
    finally
      Io.Free;
    end;
    TearDown;
  end;
end;

procedure TWsInboundThreadTest.TestAbortRacesWithTheDelivery;
var
  Run: Integer;
  Io: TDeliverThread;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    Build(Quick.WithInlineLimit(500));
    Io := TDeliverThread.Create(FChannel, MessageFrames(WsOpBinary, 200000, 500), 0);
    try
      // the abort comes at a different place of the delivery in each run
      Sleep(Run mod 5);
      FSession.Abort;
      Io.WaitFor;
      AssertEquals('the delivery raised nothing', '', Io.Error);
      AssertTrue('run ' + IntToStr(Run) + ': the handler returned', WaitUntil(Settled));
    finally
      Io.Free;
    end;
    TearDown;
  end;
end;

procedure TWsInboundThreadTest.TestPeerClosedWakesABlockedRead;
var
  Run: Integer;
  Io: TDeliverThread;
  Frames: TArray<TBytes>;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    Build(Quick.WithInlineLimit(100));
    Frames := MessageFrames(WsOpBinary, 1000, 500);
    // the first frame only: the message stays open and the handler waits in Read
    Io := TDeliverThread.Create(FChannel, TArray<TBytes>.Create(Frames[0]), 0);
    try
      Io.WaitFor;
      AssertTrue(WaitHandler('begin B'));
      FChannel.DeliverPeerClosed(False);
      AssertTrue('run ' + IntToStr(Run) + ': the read was cancelled', WaitHandler('cancelled'));
    finally
      Io.Free;
    end;
    TearDown;
  end;
end;

procedure TWsInboundThreadTest.TestStallRacesWithALateFragment;
var
  Run: Integer;
  Io: TDeliverThread;
begin
  for Run := 1 to cThreadTestRuns do
  begin
    // the fragments come about as fast as the stall time: a run ends with the whole
    // message or with the cancelled read, and never hangs
    Build(Quick.WithInlineLimit(100).WithInboundStallMs(5));
    Io := TDeliverThread.Create(FChannel, MessageFrames(WsOpBinary, 3000, 300), 4 + Run mod 3);
    try
      Io.WaitFor;
      AssertEquals('the delivery raised nothing', '', Io.Error);
      AssertTrue('run ' + IntToStr(Run) + ': the handler returned', WaitUntil(HandlerDone));
    finally
      Io.Free;
    end;
    TearDown;
  end;
end;

initialization
  RegisterTest(TWsInboundThreadTest);

end.
