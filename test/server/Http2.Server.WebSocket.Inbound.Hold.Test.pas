{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, inbound, credit, hold rule, test, fpcunit
notes:
  - These tests cover the hold rule of QueuedMessages when one receive call carries the
    end of a streamed message and a whole small message after it. The exempt octets
    end with the streamed message, and the octets after it wait while the queue is half
    full.
  - The tests use the fixture of the streamed inbound message tests.
---
}
/// Tests of the hold rule for a receive call that ends a streamed message
unit Http2.Server.WebSocket.Inbound.Hold.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, SyncObjs, fpcunit, testregistry,
  Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Inbound.Session.Test;

type
  TWsInboundHoldTest = class(TInboundFixture)
  private
    FTotal: Int64;
    FCredited: Int64;
    /// a queue of four with a message in its handler, a streamed message that is
    /// open, and then one receive call: the last frame of the streamed message and a
    /// whole small message. The queue is at the hold threshold
    procedure OpenStream(out AFrames: TArray<TBytes>);
    procedure DeliverTailAndSmallMessage(const ASmalls: Integer = 1);
    function CreditReaches: Boolean;
  published
    procedure TestSmallMessageAfterAStreamedTailIsHeld;
    procedure TestHeldCreditIsGivenAsTheHandlerConsumes;
    procedure TestTwoSmallMessagesAfterAStreamedTailBalance;
    procedure TestAbortAfterAHeldTailReturnsNoMoreCredit;
    procedure TestOpenStreamAfterTheTailKeepsEverythingExempt;
    procedure TestZeroLengthFinalFrameThenASmallMessageIsHeld;
    procedure TestSplitFinalHeaderThenASmallMessageIsHeld;
    procedure TestPingAfterAStreamedTailIsHeld;
  end;

implementation

const
  /// the octets of a frame of 60 octets from a client: 6 of header and mask key
  cFrame60 = 66;
  cHead = 6;

function TWsInboundHoldTest.CreditReaches: Boolean;
begin
  Result := FChannel.CreditSoFar = FTotal;
end;

procedure TWsInboundHoldTest.OpenStream(out AFrames: TArray<TBytes>);
begin
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imPartial;
  FHandler.PartialBytes := 0;
  Build(Quick.WithInlineLimit(100).WithQueuedMessages(4));
  // M0 is in its handler: it waits for Resume and holds one place of the queue
  FChannel.Deliver(ClientFrame(WsOpBinary, True, PatternOf(10)));
  AssertTrue(FHandler.PartReached.WaitFor(5000) = wrSignaled);
  // M1 streams: 180 octets in three frames of 60. The first frame stays inline, the
  // second one starts the stream. Two places of the queue are in use now
  AFrames := MessageFrames(WsOpBinary, 180, 60);
  FChannel.Deliver(AFrames[0]);
  FChannel.Deliver(AFrames[1]);
  // 16 (M0) + 66 (the kept frame) + 6 (the header of the second frame); the 60 octets
  // of the pipe wait for the handler
  AssertEquals(16 + cFrame60 + cHead, FChannel.CreditSoFar);
  FCredited := FChannel.CreditSoFar;
end;

procedure TWsInboundHoldTest.DeliverTailAndSmallMessage(const ASmalls: Integer);
var
  Frames: TArray<TBytes>;
  Small, Buffer: TBytes;
  I: Integer;
begin
  OpenStream(Frames);
  Small := ClientFrame(WsOpBinary, True, PatternOf(10));
  FTotal := 16 + 3 * cFrame60 + ASmalls * Length(Small);
  // one buffer: the last frame of M1 and the whole small messages after it
  Buffer := Frames[2];
  for I := 1 to ASmalls do
    Buffer := Join([Buffer, Small]);
  FChannel.Deliver(Buffer);
end;

procedure TWsInboundHoldTest.TestSmallMessageAfterAStreamedTailIsHeld;
begin
  DeliverTailAndSmallMessage;
  // the header of the last frame of M1 is credited at once. The 60 octets of the pipe
  // wait for the handler. The 16 octets of M2 wait, because the queue is half full
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
  AssertFalse('the handler has not read the small message', FHandler.Has('got 10'));
end;

procedure TWsInboundHoldTest.TestHeldCreditIsGivenAsTheHandlerConsumes;
begin
  DeliverTailAndSmallMessage;
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
  FHandler.Resume.SetEvent;
  AssertTrue(WaitHandler('got 180'));
  AssertTrue(WaitHandler('got 10'));
  // every octet that arrived is credited, and none twice
  AssertTrue(WaitUntil(CreditReaches));
  Sleep(50);
  AssertEquals(FTotal, FChannel.CreditSoFar);
end;

procedure TWsInboundHoldTest.TestTwoSmallMessagesAfterAStreamedTailBalance;
begin
  DeliverTailAndSmallMessage(2);
  // only the header of the last frame of M1 is credited at once
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
  FHandler.Resume.SetEvent;
  AssertTrue(WaitUntil(CreditReaches));
  Sleep(50);
  AssertEquals('every octet is credited once', FTotal, FChannel.CreditSoFar);
end;

procedure TWsInboundHoldTest.TestAbortAfterAHeldTailReturnsNoMoreCredit;
begin
  DeliverTailAndSmallMessage;
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
  // the session ends while the credit of M2 waits. After the end no release path
  // returns stream credit: the octets of M2 and of the pipe of M1 stay outstanding.
  // The channel is aborted, so no peer waits for them, and the HTTP/2 connection window
  // is credited when the frames arrive. The value is pinned as the code gives it
  FSession.Abort;
  FHandler.Resume.SetEvent;
  Sleep(300);
  AssertEquals('no credit after the end', FCredited + cHead, FChannel.CreditSoFar);
end;

procedure TWsInboundHoldTest.TestOpenStreamAfterTheTailKeepsEverythingExempt;
var
  Frames, Next: TArray<TBytes>;
begin
  OpenStream(Frames);
  Next := MessageFrames(WsOpBinary, 180, 60);
  // the tail of M1, a whole small message, and the start of a second stream in one
  // buffer: a stream is open at the end, so nothing is held. The octets of the two
  // pipes (60 each) wait for the handler
  FChannel.Deliver(Join([Frames[2], ClientFrame(WsOpBinary, True, PatternOf(10)),
    Next[0], Next[1]]));
  AssertEquals(FCredited + 66 + 16 + 132 - 120, FChannel.CreditSoFar);
end;

procedure TWsInboundHoldTest.TestZeroLengthFinalFrameThenASmallMessageIsHeld;
var
  Frames: TArray<TBytes>;
begin
  OpenStream(Frames);
  // the stream ends with an empty frame: its 6 octets are exempt, and the small
  // message after it waits
  FChannel.Deliver(Join([ClientFrame(WsOpContinuation, True, nil),
    ClientFrame(WsOpBinary, True, PatternOf(10))]));
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
end;

procedure TWsInboundHoldTest.TestSplitFinalHeaderThenASmallMessageIsHeld;
var
  Frames: TArray<TBytes>;
  Last: TBytes;
begin
  OpenStream(Frames);
  Last := ClientFrame(WsOpContinuation, True, nil);
  // the head of the last frame arrives in two calls: the first one leaves the stream
  // open, and the second one ends it and carries the small message
  FChannel.Deliver(Copy(Last, 0, 3));
  AssertEquals(FCredited + 3, FChannel.CreditSoFar);
  FChannel.Deliver(Join([Copy(Last, 3, 3), ClientFrame(WsOpBinary, True, PatternOf(10))]));
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
end;

procedure TWsInboundHoldTest.TestPingAfterAStreamedTailIsHeld;
var
  Frames: TArray<TBytes>;
begin
  OpenStream(Frames);
  FTotal := 16 + 3 * cFrame60 + 10 + 16;
  // the Ping and the small message after the tail wait with the rule
  FChannel.Deliver(Join([Frames[2], ClientFrame(WsOpPing, True, PatternOf(4)),
    ClientFrame(WsOpBinary, True, PatternOf(10))]));
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
  FHandler.Resume.SetEvent;
  AssertTrue(WaitUntil(CreditReaches));
  Sleep(50);
  AssertEquals('every octet is credited once', FTotal, FChannel.CreditSoFar);
end;

initialization
  RegisterTest(TWsInboundHoldTest);

end.
