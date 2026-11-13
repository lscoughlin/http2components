{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, handler error, admission, test
notes:
  - This unit holds the pool-level tests of the handler error policy.  A
    handler that raises before its first write gets a 500 response.  A
    handler that raises after its headers gets a stream reset with
    INTERNAL_ERROR.
  - The tests drive THandlerPool with fake streams.  They do not run a
    connection, so they check the stream state and not the frames on the wire.
---
}
/// Tests of the handler error policy of the handler pool
unit Http2.Server.HandlerError.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Server.Errors, Http2.Common.Errors, Http2.Server.Seam,
  Http2.Server.Stream, Http2.Server.StreamHost,
  Http2.Server.Limits, Http2.Server.Config, Http2.Common.Hpack,
  Http2.Server.Admission, Http2.Server.StreamAdapters, Http2.Server.Observer;

type
  /// a stream host that ignores the window credit
  THandlerErrorNullHost = class(TInterfacedObject, IStreamHost)
  public
    procedure WindowUpdatePending(const AStreamId: LongWord;
      const AIncrement: LongWord);
    procedure OutputPending(const AStreamId: LongWord);
  end;

  /// a handler that raises, before or after it sends the headers
  THandlerErrorRaiser = class(TInterfacedObject, IHttp2Handler)
  private
    FSendHeaders: Boolean;
  public
    constructor Create(const ASendHeaders: Boolean);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// counts the handler exceptions and the completed streams
  THandlerErrorObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FExceptions: Integer;
    FCompleted: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    function Exceptions: Integer;
    function Completed: Integer;
  end;

  /// what a returning handler does before it returns
  THandlerReturnMode = (hrmNothing, hrmHeadAndData, hrmFinish, hrmHeadEnded);

  /// a handler that returns, and does not raise
  THandlerErrorReturner = class(TInterfacedObject, IHttp2Handler)
  private
    FMode: THandlerReturnMode;
  public
    constructor Create(const AMode: THandlerReturnMode);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// tests of the handler error policy of THandlerPool
  THandlerErrorTest = class(TTestCase)
  private
    FLock: TCriticalSection;
    FHost: IStreamHost;
    FClock: TManualMonotonicClock;
    FPool: THandlerPool;
    FObserver: THandlerErrorObserver;
    FObserverRef: IHttp2ServerObserver;
    FFactory: THttp2ServerFactory;
    FStreams: TObjectList<TServerStream>;
    FErrorCount: Integer;
    FErrorStreamId: LongWord;
    FErrorBeforeHeaders: Boolean;
    function NewStream(const AStreamId: LongWord): TServerStream;
    procedure Configure(const ADepth: Integer; const AHandler: IHttp2Handler);
    function WaitCompleted(const ATimeoutMs: Integer): Boolean;
    function WaitErrors(const ACount, ATimeoutMs: Integer): Boolean;
    procedure HandleError(const AStream: TServerStream;
      const ABeforeHeaders: Boolean);
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRaiseBeforeWriteAnswers500;
    procedure TestRaiseAfterHeadersResetsWithInternalError;
    procedure TestHundredFailingStreamsEachEnd;
    procedure TestErrorEventStillFires;
    procedure TestReturnWithoutAnyWriteAnswers500;
    procedure TestReturnAfterHeadAndDataResetsWithInternalError;
    procedure TestReturnAfterFinishIsNotTouched;
    procedure TestReturnAfterHeadWithEndStreamIsNotTouched;
  end;

implementation

{ THandlerErrorNullHost }

procedure THandlerErrorNullHost.WindowUpdatePending(const AStreamId: LongWord;
  const AIncrement: LongWord);
begin
end;

procedure THandlerErrorNullHost.OutputPending(const AStreamId: LongWord);
begin
end;

{ THandlerErrorRaiser }

constructor THandlerErrorRaiser.Create(const ASendHeaders: Boolean);
begin
  inherited Create;
  FSendHeaders := ASendHeaders;
end;

procedure THandlerErrorRaiser.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  if FSendHeaders then
    AResponse.SendHeaders(200, nil, False);
  raise EHttpError.Create('the handler failed');
end;

{ THandlerErrorObserver }

constructor THandlerErrorObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor THandlerErrorObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure THandlerErrorObserver.OnEvent(const AEvent: TServerEvent);
begin
  FLock.Acquire;
  try
    if AEvent.Kind = seHandlerException then
      Inc(FExceptions)
    else if AEvent.Kind = seStreamCompleted then
      Inc(FCompleted);
  finally
    FLock.Release;
  end;
end;

function THandlerErrorObserver.Exceptions: Integer;
begin
  FLock.Acquire;
  try
    Result := FExceptions;
  finally
    FLock.Release;
  end;
end;

function THandlerErrorObserver.Completed: Integer;
begin
  FLock.Acquire;
  try
    Result := FCompleted;
  finally
    FLock.Release;
  end;
end;

{ THandlerErrorReturner }

constructor THandlerErrorReturner.Create(const AMode: THandlerReturnMode);
begin
  inherited Create;
  FMode := AMode;
end;

procedure THandlerErrorReturner.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Data: TBytes;
begin
  case FMode of
    hrmHeadAndData:
    begin
      AResponse.SendHeaders(200, nil, False);
      SetLength(Data, 1);
      Data[0] := 65;
      AResponse.Write(Data);
    end;
    hrmFinish:
    begin
      AResponse.SendHeaders(200, nil, False);
      AResponse.Finish;
    end;
    hrmHeadEnded:
      AResponse.SendHeaders(204, nil, True);
  end;
end;

{ THandlerErrorTest }

procedure THandlerErrorTest.SetUp;
begin
  inherited SetUp;
  FLock := TCriticalSection.Create;
  FHost := THandlerErrorNullHost.Create;
  FClock := TManualMonotonicClock.Create(0);
  FStreams := TObjectList<TServerStream>.Create(True);
  FObserver := THandlerErrorObserver.Create;
  FObserverRef := FObserver;
  FPool := nil;
  FErrorCount := 0;
  FErrorStreamId := 0;
  FErrorBeforeHeaders := False;
end;

procedure THandlerErrorTest.TearDown;
begin
  FreeAndNil(FPool);
  FObserverRef := nil;
  FObserver := nil;
  FStreams.Free;
  FClock := nil;
  FHost := nil;
  FLock.Free;
  inherited TearDown;
end;

function THandlerErrorTest.NewStream(const AStreamId: LongWord): TServerStream;
begin
  Result := TServerStream.Create(AStreamId, FLock, FHost, 65536, 65536);
  FStreams.Add(Result);
end;

procedure THandlerErrorTest.Configure(const ADepth: Integer;
  const AHandler: IHttp2Handler);
begin
  FFactory := THttp2ServerFactory.Create
    .WithHandlerThreads(1)
    .WithQueue(TQueueOptions.Create
      .WithDepth(ADepth)
      .WithMaxWaitMs(600000)
      .WithRefusalMode(rmRefuseStream))
    .WithClock(FClock)
    .WithGracefulStopTimeout(500)
    .WithHandler(AHandler);
  FPool := THandlerPool.Create(FFactory);
  FPool.Observer := FObserverRef;
  FPool.OnHandlerError := HandleError;
end;

function THandlerErrorTest.WaitCompleted(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (FObserver.Completed < 1) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := FObserver.Completed >= 1;
end;

function THandlerErrorTest.WaitErrors(const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (FErrorCount < ACount) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := FErrorCount >= ACount;
end;

procedure THandlerErrorTest.HandleError(const AStream: TServerStream;
  const ABeforeHeaders: Boolean);
begin
  Inc(FErrorCount);
  FErrorStreamId := AStream.StreamId;
  FErrorBeforeHeaders := ABeforeHeaders;
end;

procedure THandlerErrorTest.TestRaiseBeforeWriteAnswers500;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  Configure(4, THandlerErrorRaiser.Create(False));
  Stream := NewStream(1);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitErrors(1, 2000));
  AssertTrue('the error is before the headers', FErrorBeforeHeaders);
  AssertTrue('the stream has a queued response', Stream.HasPendingHeaders);
  AssertTrue('the queued response is taken',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the response is a 500', 500, Status);
  AssertTrue('the 500 ends the stream', EndStream);
  AssertFalse('the stream is not reset', Stream.IsCancelled);
end;

procedure THandlerErrorTest.TestRaiseAfterHeadersResetsWithInternalError;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  Configure(4, THandlerErrorRaiser.Create(True));
  Stream := NewStream(3);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitErrors(1, 2000));
  AssertFalse('the error is after the headers', FErrorBeforeHeaders);
  AssertTrue('the stream is reset', Stream.IsCancelled);
  AssertEquals('the reset code is INTERNAL_ERROR', Ord(ecInternalError),
    Ord(Stream.ResetCode));
  // the handler sent the 200 before the error; no second HEADERS block
  AssertTrue('the handler headers are still pending',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the pending block is the handler 200', 200, Status);
end;

procedure THandlerErrorTest.TestHundredFailingStreamsEachEnd;
var
  I: Integer;
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  Configure(128, THandlerErrorRaiser.Create(False));
  for I := 1 to 100 do
  begin
    Stream := NewStream(LongWord(2 * I - 1));
    AssertEquals('stream queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  end;
  AssertTrue('all 100 error hooks run', WaitErrors(100, 10000));
  AssertEquals('no handler is still busy', 0, FPool.BusyHandlers);
  for I := 0 to FStreams.Count - 1 do
  begin
    AssertTrue('each failing stream has a 500',
      FStreams[I].TakePendingHeaders(Status, Headers, EndStream));
    AssertEquals('each response is a 500', 500, Status);
  end;
end;

procedure THandlerErrorTest.TestErrorEventStillFires;
var
  Stream: TServerStream;
begin
  Configure(4, THandlerErrorRaiser.Create(False));
  Stream := NewStream(7);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitErrors(1, 2000));
  AssertEquals('the hook names the stream', 7, Integer(FErrorStreamId));
  AssertEquals('the hook runs once', 1, FErrorCount);
end;

procedure THandlerErrorTest.TestReturnWithoutAnyWriteAnswers500;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  Configure(4, THandlerErrorReturner.Create(hrmNothing));
  Stream := NewStream(1);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitErrors(1, 2000));
  AssertTrue('the error is before the headers', FErrorBeforeHeaders);
  AssertTrue('the queued response is taken',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the response is a 500', 500, Status);
  AssertTrue('the 500 ends the stream', EndStream);
  AssertFalse('the stream is not reset', Stream.IsCancelled);
  AssertTrue('the pool goes idle', WaitCompleted(2000));
  AssertEquals('the hook runs once', 1, FErrorCount);
  AssertEquals('the observer sees one exception', 1, FObserver.Exceptions);
end;

procedure THandlerErrorTest.TestReturnAfterHeadAndDataResetsWithInternalError;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  Configure(4, THandlerErrorReturner.Create(hrmHeadAndData));
  Stream := NewStream(3);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the error hook runs', WaitErrors(1, 2000));
  AssertFalse('the error is after the headers', FErrorBeforeHeaders);
  AssertTrue('the stream is reset', Stream.IsCancelled);
  AssertEquals('the reset code is INTERNAL_ERROR', Ord(ecInternalError),
    Ord(Stream.ResetCode));
  AssertTrue('the handler head is still pending',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the pending block is the handler 200', 200, Status);
  AssertFalse('the head does not end the stream', EndStream);
  AssertFalse('no finish was requested', Stream.WantsFinish);
  AssertTrue('the pool goes idle', WaitCompleted(2000));
  AssertEquals('the hook runs once', 1, FErrorCount);
  AssertEquals('the observer sees one exception', 1, FObserver.Exceptions);
end;

procedure THandlerErrorTest.TestReturnAfterFinishIsNotTouched;
var
  Stream: TServerStream;
begin
  Configure(4, THandlerErrorReturner.Create(hrmFinish));
  Stream := NewStream(5);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the pool goes idle', WaitCompleted(2000));
  AssertEquals('no error is reported', 0, FErrorCount);
  AssertEquals('the observer sees no exception', 0, FObserver.Exceptions);
  AssertFalse('the stream is not reset', Stream.IsCancelled);
  AssertTrue('the finish is requested', Stream.WantsFinish);
end;

procedure THandlerErrorTest.TestReturnAfterHeadWithEndStreamIsNotTouched;
var
  Stream: TServerStream;
  Status: Integer;
  Headers: THeaderBlock;
  EndStream: Boolean;
begin
  Configure(4, THandlerErrorReturner.Create(hrmHeadEnded));
  Stream := NewStream(9);
  AssertEquals('the request queues', Ord(asQueued), Ord(FPool.Admit(Stream)));
  AssertTrue('the pool goes idle', WaitCompleted(2000));
  AssertEquals('no error is reported', 0, FErrorCount);
  AssertEquals('the observer sees no exception', 0, FObserver.Exceptions);
  AssertFalse('the stream is not reset', Stream.IsCancelled);
  AssertTrue('the head is pending',
    Stream.TakePendingHeaders(Status, Headers, EndStream));
  AssertEquals('the head is the handler 204', 204, Status);
end;

initialization
  RegisterTest(THandlerErrorTest);

end.
