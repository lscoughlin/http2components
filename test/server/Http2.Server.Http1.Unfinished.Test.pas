{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, live, handler error, unfinished response, test, fpcunit
notes:
  - This unit tests a handler that returns and does not end its response, on a
    running server over cleartext with a raw-socket client.
  - A handler that sent no head gets a 500 and the connection closes. A handler
    that sent the head gets a cut response and a close. The client never sees a
    complete response.
  - The observer sees one handler exception for each case.
---
}
/// Live tests of a handler that returns without Finish on HTTP/1.1
unit Http2.Server.Http1.Unfinished.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Server, Http2.Server.Errors, Http2.Server.Observer,
  Http2.Server.Http1.RawClient;

type
  /// counts the handler exceptions and the completed requests
  THttp1UnfinishedObserver = class(TInterfacedObject, IHttp2ServerObserver)
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

  /// a handler that returns; the path selects what it did before
  THttp1UnfinishedHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  THttp1UnfinishedTest = class(TTestCase)
  private
    FObserver: THttp1UnfinishedObserver;
    FObserverRef: IHttp2ServerObserver;
    FHandlerRef: IHttp2Handler;
    FServer: IHttp2Server;
    function Start: Integer;
    function WaitCompleted(const ACount, ATimeoutMs: Integer): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestReturnWithoutAnyWriteGets500AndClose;
    procedure TestReturnAfterHeadAndDataCutsTheResponse;
    procedure TestReturnAfterAllContentLengthOctetsCutsTheResponse;
    procedure TestReturnAfterFinishKeepsTheConnection;
    procedure TestRaiseAfterHeadCutsTheResponseAndRaisesOneEvent;
  end;

implementation

{ THttp1UnfinishedObserver }

constructor THttp1UnfinishedObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor THttp1UnfinishedObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure THttp1UnfinishedObserver.OnEvent(const AEvent: TServerEvent);
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

function THttp1UnfinishedObserver.Exceptions: Integer;
begin
  FLock.Acquire;
  try
    Result := FExceptions;
  finally
    FLock.Release;
  end;
end;

function THttp1UnfinishedObserver.Completed: Integer;
begin
  FLock.Acquire;
  try
    Result := FCompleted;
  finally
    FLock.Release;
  end;
end;

{ THttp1UnfinishedHandler }

procedure THttp1UnfinishedHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Path: string;
  H: THeaderBlock;
  Data: TBytes;
begin
  Path := ARequest.Path;
  Data := TEncoding.ASCII.GetBytes('hello');
  if Path = '/none' then
    Exit;
  if Path = '/head-data' then
  begin
    AResponse.SendHeaders(200, nil, False);
    AResponse.Write(Data);
  end
  else if Path = '/full-length' then
  begin
    H := nil;
    SetLength(H, 1);
    H[0].Name := 'content-length';
    H[0].Value := '5';
    AResponse.SendHeaders(200, H, False);
    AResponse.Write(Data);
  end
  else if Path = '/finished' then
  begin
    AResponse.SendHeaders(200, nil, False);
    AResponse.Write(Data);
    AResponse.Finish;
  end
  else if Path = '/raise-late' then
  begin
    AResponse.SendHeaders(200, nil, False);
    AResponse.Write(Data);
    raise Exception.Create('the handler failed after the headers');
  end;
end;

{ THttp1UnfinishedTest }

procedure THttp1UnfinishedTest.SetUp;
begin
  FObserver := THttp1UnfinishedObserver.Create;
  FObserverRef := FObserver;
  FHandlerRef := THttp1UnfinishedHandler.Create;
end;

procedure THttp1UnfinishedTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandlerRef := nil;
  FObserverRef := nil;
  FObserver := nil;
end;

function THttp1UnfinishedTest.Start: Integer;
begin
  FServer := LiveFactory(FHandlerRef).Build(FObserverRef);
  FServer.Start;
  Result := FServer.Port;
end;

function THttp1UnfinishedTest.WaitCompleted(const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (FObserver.Completed < ACount) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := FObserver.Completed >= ACount;
end;

procedure THttp1UnfinishedTest.TestReturnWithoutAnyWriteGets500AndClose;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  C := TRawHttp.Create(Start);
  try
    C.Send('GET /none HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('a response', C.ReadResponse(False, ResponseMs, R));
    AssertEquals(500, R.Status);
    AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
    AssertTrue('the request completes', WaitCompleted(1, ResponseMs));
    AssertEquals('one handler exception', 1, FObserver.Exceptions);
  finally
    C.Free;
  end;
end;

procedure THttp1UnfinishedTest.TestReturnAfterHeadAndDataCutsTheResponse;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  C := TRawHttp.Create(Start);
  try
    C.Send('GET /head-data HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertFalse('the chunked response is never complete',
      C.ReadResponse(False, 1500, R));
    AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
    AssertTrue('the request completes', WaitCompleted(1, ResponseMs));
    AssertEquals('one handler exception', 1, FObserver.Exceptions);
  finally
    C.Free;
  end;
end;

procedure THttp1UnfinishedTest.TestReturnAfterAllContentLengthOctetsCutsTheResponse;
var
  C: TRawHttp;
begin
  C := TRawHttp.Create(Start);
  try
    C.Send('GET /full-length HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    // the handler wrote every octet but did not end the response: the
    // connection closes, and the request that follows gets no answer
    C.Send('GET /finished HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
    AssertTrue('the request completes', WaitCompleted(1, ResponseMs));
    AssertEquals('one handler exception', 1, FObserver.Exceptions);
    AssertTrue('no second response', C.Closed);
  finally
    C.Free;
  end;
end;

procedure THttp1UnfinishedTest.TestReturnAfterFinishKeepsTheConnection;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  C := TRawHttp.Create(Start);
  try
    C.Send('GET /finished HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertTrue('a response', C.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('hello', R.Body);
    AssertTrue('the request completes', WaitCompleted(1, ResponseMs));
    AssertEquals('no handler exception', 0, FObserver.Exceptions);
    AssertFalse('the connection stays open', C.Closed);
  finally
    C.Free;
  end;
end;

procedure THttp1UnfinishedTest.TestRaiseAfterHeadCutsTheResponseAndRaisesOneEvent;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  C := TRawHttp.Create(Start);
  try
    C.Send('GET /raise-late HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF);
    AssertFalse('the chunked response is never complete',
      C.ReadResponse(False, 1500, R));
    AssertTrue('the connection closes', C.WaitClosed(ResponseMs));
    AssertTrue('the request completes', WaitCompleted(1, ResponseMs));
    AssertEquals('one handler exception', 1, FObserver.Exceptions);
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(THttp1UnfinishedTest);

end.
