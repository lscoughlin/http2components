{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves mock socket client tests from the source project
---
}
unit Http2.Client.MockSocket.Observer.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Hpack, Http2.Client.Tls, Http2.Client.Observer,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames;

type
  TMockObserverEmissionTest = class(TTestCase)
  private
    function MakeConn(out ASock: TMockSocket; out AObs: TRecordingObserver): TConnection;
  published
    procedure TestConnectionOpenAndCloseObserved;
    procedure TestFrameOutObserved;
    procedure TestFrameInObserved;
    procedure TestGoAwayAndStreamLifecycleObserved;
    procedure TestWindowUpdateObserved;
    procedure TestDiscardedUnknownFrameObserved;
    procedure TestRetryObserved;
    procedure TestRaisingObserverDoesNotBreakConnection;
  end;

implementation

function TMockObserverEmissionTest.MakeConn(out ASock: TMockSocket;
  out AObs: TRecordingObserver): TConnection;
begin
  ASock := TMockSocket.Create;
  AObs := TRecordingObserver.Create;
  Result := TConnection.Create(ASock);
  Result.Observer := AObs;
end;
procedure TMockObserverEmissionTest.TestConnectionOpenAndCloseObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  Lease: TObserverTestLease;
  IL: IConnectionStream;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    AssertTrue('connection-open observed',
      Obs.WaitForCount(oekConnectionOpen, 1, 2000));

    // register then unregister a stream and observe the lifecycle
    Lease := TObserverTestLease.Create;
    IL := Lease;
    Conn.RegisterStream(7, IL);
    AssertTrue('stream-open observed',
      Obs.WaitForCount(oekStreamOpen, 1, 2000));
    Conn.UnregisterStream(7);
    AssertTrue('stream-close observed',
      Obs.WaitForCount(oekStreamClose, 1, 2000));

    Conn.Close;
    AssertTrue('connection-close observed',
      Obs.WaitForCount(oekConnectionClose, 1, 2000));
    AssertEquals('exactly one close event', 1,
      Obs.CountOf(oekConnectionClose));
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestFrameOutObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  I: Integer;
  FoundPing: Boolean;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    AssertTrue('initial SETTINGS frame-out observed',
      Obs.WaitForCount(oekFrameOut, 1, 2000));
    // an explicitly posted frame must also be observed as frame-out
    AssertTrue('frame posted', Conn.PostFrame(BuildPingFrame(nil, False)));
    AssertTrue('posted frame-out observed',
      Obs.WaitForCount(oekFrameOut, 2, 2000));
    FoundPing := False;
    for I := 0 to Obs.Count - 1 do
      if (Obs.Event(I).Kind = oekFrameOut) and
         (Obs.Event(I).FrameType = ftPing) then
        FoundPing := True;
    AssertTrue('the PING frame-out event carries its type', FoundPing);
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestFrameInObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  Idx: Integer;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Sock.EnqueuePing(nil, False);
    AssertTrue('frame-in observed',
      Obs.WaitForCount(oekFrameIn, 1, 2000));
    Idx := Obs.IndexOf(oekFrameIn);
    AssertEquals('the inbound frame event is the PING', Ord(ftPing),
      Ord(Obs.Event(Idx).FrameType));
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestGoAwayAndStreamLifecycleObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  Idx: Integer;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Sock.EnqueueGoAway(5, ecNoError, nil);
    AssertTrue('GOAWAY observed', Obs.WaitForCount(oekGoAway, 1, 2000));
    AssertTrue('connection reaches goaway state',
      Conn.WaitForState(csGoAway, 2000));
    Idx := Obs.IndexOf(oekGoAway);
    AssertEquals('GOAWAY event carries the last-stream-id', LongWord(5),
      Obs.Event(Idx).StreamId);
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestWindowUpdateObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  Idx: Integer;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Sock.EnqueueWindowUpdate(1, 4096);
    AssertTrue('window-update observed',
      Obs.WaitForCount(oekWindowUpdate, 1, 2000));
    Idx := Obs.IndexOf(oekWindowUpdate);
    AssertEquals('window-update stream id', LongWord(1),
      Obs.Event(Idx).StreamId);
    AssertEquals('window-update increment', LongWord(4096),
      Obs.Event(Idx).Increment);
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestDiscardedUnknownFrameObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  Raw: TBytes;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    // a frame type that RFC 7540 does not define (0x0A) must be reported
    // as discarded, not silently swallowed
    SetLength(Raw, FrameHeaderSize);
    Raw[0] := 0; Raw[1] := 0; Raw[2] := 0;
    Raw[3] := $0A; Raw[4] := 0;
    Raw[5] := 0; Raw[6] := 0; Raw[7] := 0; Raw[8] := 0;
    Sock.Feed(Raw);
    AssertTrue('discarded frame observed',
      Obs.WaitForCount(oekDiscarded, 1, 2000));
    AssertEquals('discard reason mentions unknown type', True,
      Pos('unknown', Obs.Event(Obs.IndexOf(oekDiscarded)).Reason) > 0);
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestRetryObserved;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
  Idx: Integer;
begin
  Conn := MakeConn(Sock, Obs);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Sock.EnqueueGoAway(5, ecNoError, nil);
    AssertTrue('connection reaches goaway state',
      Conn.WaitForState(csGoAway, 2000));
    // a stream above the peer's last-stream-id is retryable, which emits
    AssertTrue('stream 7 is retryable', Conn.IsStreamRetryable(7));
    AssertTrue('retry observed', Obs.WaitForCount(oekRetry, 1, 2000));
    Idx := Obs.IndexOf(oekRetry);
    AssertEquals('retry event carries the stream id', LongWord(7),
      Obs.Event(Idx).StreamId);
    AssertFalse('stream at last id is not retryable', Conn.IsStreamRetryable(5));
  finally
    Conn.Free;
  end;
end;
procedure TMockObserverEmissionTest.TestRaisingObserverDoesNotBreakConnection;
var
  Conn: TConnection;
  Sock: TMockSocket;
  Obs: TRecordingObserver;
begin
  Conn := MakeConn(Sock, Obs);
  Obs.RaiseOnEvent := True;
  try
    Conn.Start;
    // every observer callback raises; the connection loop must survive
    AssertTrue('connection still opens despite a raising observer',
      Conn.WaitForState(csOpen, 2000));
    Sock.EnqueuePing(nil, False);
    // feed a frame so frame-in, frame-out (the ping ack) and drop paths run
    AssertTrue('the ping is still acknowledged on the wire',
      Sock.WaitForFrames(2, 2000));
    AssertEquals('connection remains open after a raising observer',
      Ord(csOpen), Ord(Conn.State));
    Conn.Close;
    AssertEquals('a raising observer does not block Close',
      Ord(csClosed), Ord(Conn.State));
  finally
    Conn.Free;
  end;
end;

{ TMockSocketTest }
initialization
  RegisterTest(TMockObserverEmissionTest);
end.
