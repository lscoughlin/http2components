{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, flow_control, send_credit
notes:
  - this checks that a sender waiting for send credit wakes when the peer ends or resets the stream
---
}
unit Http2.Client.SendCredit.Wakeup.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Connection,
  Http2.Client.Stream.Receive, Http2.Client.Stream.Inbound,
  Http2.Client.MockSocket.Support;

type
  TSendCreditWakeupTest = class(TTestCase)
  private
    procedure RunRaceLoops(const AResetPeer: Boolean);
  published
    procedure TestPeerEndWakesWaitingSender;
    procedure TestPeerResetWakesWaitingSender;
  end;

implementation

const
  /// number of races per test
  cRaceLoops = 200;
  /// time limit of the waiting sender, in milliseconds
  cWaitLimitMs = 300;
  /// a sender that returns this late has waited for its time limit
  cBlockedAfterMs = 200;
  /// wake signals sent before the peer frame, so that the sender cycles
  /// through its lock, credit test, registration and wait
  cNoiseWakes = 400;
  /// byte cap of the receive queue of the stream
  cQueueBytes = 1000000;

type
  TSendCreditRaceWorker = class(TThread)
  private
    FConnection: TConnection;
    FPeerDone: PLongInt;
    FGranted: LongWord;
    FElapsedMs: QWord;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConnection: TConnection; const APeerDone: PLongInt);
    property Granted: LongWord read FGranted;
    property ElapsedMs: QWord read FElapsedMs;
    property ErrorText: string read FErrorText;
  end;

constructor TSendCreditRaceWorker.Create(const AConnection: TConnection;
  const APeerDone: PLongInt);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConnection := AConnection;
  FPeerDone := APeerDone;
  FGranted := 0;
  FElapsedMs := 0;
  FErrorText := '';
end;

procedure TSendCreditRaceWorker.Execute;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  try
    // no peer SETTINGS are applied, so no credit is ever granted here: the
    // sender can only leave the wait through the peer flag
    FGranted := FConnection.AcquireSendCredit(1, 100, cWaitLimitMs, FPeerDone);
  except
    on E: Exception do
      FErrorText := E.ClassName + ': ' + E.Message;
  end;
  FElapsedMs := GetTickCount64 - Started;
end;

procedure TSendCreditWakeupTest.RunRaceLoops(const AResetPeer: Boolean);
var
  I, J: Integer;
  Conn: TConnection;
  Queue: TByteBoundedFrameQueue;
  Worker: TSendCreditRaceWorker;
  Frame: TFrame;
  Done, Reset: LongInt;
  Blocked: Integer;
  Failures: string;
begin
  Blocked := 0;
  Failures := '';
  for I := 1 to cRaceLoops do
  begin
    Conn := TConnection.Create(TMockSocket.Create);
    Queue := TByteBoundedFrameQueue.Create(cQueueBytes);
    Done := 0;
    Reset := 0;
    try
      Worker := TSendCreditRaceWorker.Create(Conn, @Done);
      try
        Worker.Start;
        for J := 1 to cNoiseWakes + (I mod 37) do
          Conn.WakeSendCredit;
        // the reader thread runs LeasePushInbound: it sets the peer flag with
        // no lock, then wakes the senders; this call is the last wake
        if AResetPeer then
          Frame := BuildRstStreamFrame(1, ecCancel)
        else
          Frame := BuildHeadersFrame(1, nil, True, True);
        LeasePushInbound(Conn, Queue, 1, Frame, @Done, @Reset);
        Worker.WaitFor;
        if Worker.ErrorText <> '' then
          Failures := Failures + Format(' loop %d: %s;', [I, Worker.ErrorText]);
        if (Worker.Granted <> 0) or (Worker.ElapsedMs >= cBlockedAfterMs) then
          Inc(Blocked);
      finally
        Worker.Free;
      end;
    finally
      Queue.Free;
      Conn.Free;
    end;
  end;
  AssertEquals('no sender raised an error:' + Failures, '', Trim(Failures));
  AssertEquals(Format('senders that waited for their time limit of %d ms (of %d)',
    [cWaitLimitMs, cRaceLoops]), 0, Blocked);
end;

procedure TSendCreditWakeupTest.TestPeerEndWakesWaitingSender;
begin
  RunRaceLoops(False);
end;

procedure TSendCreditWakeupTest.TestPeerResetWakesWaitingSender;
begin
  RunRaceLoops(True);
end;

initialization
  RegisterTest(TSendCreditWakeupTest);
end.
