{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, close decision, write in flight, test
notes:
  - Live test of the close decision of the async server while a write is in
    flight.
  - A handler-side thread takes the GOAWAY frame from the core and parks in
    the write gate before it hands the frame to the socket. At that moment the
    core holds no output and mORMot holds no bytes, so the connection looks
    drained. A read of the IO thread then decides the close.
  - The server must keep the connection open until the frame left, so the
    client must receive the GOAWAY frame.
  - The parked thread leaves the gate when the connection closed or when the
    server deferred the close. The gate wait is a bounded poll.
---
}
/// Tests of the close decision of the async server while a write is in flight
unit Http2.Server.Async.Flight.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.base,
  mormot.net.sock,
  mormot.net.async,
  Http2.Server.Errors, Http2.Server.Seam,
  Http2.Server.Config, Http2.Server.Async, Http2.Server.Async.Flight,
  Http2.Server.Async.Test;

type
  /// the gate that parks the first write of a thread that is not an IO thread
  TParkGate = class
  private
    FParked: Integer;
    FReleased: Integer;
    FBaseDeferred: Integer;
  public
    constructor Create;
    /// the gate method of the write seam
    procedure Gate(const AConnection: TObject);
    function Parked: Boolean;
    function Released: Boolean;
  end;

  /// the thread that sends a GOAWAY frame, as a handler or a stop does
  TGoAwayThread = class(TThread)
  private
    FServer: THttp2AsyncServer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AServer: THttp2AsyncServer);
  end;

  /// the close decision tests
  TCloseInFlightTest = class(TTestCase)
  private
    FServer: THttp2AsyncServer;
    FGate: TParkGate;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    /// a read that decides the close while a GOAWAY is in flight does not drop it
    procedure TestGoAwayInFlightSurvivesTheClose;
  end;

implementation

const
  cWaitMs = 10000;
  cGateWaitMs = 10000;
  cPrefaceAndSettings =
    'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10 +
    #0#0#0#4#0#0#0#0#0;
  // a WINDOW_UPDATE frame on stream zero: the server reads it and sends nothing
  cWindowUpdate = #0#0#4#8#0#0#0#0#0#0#0#0#1;
  cFrameHeaderBytes = 9;
  cFrameTypeGoAway = 7;

{ TParkGate }

constructor TParkGate.Create;
begin
  inherited Create;
  FBaseDeferred := FlightDeferredCount;
end;

procedure TParkGate.Gate(const AConnection: TObject);
var
  Deadline: QWord;
begin
  if Http2IsIoThread then
    Exit;
  if InterlockedCompareExchange(FParked, 1, 0) <> 0 then
    Exit;
  Deadline := GetTickCount64 + QWord(cGateWaitMs);
  while (not TPollAsyncConnection(AConnection).IsClosed) and
        (FlightDeferredCount = FBaseDeferred) and
        (GetTickCount64 < Deadline) do
    Sleep(1);
  InterlockedExchange(FReleased, 1);
end;

function TParkGate.Parked: Boolean;
begin
  Result := InterlockedExchangeAdd(FParked, 0) <> 0;
end;

function TParkGate.Released: Boolean;
begin
  Result := InterlockedExchangeAdd(FReleased, 0) <> 0;
end;

{ TGoAwayThread }

constructor TGoAwayThread.Create(const AServer: THttp2AsyncServer);
begin
  FServer := AServer;
  inherited Create(False);
end;

procedure TGoAwayThread.Execute;
begin
  FServer.BroadcastGoAway(ecNoError);
end;

{ TCloseInFlightTest }

procedure TCloseInFlightTest.SetUp;
var
  Factory: THttp2ServerFactory;
begin
  FGate := TParkGate.Create;
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

procedure TCloseInFlightTest.TearDown;
begin
  SetWriteGate(nil);
  FreeAndNil(FServer);
  FreeAndNil(FGate);
end;

procedure TCloseInFlightTest.TestGoAwayInFlightSurvivesTheClose;
var
  Sock: TCrtSocket;
  Thread: TGoAwayThread;
  Deadline: QWord;
  Answer: RawByteString;
  Pending: TCrtSocketPending;
  Seen: Boolean;

  function HasGoAway: Boolean;
  var
    Pos, Len: Integer;
  begin
    Result := False;
    Pos := 1;
    while Pos + cFrameHeaderBytes - 1 <= Length(Answer) do
    begin
      Len := (Ord(Answer[Pos]) shl 16) or (Ord(Answer[Pos + 1]) shl 8) or
        Ord(Answer[Pos + 2]);
      if Ord(Answer[Pos + 3]) = cFrameTypeGoAway then
        Exit(True);
      Inc(Pos, cFrameHeaderBytes + Len);
    end;
  end;

begin
  Answer := '';
  Seen := False;
  Sock := TCrtSocket.Open('127.0.0.1', IntToStr(FServer.BoundPort), nlTcp, 4000);
  try
    SetWriteGate(FGate.Gate);
    Sock.SockSend(cPrefaceAndSettings);
    Sock.SockSendFlush();
    // the server SETTINGS frame proves that the connection runs
    Deadline := GetTickCount64 + QWord(cWaitMs);
    repeat
      Pending := Sock.SockReceivePending(50);
      if Pending in [cspSocketError, cspSocketClosed] then
        Break;
      if Pending = cspDataAvailable then
        Answer := Answer + Sock.SockReceiveString;
    until (Length(Answer) >= cFrameHeaderBytes) or (GetTickCount64 >= Deadline);
    AssertTrue('the server did not answer', Length(Answer) >= cFrameHeaderBytes);
    Thread := TGoAwayThread.Create(FServer);
    try
      Deadline := GetTickCount64 + QWord(cWaitMs);
      while (not FGate.Parked) and (GetTickCount64 < Deadline) do
        Sleep(1);
      AssertTrue('the GOAWAY write did not reach the gate', FGate.Parked);
      // the IO thread reads one frame that makes no output and decides the close
      Sock.SockSend(cWindowUpdate);
      Sock.SockSendFlush();
      Deadline := GetTickCount64 + QWord(cWaitMs);
      repeat
        Pending := Sock.SockReceivePending(50);
        // a closed socket can still hold the last frames of the server
        if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
          Answer := Answer + Sock.SockReceiveString;
        Seen := HasGoAway;
      until Seen or (GetTickCount64 >= Deadline) or
        (Pending in [cspSocketError, cspSocketClosed]);
      Seen := Seen or HasGoAway;
    finally
      Thread.WaitFor;
      Thread.Free;
    end;
  finally
    Sock.Free;
  end;
  AssertTrue('the GOAWAY frame in flight reached the client; gate released=' +
    BoolToStr(FGate.Released, True) + ' last poll=' + IntToStr(Ord(Pending)) +
    ' bytes=' + IntToStr(Length(Answer)), Seen);
end;

initialization
  RegisterTest(TCloseInFlightTest);

end.
