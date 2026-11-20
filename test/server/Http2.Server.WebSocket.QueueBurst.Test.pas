{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, queue, QueuedMessages, flow control, 1008, test, fpcunit
notes:
  - This unit tests the queue cap of a WebSocket session over HTTP/2 with the default
    QueuedMessages. A handler blocks in its first Message call. A window-respecting
    client sends a burst of small messages while the handler is blocked, and then the
    handler is released.
  - The test expects that the server neither closes the session with 1008 nor drops a
    message, because the client keeps to the window.
  - The test runs on a raw h2c frame client (TH2WsClient) that answers every DATA frame
    with a WINDOW_UPDATE at once.
  - The waits are bounded polls. The burst gets 1 s to arrive while the handler is blocked.
---
}
/// Tests of the queue cap of WebSocket over HTTP/2 with a burst of small messages
unit Http2.Server.WebSocket.QueueBurst.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2.Server, Http2.Server.Errors, Http2.Common.Headers, Http2.Common.Body,
  Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types,
  Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.TestKit,
  Http2.Server.WebSocket.Http1.Test, Http2.Server.WebSocket.H2Client,
  Http2.Server.Http1.RawClient;

type
  /// tests of a burst of small messages against the default queue of a session
  TWsQueueBurstTest = class(TTestCase)
  private
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function OpenSocket(out AClient: TH2WsClient): Boolean;
    function OpenHttp1(out AClient: TRawHttp): Boolean;
    procedure AssertDeliveredInOrder(const ACount: Integer);
    function DeliveredCount: Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestBurstOfSmallMessagesWhileTheHandlerBlocks;
    procedure TestBurstOnHttp1IsClosedAt1008;
    procedure TestTwentyThousandMessagesBackUpThroughTheWindow;
    procedure TestOneOctetMessagesAreBoundedByTheByteBudget;
    procedure TestTwoSessionsShareTheByteBudget;
  end;

  /// a handler whose Message calls wait on one manual-reset event, and that keeps the
  /// texts of the messages in the order of their delivery
  TGateWsHandler = class(TInterfacedObject, IWsHandler)
  private
    FGate: TEvent;
    FLock: TCriticalSection;
    FTexts: TStringList;
    FCloses: TStringList;
  public
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
    /// let every waiting and every later Message call run
    procedure Release;
    /// the texts delivered so far that start with APrefix
    function Delivered(const APrefix: string): Integer;
    /// the texts that start with APrefix follow in order, from the index AFirst, with
    /// AWidth digits; '' when they do, otherwise the first text that does not
    function OrderError(const APrefix: string; const AFirst, AWidth: Integer): string;
    /// the close records: the code and the reason of each session that ended by a close
    function Closes: TStringList;
  end;

  /// sets an event after a delay, on its own thread
  TReleaseThread = class(TThread)
  private
    FHandler: TGateWsHandler;
    FDelayMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHandler: TGateWsHandler; const ADelayMs: Integer);
  end;

implementation

const
  /// the messages of the burst
  BurstCount = 100;
  /// the time that the burst gets to arrive while the handler is blocked
  BurstArrivalMs = 1000;
  /// the time limit of the delivery after the handler is released
  DeliveryMs = 10000;

{ helpers }

function MessageText(const APrefix: string; const AIndex, AWidth: Integer): string;
begin
  if AWidth = 0 then
    Result := APrefix
  else
    Result := APrefix + Format('%.*d', [AWidth, AIndex]);
end;

function BurstWire(const APrefix: string; const AFirst, ACount, AWidth: Integer): TBytes;
var
  I, Pos, Size: Integer;
  F: TBytes;
begin
  // every text of one burst has the same length, so every frame has the same size
  Size := Length(MessageText(APrefix, AFirst, AWidth)) + 6;
  SetLength(Result, Size * ACount);
  Pos := 0;
  for I := AFirst to AFirst + ACount - 1 do
  begin
    F := ClientText(MessageText(APrefix, I, AWidth));
    Move(F[0], Result[Pos], Length(F));
    Inc(Pos, Length(F));
  end;
end;

function BigBucketOptions: TWsOptions;
begin
  // the message bucket must not confound the tests of the queue
  Result := TWsOptions.Create.WithMessageBucket(TTokenBucketOptions.Create
    .WithCapacity(1000000).WithRefillPerSecond(1000000));
end;

function LimitsWithBudget(const ABytes: Int64): TServerLimits;
begin
  Result := TServerLimits.Create.WithMaxWsQueuedBytes(ABytes);
end;

{ TGateWsHandler }

constructor TGateWsHandler.Create;
begin
  inherited Create;
  FGate := TEvent.Create(nil, True, False, '');
  FLock := TCriticalSection.Create;
  FTexts := TStringList.Create;
  FCloses := TStringList.Create;
end;

destructor TGateWsHandler.Destroy;
begin
  FGate.Free;
  FLock.Free;
  FTexts.Free;
  FCloses.Free;
  inherited Destroy;
end;

function TGateWsHandler.Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
  const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TGateWsHandler.Message(const ASession: IWsSession; const AMessage: IBodyReader;
  const AText: Boolean);
var
  S: string;
begin
  FGate.WaitFor(DeliveryMs * 2);
  S := TextOf(ReadAllBody(AMessage));
  FLock.Acquire;
  try
    FTexts.Add(S);
  finally
    FLock.Release;
  end;
end;

procedure TGateWsHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TGateWsHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  FLock.Acquire;
  try
    FCloses.Add(IntToStr(ACode) + ' ' + AReason);
  finally
    FLock.Release;
  end;
end;

procedure TGateWsHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

procedure TGateWsHandler.Release;
begin
  FGate.SetEvent;
end;

function TGateWsHandler.Delivered(const APrefix: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to FTexts.Count - 1 do
      if Copy(FTexts[I], 1, Length(APrefix)) = APrefix then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TGateWsHandler.OrderError(const APrefix: string; const AFirst, AWidth: Integer): string;
var
  I, Expected: Integer;
begin
  Result := '';
  Expected := AFirst;
  FLock.Acquire;
  try
    for I := 0 to FTexts.Count - 1 do
      if Copy(FTexts[I], 1, Length(APrefix)) = APrefix then
      begin
        if FTexts[I] <> MessageText(APrefix, Expected, AWidth) then
        begin
          Result := 'expected ' + MessageText(APrefix, Expected, AWidth) + ' but got ' +
            FTexts[I];
          Exit;
        end;
        Inc(Expected);
      end;
  finally
    FLock.Release;
  end;
end;

function TGateWsHandler.Closes: TStringList;
begin
  // the list belongs to the handler; the caller reads it only
  Result := FCloses;
end;

{ TReleaseThread }

constructor TReleaseThread.Create(const AHandler: TGateWsHandler; const ADelayMs: Integer);
begin
  FHandler := AHandler;
  FDelayMs := ADelayMs;
  inherited Create(False);
end;

procedure TReleaseThread.Execute;
begin
  Sleep(FDelayMs);
  FHandler.Release;
end;

{ TWsQueueBurstTest }

procedure TWsQueueBurstTest.SetUp;
begin
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
end;

procedure TWsQueueBurstTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
end;

procedure TWsQueueBurstTest.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function TWsQueueBurstTest.OpenSocket(out AClient: TH2WsClient): Boolean;
var
  F: THeaderBlock;
begin
  AClient := TH2WsClient.Create(FServer.Port);
  AClient.OpenWebSocket(1);
  Result := AClient.WaitHeaders(1, ResponseMs, F) and (Length(F) > 0);
  if Result then
    Result := (F[0].Name = ':status') and (F[0].Value = '200');
end;

function TWsQueueBurstTest.OpenHttp1(out AClient: TRawHttp): Boolean;
var
  H: TRawResponse;
begin
  AClient := TRawHttp.Create(FServer.Port);
  AClient.Send('GET /ws HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
    'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF +
    'Sec-WebSocket-Version: 13' + CRLF + CRLF);
  Result := AClient.ReadHead(ResponseMs, H) and (H.Status = 101);
end;

function TWsQueueBurstTest.DeliveredCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FRecording.Count - 1 do
    if Copy(FRecording.Line(I), 1, 6) = 'msg T ' then
      Inc(Result);
end;

procedure TWsQueueBurstTest.AssertDeliveredInOrder(const ACount: Integer);
var
  I, K: Integer;
  Line: string;
begin
  K := 0;
  for I := 0 to FRecording.Count - 1 do
  begin
    Line := FRecording.Line(I);
    if Copy(Line, 1, 6) = 'msg T ' then
    begin
      Inc(K);
      AssertEquals('message ' + IntToStr(K) + ' is in order',
        Format('msg T m%.3d', [K]), Line);
    end;
  end;
  AssertEquals('every message of the burst reached Message', ACount, K);
end;

procedure TWsQueueBurstTest.TestBurstOfSmallMessagesWhileTheHandlerBlocks;
var
  C: TH2WsClient;
  Gate: PRTLEvent;
  Wire: TBytes;
  I: Integer;
  Deadline: QWord;
  L: TStringList;
begin
  Gate := RTLEventCreate;
  try
    FRecording.Gate := Gate;
    // the default options: QueuedMessages is 16, and the message bucket holds 10000 tokens
    StartServer(LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create));
    AssertTrue('the handshake answers 200', OpenSocket(C));
    try
      Wire := nil;
      for I := 1 to BurstCount do
        Wire := Cat(Wire, ClientText(Format('m%.3d', [I])));
      // the client keeps to the window: 100 small messages are about 1 KiB, well inside
      // the 64 KiB stream window, so SendData returns at once
      C.SendData(1, Wire);
      // the handler is blocked in its first Message call; the burst gets time to arrive
      Deadline := GetTickCount64 + BurstArrivalMs;
      repeat
        C.Pump(20);
      until GetTickCount64 > Deadline;
      // release the handler and wait for the deliveries
      RTLEventSetEvent(Gate);
      Deadline := GetTickCount64 + DeliveryMs;
      repeat
        C.Pump(20);
      until (DeliveredCount >= BurstCount) or (GetTickCount64 > Deadline);
      L := DecodeOutput(C.DataOf(1));
      try
        AssertTrue('no close frame with 1008 for a window-respecting client; the server sent: ' +
          StringReplace(Trim(L.Text), LineEnding, ' | ', [rfReplaceAll]) +
          '; messages that reached Message: ' + IntToStr(DeliveredCount),
          Pos('C:1008', L.Text) = 0);
      finally
        L.Free;
      end;
      AssertDeliveredInOrder(BurstCount);
    finally
      C.Free;
    end;
  finally
    // the handler must not wait on the gate when the server stops
    RTLEventSetEvent(Gate);
    if FServer <> nil then
    begin
      FServer.Stop;
      FServer := nil;
    end;
    RTLEventDestroy(Gate);
    FRecording.Gate := nil;
  end;
end;

procedure TWsQueueBurstTest.TestBurstOnHttp1IsClosedAt1008;
var
  C: TRawHttp;
  Gate: PRTLEvent;
  Wire, Got: TBytes;
  I: Integer;
  Deadline: QWord;
  L: TStringList;
  Closed: Boolean;
begin
  // HTTP/1.1 has no window, so the queue cap closes the session (design: no flow control)
  Gate := RTLEventCreate;
  try
    FRecording.Gate := Gate;
    StartServer(LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create));
    AssertTrue('the upgrade answers 101', OpenHttp1(C));
    try
      Wire := nil;
      for I := 1 to BurstCount do
        Wire := Cat(Wire, ClientText(Format('m%.3d', [I])));
      C.Send(TextOf(Wire));
      // the octets of the server are kept: the close frame can arrive while the handler is blocked
      Got := nil;
      Closed := False;
      Deadline := GetTickCount64 + BurstArrivalMs;
      repeat
        Got := Cat(Got, BytesOf(C.ReadSome(20)));
      until GetTickCount64 > Deadline;
      RTLEventSetEvent(Gate);
      Deadline := GetTickCount64 + DeliveryMs;
      repeat
        Got := Cat(Got, BytesOf(C.ReadSome(50)));
        L := DecodeOutput(Got);
        try
          Closed := Pos('C:1008', L.Text) > 0;
        finally
          L.Free;
        end;
      until Closed or (GetTickCount64 > Deadline);
      L := DecodeOutput(Got);
      try
        AssertTrue('the session closes with 1008 after the burst; octets received: ' +
          IntToStr(Length(Got)) + '; frames: ' +
          StringReplace(Trim(L.Text), LineEnding, ' | ', [rfReplaceAll]), Closed);
      finally
        L.Free;
      end;
      AssertTrue('the queue cap drops the messages that wait: ' +
        IntToStr(DeliveredCount) + ' of ' + IntToStr(BurstCount) + ' reached Message',
        DeliveredCount < BurstCount);
    finally
      C.Free;
    end;
  finally
    RTLEventSetEvent(Gate);
    if FServer <> nil then
    begin
      FServer.Stop;
      FServer := nil;
    end;
    RTLEventDestroy(Gate);
    FRecording.Gate := nil;
  end;
end;

procedure TWsQueueBurstTest.TestTwentyThousandMessagesBackUpThroughTheWindow;
const
  Total = 20000;
  ReleaseAfterMs = 1000;
var
  C: TH2WsClient;
  H: TGateWsHandler;
  HRef: IWsHandler;
  Rel: TReleaseThread;
  Start, Elapsed, Deadline: QWord;
begin
  H := TGateWsHandler.Create;
  HRef := H;
  FRouter.Handler := HRef;
  // 20000 messages of 6 octets are 240000 octets: the 64 KiB window must stop the sender
  // until the handler takes messages, and the default queue and budget must not close
  StartServer(LiveFactory(FRouterRef).WithWebSockets(BigBucketOptions));
  AssertTrue('the handshake answers 200', OpenSocket(C));
  try
    Rel := TReleaseThread.Create(H, ReleaseAfterMs);
    try
      Start := GetTickCount64;
      C.SendData(1, BurstWire('m', 1, Total, 5));
      Elapsed := GetTickCount64 - Start;
    finally
      Rel.WaitFor;
      Rel.Free;
    end;
    Deadline := GetTickCount64 + 30000;
    repeat
      C.Pump(20);
    until (H.Delivered('m') >= Total) or (GetTickCount64 > Deadline);
    AssertTrue('the window stopped the sender until the release: ' + IntToStr(Elapsed) + ' ms',
      Elapsed >= ReleaseAfterMs - 100);
    AssertEquals('every admitted message reached Message', Total, H.Delivered('m'));
    AssertEquals('the messages arrived in order', '', H.OrderError('m', 1, 5));
    AssertEquals('no session closed', 0, H.Closes.Count);
  finally
    C.Free;
    FRouter.Handler := nil;
    H.Release;
  end;
end;

procedure TWsQueueBurstTest.TestOneOctetMessagesAreBoundedByTheByteBudget;
const
  Total = 20000;
var
  C: TH2WsClient;
  H: TGateWsHandler;
  HRef: IWsHandler;
  Deadline: QWord;
begin
  H := TGateWsHandler.Create;
  HRef := H;
  FRouter.Handler := HRef;
  // the budget of 1 MiB charges 257 octets per one-octet message: 4080 messages fit, and
  // the window would admit about 9000, so the budget closes the session
  StartServer(LiveFactory(FRouterRef).WithWebSockets(BigBucketOptions)
    .WithServerLimits(LimitsWithBudget(1048576)));
  AssertTrue('the handshake answers 200', OpenSocket(C));
  try
    try
      C.SendData(1, BurstWire('x', 1, Total, 0));
    except
      // the session ends while the sender waits for the window: that is expected here
      on E: Exception do
        ;
    end;
    AssertTrue('the close frame arrives',
      C.WaitFrames(1, 'C:1008:the queued bytes of the server are full', 5000));
    // the Closed call of the handler waits for the Message call that is blocked
    H.Release;
    Deadline := GetTickCount64 + 5000;
    repeat
      C.Pump(20);
    until (H.Closes.Count >= 1) or (GetTickCount64 > Deadline);
    AssertEquals('the session closes once', 1, H.Closes.Count);
    AssertTrue('the close names the byte budget: ' + H.Closes.Text,
      Pos('the queued bytes of the server are full', H.Closes.Text) > 0);
  finally
    C.Free;
    FRouter.Handler := nil;
    H.Release;
  end;
end;

procedure TWsQueueBurstTest.TestTwoSessionsShareTheByteBudget;
const
  Admitted = 2500;
var
  C: TH2WsClient;
  H: TGateWsHandler;
  HRef: IWsHandler;
  F: THeaderBlock;
  Deadline: QWord;
begin
  H := TGateWsHandler.Create;
  HRef := H;
  FRouter.Handler := HRef;
  // one 1 MiB budget: session A charges 262 octets per message, 2500 messages take 655000
  // octets, and session B fits 1502 messages of its 2000 before the budget closes it
  StartServer(LiveFactory(FRouterRef).WithWebSockets(BigBucketOptions)
    .WithServerLimits(LimitsWithBudget(1048576)));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue('stream 1 answers 200', C.WaitHeaders(1, ResponseMs, F));
    C.OpenWebSocket(3);
    AssertTrue('stream 3 answers 200', C.WaitHeaders(3, ResponseMs, F));
    C.SendData(1, BurstWire('A', 1, Admitted, 5));
    // the handler is blocked: session A keeps its messages in the queue
    Deadline := GetTickCount64 + BurstArrivalMs;
    repeat
      C.Pump(20);
    until GetTickCount64 > Deadline;
    try
      C.SendData(3, BurstWire('B', 1, 2000, 5));
    except
      on E: Exception do
        ;
    end;
    AssertTrue('session B closes with the byte budget',
      C.WaitFrames(3, 'C:1008:the queued bytes of the server are full', 5000));
    AssertFalse('session A stays open while B is closed', C.WaitFrames(1, 'C:', 300));
    // the Closed call of B waits for its blocked Message call: release, then count
    H.Release;
    Deadline := GetTickCount64 + 5000;
    repeat
      C.Pump(20);
    until (H.Closes.Count >= 1) or (GetTickCount64 > Deadline);
    AssertEquals('only session B closed', 1, H.Closes.Count);
    Deadline := GetTickCount64 + DeliveryMs;
    repeat
      C.Pump(20);
    until (H.Delivered('A') >= Admitted) or (GetTickCount64 > Deadline);
    AssertEquals('every message of session A reached Message', Admitted, H.Delivered('A'));
    AssertEquals('session A delivers in order', '', H.OrderError('A', 1, 5));
  finally
    C.Free;
    FRouter.Handler := nil;
    H.Release;
  end;
end;

initialization
  RegisterTest(TWsQueueBurstTest);

end.
