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
    procedure DeliverTailAndSmallMessage(const ASmalls: Integer = 1);
    function CreditReaches: Boolean;
  published
    procedure TestSmallMessageAfterAStreamedTailIsHeld;
    procedure TestHeldCreditIsGivenAsTheHandlerConsumes;
    procedure TestTwoSmallMessagesAfterAStreamedTailBalance;
    procedure TestAbortAfterAHeldTailNeverCreditsTwice;
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

procedure TWsInboundHoldTest.DeliverTailAndSmallMessage(const ASmalls: Integer);
var
  Frames: TArray<TBytes>;
  Small, Buffer: TBytes;
  I: Integer;
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
  Frames := MessageFrames(WsOpBinary, 180, 60);
  FChannel.Deliver(Frames[0]);
  FChannel.Deliver(Frames[1]);
  // 16 (M0) + 66 (the kept frame) + 6 (the header of the second frame); the 60 octets
  // of the pipe wait for the handler
  AssertEquals(16 + cFrame60 + cHead, FChannel.CreditSoFar);
  Small := ClientFrame(WsOpBinary, True, PatternOf(10));
  FTotal := 16 + 3 * cFrame60 + ASmalls * Length(Small);
  FCredited := FChannel.CreditSoFar;
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

procedure TWsInboundHoldTest.TestAbortAfterAHeldTailNeverCreditsTwice;
begin
  DeliverTailAndSmallMessage;
  AssertEquals(FCredited + cHead, FChannel.CreditSoFar);
  // the session ends while the credit of M2 waits. The channel is closed, so the held
  // octets may stay with the session, but no octet is credited twice
  FSession.Abort;
  FHandler.Resume.SetEvent;
  Sleep(200);
  AssertTrue(FChannel.CreditSoFar <= FTotal);
end;

initialization
  RegisterTest(TWsInboundHoldTest);

end.
