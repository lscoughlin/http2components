{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: handler deadline, max handler time, stuck handler, test, fpcunit
notes:
  - This unit tests the handler time limit. The tracker tests use an explicit
    clock. The pool tests run the handler pool with fake streams. The live tests
    run a server with an h2c client and an HTTP/1.1 client.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Tests of the handler time limit
unit Http2.Server.HandlerDeadline.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.base, mormot.core.os, mormot.net.sock,
  Http2.Server, Http2.Server.Errors, Http2.Common.Errors, Http2.Common.Frames,
  Http2.Common.Headers, Http2.Common.Hpack, Http2.Server.Seam,
  Http2.Server.Stream, Http2.Server.StreamHost, Http2.Server.Limits,
  Http2.Server.Config, Http2.Server.Config.Limits, Http2.Server.Observer,
  Http2.Server.Admission, Http2.Server.HandlerJob, Http2.Server.HandlerDeadline,
  Http2.Server.Duplex,
  Http2.Server.Http1.RawClient;

type
  /// a stream host that ignores the calls
  TDeadlineNullHost = class(TInterfacedObject, IStreamHost)
  public
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    procedure OutputPending(const AStreamId: LongWord);
  end;

  /// an observer that keeps the handler timeout events
  TDeadlineObserver = class(TInterfacedObject, IHttp2ServerObserver,
    IHttp2HandlerTimeoutObserver)
  private
    FLock: TCriticalSection;
    FIds: TList<LongWord>;
    FStuck: TList<Integer>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    procedure OnHandlerTimeout(const AStreamId: LongWord;
      const AStuckCount: Integer);
    function Count: Integer;
    function IdAt(const AIndex: Integer): LongWord;
    function StuckAt(const AIndex: Integer): Integer;
  end;

  /// a job that only keeps its state
  TDeadlineStubJob = class(TInterfacedObject, IHandlerJob)
  public
    procedure Run(const AHandler: IHttp2Handler;
      const ARegistry: IChannelRegistry);
    procedure Refuse(const AReason: THandlerJobRefusal);
    procedure Cancel;
    function IsCancelled: Boolean;
  end;

  /// the handler of the pool and live tests; the path selects the behavior
  // - /fast answers 200
  // - /read waits 600 ms, then reads, so a cancelled stream ends the handler
  // - /headed sends the 200 head, then waits for the cancel
  // - /stuck ignores the cancel until the gate opens
  TDeadlineHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FLock: TCriticalSection;
    FGate: TEvent;
    FStarted, FCancelled, FReturned: Integer;
    procedure Bump(var ACounter: Integer);
    function Get(const ACounter: PInteger): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    procedure OpenGate;
    function Started: Integer;
    function Cancelled: Integer;
    function Returned: Integer;
    function CancelledRef: PInteger;
    function ReturnedRef: PInteger;
  end;

  /// a small h2c client that keeps one connection for many requests
  TDeadlineH2Client = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
    FBuf: RawByteString;
    procedure Pump(const AWaitMs: Integer);
    function TakeFrame(out AFrame: TFrame): Boolean;
    procedure SendBytes(const AFrame: TFrame);
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    procedure SendGet(const AStreamId: LongWord; const APath: string);
    /// wait for the HEADERS of AStreamId and answer its status
    function WaitStatus(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out AStatus: Integer): Boolean;
    function WaitReset(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out ACode: THttp2ErrorCode): Boolean;
  end;

  THandlerDeadlineTest = class(TTestCase)
  private
    FLock: TCriticalSection;
    FHost: IStreamHost;
    FStreams: TObjectList<TServerStream>;
    FHandler: TDeadlineHandler;
    FHandlerRef: IHttp2Handler;
    FObserver: TDeadlineObserver;
    FObserverRef: IHttp2ServerObserver;
    FPool: THandlerPool;
    FServer: IHttp2Server;
    FExpired: Integer;
    FJobExpired: Integer;
    procedure OnExpired(const AStream: TServerStream);
    procedure OnJobExpired(const AJob: IHandlerJob);
    function NewStream(const AStreamId: LongWord;
      const APath: string): TServerStream;
    procedure WaitFor(const ACounter: PInteger; const AWanted: Integer);
    procedure StartPool(const ALimitMs: Integer);
    procedure StartServer(const ALimitMs: Integer);
    function WaitEvents(const ACount, ATimeoutMs: Integer): Boolean;
    function WaitCancelled(const AStream: TServerStream;
      const ATimeoutMs: Integer): Boolean;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSweepFiresOnceAndCountsStuck;
    procedure TestUnregisterBeforeTheLimitNeverFires;
    procedure TestLimitZeroFiresNothing;
    procedure TestJobExpiresOnce;
    procedure TestPoolAnswers503AndCancelsTheHandlerSide;
    procedure TestPoolResetsAStreamWithAHeadOut;
    procedure TestPoolCountsAHandlerThatIgnoresTheCancel;
    procedure TestPoolLimitZeroChangesNothing;
    procedure TestH2SlowHandlerGets503AndTheSlotFrees;
    procedure TestH2HeadedHandlerGetsAReset;
    procedure TestH2StuckHandlerFreesTheSlotAndIsCounted;
    procedure TestH1SlowHandlerGets503;
    procedure TestH1HeadedHandlerLosesTheConnection;
    procedure TestH1StuckHandlerIsCountedAndTheServerServes;
  end;

implementation

const
  WaitMs = 5000;
  LimitMs = 300;

function BytesOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

{ TDeadlineNullHost }

procedure TDeadlineNullHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
end;

procedure TDeadlineNullHost.OutputPending(const AStreamId: LongWord);
begin
end;

{ TDeadlineObserver }

constructor TDeadlineObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FIds := TList<LongWord>.Create;
  FStuck := TList<Integer>.Create;
end;

destructor TDeadlineObserver.Destroy;
begin
  FStuck.Free;
  FIds.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDeadlineObserver.OnEvent(const AEvent: TServerEvent);
begin
end;

procedure TDeadlineObserver.OnHandlerTimeout(const AStreamId: LongWord;
  const AStuckCount: Integer);
begin
  FLock.Acquire;
  try
    FIds.Add(AStreamId);
    FStuck.Add(AStuckCount);
  finally
    FLock.Release;
  end;
end;

function TDeadlineObserver.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FIds.Count;
  finally
    FLock.Release;
  end;
end;

function TDeadlineObserver.IdAt(const AIndex: Integer): LongWord;
begin
  FLock.Acquire;
  try
    Result := FIds[AIndex];
  finally
    FLock.Release;
  end;
end;

function TDeadlineObserver.StuckAt(const AIndex: Integer): Integer;
begin
  FLock.Acquire;
  try
    Result := FStuck[AIndex];
  finally
    FLock.Release;
  end;
end;

{ TDeadlineStubJob }

procedure TDeadlineStubJob.Run(const AHandler: IHttp2Handler;
  const ARegistry: IChannelRegistry);
begin
end;

procedure TDeadlineStubJob.Refuse(const AReason: THandlerJobRefusal);
begin
end;

procedure TDeadlineStubJob.Cancel;
begin
end;

function TDeadlineStubJob.IsCancelled: Boolean;
begin
  Result := False;
end;

{ TDeadlineHandler }

constructor TDeadlineHandler.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FGate := TEvent.Create(nil, True, False, '');
end;

destructor TDeadlineHandler.Destroy;
begin
  FGate.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDeadlineHandler.Bump(var ACounter: Integer);
begin
  FLock.Acquire;
  try
    Inc(ACounter);
  finally
    FLock.Release;
  end;
end;

function TDeadlineHandler.Get(const ACounter: PInteger): Integer;
begin
  FLock.Acquire;
  try
    Result := ACounter^;
  finally
    FLock.Release;
  end;
end;

procedure TDeadlineHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Path: string;
  Buf: array[0..15] of Byte;
  Until_: QWord;
begin
  Bump(FStarted);
  Path := ARequest.Path;
  try
    if Path = '/fast' then
    begin
      AResponse.SendHeaders(200, nil, False);
      AResponse.Write(BytesOf('ok'));
      AResponse.Finish;
    end
    else if Path = '/read' then
    begin
      Sleep(600);
      ARequest.Read(Buf, SizeOf(Buf));
      AResponse.SendHeaders(200, nil, True);
    end
    else if Path = '/headed' then
    begin
      AResponse.SendHeaders(200, nil, False);
      AResponse.Write(BytesOf('part'));
      Until_ := GetTickCount64 + 3000;
      while (not ARequest.IsCancelled) and (GetTickCount64 < Until_) do
        Sleep(10);
      AResponse.Write(BytesOf('more'));
    end
    else if Path = '/stuck' then
      FGate.WaitFor(8000);
  except
    on EStreamCancelled do
    begin
      Bump(FCancelled);
      raise;
    end;
  end;
  Bump(FReturned);
end;

procedure TDeadlineHandler.OpenGate;
begin
  FGate.SetEvent;
end;

function TDeadlineHandler.Started: Integer;
begin
  Result := Get(@FStarted);
end;

function TDeadlineHandler.Cancelled: Integer;
begin
  Result := Get(@FCancelled);
end;

function TDeadlineHandler.Returned: Integer;
begin
  Result := Get(@FReturned);
end;

function TDeadlineHandler.CancelledRef: PInteger;
begin
  Result := @FCancelled;
end;

function TDeadlineHandler.ReturnedRef: PInteger;
begin
  Result := @FReturned;
end;

{ TDeadlineH2Client }

constructor TDeadlineH2Client.Create(const APort: Integer);
var
  Wire: TBytes;
  Frame: TFrame;
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, WaitMs);
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  FSock.SockSend(@Wire[0], Length(Wire));
  Frame := BuildSettingsFrame(TConnectionSettings.Defaults);
  SendBytes(Frame);
end;

destructor TDeadlineH2Client.Destroy;
begin
  FSock.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure TDeadlineH2Client.SendBytes(const AFrame: TFrame);
var
  Bytes: TBytes;
begin
  SetLength(Bytes, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Bytes);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Bytes[FrameHeaderSize], Length(AFrame.Payload));
  FSock.SockSend(@Bytes[0], Length(Bytes));
  FSock.SockSendFlush();
end;

procedure TDeadlineH2Client.Pump(const AWaitMs: Integer);
var
  Pending: TCrtSocketPending;
begin
  Pending := FSock.SockReceivePending(AWaitMs);
  if Pending in [cspSocketError, cspSocketClosed] then
    Exit;
  FBuf := FBuf + FSock.SockReceiveString;
end;

function TDeadlineH2Client.TakeFrame(out AFrame: TFrame): Boolean;
var
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
begin
  Result := False;
  if Length(FBuf) < FrameHeaderSize then
    Exit;
  SetLength(HeaderBytes, FrameHeaderSize);
  Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
  Header := TFrameHeader.ReadFrom(HeaderBytes);
  N := FrameHeaderSize + Integer(Header.Length);
  if Length(FBuf) < N then
    Exit;
  SetLength(AFrame.Payload, Header.Length);
  if Header.Length > 0 then
    Move(FBuf[FrameHeaderSize + 1], AFrame.Payload[0], Header.Length);
  AFrame.Header := Header;
  FBuf := Copy(FBuf, N + 1, MaxInt);
  Result := True;
end;

procedure TDeadlineH2Client.SendGet(const AStreamId: LongWord;
  const APath: string);
var
  Fields: THeaderBlock;
begin
  SetLength(Fields, 4);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := 'GET';
  Fields[1].Name := HeaderPath;
  Fields[1].Value := APath;
  Fields[2].Name := HeaderScheme;
  Fields[2].Value := 'http';
  Fields[3].Name := HeaderAuthority;
  Fields[3].Value := '127.0.0.1';
  SendBytes(BuildHeadersFrame(AStreamId, FCodec.Encode(Fields), True, True));
end;

function TDeadlineH2Client.WaitStatus(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out AStatus: Integer): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
  Fields: THeaderBlock;
  I: Integer;
begin
  Result := False;
  AStatus := 0;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Pump(20);
    while TakeFrame(Frame) do
      if (Frame.Header.FrameType = ftHeaders) and
         (Frame.Header.StreamId = AStreamId) then
      begin
        Fields := FCodec.Decode(Frame.Payload);
        for I := 0 to High(Fields) do
          if Fields[I].Name = ':status' then
          begin
            AStatus := StrToIntDef(Fields[I].Value, 0);
            Exit(True);
          end;
      end;
  end;
end;

function TDeadlineH2Client.WaitReset(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out ACode: THttp2ErrorCode): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
begin
  Result := False;
  ACode := ecNoError;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while GetTickCount64 < Deadline do
  begin
    Pump(20);
    while TakeFrame(Frame) do
      if (Frame.Header.FrameType = ftRstStream) and
         (Frame.Header.StreamId = AStreamId) then
      begin
        ParseRstStream(Frame, ACode);
        Exit(True);
      end;
  end;
end;

{ THandlerDeadlineTest }

procedure THandlerDeadlineTest.SetUp;
begin
  inherited SetUp;
  FLock := TCriticalSection.Create;
  FHost := TDeadlineNullHost.Create;
  FStreams := TObjectList<TServerStream>.Create(True);
  FHandler := TDeadlineHandler.Create;
  FHandlerRef := FHandler;
  FObserver := TDeadlineObserver.Create;
  FObserverRef := FObserver;
  FPool := nil;
  FServer := nil;
  FExpired := 0;
  FJobExpired := 0;
end;

procedure THandlerDeadlineTest.TearDown;
begin
  FHandler.OpenGate;
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FreeAndNil(FPool);
  FStreams.Free;
  FObserverRef := nil;
  FHandlerRef := nil;
  FHost := nil;
  FLock.Free;
  inherited TearDown;
end;

procedure THandlerDeadlineTest.OnExpired(const AStream: TServerStream);
begin
  Inc(FExpired);
end;

procedure THandlerDeadlineTest.OnJobExpired(const AJob: IHandlerJob);
begin
  Inc(FJobExpired);
end;

function THandlerDeadlineTest.NewStream(const AStreamId: LongWord;
  const APath: string): TServerStream;
var
  Fields: THeaderBlock;
begin
  Result := TServerStream.Create(AStreamId, FLock, FHost, 65536, 65536);
  FStreams.Add(Result);
  SetLength(Fields, 1);
  Fields[0].Name := HeaderPath;
  Fields[0].Value := APath;
  Result.SetRemoteHeaders(Fields);
  // a request without a body: the handler read ends at once
  Result.MarkRemoteEnded;
end;

procedure THandlerDeadlineTest.WaitFor(const ACounter: PInteger;
  const AWanted: Integer);
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + WaitMs;
  while (ACounter^ < AWanted) and (GetTickCount64 < Deadline) do
    Sleep(5);
end;

procedure THandlerDeadlineTest.StartPool(const ALimitMs: Integer);
begin
  FPool := THandlerPool.Create(THttp2ServerFactory.Create
    .WithHandlerThreads(2)
    .WithQueue(TQueueOptions.Create.WithDepth(8).WithMaxWaitMs(600000)
      .WithRefusalMode(rmRefuseStream))
    .WithServerLimits(TServerLimits.Create.WithMaxHandlerTimeMs(ALimitMs))
    .WithGracefulStopTimeout(500)
    .WithHandler(FHandlerRef));
  FPool.Observer := FObserverRef;
end;

procedure THandlerDeadlineTest.StartServer(const ALimitMs: Integer);
begin
  FServer := LiveFactory(FHandlerRef).WithMaxConcurrentStreams(1)
    .WithServerLimits(TServerLimits.Create.WithMaxHandlerTimeMs(ALimitMs))
    .Build(FObserverRef);
  FServer.Start;
end;

function THandlerDeadlineTest.WaitEvents(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (FObserver.Count < ACount) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := FObserver.Count >= ACount;
end;

function THandlerDeadlineTest.WaitCancelled(const AStream: TServerStream;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (not AStream.IsCancelled) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := AStream.IsCancelled;
end;

procedure THandlerDeadlineTest.TestSweepFiresOnceAndCountsStuck;
var
  Deadlines: THandlerDeadlines;
  Stream: TServerStream;
begin
  Deadlines := THandlerDeadlines.Create;
  try
    Stream := NewStream(1, '/x');
    Deadlines.Register(Stream, 1000);
    Deadlines.Sweep(1299, 300, OnExpired);
    AssertEquals('the stream is before its limit', 0, FExpired);
    AssertEquals('nothing is stuck yet', 0, Deadlines.StuckCount);
    Deadlines.Sweep(1300, 300, OnExpired);
    AssertEquals('the stream expires at the limit', 1, FExpired);
    AssertEquals('the handler counts as stuck', 1, Deadlines.StuckCount);
    Deadlines.Sweep(2000, 300, OnExpired);
    AssertEquals('the stream expires once', 1, FExpired);
    AssertEquals('the count stays at 1', 1, Deadlines.StuckCount);
    Deadlines.Unregister(Stream);
    AssertEquals('the return of the handler clears the count', 0,
      Deadlines.StuckCount);
  finally
    Deadlines.Free;
  end;
end;

procedure THandlerDeadlineTest.TestUnregisterBeforeTheLimitNeverFires;
var
  Deadlines: THandlerDeadlines;
  Stream: TServerStream;
begin
  Deadlines := THandlerDeadlines.Create;
  try
    Stream := NewStream(1, '/x');
    Deadlines.Register(Stream, 1000);
    Deadlines.Unregister(Stream);
    Deadlines.Sweep(5000, 300, OnExpired);
    AssertEquals('a finished handler never expires', 0, FExpired);
    AssertEquals('nothing is stuck', 0, Deadlines.StuckCount);
  finally
    Deadlines.Free;
  end;
end;

procedure THandlerDeadlineTest.TestLimitZeroFiresNothing;
var
  Deadlines: THandlerDeadlines;
  Stream: TServerStream;
begin
  Deadlines := THandlerDeadlines.Create;
  try
    Stream := NewStream(1, '/x');
    Deadlines.Register(Stream, 1000);
    Deadlines.Sweep(900000, 0, OnExpired);
    AssertEquals('a limit of 0 expires nothing', 0, FExpired);
    AssertEquals('nothing is stuck', 0, Deadlines.StuckCount);
    Deadlines.Unregister(Stream);
  finally
    Deadlines.Free;
  end;
end;

procedure THandlerDeadlineTest.TestJobExpiresOnce;
var
  Deadlines: THandlerDeadlines;
  Job: IHandlerJob;
begin
  Deadlines := THandlerDeadlines.Create;
  try
    Job := TDeadlineStubJob.Create;
    Deadlines.RegisterJob(Job, 1000);
    Deadlines.Sweep(1300, 300, OnExpired, OnJobExpired);
    Deadlines.Sweep(1900, 300, OnExpired, OnJobExpired);
    AssertEquals('the job expires once', 1, FJobExpired);
    AssertEquals('no stream expires', 0, FExpired);
    AssertEquals('the job counts as stuck', 1, Deadlines.StuckCount);
    Deadlines.UnregisterJob(Job);
    AssertEquals('the return of the job clears the count', 0,
      Deadlines.StuckCount);
  finally
    Deadlines.Free;
  end;
end;

procedure THandlerDeadlineTest.TestPoolAnswers503AndCancelsTheHandlerSide;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  StartPool(LimitMs);
  Stream := NewStream(1, '/read');
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the observer hears the timeout', WaitEvents(1, 3000));
  AssertEquals('the event names the stream', 1, Integer(FObserver.IdAt(0)));
  AssertTrue('the stream has a queued answer',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the answer is 503', 503, Status);
  AssertTrue('the 503 ends the response', EndStream);
  AssertTrue('the stream is cancelled', WaitCancelled(Stream, 1000));
  AssertEquals('the reset code is CANCEL', Ord(ecCancel), Ord(Stream.ResetCode));
  WaitFor(FHandler.CancelledRef, 1);
  AssertEquals('the handler saw the cancel on its read', 1,
    FHandler.Cancelled);
end;

procedure THandlerDeadlineTest.TestPoolResetsAStreamWithAHeadOut;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  StartPool(LimitMs);
  Stream := NewStream(3, '/headed');
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the observer hears the timeout', WaitEvents(1, 3000));
  AssertTrue('the stream is cancelled', WaitCancelled(Stream, 1000));
  AssertEquals('the reset code is CANCEL', Ord(ecCancel), Ord(Stream.ResetCode));
  AssertTrue('the handler head is the only head',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('no 503 follows the 200', 200, Status);
  AssertFalse('no second head is queued', Stream.HasPendingHeaders);
end;

procedure THandlerDeadlineTest.TestPoolCountsAHandlerThatIgnoresTheCancel;
var
  First, Second: TServerStream;
begin
  StartPool(LimitMs);
  First := NewStream(5, '/stuck');
  AssertEquals('the first request queues', Ord(asQueued), Ord(FPool.Admit(First)));
  AssertTrue('the observer hears the first timeout', WaitEvents(1, 3000));
  AssertEquals('the stuck handler is counted', 1, FObserver.StuckAt(0));
  // the second worker still serves
  Second := NewStream(7, '/stuck');
  AssertEquals('the second request queues', Ord(asQueued),
    Ord(FPool.Admit(Second)));
  AssertTrue('the second timeout comes', WaitEvents(2, 3000));
  AssertEquals('two handlers are past the limit', 2, FObserver.StuckAt(1));
  FHandler.OpenGate;
  WaitFor(FHandler.ReturnedRef, 2);
  AssertEquals('both stuck handlers return', 2, FHandler.Returned);
end;

procedure THandlerDeadlineTest.TestPoolLimitZeroChangesNothing;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  StartPool(0);
  Stream := NewStream(1, '/read');
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  WaitFor(FHandler.ReturnedRef, 1);
  AssertEquals('the slow handler returns', 1, FHandler.Returned);
  AssertEquals('no timeout event', 0, FObserver.Count);
  AssertFalse('the stream is not cancelled', Stream.IsCancelled);
  AssertTrue('the answer is the handler answer',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the status is 200', 200, Status);
end;

procedure THandlerDeadlineTest.TestH2SlowHandlerGets503AndTheSlotFrees;
var
  Client: TDeadlineH2Client;
  Status: Integer;
  Code: THttp2ErrorCode;
begin
  StartServer(LimitMs);
  Client := TDeadlineH2Client.Create(FServer.Port);
  try
    Client.SendGet(1, '/read');
    AssertTrue('the client gets a head within 1 s',
      Client.WaitStatus(1, 1000, Status));
    AssertEquals('the head is 503', 503, Status);
    AssertTrue('the stream is reset after the 503',
      Client.WaitReset(1, 2000, Code));
    AssertEquals('the code is CANCEL', Ord(ecCancel), Ord(Code));
    AssertTrue('the observer hears the timeout', WaitEvents(1, 2000));
    // the limit of one stream is free again: the next request is served
    Client.SendGet(3, '/fast');
    AssertTrue('the second request gets a head',
      Client.WaitStatus(3, WaitMs, Status));
    AssertEquals('the second request is served', 200, Status);
  finally
    Client.Free;
  end;
end;

procedure THandlerDeadlineTest.TestH2HeadedHandlerGetsAReset;
var
  Client: TDeadlineH2Client;
  Status: Integer;
  Code: THttp2ErrorCode;
begin
  StartServer(LimitMs);
  Client := TDeadlineH2Client.Create(FServer.Port);
  try
    Client.SendGet(1, '/headed');
    AssertTrue('the head arrives', Client.WaitStatus(1, WaitMs, Status));
    AssertEquals('the head is the handler head', 200, Status);
    AssertTrue('the stream is reset at the limit',
      Client.WaitReset(1, 2000, Code));
    AssertEquals('the code is CANCEL', Ord(ecCancel), Ord(Code));
    WaitFor(FHandler.CancelledRef, 1);
    AssertEquals('the handler saw the cancel', 1, FHandler.Cancelled);
  finally
    Client.Free;
  end;
end;

procedure THandlerDeadlineTest.TestH2StuckHandlerFreesTheSlotAndIsCounted;
var
  Client: TDeadlineH2Client;
  Status: Integer;
  Deadline: QWord;
begin
  StartServer(LimitMs);
  Client := TDeadlineH2Client.Create(FServer.Port);
  try
    Client.SendGet(1, '/stuck');
    AssertTrue('the client gets a head', Client.WaitStatus(1, 1500, Status));
    AssertEquals('the head is 503', 503, Status);
    AssertTrue('the observer hears the timeout', WaitEvents(1, 2000));
    AssertEquals('one handler is stuck', 1, FObserver.StuckAt(0));
    Client.SendGet(3, '/fast');
    AssertTrue('the second request gets a head on the same connection',
      Client.WaitStatus(3, WaitMs, Status));
    AssertEquals('the second request is served', 200, Status);
    // the /fast handler counts its return after its head reached the client
    Deadline := GetTickCount64 + WaitMs;
    while (FHandler.Returned < 1) and (GetTickCount64 < Deadline) do
      Sleep(5);
    // settle: the stuck handler must not return in this short window either
    Sleep(50);
    // only the /fast handler has returned; the stuck one still waits
    AssertEquals('the stuck handler still runs', 1, FHandler.Returned);
  finally
    Client.Free;
  end;
end;

procedure THandlerDeadlineTest.TestH1SlowHandlerGets503;
var
  Client: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LimitMs);
  Client := TRawHttp.Create(FServer.Port);
  try
    Client.Send('GET /read HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('the client gets an answer within 1 s',
      Client.ReadResponse(False, 1000, R));
    AssertEquals('the answer is 503', 503, R.Status);
    AssertTrue('the connection closes', Client.WaitClosed(WaitMs));
    AssertTrue('the observer hears the timeout', WaitEvents(1, 2000));
  finally
    Client.Free;
  end;
end;

procedure THandlerDeadlineTest.TestH1HeadedHandlerLosesTheConnection;
var
  Client: TRawHttp;
  R: TRawResponse;
  Rest: string;
begin
  StartServer(LimitMs);
  Client := TRawHttp.Create(FServer.Port);
  try
    Client.Send('GET /headed HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('the head arrives', Client.ReadHead(WaitMs, R));
    AssertEquals('the head is the handler head', 200, R.Status);
    AssertTrue('the connection closes at the limit', Client.WaitClosed(3000));
    Rest := Client.ReadSome(10);
    AssertTrue('the chunked body does not end cleanly',
      Pos('0' + CRLF + CRLF, Rest) = 0);
    AssertTrue('the observer hears the timeout', WaitEvents(1, 2000));
  finally
    Client.Free;
  end;
end;

procedure THandlerDeadlineTest.TestH1StuckHandlerIsCountedAndTheServerServes;
var
  First, Second: TRawHttp;
  R: TRawResponse;
begin
  StartServer(LimitMs);
  First := TRawHttp.Create(FServer.Port);
  Second := TRawHttp.Create(FServer.Port);
  try
    First.Send('GET /stuck HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('the stuck request gets an answer',
      First.ReadResponse(False, 1500, R));
    AssertEquals('the answer is 503', 503, R.Status);
    AssertTrue('the observer hears the timeout', WaitEvents(1, 2000));
    AssertEquals('one handler is stuck', 1, FObserver.StuckAt(0));
    Second.Send('GET /fast HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('a new connection is served', Second.ReadResponse(False, WaitMs, R));
    AssertEquals('the new request is served', 200, R.Status);
  finally
    Second.Free;
    First.Free;
  end;
end;

initialization
  RegisterTest(THandlerDeadlineTest);

end.
