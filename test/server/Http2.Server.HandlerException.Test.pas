{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, handler exception, 500, request body, flow control, test
notes:
  - This unit holds the live HTTP/2 tests of an uncaught handler exception. A
    live server runs the handler pool and the connection, and a raw client sends
    the request body and reads the frames of the response.
  - A test that expects a reset or a 500 waits with a deadline. The client counts
    the WINDOW_UPDATE octets of the connection and of each stream, so a test can
    show that the credit of the delivered octets came back.
  - The HTTP/1.1 tests are in Http2.Server.HandlerException.Http1.Test.
---
}
/// Live HTTP/2 tests of an uncaught handler exception
unit Http2.Server.HandlerException.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2.Server, Http2.Server.Errors, Http2.Common.Frames, Http2.Common.Hpack,
  Http2.Common.Headers, Http2.Common.Status;

type
  /// what the failing handler does before it raises
  THandlerExceptionMode = (
    /// raise at once, before a response head
    hemRaiseNow,
    /// send a head and a partial body, then raise
    hemHeadThenRaise,
    /// read the first 512 KiB of the request body, then raise
    hemReadHalfThenRaise);

  /// a handler that raises an exception with a secret message
  THandlerExceptionRaiser = class(TInterfacedObject, IHttp2Handler)
  private
    FMode: THandlerExceptionMode;
  public
    constructor Create(const AMode: THandlerExceptionMode);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a handler that answers 200 with the body 'ok'
  THandlerExceptionOk = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// an observer that counts the handler exception events
  THandlerExceptionObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FLock: TCriticalSection;
    FExceptions: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const AEvent: TServerEvent);
    function Exceptions: Integer;
  end;

  /// a raw HTTP/2 client that tracks the send windows of the connection and of
  /// each stream from the WINDOW_UPDATE frames that the server sends
  THandlerExceptionClient = class
  private
    FSock: TCrtSocket;
    FCodec: THpackCodec;
    FBuf: RawByteString;
    FStatus: TDictionary<LongWord, Integer>;
    FReset: TDictionary<LongWord, THttp2ErrorCode>;
    FServerEnded: TDictionary<LongWord, Boolean>;
    FCredit: TDictionary<LongWord, Int64>;
    FSent: TDictionary<LongWord, Int64>;
    FDataIn: TDictionary<LongWord, Int64>;
    FSeen: string;
    FBaseline: Int64;
    procedure Pump(const AWaitMs: Integer);
    function TakeFrame(out AFrame: TFrame): Boolean;
    procedure Absorb(const AFrame: TFrame);
    function CreditOf(const AStreamId: LongWord): Int64;
    function SentOf(const AStreamId: LongWord): Int64;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// the connection preface and the client SETTINGS
    procedure Preface;
    /// a request head; AEndStream is False for a request with a body
    procedure SendRequest(const AStreamId: LongWord; const AMethod, APath: string;
      const AEndStream: Boolean);
    /// DATA of ACount zero octets on the stream
    procedure SendData(const AStreamId: LongWord; const ACount: Integer;
      const AEndStream: Boolean);
    /// send up to ATotal octets, as the windows allow, until the stream ends or
    // is reset or the deadline passes; AStopped is True when the stream ended
    function SendBody(const AStreamId: LongWord; const ATotal: Int64;
      const ATimeoutMs: Integer): Int64;
    /// wait for the first HEADERS of the stream; the status is in AStatus
    function WaitStatus(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out AStatus: Integer): Boolean;
    /// wait for an RST_STREAM or an END_STREAM from the server on the stream
    function WaitResetOrEnd(const AStreamId: LongWord; const ATimeoutMs: Integer;
      out ACode: THttp2ErrorCode; out AReset: Boolean): Boolean;
    /// read the frames that arrive within the wait
    procedure Drain(const ATimeoutMs: Integer);
    /// the status of the first HEADERS of the stream, or 0
    function StatusOf(const AStreamId: LongWord): Integer;
    /// the DATA octets that the server sent on the stream
    function DataInOf(const AStreamId: LongWord): Int64;
    /// the octets of the connection send window that are free now
    function ConnectionAvailable: Int64;
    /// the WINDOW_UPDATE octets that the server returned on stream 0 after the
    // preface, minus the octets that the client sent; zero or more means every
    // sent octet came back
    function ConnectionCredit: Int64;
    /// the octets of the send window of the stream that are free now
    function StreamAvailable(const AStreamId: LongWord): Int64;
    /// the text of every DATA payload that the server sent
    property Seen: string read FSeen;
  end;

  /// the live tests of the handler exception policy for HTTP/2
  THandlerExceptionTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FObserver: THandlerExceptionObserver;
    FObserverRef: IHttp2ServerObserver;
    procedure StartServer(const AMode: THandlerExceptionMode);
    function WaitIdle(const ATimeoutMs: Integer): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestRaiseBeforeHeadAnswers500;
    procedure TestRaiseBeforeHeadWithUnreadBodyEndsAndKeepsCredit;
    procedure TestRaiseAfterHeadResetsWithInternalError;
    procedure TestRaiseWhileBodyHalfRead;
    procedure TestHundredFailingRequestsLeaveNothing;
    procedure TestObserverCountsEachException;
  end;

const
  /// the message of the exception; it must never reach the peer
  ExceptionSecret = 'secret-internal-7741';
  /// the initial window of a stream and of the connection (RFC 9113 section 6.9.2)
  InitialWindow = 65535;
  /// the octets of the request body of the unread-body tests
  UnreadBodyBytes = 1048576;
  /// the wait of a test step, in milliseconds
  StepMs = 3000;

implementation

const
  /// the body octets that the handler reads before it raises in the half-read test
  HalfReadBytes = 524288;
  /// the size of one DATA frame that the client sends
  ClientChunk = 16384;

/// the text of an octet array
function TextOfBytes(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

/// the octets of a text literal
function OctetsOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

{ THandlerExceptionRaiser }

constructor THandlerExceptionRaiser.Create(const AMode: THandlerExceptionMode);
begin
  inherited Create;
  FMode := AMode;
end;

procedure THandlerExceptionRaiser.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buf: array[0..ClientChunk - 1] of Byte;
  Got, N: Integer;
begin
  case FMode of
    hemHeadThenRaise:
      begin
        AResponse.SendHeaders(200, nil, False);
        AResponse.Write(OctetsOf('part'));
      end;
    hemReadHalfThenRaise:
      begin
        Got := 0;
        while Got < HalfReadBytes do
        begin
          N := ARequest.Read(Buf[0], ClientChunk);
          if N <= 0 then
            Break;
          Inc(Got, N);
        end;
      end;
  end;
  raise Exception.Create(ExceptionSecret);
end;

{ THandlerExceptionOk }

procedure THandlerExceptionOk.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(OctetsOf('ok'));
  AResponse.Finish;
end;

{ THandlerExceptionObserver }

constructor THandlerExceptionObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor THandlerExceptionObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure THandlerExceptionObserver.OnEvent(const AEvent: TServerEvent);
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

function THandlerExceptionObserver.Exceptions: Integer;
begin
  FLock.Acquire;
  try
    Result := FExceptions;
  finally
    FLock.Release;
  end;
end;

{ THandlerExceptionClient }

constructor THandlerExceptionClient.Create(const APort: Integer);
begin
  inherited Create;
  FCodec := THpackCodec.Create;
  FStatus := TDictionary<LongWord, Integer>.Create;
  FReset := TDictionary<LongWord, THttp2ErrorCode>.Create;
  FServerEnded := TDictionary<LongWord, Boolean>.Create;
  FCredit := TDictionary<LongWord, Int64>.Create;
  FSent := TDictionary<LongWord, Int64>.Create;
  FDataIn := TDictionary<LongWord, Int64>.Create;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, StepMs);
end;

destructor THandlerExceptionClient.Destroy;
begin
  FSock.Free;
  FDataIn.Free;
  FSent.Free;
  FCredit.Free;
  FServerEnded.Free;
  FReset.Free;
  FStatus.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure THandlerExceptionClient.Pump(const AWaitMs: Integer);
var
  Pending: TCrtSocketPending;
  Chunk: RawByteString;
begin
  Pending := FSock.SockReceivePending(AWaitMs);
  // a read without pending data waits for the socket timeout, so it runs only
  // when the poll reports octets
  if not (Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket]) then
    Exit;
  Chunk := FSock.SockReceiveString;
  if Chunk <> '' then
    FBuf := FBuf + Chunk;
end;

function THandlerExceptionClient.TakeFrame(out AFrame: TFrame): Boolean;
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

procedure THandlerExceptionClient.Absorb(const AFrame: TFrame);
var
  Id: LongWord;
  Fields: THeaderBlock;
  Code: THttp2ErrorCode;
  Old: Int64;
  Text: TBytes;
  Octets: Int64;
begin
  Id := AFrame.Header.StreamId;
  case AFrame.Header.FrameType of
    ftHeaders:
      if not FStatus.ContainsKey(Id) then
      begin
        Fields := FCodec.Decode(ExtractHeaderBlock(AFrame));
        FStatus.Add(Id, 0);
        if (Length(Fields) > 0) and (Fields[0].Name = HeaderStatus) then
          FStatus[Id] := StrToIntDef(Fields[0].Value, 0);
      end;
    ftData:
      begin
        Text := ExtractDataPayload(AFrame);
        Octets := Length(Text);
        if FDataIn.TryGetValue(Id, Old) then
          FDataIn[Id] := Old + Octets
        else
          FDataIn.Add(Id, Octets);
        FSeen := FSeen + TextOfBytes(Text);
      end;
    ftRstStream:
      begin
        ParseRstStream(AFrame, Code);
        FReset.AddOrSetValue(Id, Code);
      end;
    ftWindowUpdate:
      begin
        Old := ParseWindowUpdate(AFrame);
        if FCredit.TryGetValue(Id, Octets) then
          FCredit[Id] := Octets + Old
        else
          FCredit.Add(Id, Old);
      end;
  end;
  if (AFrame.Header.FrameType in [ftHeaders, ftData]) and AFrame.IsEndStream then
    FServerEnded.AddOrSetValue(Id, True);
end;

function THandlerExceptionClient.CreditOf(const AStreamId: LongWord): Int64;
begin
  if not FCredit.TryGetValue(AStreamId, Result) then
    Result := 0;
end;

function THandlerExceptionClient.SentOf(const AStreamId: LongWord): Int64;
begin
  if not FSent.TryGetValue(AStreamId, Result) then
    Result := 0;
end;

procedure THandlerExceptionClient.Preface;
var
  Wire: TBytes;
  Settings: TBytes;
  Frame: TFrame;
begin
  Frame := BuildSettingsFrame(TConnectionSettings.Defaults);
  SetLength(Settings, FrameHeaderSize + Length(Frame.Payload));
  Frame.Header.WriteTo(Settings);
  if Length(Frame.Payload) > 0 then
    Move(Frame.Payload[0], Settings[FrameHeaderSize], Length(Frame.Payload));
  SetLength(Wire, ClientPrefaceSize + Length(Settings));
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Move(Settings[0], Wire[ClientPrefaceSize], Length(Settings));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
  // the window that the server raises at its start is not a return of credit
  Drain(200);
  FBaseline := CreditOf(0);
end;

procedure THandlerExceptionClient.SendRequest(const AStreamId: LongWord;
  const AMethod, APath: string; const AEndStream: Boolean);
var
  Fields: THeaderBlock;
  Wire: TBytes;
  Frame: TFrame;
begin
  SetLength(Fields, 4);
  Fields[0].Name := HeaderMethod;
  Fields[0].Value := AMethod;
  Fields[1].Name := HeaderPath;
  Fields[1].Value := APath;
  Fields[2].Name := HeaderScheme;
  Fields[2].Value := 'http';
  Fields[3].Name := HeaderAuthority;
  Fields[3].Value := '127.0.0.1';
  Frame := BuildHeadersFrame(AStreamId, FCodec.Encode(Fields), True, AEndStream);
  SetLength(Wire, FrameHeaderSize + Length(Frame.Payload));
  Frame.Header.WriteTo(Wire);
  if Length(Frame.Payload) > 0 then
    Move(Frame.Payload[0], Wire[FrameHeaderSize], Length(Frame.Payload));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

procedure THandlerExceptionClient.SendData(const AStreamId: LongWord;
  const ACount: Integer; const AEndStream: Boolean);
var
  Frame: TFrame;
  Wire: TBytes;
  Zeros: TBytes;
  Old: Int64;
begin
  SetLength(Zeros, ACount);
  Frame := BuildDataFrame(AStreamId, Zeros, AEndStream);
  SetLength(Wire, FrameHeaderSize + Length(Frame.Payload));
  Frame.Header.WriteTo(Wire);
  if Length(Frame.Payload) > 0 then
    Move(Frame.Payload[0], Wire[FrameHeaderSize], Length(Frame.Payload));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
  if FSent.TryGetValue(AStreamId, Old) then
    FSent[AStreamId] := Old + ACount
  else
    FSent.Add(AStreamId, ACount);
  // the connection window is the count of the octets of stream 0 in the same map
  if FSent.TryGetValue(0, Old) then
    FSent[0] := Old + ACount
  else
    FSent.Add(0, ACount);
end;

function THandlerExceptionClient.StreamAvailable(const AStreamId: LongWord): Int64;
begin
  Result := InitialWindow + CreditOf(AStreamId) - SentOf(AStreamId);
end;

function THandlerExceptionClient.ConnectionAvailable: Int64;
begin
  Result := InitialWindow + CreditOf(0) - SentOf(0);
end;

function THandlerExceptionClient.ConnectionCredit: Int64;
begin
  // the octets the server returned on stream 0 after the preface, minus the
  // octets sent: zero or more when every sent octet came back
  Result := CreditOf(0) - FBaseline - SentOf(0);
end;

function THandlerExceptionClient.SendBody(const AStreamId: LongWord;
  const ATotal: Int64; const ATimeoutMs: Integer): Int64;
var
  Deadline: QWord;
  Want, Avail: Int64;
  Ch: Integer;
begin
  Result := 0;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  // the server END_STREAM of a response does not end the request body, so
  // only a reset of the stream stops the sender early
  while (Result < ATotal) and (GetTickCount64 < Deadline) and
        not FReset.ContainsKey(AStreamId) do
  begin
    Drain(10);
    Avail := StreamAvailable(AStreamId);
    if ConnectionAvailable < Avail then
      Avail := ConnectionAvailable;
    if Avail <= 0 then
      Continue;
    Want := ATotal - Result;
    if Want > Avail then
      Want := Avail;
    if Want > ClientChunk then
      Want := ClientChunk;
    Ch := Integer(Want);
    SendData(AStreamId, Ch, False);
    Inc(Result, Ch);
  end;
  Drain(50);
end;

procedure THandlerExceptionClient.Drain(const ATimeoutMs: Integer);
var
  Deadline: QWord;
  Frame: TFrame;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pump(10);
    while TakeFrame(Frame) do
      Absorb(Frame);
  until GetTickCount64 >= Deadline;
end;

function THandlerExceptionClient.WaitStatus(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out AStatus: Integer): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
begin
  AStatus := 0;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pump(10);
    while TakeFrame(Frame) do
      Absorb(Frame);
    if FStatus.ContainsKey(AStreamId) and (FStatus[AStreamId] > 0) then
    begin
      AStatus := FStatus[AStreamId];
      Exit(True);
    end;
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function THandlerExceptionClient.WaitResetOrEnd(const AStreamId: LongWord;
  const ATimeoutMs: Integer; out ACode: THttp2ErrorCode; out AReset: Boolean): Boolean;
var
  Deadline: QWord;
  Frame: TFrame;
begin
  ACode := ecNoError;
  AReset := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pump(10);
    while TakeFrame(Frame) do
      Absorb(Frame);
    if FReset.TryGetValue(AStreamId, ACode) then
    begin
      AReset := True;
      Exit(True);
    end;
    if FServerEnded.ContainsKey(AStreamId) then
      Exit(True);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function THandlerExceptionClient.StatusOf(const AStreamId: LongWord): Integer;
begin
  if not FStatus.TryGetValue(AStreamId, Result) then
    Result := 0;
end;

function THandlerExceptionClient.DataInOf(const AStreamId: LongWord): Int64;
begin
  if not FDataIn.TryGetValue(AStreamId, Result) then
    Result := 0;
end;

{ THandlerExceptionTest }

procedure THandlerExceptionTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FObserverRef := nil;
  inherited TearDown;
end;

procedure THandlerExceptionTest.StartServer(const AMode: THandlerExceptionMode);
var
  Handler: IHttp2Handler;
  Factory: THttp2ServerFactory;
begin
  FObserver := THandlerExceptionObserver.Create;
  FObserverRef := FObserver;
  Handler := THandlerExceptionRaiser.Create(AMode);
  Factory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHandler(Handler)
    .WithHandlerThreads(2)
    .WithIOThreads(2);
  FServer := Factory.Build(FObserverRef);
  FServer.Start;
end;

function THandlerExceptionTest.WaitIdle(const ATimeoutMs: Integer): Boolean;
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

procedure THandlerExceptionTest.TestRaiseBeforeHeadAnswers500;
var
  C: THandlerExceptionClient;
  Status: Integer;
  Code: THttp2ErrorCode;
  Reset: Boolean;
  Ok: Integer;
begin
  StartServer(hemRaiseNow);
  C := THandlerExceptionClient.Create(FServer.Port);
  try
    C.Preface;
    C.SendRequest(1, 'GET', '/fail', True);
    AssertTrue('no response head arrived', C.WaitStatus(1, StepMs, Status));
    AssertEquals('a raise before the head gives 500', 500, Status);
    AssertTrue('the 500 ends the stream', C.WaitResetOrEnd(1, StepMs, Code, Reset));
    AssertFalse('the 500 is not a reset', Reset);
    AssertEquals('the 500 body is empty', 0, C.DataInOf(1));
    AssertEquals('the exception text never reaches the peer', 0,
      Pos(ExceptionSecret, C.Seen));
    // the connection and the pool survive: a second request is served
    C.SendRequest(3, 'GET', '/ok', True);
    AssertTrue('the second request got no head', C.WaitStatus(3, StepMs, Ok));
    AssertEquals('the second request is served', 500, Ok);
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(StepMs));
end;

procedure THandlerExceptionTest.TestRaiseBeforeHeadWithUnreadBodyEndsAndKeepsCredit;
var
  C: THandlerExceptionClient;
  Status, Sent: Integer;
  Code: THttp2ErrorCode;
  Reset: Boolean;
  Total: Int64;
begin
  StartServer(hemRaiseNow);
  C := THandlerExceptionClient.Create(FServer.Port);
  try
    C.Preface;
    C.SendRequest(1, 'POST', '/upload', False);
    Total := C.SendBody(1, UnreadBodyBytes, StepMs);
    AssertTrue('no response head arrived', C.WaitStatus(1, StepMs, Status));
    AssertEquals('a raise before the head gives 500', 500, Status);
    AssertTrue('the stream did not end', C.WaitResetOrEnd(1, StepMs, Code, Reset));
    Sent := Integer(Total);
    // the client may stop early: the stream must end in both directions, by a
    // NO_ERROR reset (RFC 9113 section 8.1) or by the end of the request body
    AssertTrue('the request body was not finished and no reset came',
      Reset or (Total = UnreadBodyBytes));
    if Reset then
      AssertEquals('the reset after a complete 500 is NO_ERROR', Ord(ecNoError), Ord(Code));
    AssertTrue('the streams close', WaitIdle(StepMs));
    // every octet the server received came back to the connection window
    AssertTrue('the connection window leaked: credit ' +
      IntToStr(C.ConnectionCredit) + ' after ' + IntToStr(Sent) + ' octets',
      C.ConnectionCredit >= 0);
    C.SendRequest(3, 'GET', '/ok', True);
    AssertTrue('a second request got no head', C.WaitStatus(3, StepMs, Status));
    AssertEquals('the second request is served', 500, Status);
  finally
    C.Free;
  end;
end;

procedure THandlerExceptionTest.TestRaiseAfterHeadResetsWithInternalError;
var
  C: THandlerExceptionClient;
  Status: Integer;
  Code: THttp2ErrorCode;
  Reset: Boolean;
begin
  StartServer(hemHeadThenRaise);
  C := THandlerExceptionClient.Create(FServer.Port);
  try
    C.Preface;
    C.SendRequest(1, 'GET', '/cut', True);
    AssertTrue('no response head arrived', C.WaitStatus(1, StepMs, Status));
    AssertEquals('the head that went out keeps its status', 200, Status);
    AssertTrue('the stream did not end', C.WaitResetOrEnd(1, StepMs, Code, Reset));
    AssertTrue('the stream is reset, not ended', Reset);
    AssertEquals('the reset carries INTERNAL_ERROR', Ord(ecInternalError), Ord(Code));
    AssertEquals('the exception text never reaches the peer', 0,
      Pos(ExceptionSecret, C.Seen));
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(StepMs));
end;

procedure THandlerExceptionTest.TestRaiseWhileBodyHalfRead;
var
  C: THandlerExceptionClient;
  Status: Integer;
  Code: THttp2ErrorCode;
  Reset: Boolean;
  Total: Int64;
begin
  StartServer(hemReadHalfThenRaise);
  C := THandlerExceptionClient.Create(FServer.Port);
  try
    C.Preface;
    C.SendRequest(1, 'POST', '/half', False);
    Total := C.SendBody(1, UnreadBodyBytes, StepMs);
    AssertTrue('no response head arrived', C.WaitStatus(1, StepMs, Status));
    AssertEquals('a raise after a half read gives 500', 500, Status);
    AssertTrue('the stream did not end', C.WaitResetOrEnd(1, StepMs, Code, Reset));
    AssertTrue('the request body was not finished and no reset came',
      Reset or (Total = UnreadBodyBytes));
    AssertTrue('the streams close', WaitIdle(StepMs));
    AssertTrue('the connection window leaked', C.ConnectionCredit >= 0);
  finally
    C.Free;
  end;
end;

procedure THandlerExceptionTest.TestHundredFailingRequestsLeaveNothing;
var
  C: THandlerExceptionClient;
  I, Status: Integer;
  Id: LongWord;
begin
  StartServer(hemRaiseNow);
  C := THandlerExceptionClient.Create(FServer.Port);
  try
    C.Preface;
    for I := 0 to 99 do
    begin
      Id := LongWord(1 + 2 * I);
      C.SendRequest(Id, 'POST', '/loop', False);
      C.SendData(Id, 4096, False);
      AssertTrue('request ' + IntToStr(I) + ' got no head',
        C.WaitStatus(Id, StepMs, Status));
      AssertEquals('request ' + IntToStr(I) + ' is a 500', 500, Status);
    end;
    AssertTrue('streams are left open after 100 failures',
      WaitIdle(StepMs));
    AssertTrue('the connection window leaked after 100 failures',
      C.ConnectionCredit >= 0);
    AssertEquals('one exception per request', 100, FObserver.Exceptions);
  finally
    C.Free;
  end;
end;

procedure THandlerExceptionTest.TestObserverCountsEachException;
var
  C: THandlerExceptionClient;
  Status: Integer;
begin
  StartServer(hemRaiseNow);
  C := THandlerExceptionClient.Create(FServer.Port);
  try
    C.Preface;
    C.SendRequest(1, 'GET', '/one', True);
    AssertTrue('no response head arrived', C.WaitStatus(1, StepMs, Status));
    AssertEquals(500, Status);
  finally
    C.Free;
  end;
  AssertTrue('the streams close', WaitIdle(StepMs));
  AssertEquals('the observer counts the exception', 1, FObserver.Exceptions);
end;

initialization
  RegisterTest(THandlerExceptionTest);
end.
