{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, trace, connection start, test
notes:
  - Live tests of the start trace of the async server connections.
  - One raw h2c client opens one connection. With the trace on, the lines of
    accept, first read, first write and SETTINGS write appear in this order,
    with one connection id and a monotonic time.
  - With the trace off, the same flow emits no line.
  - The tests wait for the answer of the server with a bounded poll and never
    with a fixed sleep.
---
}
/// Tests of the start trace of the async server
unit Http2.Server.Async.Trace.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.base,
  mormot.net.sock,
  Http2.Server.Config, Http2.Server.Async, Http2.Server.Async.Trace,
  Http2.Server.Async.Test;

type
  /// the collector of the trace lines of one test
  TTraceCollector = class
  private
    FLock: TCriticalSection;
    FLines: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    /// the receiver that the trace calls with one line
    procedure Add(const ALine: string);
    /// a copy of the lines seen so far
    function Snapshot: TStringList;
  end;

  /// the start trace tests
  TAsyncStartTraceTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    FCollector: TTraceCollector;
    FWasOn: Boolean;
    /// open one connection, send the preface and an empty SETTINGS frame, and
    /// wait until the server answers
    function RunOneConnection: Boolean;
    function FieldOf(const ALine, AName: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    /// the four lines of one connection appear in order
    procedure TestLinesAppearInOrderWhenOn;
    /// no line appears when the trace is off
    procedure TestNothingWhenOff;
  end;

implementation

const
  cAnswerWaitMs = 10000;
  cPrefaceAndSettings =
    'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10 +
    #0#0#0#4#0#0#0#0#0;
  cExpectedEvents: array[0..3] of string =
    ('accept', 'first_read', 'first_write', 'settings_write');

{ TTraceCollector }

constructor TTraceCollector.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
end;

destructor TTraceCollector.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TTraceCollector.Add(const ALine: string);
begin
  FLock.Enter;
  try
    FLines.Add(ALine);
  finally
    FLock.Leave;
  end;
end;

function TTraceCollector.Snapshot: TStringList;
begin
  Result := TStringList.Create;
  FLock.Enter;
  try
    Result.AddStrings(FLines);
  finally
    FLock.Leave;
  end;
end;

{ TAsyncStartTraceTest }

procedure TAsyncStartTraceTest.SetUp;
var
  Factory: THttp2ServerFactory;
begin
  FWasOn := AsyncTraceOn;
  FCollector := TTraceCollector.Create;
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(TEchoHandler.Create)
    .WithHandlerThreads(2)
    .WithIOThreads(2);
  FServer := THttp2AsyncServer.Create(Factory);
  FServer.Start;
end;

procedure TAsyncStartTraceTest.TearDown;
begin
  FreeAndNil(FServer);
  // restore the state of the process: the environment decides it
  SetAsyncTrace(FWasOn);
  FreeAndNil(FCollector);
end;

function TAsyncStartTraceTest.RunOneConnection: Boolean;
var
  Sock: TCrtSocket;
  Deadline: QWord;
  Pending: TCrtSocketPending;
  Answer: RawByteString;
begin
  Result := False;
  Answer := '';
  Sock := TCrtSocket.Open('127.0.0.1', IntToStr(FServer.BoundPort), nlTcp, 4000);
  try
    Sock.SockSend(cPrefaceAndSettings);
    Sock.SockSendFlush();
    Deadline := GetTickCount64 + QWord(cAnswerWaitMs);
    repeat
      Pending := Sock.SockReceivePending(50);
      if Pending in [cspSocketError, cspSocketClosed] then
        Break;
      Answer := Answer + Sock.SockReceiveString;
      // a frame header of the server SETTINGS frame is enough
      if Length(Answer) >= 9 then
        Exit(True);
    until GetTickCount64 >= Deadline;
  finally
    Sock.Free;
  end;
end;

function TAsyncStartTraceTest.FieldOf(const ALine, AName: string): string;
var
  P, E: Integer;
begin
  Result := '';
  P := Pos(' ' + AName + '=', ALine);
  if P = 0 then
    Exit;
  Inc(P, Length(AName) + 2);
  E := P;
  while (E <= Length(ALine)) and (ALine[E] <> ' ') do
    Inc(E);
  Result := Copy(ALine, P, E - P);
end;

procedure TAsyncStartTraceTest.TestLinesAppearInOrderWhenOn;
var
  Lines: TStringList;
  I: Integer;
  Id, Cur: string;
  PrevUs, CurUs: Int64;
begin
  SetAsyncTrace(True, FCollector.Add);
  AssertTrue('the server did not answer', RunOneConnection);
  Lines := FCollector.Snapshot;
  try
    AssertEquals('the number of trace lines', Length(cExpectedEvents),
      Lines.Count);
    Id := FieldOf(Lines[0], 'conn');
    AssertTrue('the line has no connection id', Id <> '');
    PrevUs := -1;
    for I := 0 to Lines.Count - 1 do
    begin
      AssertTrue('the line has the trace prefix: ' + Lines[I],
        Pos('HTTP2_TEST_TRACE CONN ' + cExpectedEvents[I] + ' ', Lines[I]) = 1);
      AssertEquals('one connection id', Id, FieldOf(Lines[I], 'conn'));
      AssertTrue('the line has no thread id', FieldOf(Lines[I], 'tid') <> '');
      Cur := FieldOf(Lines[I], 't_us');
      CurUs := StrToInt64Def(Cur, -1);
      AssertTrue('the line has no time: ' + Lines[I], CurUs >= 0);
      AssertTrue('the time went back: ' + Lines[I], CurUs >= PrevUs);
      PrevUs := CurUs;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TAsyncStartTraceTest.TestNothingWhenOff;
var
  Lines: TStringList;
begin
  SetAsyncTrace(False, FCollector.Add);
  AssertTrue('the server did not answer', RunOneConnection);
  Lines := FCollector.Snapshot;
  try
    AssertEquals('the trace is off, so no line appears', 0, Lines.Count);
  finally
    Lines.Free;
  end;
end;

initialization
  RegisterTest(TAsyncStartTraceTest);

end.
