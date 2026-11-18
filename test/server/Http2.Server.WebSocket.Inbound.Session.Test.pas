{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, inbound, streamed message, credit, test, fpcunit
notes:
  - These tests drive a session with the test kit (a fake channel and a real streaming
    pool) and a handler that reads each message in one of four ways. They cover a
    message in one frame, a message that streams, the credit rules, the aborts and
    the three closes that a streamed message can cause (1007, 1008, 1009).
  - The fake channel counts credit in one number. A test that models the window of an
    HTTP/2 stream sends a frame only when the credit that came back leaves room.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Tests of the streamed inbound message of a WebSocket session
unit Http2.Server.WebSocket.Inbound.Session.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Body, Http2.Server.Errors, Http2.Common.Hpack, Http2.Server.Seam,
  Http2.Server.Duplex, Http2.Server.Limits, Http2.Server.Observer, Http2.Server.Sse.Test,
  Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.Parser, Http2.Server.WebSocket.Reader,
  Http2.Server.WebSocket.Session, Http2.Server.WebSocket.TestKit;

type
  /// how the handler reads a message
  TInboundMode = (imAll, imChunks, imPartial, imNone);

  /// a handler that reads each message in one way and records what happened
  TInboundHandler = class(TInterfacedObject, IWsHandler)
  private
    FLock: TCriticalSection;
    FLines: TStringList;
    FReceived: TBytes;
  public
    Mode: TInboundMode;
    /// imPartial: the octets that the handler reads before it waits for Resume
    PartialBytes: Integer;
    /// imPartial: set when the handler has read PartialBytes
    PartReached: TEvent;
    /// imPartial: the handler waits for it, and then reads the rest
    Resume: TEvent;
    Chunks: Integer;
    constructor Create;
    destructor Destroy; override;
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
    procedure Add(const ALine: string);
    function Text: string;
    function Has(const AText: string): Boolean;
    /// the octets of the last message that the handler read to its end
    function Received: TBytes;
  end;

  /// the base of the tests: one rig, one channel, one session
  TInboundFixture = class(TTestCase)
  private
    FNeedle: string;
    function ChannelActivated: Boolean;
    function HandlerNeedle: Boolean;
    function OutNeedle: Boolean;
  protected
    FRig: TWsRig;
    FHandler: TInboundHandler;
    FHandlerRef: IWsHandler;
    FChannel: TFakeWsChannel;
    FChannelRef: IDuplexChannel;
    FSession: IWsSession;
    FRequestRef: IServerRequest;
    function Quick: TWsOptions;
    procedure Build(const AOptions: TWsOptions; const APoolSize: Integer = 2);
    procedure TearDown; override;
    function WaitHandler(const AText: string): Boolean;
    function WaitOut(const AText: string): Boolean;
    /// frames of one message of ATotal octets, AFrame octets in each frame
    function MessageFrames(const AOpcode: Byte; const ATotal, AFrame: Integer): TArray<TBytes>;
    function Join(const AFrames: array of TBytes): TBytes;
  end;

  TWsInboundSessionTest = class(TInboundFixture)
  private
    function CreditEqualsDelivered(const ADelivered: Int64): Boolean;
    procedure SendWithWindow(const AFrames: TArray<TBytes>; const AWindow: Integer);
    procedure WindowMessage(const ATotal: Integer);
  published
    procedure TestMessageInOneFrameIsWholeAndCreditedOnArrival;
    procedure TestEmptyMessageIsDelivered;
    procedure TestMessageOverTheInlineLimitStreamsInManyFragments;
    procedure TestChunkLoopReadsAStreamedMessage;
    procedure TestSlowHandlerHoldsCreditOnAHttp2Window;
    procedure TestBadUtf8AfterAPartialReadClosesWith1007;
    procedure TestCloseFrameBetweenFragmentsCancelsTheRead;
    procedure TestEndOfTheSessionDuringARead;
    procedure TestServerStopWakesABlockedRead;
    procedure TestMessageOverMaxMessageSizeClosesWith1009;
    procedure TestHandlerThatReturnsWithoutReadingDropsTheRest;
    procedure TestStalledReadClosesWith1008;
    procedure TestPushOverThePipeCapClosesWith1009;
    procedure TestMessageOfTheWindowSize;
    procedure TestMessageOfTheWindowSizePlusOne;
    procedure TestQueuedMessagesOneDoesNotStallAStreamedMessage;
    procedure TestReaderStartsTheStreamAtTheInlineLimit;
    procedure TestReaderGivesTheSameMessageWithAnyInlineLimit;
  end;

/// a message of ACount octets that a test can check; the text form is ASCII
function PatternOf(const ACount: Integer; const AText: Boolean = False): TBytes;
function SamePattern(const AData: TBytes; const AText: Boolean = False): Boolean;

implementation

function PatternOf(const ACount: Integer; const AText: Boolean): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    if AText then
      Result[I] := Ord('a') + I mod 26
    else
      Result[I] := I mod 251;
end;

function SamePattern(const AData: TBytes; const AText: Boolean): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to High(AData) do
    if AText then
    begin
      if AData[I] <> Ord('a') + I mod 26 then
        Exit(False);
    end
    else if AData[I] <> I mod 251 then
      Exit(False);
end;

{ TInboundHandler }

constructor TInboundHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
  PartReached := TEvent.Create(nil, True, False, '');
  Resume := TEvent.Create(nil, True, False, '');
end;

destructor TInboundHandler.Destroy;
begin
  Resume.Free;
  PartReached.Free;
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

function TInboundHandler.Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
  const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TInboundHandler.Message(const ASession: IWsSession; const AMessage: IBodyReader;
  const AText: Boolean);
var
  Buf: TChunkBuffer;
  Head, Tail, Whole: TBytes;
  N, R: Integer;
begin
  Add(BoolToStr(AText, 'begin T', 'begin B'));
  try
    case Mode of
      imAll:
        Whole := ReadAllBody(AMessage);
      imChunks:
        begin
          Buf := TChunkBuffer.Create;
          try
            repeat
              FLock.Acquire;
              Inc(Chunks);
              FLock.Release;
            until not AMessage.ReadChunk(Buf);
            Whole := ChunkBytes(Buf);
          finally
            Buf.Free;
          end;
        end;
      imPartial:
        begin
          SetLength(Head, PartialBytes);
          N := 0;
          while N < PartialBytes do
          begin
            R := AMessage.Read(Head[N], PartialBytes - N);
            if R = 0 then
              Break;
            Inc(N, R);
          end;
          PartReached.SetEvent;
          Resume.WaitFor(15000);
          Tail := ReadAllBody(AMessage);
          SetLength(Whole, N + Length(Tail));
          if N > 0 then
            Move(Head[0], Whole[0], N);
          if Length(Tail) > 0 then
            Move(Tail[0], Whole[N], Length(Tail));
        end;
      imNone:
        begin
          Add('none');
          Exit;
        end;
    end;
    FLock.Acquire;
    try
      FReceived := Whole;
    finally
      FLock.Release;
    end;
    Add('got ' + IntToStr(Length(Whole)));
  except
    on EStreamCancelled do
    begin
      Add('cancelled');
      raise;
    end;
  end;
end;

procedure TInboundHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TInboundHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  Add('closed ' + IntToStr(ACode) + ' ' + AReason);
end;

procedure TInboundHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
  Add('failed ' + E.Message);
end;

procedure TInboundHandler.Add(const ALine: string);
begin
  FLock.Acquire;
  try
    FLines.Add(ALine);
  finally
    FLock.Release;
  end;
end;

function TInboundHandler.Text: string;
begin
  FLock.Acquire;
  try
    Result := FLines.Text;
  finally
    FLock.Release;
  end;
end;

function TInboundHandler.Has(const AText: string): Boolean;
begin
  Result := Pos(AText, Text) > 0;
end;

function TInboundHandler.Received: TBytes;
begin
  FLock.Acquire;
  try
    Result := Copy(FReceived);
  finally
    FLock.Release;
  end;
end;

{ TInboundFixture }

function TInboundFixture.Quick: TWsOptions;
begin
  Result := TWsOptions.Create
    .WithPingIntervalMs(0)
    .WithCloseTimeoutMs(300)
    .WithInitTimeoutMs(5000);
end;

procedure TInboundFixture.Build(const AOptions: TWsOptions; const APoolSize: Integer);
var
  Request: TFakeRequest;
begin
  FRig := TWsRig.Create(AOptions, APoolSize);
  if FHandler = nil then
  begin
    FHandler := TInboundHandler.Create;
    FHandlerRef := FHandler;
  end;
  FChannel := FRig.NewChannel;
  FChannelRef := FChannel;
  Request := TFakeRequest.Create;
  FRequestRef := Request;
  FSession := WsStartSession(FChannelRef, FRequestRef, FHandlerRef, TFakeHandshake.Create,
    nil);
  AssertTrue('the handshake response went out', WaitUntil(ChannelActivated));
end;

procedure TInboundFixture.TearDown;
begin
  if FHandler <> nil then
  begin
    // a handler that waits for Resume must not hold the pool at the end of a test
    FHandler.Resume.SetEvent;
  end;
  if FRig <> nil then
  begin
    FRig.Registry.CloseAll(ccGraceful);
    FRig.Registry.CloseAll(ccAbort);
  end;
  if FChannel <> nil then
    FChannel.Sink := nil;
  FSession := nil;
  FreeAndNil(FRig);
  FChannelRef := nil;
  FRequestRef := nil;
  FHandlerRef := nil;
  FHandler := nil;
  inherited TearDown;
end;

function TInboundFixture.ChannelActivated: Boolean;
begin
  Result := FChannel.Activated;
end;

function TInboundFixture.HandlerNeedle: Boolean;
begin
  Result := FHandler.Has(FNeedle);
end;

function TInboundFixture.OutNeedle: Boolean;
var
  L: TStringList;
begin
  L := DecodeOutput(FChannel.SentBytes);
  try
    Result := Pos(FNeedle, L.Text) > 0;
  finally
    L.Free;
  end;
end;

function TInboundFixture.WaitHandler(const AText: string): Boolean;
begin
  FNeedle := AText;
  Result := WaitUntil(HandlerNeedle);
end;

function TInboundFixture.WaitOut(const AText: string): Boolean;
begin
  FNeedle := AText;
  Result := WaitUntil(OutNeedle);
end;

function TInboundFixture.MessageFrames(const AOpcode: Byte; const ATotal, AFrame: Integer): TArray<TBytes>;
var
  All: TBytes;
  At, N, Count: Integer;
  Op: Byte;
begin
  All := PatternOf(ATotal, AOpcode = WsOpText);
  Result := nil;
  At := 0;
  Count := 0;
  repeat
    N := ATotal - At;
    if N > AFrame then
      N := AFrame;
    if At = 0 then
      Op := AOpcode
    else
      Op := WsOpContinuation;
    SetLength(Result, Count + 1);
    Result[Count] := ClientFrame(Op, At + N >= ATotal, Copy(All, At, N));
    Inc(Count);
    Inc(At, N);
  until At >= ATotal;
end;

function TInboundFixture.Join(const AFrames: array of TBytes): TBytes;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to High(AFrames) do
    Result := Cat(Result, AFrames[I]);
end;

{ TWsInboundSessionTest }

function TWsInboundSessionTest.CreditEqualsDelivered(const ADelivered: Int64): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + 5000;
  repeat
    if FChannel.CreditSoFar = ADelivered then
      Exit(True);
    Sleep(2);
  until GetTickCount64 >= Deadline;
  Result := FChannel.CreditSoFar = ADelivered;
end;

procedure TWsInboundSessionTest.TestMessageInOneFrameIsWholeAndCreditedOnArrival;
var
  Frame: TBytes;
begin
  Build(Quick);
  Frame := ClientFrame(WsOpBinary, True, PatternOf(500));
  FChannel.Deliver(Frame);
  AssertTrue(WaitHandler('got 500'));
  AssertTrue(SamePattern(FHandler.Received));
  AssertEquals('every octet is credited, once', Length(Frame), FChannel.CreditSoFar);
end;

procedure TWsInboundSessionTest.TestEmptyMessageIsDelivered;
begin
  Build(Quick);
  FChannel.Deliver(ClientFrame(WsOpBinary, True, nil));
  AssertTrue(WaitHandler('got 0'));
end;

procedure TWsInboundSessionTest.TestMessageOverTheInlineLimitStreamsInManyFragments;
var
  Stream: TBytes;
begin
  Build(Quick.WithInlineLimit(1000));
  Stream := Join(MessageFrames(WsOpBinary, 20000, 700));
  FChannel.Deliver(Stream);
  AssertTrue(WaitHandler('got 20000'));
  AssertTrue('the octets are in order', SamePattern(FHandler.Received));
  AssertTrue('every octet is credited, once', CreditEqualsDelivered(Length(Stream)));
  AssertFalse('no protocol error', FHandler.Has('closed'));
end;

procedure TWsInboundSessionTest.TestChunkLoopReadsAStreamedMessage;
var
  Frames: TArray<TBytes>;
  I: Integer;
begin
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imChunks;
  Build(Quick.WithInlineLimit(100));
  Frames := MessageFrames(WsOpBinary, 5000, 500);
  // the frames come one by one, so the handler sees more than one chunk
  for I := 0 to High(Frames) do
  begin
    FChannel.Deliver(Frames[I]);
    Sleep(2);
  end;
  AssertTrue(WaitHandler('got 5000'));
  AssertTrue(SamePattern(FHandler.Received));
  AssertTrue('more than one chunk', FHandler.Chunks > 1);
end;

procedure TWsInboundSessionTest.TestSlowHandlerHoldsCreditOnAHttp2Window;
var
  Frames: TArray<TBytes>;
  Total: Int64;
  I: Integer;
begin
  // the inline limit is 100: the first 100 octets are credited on arrival. The
  // handler reads 150 octets, then waits. The octets after the first 100 give credit
  // only as the handler reads them
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imPartial;
  FHandler.PartialBytes := 150;
  Build(Quick.WithInlineLimit(100));
  Frames := MessageFrames(WsOpBinary, 400, 100);
  Total := 0;
  for I := 0 to High(Frames) do
    Inc(Total, Length(Frames[I]));
  FChannel.Deliver(Join(Frames));
  AssertTrue(FHandler.PartReached.WaitFor(5000) = wrSignaled);
  // 4 frames of 106 octets: the headers (24) and the inline 100 are credited, and the
  // 50 octets that the handler read after them
  AssertEquals('headers, inline octets and the octets read', 24 + 100 + 50,
    FChannel.CreditSoFar);
  AssertTrue('credit stays held for the octets that wait', FChannel.CreditSoFar < Total);
  FHandler.Resume.SetEvent;
  AssertTrue(WaitHandler('got 400'));
  AssertTrue(CreditEqualsDelivered(Total));
end;

procedure TWsInboundSessionTest.TestBadUtf8AfterAPartialReadClosesWith1007;
var
  Frames: TArray<TBytes>;
begin
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imPartial;
  FHandler.PartialBytes := 20;
  Build(Quick.WithInlineLimit(16));
  Frames := MessageFrames(WsOpText, 100, 50);
  // the first frame is not the end: the message is still open
  FChannel.Deliver(Frames[0]);
  AssertTrue(FHandler.PartReached.WaitFor(5000) = wrSignaled);
  FChannel.Deliver(ClientFrame(WsOpContinuation, True, TBytes.Create(Ord('a'), $FF, Ord('b'))));
  AssertTrue(WaitOut('C:1007'));
  FHandler.Resume.SetEvent;
  AssertTrue('the read raised EStreamCancelled', WaitHandler('cancelled'));
  AssertFalse(FHandler.Has('got'));
end;

procedure TWsInboundSessionTest.TestCloseFrameBetweenFragmentsCancelsTheRead;
var
  Frames: TArray<TBytes>;
begin
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imPartial;
  FHandler.PartialBytes := 20;
  Build(Quick.WithInlineLimit(16));
  Frames := MessageFrames(WsOpBinary, 100, 50);
  FChannel.Deliver(Frames[0]);
  AssertTrue(FHandler.PartReached.WaitFor(5000) = wrSignaled);
  FChannel.Deliver(ClientClose(1000));
  AssertTrue('the Close frame is echoed', WaitOut('C:1000'));
  FHandler.Resume.SetEvent;
  AssertTrue(WaitHandler('cancelled'));
  AssertTrue('Closed follows the handler', WaitHandler('closed 1000'));
end;

procedure TWsInboundSessionTest.TestEndOfTheSessionDuringARead;
var
  Frames: TArray<TBytes>;
begin
  // the handler waits inside Read for octets that never come
  Build(Quick.WithInlineLimit(16));
  Frames := MessageFrames(WsOpBinary, 100, 50);
  FChannel.Deliver(Frames[0]);
  AssertTrue(WaitHandler('begin B'));
  Sleep(50);
  AssertFalse(FHandler.Has('cancelled'));
  FChannel.DeliverPeerClosed(False);
  AssertTrue('the transport loss wakes the read', WaitHandler('cancelled'));
  AssertTrue(WaitHandler('closed 1006'));
end;

procedure TWsInboundSessionTest.TestServerStopWakesABlockedRead;
var
  Frames: TArray<TBytes>;
  T0: QWord;
begin
  // the stop closes the sessions first, and the pool stop then waits for the tasks: a
  // handler in Read must be awake by then, or the stop waits for ever
  Build(Quick.WithInlineLimit(16), 1);
  Frames := MessageFrames(WsOpBinary, 100, 50);
  FChannel.Deliver(Frames[0]);
  AssertTrue(WaitHandler('begin B'));
  Sleep(50);
  T0 := GetTickCount64;
  FRig.Registry.CloseAll(ccGraceful);
  FRig.Registry.CloseAll(ccAbort);
  FreeAndNil(FRig);
  AssertTrue('the pool stopped in time', GetTickCount64 - T0 < 10000);
  AssertTrue(FHandler.Has('cancelled'));
end;

procedure TWsInboundSessionTest.TestMessageOverMaxMessageSizeClosesWith1009;
var
  Frames: TArray<TBytes>;
begin
  Build(Quick.WithInlineLimit(100).WithMaxMessageSize(600).WithMaxFrameSize(300));
  Frames := MessageFrames(WsOpBinary, 900, 300);
  FChannel.Deliver(Frames[0]);
  AssertTrue(WaitHandler('begin B'));
  FChannel.Deliver(Frames[1]);
  FChannel.Deliver(Frames[2]);
  AssertTrue(WaitOut('C:1009'));
  AssertTrue('the read of the handler ends', WaitHandler('cancelled'));
end;

procedure TWsInboundSessionTest.TestHandlerThatReturnsWithoutReadingDropsTheRest;
var
  Stream, Second: TBytes;
begin
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imNone;
  Build(Quick.WithInlineLimit(100));
  Stream := Join(MessageFrames(WsOpBinary, 3000, 500));
  FChannel.Deliver(Stream);
  AssertTrue(WaitHandler('none'));
  AssertTrue('the rest is dropped and credited', CreditEqualsDelivered(Length(Stream)));
  // the session goes on, and the next message arrives
  FHandler.Mode := imAll;
  Second := ClientFrame(WsOpBinary, True, PatternOf(50));
  FChannel.Deliver(Second);
  AssertTrue(WaitHandler('got 50'));
  AssertFalse(FHandler.Has('closed'));
  AssertTrue(CreditEqualsDelivered(Length(Stream) + Length(Second)));
end;

procedure TWsInboundSessionTest.TestStalledReadClosesWith1008;
var
  Frames: TArray<TBytes>;
begin
  Build(Quick.WithInlineLimit(16).WithInboundStallMs(150));
  Frames := MessageFrames(WsOpBinary, 100, 50);
  // the peer sends the first part and then nothing
  FChannel.Deliver(Frames[0]);
  AssertTrue(WaitOut('C:1008:the message stalled'));
  AssertTrue(WaitHandler('cancelled'));
end;

procedure TWsInboundSessionTest.TestPushOverThePipeCapClosesWith1009;
var
  Frames: TArray<TBytes>;
  I: Integer;
begin
  // the fake channel gives no flow control: the peer is not slowed. The handler reads
  // 10 octets and then waits, so the pipe fills up to its cap of 300
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imPartial;
  FHandler.PartialBytes := 10;
  Build(Quick.WithInlineLimit(50).WithInboundPipeBytes(300).WithMaxMessageSize(100000));
  Frames := MessageFrames(WsOpBinary, 2000, 100);
  FChannel.Deliver(Frames[0]);
  AssertTrue(FHandler.PartReached.WaitFor(5000) = wrSignaled);
  for I := 1 to High(Frames) do
    FChannel.Deliver(Frames[I]);
  AssertTrue(WaitOut('C:1009:the handler reads too slowly'));
  FHandler.Resume.SetEvent;
  AssertTrue(WaitHandler('cancelled'));
end;

procedure TWsInboundSessionTest.SendWithWindow(const AFrames: TArray<TBytes>;
  const AWindow: Integer);
var
  I: Integer;
  Sent, Deadline: Int64;
begin
  // the peer of an HTTP/2 stream: it sends a frame only when the window has room
  Sent := 0;
  for I := 0 to High(AFrames) do
  begin
    Deadline := Int64(GetTickCount64) + 5000;
    while Sent + Length(AFrames[I]) - FChannel.CreditSoFar > AWindow do
    begin
      AssertTrue('the peer waits for credit for ever: deadlock', Int64(GetTickCount64) < Deadline);
      Sleep(1);
    end;
    FChannel.Deliver(AFrames[I]);
    Inc(Sent, Length(AFrames[I]));
  end;
end;

procedure TWsInboundSessionTest.WindowMessage(const ATotal: Integer);
begin
  // the window and the inline limit are both 2000, like the defaults (65535 and
  // 65536): a message of the window size stays in memory, and one octet more streams
  Build(Quick.WithInlineLimit(2000).WithInboundPipeBytes(100000));
  SendWithWindow(MessageFrames(WsOpBinary, ATotal, 400), 2000);
  AssertTrue(WaitHandler('got ' + IntToStr(ATotal)));
  AssertTrue(SamePattern(FHandler.Received));
end;

procedure TWsInboundSessionTest.TestMessageOfTheWindowSize;
begin
  WindowMessage(2000);
end;

procedure TWsInboundSessionTest.TestMessageOfTheWindowSizePlusOne;
begin
  WindowMessage(2001);
end;

procedure TWsInboundSessionTest.TestQueuedMessagesOneDoesNotStallAStreamedMessage;
var
  Frames: TArray<TBytes>;
  Total: Int64;
  I: Integer;
begin
  // a queue of one: the streamed message counts once at its start, so the headers of
  // its next frames do not wait for the handler. The handler reads 10 octets and waits
  FHandler := TInboundHandler.Create;
  FHandlerRef := FHandler;
  FHandler.Mode := imPartial;
  FHandler.PartialBytes := 10;
  Build(Quick.WithInlineLimit(50).WithQueuedMessages(1));
  Frames := MessageFrames(WsOpBinary, 400, 20);
  Total := 0;
  for I := 0 to High(Frames) do
    Inc(Total, Length(Frames[I]));
  // the stream starts in the third frame: 40 octets were kept, and 360 follow
  for I := 0 to 2 do
    FChannel.Deliver(Frames[I]);
  AssertTrue(FHandler.PartReached.WaitFor(5000) = wrSignaled);
  for I := 3 to High(Frames) do
    FChannel.Deliver(Frames[I]);
  // 20 frames of 26 octets. The octets of the pipe are 400 - 40 = 360, and the handler
  // read 10 of the 40 kept octets: so all but the 360 octets are credited
  AssertEquals(Total - 360, FChannel.CreditSoFar);
  AssertFalse('the peer is not closed', FHandler.Has('closed'));
  FHandler.Resume.SetEvent;
  AssertTrue(WaitHandler('got 400'));
  AssertTrue(CreditEqualsDelivered(Total));
end;

type
  /// a reader sink that records the calls
  TLogSink = class(TInterfacedObject, IWsReaderSink)
  public
    Reader: TWsReader;
    Log: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure MessageBegin(const AText: Boolean);
    procedure MessageData(const AData; const ACount: Integer);
    procedure MessageEnd;
    procedure Control(const AOpcode: Byte; const AData: TBytes);
  end;

constructor TLogSink.Create;
begin
  inherited Create;
  Log := TStringList.Create;
end;

destructor TLogSink.Destroy;
begin
  Log.Free;
  inherited Destroy;
end;

procedure TLogSink.MessageBegin(const AText: Boolean);
begin
  Log.Add('begin ' + BoolToStr(Reader.Streaming, 'stream', 'inline'));
end;

procedure TLogSink.MessageData(const AData; const ACount: Integer);
begin
  Log.Add('data ' + IntToStr(ACount) + BoolToStr(Reader.Replaying, ' replay', ''));
end;

procedure TLogSink.MessageEnd;
begin
  Log.Add('end');
end;

procedure TLogSink.Control(const AOpcode: Byte; const AData: TBytes);
begin
end;

function RunReader(const AStream: TBytes; const AInlineLimit: Integer; out ALog: string): Boolean;
var
  Limits: TWsLimits;
  Reader: TWsReader;
  Sink: TLogSink;
  Ref: IWsReaderSink;
begin
  Limits.MaxFrameSize := 1 shl 20;
  Limits.MaxMessageSize := 1 shl 24;
  Limits.MaxFragments := 1000;
  Reader := TWsReader.Create(Limits, True, AInlineLimit);
  Sink := TLogSink.Create;
  Sink.Reader := Reader;
  Ref := Sink;
  try
    Result := Reader.Feed(AStream[0], Length(AStream), Ref);
    ALog := StringReplace(Trim(Sink.Log.Text), LineEnding, ';', [rfReplaceAll]);
  finally
    Reader.Free;
  end;
end;

procedure TWsInboundSessionTest.TestReaderStartsTheStreamAtTheInlineLimit;
var
  Log: string;
begin
  // a message of the limit stays in memory: the three calls come at its end
  AssertTrue(RunReader(ClientFrame(WsOpBinary, True, PatternOf(10)), 10, Log));
  AssertEquals('begin inline;data 10;end', Log);
  // one octet more starts the stream when the octet arrives; the kept octets replay
  AssertTrue(RunReader(Join([ClientFrame(WsOpBinary, False, PatternOf(6)),
    ClientFrame(WsOpContinuation, False, PatternOf(5)),
    ClientFrame(WsOpContinuation, True, PatternOf(2))]), 10, Log));
  AssertEquals('begin stream;data 6 replay;data 5;data 2;end', Log);
  // a first piece that passes the limit alone has nothing to replay
  AssertTrue(RunReader(ClientFrame(WsOpBinary, True, PatternOf(11)), 10, Log));
  AssertEquals('begin stream;data 11;end', Log);
end;

procedure TWsInboundSessionTest.TestReaderGivesTheSameMessageWithAnyInlineLimit;
var
  Stream: TBytes;
  Plain, Cut: string;
begin
  Stream := ClientFrame(WsOpText, True, PatternOf(3000, True));
  AssertTrue(RunReader(Stream, 65536, Plain));
  AssertEquals('begin inline;data 3000;end', Plain);
  AssertTrue(RunReader(Stream, 1, Cut));
  AssertEquals('begin stream;data 3000;end', Cut);
  // a bad octet after the stream started fails the reader
  AssertFalse(RunReader(Join([ClientFrame(WsOpText, False, PatternOf(100, True)),
    ClientFrame(WsOpContinuation, True, TBytes.Create($FF))]), 10, Cut));
end;

initialization
  RegisterTest(TWsInboundSessionTest);

end.
