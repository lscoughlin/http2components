{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, server, handler exception, 500, request body, keep-alive, test
notes:
  - This unit holds the live HTTP/1.1 tests of an uncaught handler exception. A
    live server runs the handler pool and the connection, and a raw client sends
    the request and reads the response.
  - The tests of the unread body use two sizes: a body under the drain bound
    keeps the connection alive, and a body over the bound closes it.
  - The HTTP/2 tests are in Http2.Server.HandlerException.Test.
---
}
/// Live HTTP/1.1 tests of an uncaught handler exception
unit Http2.Server.HandlerException.Http1.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Server, Http2.Server.Errors, Http2.Server.Http1.RawClient;

type
  /// what the failing handler does before it raises
  THttp1ExceptionMode = (
    /// raise at once, before a response head
    h1emRaiseNow,
    /// send a chunked head and a partial body, then raise
    h1emHeadThenRaise,
    /// read the first 512 KiB of the request body, then raise
    h1emReadHalfThenRaise);

  /// a handler that raises an exception with a secret message
  THttp1ExceptionRaiser = class(TInterfacedObject, IHttp2Handler)
  private
    FMode: THttp1ExceptionMode;
  public
    constructor Create(const AMode: THttp1ExceptionMode);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a handler that answers 200 with the body 'ok'
  THttp1ExceptionOk = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// an observer that counts the handler exception events
  THttp1ExceptionObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FExceptions: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    function Exceptions: Integer;
  end;

  /// the live tests of the handler exception policy for HTTP/1.1
  THttp1HandlerExceptionTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FObserver: THttp1ExceptionObserver;
    FObserverRef: IHttp2ServerObserver;
    procedure StartServer(const AMode: THttp1ExceptionMode);
    function PostWithBody(const APath: string; const ABytes: Integer): string;
    function WaitIdle(const ATimeoutMs: Integer): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestRaiseBeforeHeadAnswers500WithoutTheMessage;
    procedure TestRaiseBeforeHeadKeepsTheConnectionForASmallBody;
    procedure TestRaiseBeforeHeadClosesForABodyOverTheBound;
    procedure TestRaiseAfterHeadCutsTheResponse;
    procedure TestRaiseWhileBodyHalfReadCloses;
    procedure TestHundredFailingRequestsOnOneConnection;
    procedure TestObserverCountsEachException;
  end;

const
  /// the message of the exception; it must never reach the peer
  Http1ExceptionSecret = 'secret-internal-7741';
  /// a request body under the drain bound of 256 KiB
  Http1SmallBody = 200 * 1024;
  /// a request body over the drain bound of 256 KiB
  Http1LargeBody = 1024 * 1024;
  /// the wait of a test step, in milliseconds
  Http1StepMs = 5000;

implementation

const
  /// the octets that the handler reads before it raises in the half-read test
  Http1HalfReadBytes = 524288;
  /// the size of one read of the handler
  Http1ReadChunk = 16384;

/// the raw bytes of a text literal
function OctetsOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

{ THttp1ExceptionRaiser }

constructor THttp1ExceptionRaiser.Create(const AMode: THttp1ExceptionMode);
begin
  inherited Create;
  FMode := AMode;
end;

procedure THttp1ExceptionRaiser.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: array[0..Http1ReadChunk - 1] of Byte;
  Got, N: Integer;
  Part: TBytes;
begin
  case FMode of
    h1emHeadThenRaise:
      begin
        AResponse.SendHeaders(200, nil, False);
        Part := OctetsOf('part');
        AResponse.Write(Part);
      end;
    h1emReadHalfThenRaise:
      begin
        Got := 0;
        while Got < Http1HalfReadBytes do
        begin
          N := ARequest.Read(Buf[0], Http1ReadChunk);
          if N <= 0 then
            Break;
          Inc(Got, N);
        end;
      end;
  end;
  raise Exception.Create(Http1ExceptionSecret);
end;

{ THttp1ExceptionOk }

procedure THttp1ExceptionOk.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Part: TBytes;
begin
  AResponse.SendHeaders(200, nil, False);
  Part := OctetsOf('ok');
  AResponse.Write(Part);
  AResponse.Finish;
end;

{ THttp1ExceptionObserver }

constructor THttp1ExceptionObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor THttp1ExceptionObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure THttp1ExceptionObserver.OnEvent(const AEvent: TServerEvent);
begin
  if AEvent.Kind <> seHandlerException then
    Exit;
  FLock.Acquire;
  try
    Inc(FExceptions);
  finally
    FLock.Release;
  end;
end;

function THttp1ExceptionObserver.Exceptions: Integer;
begin
  FLock.Acquire;
  try
    Result := FExceptions;
  finally
    FLock.Release;
  end;
end;

{ THttp1HandlerExceptionTest }

procedure THttp1HandlerExceptionTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FObserverRef := nil;
  inherited TearDown;
end;

procedure THttp1HandlerExceptionTest.StartServer(const AMode: THttp1ExceptionMode);
var
  Factory: THttp2ServerFactory;
begin
  FObserver := THttp1ExceptionObserver.Create;
  FObserverRef := FObserver;
  Factory := LiveFactory(THttp1ExceptionRaiser.Create(AMode))
    .WithHandlerThreads(2)
    .WithIOThreads(2);
  FServer := Factory.Build(FObserverRef);
  FServer.Start;
end;

function THttp1HandlerExceptionTest.PostWithBody(const APath: string;
  const ABytes: Integer): string;
begin
  Result := 'POST ' + APath + ' HTTP/1.1' + CRLF + 'Host: a' + CRLF +
    'Content-Length: ' + IntToStr(ABytes) + CRLF + CRLF +
    StringOfChar('x', ABytes);
end;

function THttp1HandlerExceptionTest.WaitIdle(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if FServer.Stats.OpenStreams = 0 then
      Exit(True);
    Sleep(10);
  until GetTickCount64 >= Deadline;
  Result := FServer.Stats.OpenStreams = 0;
end;

procedure THttp1HandlerExceptionTest.TestRaiseBeforeHeadAnswers500WithoutTheMessage;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(h1emRaiseNow);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /fail HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('no response arrived', C.ReadResponse(False, Http1StepMs, R));
    AssertEquals('a raise before the head gives 500', 500, R.Status);
    AssertEquals('the 500 body is empty', 0, Length(R.Body));
    AssertEquals('the exception text never reaches the peer', 0,
      Pos(Http1ExceptionSecret, R.Head + R.Body));
  finally
    C.Free;
  end;
end;

procedure THttp1HandlerExceptionTest.TestRaiseBeforeHeadKeepsTheConnectionForASmallBody;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(h1emRaiseNow);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(PostWithBody('/upload', Http1SmallBody));
    AssertTrue('no response arrived', C.ReadResponse(False, Http1StepMs, R));
    AssertEquals('a raise before the head gives 500', 500, R.Status);
    AssertFalse('the body was drained, so the connection stays open', R.Closed);
    // the second request is answered on the same connection
    C.Send('GET /ok HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('the second request got no response on the same connection',
      C.ReadResponse(False, Http1StepMs, R));
    AssertEquals('the second request is served', 500, R.Status);
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(Http1StepMs));
end;

procedure THttp1HandlerExceptionTest.TestRaiseBeforeHeadClosesForABodyOverTheBound;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(h1emRaiseNow);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(PostWithBody('/upload', Http1LargeBody));
    AssertTrue('no response arrived', C.ReadResponse(False, Http1StepMs, R));
    AssertEquals('a raise before the head gives 500', 500, R.Status);
    AssertTrue('a body over the drain bound closes the connection',
      R.Closed or C.WaitClosed(Http1StepMs));
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(Http1StepMs));
end;

procedure THttp1HandlerExceptionTest.TestRaiseAfterHeadCutsTheResponse;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(h1emHeadThenRaise);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /cut HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertFalse('the chunked body is cut, so it is not read as complete',
      C.ReadResponse(False, Http1StepMs, R));
    AssertEquals('the head that went out keeps its status', 200, R.Status);
    AssertTrue('the connection closes after the cut response',
      C.WaitClosed(Http1StepMs));
    AssertEquals('the exception text never reaches the peer', 0,
      Pos(Http1ExceptionSecret, R.Head + R.Body));
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(Http1StepMs));
end;

procedure THttp1HandlerExceptionTest.TestRaiseWhileBodyHalfReadCloses;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(h1emReadHalfThenRaise);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(PostWithBody('/half', Http1LargeBody));
    AssertTrue('no response arrived', C.ReadResponse(False, Http1StepMs, R));
    AssertEquals('a raise after a half read gives 500', 500, R.Status);
    AssertTrue('the unread part is over the bound, so the connection closes',
      R.Closed or C.WaitClosed(Http1StepMs));
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(Http1StepMs));
end;

procedure THttp1HandlerExceptionTest.TestHundredFailingRequestsOnOneConnection;
var
  C: TRawHttp;
  R: TRawResponse;
  I: Integer;
begin
  StartServer(h1emRaiseNow);
  C := TRawHttp.Create(FServer.Port);
  try
    for I := 0 to 99 do
    begin
      C.Send(PostWithBody('/loop', 4096));
      AssertTrue('request ' + IntToStr(I) + ' got no response',
        C.ReadResponse(False, Http1StepMs, R));
      AssertEquals('request ' + IntToStr(I) + ' is a 500', 500, R.Status);
    end;
  finally
    C.Free;
  end;
  AssertTrue('streams are left open after 100 failures', WaitIdle(Http1StepMs));
  AssertEquals('one exception per request', 100, FObserver.Exceptions);
end;

procedure THttp1HandlerExceptionTest.TestObserverCountsEachException;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  StartServer(h1emRaiseNow);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET /one HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('no response arrived', C.ReadResponse(False, Http1StepMs, R));
    AssertEquals(500, R.Status);
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(Http1StepMs));
  AssertEquals('the observer counts the exception', 1, FObserver.Exceptions);
end;

initialization
  RegisterTest(THttp1HandlerExceptionTest);
end.
