{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, flow control, back pressure, volume, error, integration, test
notes:
  - This unit holds integration tests of flow control, volume and error cases between the
    library client and the library server. The WebSocket runs over HTTP/2 with the
    extended CONNECT of RFC 8441 on a cleartext connection with prior knowledge (h2c).
  - Each test starts its own server on a port that the system picks. TearDown stops the
    server and closes the client.
  - Every wait has a limit of 10 s and fails with a message. No test sleeps for more
    than 2 s.
  - The server sends a message of 16 MiB with SendStream. The client holds its demand at
    zero, so the server stream parks and the writer is not asked for every chunk.
  - The octets of a message follow a pattern of the letters a to z by their index, so a
    test checks the order of the octets without a copy of the expected message.
---
}
/// Integration tests of flow control, volume and error cases of a WebSocket over HTTP/2
// - each test starts its own server and stops it in TearDown
unit Http2.Integration.WsH2Flow.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Body, Http2.Common, Http2.Common.Headers, Http2.Common.Status,
  Http2.Client, Http2.Client.Errors, Http2.Client.Messages, Http2.Client.Stream,
  Http2.Server, Http2.Server.StreamAdapters;

type
  /// what the server handler does after it has read a message
  // - waRead: nothing more; waStream: streams the writer; waClose: closes with the code;
  //   waAbort: aborts the session with no Close frame
  TWsFlowAction = (waRead, waStream, waClose, waAbort);

  /// a body writer that counts its calls and writes the expected text
  // - call 1 to the chunk count write one chunk each and answer True
  // - the call after the last chunk writes nothing and answers False, which ends the body
  TCountingWriter = class(TInterfacedObject, IBodyWriter)
  private
    FText: string;
    FCalls: Integer;
    FChunkCount: Integer;
  public
    constructor Create(const AText: string; const AChunkCount: Integer);
    function NextChunk(const ABuffer: TStream): Boolean;
    /// the number of calls so far; safe to read from the test thread
    function Calls: Integer;
  end;

  /// what the server handler saw, with one event for each group of fields
  // - the test reads a field only after the event of its group
  TWsFlowRecord = class
  public
    /// set when the handler sees a request on the WebSocket path
    RequestSeen: TEvent;
    /// set when the handler starts to read a message
    MessageStarted: TEvent;
    /// set when the handler has read a message, or has failed to read it
    MessageSeen: TEvent;
    /// set when the session has ended
    ClosedSeen: TEvent;
    Method: string;
    MessageCount: Integer;
    MessageOctets: Int64;
    MessageOk: Boolean;
    MessageText: Boolean;
    Failure: string;
    ClosedCode: Integer;
    ClosedClean: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  /// a server handler that serves the WebSocket path and answers 404 on other paths
  TWsFlowHttpHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FRecord: TWsFlowRecord;
    FWriter: IBodyWriter;
    FAction: TWsFlowAction;
    FCloseCode: Word;
  public
    constructor Create(const ARecord: TWsFlowRecord; const AWriter: IBodyWriter;
      const AAction: TWsFlowAction; const ACloseCode: Word);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the WebSocket handler of the tests
  // - it reads each message and checks its octets against the pattern
  // - then it does the action of the test
  TWsFlowHandler = class(TInterfacedObject, IWsHandler)
  private
    FRecord: TWsFlowRecord;
    FWriter: IBodyWriter;
    FAction: TWsFlowAction;
    FCloseCode: Word;
  public
    constructor Create(const ARecord: TWsFlowRecord; const AWriter: IBodyWriter;
      const AAction: TWsFlowAction; const ACloseCode: Word);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// a client listener that counts the fragments and keeps the octets
  // - Done is set by the last fragment, by OnClose and by OnError
  // - Kind tells how the socket ended: 0 while open, 1 for OnClose, 2 for OnError
  TWsFlowListener = class(TWebSocketListener)
  private
    procedure Absorb(const AData: Pointer; const ACount: Integer; const ALast: Boolean);
  public
    Opened: TEvent;
    Done: TEvent;
    Octets: TMemoryStream;
    Callbacks: Integer;
    LastFlagCount: Integer;
    LastLength: Integer;
    Kind: Integer;
    CloseCode: Integer;
    CloseReason: string;
    ErrorText: string;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    procedure OnBytes(const ASocket: IWebSocket; const AData: TBytes;
      const ALast: Boolean); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket; const AError: Exception); override;
  end;

  /// the integration tests of flow control, volume and error cases
  TWsH2FlowIntegrationTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FClient: IHttpClient;
    FRecord: TWsFlowRecord;
    FWriterIntf: IBodyWriter;
    FCounter: TCountingWriter;
    procedure StartServer(const AOptions: TWsOptions; const AAction: TWsFlowAction;
      const ACloseCode: Word; const AWriter: IBodyWriter; const AGraceMs: Integer);
    function NewClient: IHttpClient;
    function WsUrl: string;
    function WsRequest(const AListener: IWebSocketListener): IWebSocketRequest;
    procedure AwaitEvent(const AEvent: TEvent; const AWhat: string);
    procedure AwaitRequest;
    procedure AssertWriterParks(const AMaxCalls: Integer);
    procedure AssertNoServerClose(const AWhat: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestServerStreamedMessageReachesTheClient;
    procedure TestSlowListenerGetsBackPressure;
    procedure TestClientSendsLargeMessageInFragments;
    procedure TestMessageAboveTheLimitClosesWith1009;
    procedure TestServerStopClosesTheClientSocket;
    procedure TestServerResetsTheStream;
    procedure TestServerAbortGivesOnError;
  end;

/// the octet of a message at AIndex: the letters a to z in a repeating order
function PatternByte(const AIndex: Int64): Byte;
/// true when ACount octets from AData follow the pattern from AOffset
function PatternMatches(const AData: PByte; const ACount: Integer;
  const AOffset: Int64): Boolean;
/// the text of ACount octets of the pattern, from offset 0
function PatternText(const ACount: Integer): string;

implementation

const
  /// the octets of one chunk that the server writer sends
  cChunkBytes = 65536;
  /// the chunks of the 16 MiB message, before the writer answers False
  cChunkCount = 256;
  /// the octets of the 16 MiB message
  cTotalBytes = cChunkBytes * cChunkCount;
  /// the octets of the message that the client sends
  cUploadBytes = 8 * 1024 * 1024;
  /// the octets of one fragment of the uploaded message
  cUploadFragmentBytes = 128 * 1024;
  /// the fragments of the uploaded message
  cUploadFragments = cUploadBytes div cUploadFragmentBytes;
  /// the octets of one fragment in the test of the message limit; below the default
  // frame limit of 64 KiB, so that the message limit, not the frame limit, closes the session
  cLimitFragmentBytes = 32 * 1024;
  /// the octets that the client sends in the test of the limit
  cOverLimitBytes = 2 * 1024 * 1024;
  /// the limit of one message on the server, 1 MiB as the default
  cServerLimitBytes = 1024 * 1024;
  /// the limit of one message on the server for the upload: above the upload
  cServerUploadLimitBytes = 16 * 1024 * 1024;
  /// the limit of one frame on the server for the upload; the client writes one
  // frame for each fragment, and the server default of 64 KiB is below a fragment
  cServerUploadFrameBytes = 256 * 1024;
  /// the limit of one message on the client: above the 16 MiB of the server message
  cClientLimitBytes = 32 * 1024 * 1024;
  /// the most fragments of the 16 MiB message that a frame size of 16 KiB makes
  cFramesOfServerMessage = cTotalBytes div 16384;
  /// the method of an extended CONNECT request
  cMethodConnect = 'CONNECT';
  /// the path of the WebSocket route
  cPathWs = '/ws';
  /// the wait for an event, in milliseconds
  cWaitMs = 10000;
  /// the time that the demand stays at zero before the test checks the writer, in ms
  cParkedMs = 1000;
  /// the text that makes the test client start the stream
  cGoText = 'go';
  /// the close code of a policy violation (RFC 6455 section 7.4.1)
  cClosePolicy = 1008;
  /// the close code of a message that is too big (RFC 6455 section 7.4.1)
  cCloseTooBig = 1009;
  /// the reason of the server close of the test that resets the stream
  cResetReason = 'test reset';
  /// the kind of end that the listener records
  cKindOpen = 0;
  cKindClosed = 1;
  cKindError = 2;

/// the octet of a message at AIndex: the letters a to z in a repeating order
function PatternByte(const AIndex: Int64): Byte;
begin
  Result := Byte(Ord('a') + (AIndex mod 26));
end;

/// true when ACount octets from AData follow the pattern from AOffset
function PatternMatches(const AData: PByte; const ACount: Integer;
  const AOffset: Int64): Boolean;
var
  I: Integer;
  Octets: PByteArray;
begin
  Result := True;
  if ACount <= 0 then
    Exit;
  Octets := PByteArray(AData);
  for I := 0 to ACount - 1 do
    if Octets^[I] <> PatternByte(AOffset + I) then
      Exit(False);
end;

/// the text of ACount octets of the pattern, from offset 0
function PatternText(const ACount: Integer): string;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 1 to ACount do
    Result[I] := Chr(PatternByte(I - 1));
end;

/// closes a client; a failure while it closes does not change the test result
procedure CloseClientQuietly(const AClient: IHttpClient);
begin
  try
    if AClient <> nil then
      AClient.Close;
  except
    // the test has already checked its result
  end;
end;

/// closes a socket; a failure while it closes does not change the test result
procedure AbortQuietly(const ASocket: IWebSocket);
begin
  try
    if ASocket <> nil then
      ASocket.Abort;
  except
    // the test has already checked its result
  end;
end;

constructor TCountingWriter.Create(const AText: string; const AChunkCount: Integer);
begin
  inherited Create;
  FText := AText;
  FCalls := 0;
  FChunkCount := AChunkCount;
end;

function TCountingWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  Index: Integer;
begin
  Index := InterlockedIncrement(FCalls) - 1;
  if Index < FChunkCount then
  begin
    ChunkAppendText(ABuffer, UTF8String(Copy(FText, Index * cChunkBytes + 1,
      cChunkBytes)));
    Result := True;
  end
  else
    // the call after the last chunk writes no octets and ends the body
    Result := False;
end;

function TCountingWriter.Calls: Integer;
begin
  Result := InterlockedExchangeAdd(FCalls, 0);
end;

constructor TWsFlowRecord.Create;
begin
  inherited Create;
  RequestSeen := TEvent.Create(nil, True, False, '');
  MessageStarted := TEvent.Create(nil, True, False, '');
  MessageSeen := TEvent.Create(nil, True, False, '');
  ClosedSeen := TEvent.Create(nil, True, False, '');
end;

destructor TWsFlowRecord.Destroy;
begin
  RequestSeen.Free;
  MessageStarted.Free;
  MessageSeen.Free;
  ClosedSeen.Free;
  inherited Destroy;
end;

constructor TWsFlowHttpHandler.Create(const ARecord: TWsFlowRecord;
  const AWriter: IBodyWriter; const AAction: TWsFlowAction; const ACloseCode: Word);
begin
  inherited Create;
  FRecord := ARecord;
  FWriter := AWriter;
  FAction := AAction;
  FCloseCode := ACloseCode;
end;

procedure TWsFlowHttpHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Headers: THeaderBlock;
begin
  if ARequest.Path = cPathWs then
  begin
    FRecord.Method := ARequest.Method;
    FRecord.RequestSeen.SetEvent;
    AcceptWebSocket(ARequest, AResponse,
      TWsFlowHandler.Create(FRecord, FWriter, FAction, FCloseCode));
    Exit;
  end;
  SetLength(Headers, 0);
  AResponse.SendHeaders(HttpStatusNotFound, Headers, False);
  AResponse.Finish;
end;

constructor TWsFlowHandler.Create(const ARecord: TWsFlowRecord;
  const AWriter: IBodyWriter; const AAction: TWsFlowAction; const ACloseCode: Word);
begin
  inherited Create;
  FRecord := ARecord;
  FWriter := AWriter;
  FAction := AAction;
  FCloseCode := ACloseCode;
end;

function TWsFlowHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TWsFlowHandler.Message(const ASession: IWsSession;
  const AMessage: IBodyReader; const AText: Boolean);
var
  Data: TBytes;
begin
  Data := nil;
  FRecord.MessageStarted.SetEvent;
  try
    Data := ReadAllBody(AMessage);
  except
    on E: Exception do
      FRecord.Failure := E.Message;
  end;
  FRecord.MessageCount := FRecord.MessageCount + 1;
  FRecord.MessageText := AText;
  FRecord.MessageOctets := Length(Data);
  if Length(Data) > 0 then
    FRecord.MessageOk := PatternMatches(@Data[0], Length(Data), 0)
  else
    FRecord.MessageOk := False;
  FRecord.MessageSeen.SetEvent;
  case FAction of
    waStream: ASession.SendStream(FWriter, True);
    waClose: ASession.Close(FCloseCode, cResetReason);
    waAbort: ASession.Abort;
  end;
end;

procedure TWsFlowHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TWsFlowHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  FRecord.ClosedCode := ACode;
  FRecord.ClosedClean := AClean;
  FRecord.ClosedSeen.SetEvent;
end;

procedure TWsFlowHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
  FRecord.Failure := E.Message;
end;

constructor TWsFlowListener.Create;
begin
  inherited Create;
  Opened := TEvent.Create(nil, True, False, '');
  Done := TEvent.Create(nil, True, False, '');
  Octets := TMemoryStream.Create;
  Kind := cKindOpen;
end;

destructor TWsFlowListener.Destroy;
begin
  Opened.Free;
  Done.Free;
  Octets.Free;
  inherited Destroy;
end;

procedure TWsFlowListener.Absorb(const AData: Pointer; const ACount: Integer;
  const ALast: Boolean);
begin
  Inc(Callbacks);
  LastLength := ACount;
  if ACount > 0 then
    Octets.WriteBuffer(PByte(AData)^, ACount);
  if ALast then
  begin
    Inc(LastFlagCount);
    Done.SetEvent;
  end;
end;

procedure TWsFlowListener.OnOpen(const ASocket: IWebSocket);
begin
  Opened.SetEvent;
end;

procedure TWsFlowListener.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  if Length(AText) > 0 then
    Absorb(Pointer(@AText[1]), Length(AText), ALast)
  else
    Absorb(nil, 0, ALast);
end;

procedure TWsFlowListener.OnBytes(const ASocket: IWebSocket; const AData: TBytes;
  const ALast: Boolean);
begin
  if Length(AData) > 0 then
    Absorb(Pointer(@AData[0]), Length(AData), ALast)
  else
    Absorb(nil, 0, ALast);
end;

procedure TWsFlowListener.OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
  const AReason: string);
begin
  Kind := cKindClosed;
  CloseCode := AStatusCode;
  CloseReason := AReason;
  Done.SetEvent;
end;

procedure TWsFlowListener.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  Kind := cKindError;
  ErrorText := AError.Message;
  Done.SetEvent;
end;

procedure TWsH2FlowIntegrationTest.SetUp;
begin
  inherited SetUp;
  FServer := nil;
  FClient := nil;
  FRecord := nil;
  FWriterIntf := nil;
  FCounter := nil;
end;

procedure TWsH2FlowIntegrationTest.TearDown;
begin
  try
    if FClient <> nil then
      CloseClientQuietly(FClient);
    if FServer <> nil then
      FServer.Stop;
  finally
    FClient := nil;
    FServer := nil;
    // the writer lives as long as the test, so the server never sees a freed writer
    FWriterIntf := nil;
    FCounter := nil;
    FreeAndNil(FRecord);
    inherited TearDown;
  end;
end;

procedure TWsH2FlowIntegrationTest.StartServer(const AOptions: TWsOptions;
  const AAction: TWsFlowAction; const ACloseCode: Word; const AWriter: IBodyWriter;
  const AGraceMs: Integer);
var
  Factory: THttp2ServerFactory;
begin
  FRecord := TWsFlowRecord.Create;
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithHandler(TWsFlowHttpHandler.Create(FRecord, AWriter, AAction, ACloseCode))
    .WithHandlerThreads(2).WithIOThreads(1).WithGracefulStopTimeout(AGraceMs)
    .WithClearTextAllowed(True).WithWebSockets(AOptions);
  FServer := Factory.Build;
  FServer.Start;
end;

function TWsH2FlowIntegrationTest.NewClient: IHttpClient;
begin
  Result := THttpClientFactory.Create.WithClearText(ctPriorKnowledge)
    .WithConnectTimeout(2000).WithHeaderTimeout(3000).Build;
end;

function TWsH2FlowIntegrationTest.WsUrl: string;
begin
  Result := 'ws://127.0.0.1:' + IntToStr(FServer.Port) + cPathWs;
end;

function TWsH2FlowIntegrationTest.WsRequest(
  const AListener: IWebSocketListener): IWebSocketRequest;
begin
  Result := TWebSocketRequest.Create(WsUrl, AListener).WithProtocolMode(wpmHttp2)
    .WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000)
    .WithMaxMessageBytes(cClientLimitBytes).WithAutoRequest(True);
end;

procedure TWsH2FlowIntegrationTest.AwaitEvent(const AEvent: TEvent; const AWhat: string);
begin
  AssertEquals(AWhat + ' within 10 s', Ord(wrSignaled), Ord(AEvent.WaitFor(cWaitMs)));
end;

/// waits until the server has the request, and checks that it is an extended CONNECT
procedure TWsH2FlowIntegrationTest.AwaitRequest;
begin
  AwaitEvent(FRecord.RequestSeen, 'the server saw the request');
  AssertEquals('method of the request', cMethodConnect, FRecord.Method);
end;

/// checks that the writer stops at fewer than AMaxCalls calls
// - polls for at most 10 s, until the call count is the same for 500 ms
procedure TWsH2FlowIntegrationTest.AssertWriterParks(const AMaxCalls: Integer);
var
  Deadline: QWord;
  Previous, Current, Stable: Integer;
begin
  Deadline := GetTickCount64 + cWaitMs;
  Previous := -1;
  Stable := 0;
  while (GetTickCount64 < Deadline) and (Stable < 10) do
  begin
    Sleep(50);
    Current := FCounter.Calls;
    if Current = Previous then
      Inc(Stable)
    else
    begin
      Previous := Current;
      Stable := 0;
    end;
  end;
  AssertTrue('the writer was never asked for a chunk', FCounter.Calls > 0);
  AssertTrue('the stream did not park within 10 s (the count still grows)',
    Stable >= 10);
  AssertTrue('the parked stream was asked ' + IntToStr(FCounter.Calls) +
    ' times; expected fewer than ' + IntToStr(AMaxCalls),
    FCounter.Calls < AMaxCalls);
end;

/// checks that the server has not closed the session
procedure TWsH2FlowIntegrationTest.AssertNoServerClose(const AWhat: string);
begin
  AssertEquals(AWhat + ': the server has not ended the session', Ord(wrTimeout),
    Ord(FRecord.ClosedSeen.WaitFor(0)));
end;

procedure TWsH2FlowIntegrationTest.TestServerStreamedMessageReachesTheClient;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  FCounter := TCountingWriter.Create(PatternText(cTotalBytes), cChunkCount);
  FWriterIntf := FCounter;
  StartServer(TWsOptions.Create, waStream, 0, FWriterIntf, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(KeepListener));
    AwaitEvent(Listener.Opened, 'OnOpen');
    AwaitRequest;
    Socket.SendText(cGoText, True);
    AwaitEvent(Listener.Done, 'the last fragment of the 16 MiB message');
    AssertEquals('the socket is still open: no close or error', cKindOpen, Listener.Kind);
    AssertEquals('octets of the message', Int64(cTotalBytes), Listener.Octets.Size);
    AssertTrue('the octets are in the pattern order',
      PatternMatches(PByte(Listener.Octets.Memory), cTotalBytes, 0));
    AssertEquals('only one fragment has ALast', 1, Listener.LastFlagCount);
    // 1024 frames of 16 KiB carry the octets; the end of the body is one more frame,
    // with no octets and with ALast
    AssertEquals('fragments: 1024 frames of 16 KiB and the empty end', cFramesOfServerMessage + 1,
      Listener.Callbacks);
    AssertEquals('the last fragment has no octets', 0, Listener.LastLength);
    AssertEquals('writer calls: 256 chunks and the end', cChunkCount + 1, FCounter.Calls);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2FlowIntegrationTest.TestSlowListenerGetsBackPressure;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Parked: Integer;
  Deadline: QWord;
begin
  FCounter := TCountingWriter.Create(PatternText(cTotalBytes), cChunkCount);
  FWriterIntf := FCounter;
  StartServer(TWsOptions.Create, waStream, 0, FWriterIntf, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    // the demand stays at zero: auto request is off and no Request is called
    Socket := FClient.Send(TWebSocketRequest.Create(WsUrl, KeepListener)
      .WithProtocolMode(wpmHttp2).WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000)
      .WithMaxMessageBytes(cClientLimitBytes).WithAutoRequest(False));
    AwaitEvent(Listener.Opened, 'OnOpen');
    Socket.SendText(cGoText, True);
    Sleep(cParkedMs);
    Parked := FCounter.Calls;
    AssertTrue('the writer was asked for a chunk', Parked > 0);
    AssertTrue('after ' + IntToStr(cParkedMs) + ' ms the writer was asked ' +
      IntToStr(Parked) + ' times; expected far fewer than ' + IntToStr(cChunkCount),
      Parked < cChunkCount div 4);
    AssertWriterParks(cChunkCount div 4);
    AssertEquals('no fragment reached the listener while the demand is zero',
      0, Listener.Callbacks);
    AssertEquals('the message is not complete while the demand is zero',
      Ord(wrTimeout), Ord(Listener.Done.WaitFor(0)));
    Parked := FCounter.Calls;
    Sleep(500);
    AssertEquals('the writer count stays the same while parked', Parked, FCounter.Calls);
    // the listener gives demand, one step at a time, until the message ends
    Deadline := GetTickCount64 + cWaitMs;
    while (Listener.Done.WaitFor(0) <> wrSignaled) and (GetTickCount64 < Deadline) do
    begin
      Socket.Request(64);
      Listener.Done.WaitFor(20);
    end;
    AwaitEvent(Listener.Done, 'the last fragment after Request');
    AssertEquals('the socket is still open: no close or error', cKindOpen, Listener.Kind);
    AssertEquals('octets of the message', Int64(cTotalBytes), Listener.Octets.Size);
    AssertTrue('the octets are in the pattern order',
      PatternMatches(PByte(Listener.Octets.Memory), cTotalBytes, 0));
    AssertEquals('only one fragment has ALast', 1, Listener.LastFlagCount);
    AssertEquals('writer calls: 256 chunks and the end', cChunkCount + 1, FCounter.Calls);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2FlowIntegrationTest.TestClientSendsLargeMessageInFragments;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Big: TBytes;
  I, Pos, N: Integer;
begin
  // the server limits and the frame size are above the message, as the server test does
  StartServer(TWsOptions.Create.WithMaxMessageSize(cServerUploadLimitBytes)
    .WithMaxFrameSize(cServerUploadFrameBytes), waRead, 0, nil, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    SetLength(Big, cUploadBytes);
    for I := 0 to High(Big) do
      Big[I] := PatternByte(I);
    Socket := FClient.Send(WsRequest(KeepListener));
    AwaitEvent(Listener.Opened, 'OnOpen');
    Pos := 0;
    for I := 1 to cUploadFragments do
    begin
      N := cUploadFragmentBytes;
      Socket.SendBinary(Copy(Big, Pos, N), I = cUploadFragments);
      Inc(Pos, N);
    end;
    AwaitEvent(FRecord.MessageSeen, 'the server read the 8 MiB message');
    AssertEquals('one message on the server', 1, FRecord.MessageCount);
    AssertFalse('the server read the message as binary', FRecord.MessageText);
    AssertEquals('octets of the message on the server', Int64(cUploadBytes),
      FRecord.MessageOctets);
    AssertTrue('the octets on the server are in the order of the fragments',
      FRecord.MessageOk);
    AssertEquals('no close code 1009: the session is still open', cKindOpen,
      Listener.Kind);
    AssertEquals('no close from the server', '', FRecord.Failure);
    AssertNoServerClose('after the 8 MiB message');
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2FlowIntegrationTest.TestMessageAboveTheLimitClosesWith1009;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Chunk: TBytes;
  I, Fragments: Integer;
  SendFailure: string;
begin
  SendFailure := '';
  StartServer(TWsOptions.Create.WithMaxMessageSize(cServerLimitBytes), waRead, 0, nil, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(KeepListener));
    AwaitEvent(Listener.Opened, 'OnOpen');
    // 2 MiB in fragments: the server limit of 1 MiB passes in the middle of them
    Fragments := cOverLimitBytes div cLimitFragmentBytes;
    for I := 1 to Fragments do
    begin
      SetLength(Chunk, cLimitFragmentBytes);
      FillChar(Chunk[0], cLimitFragmentBytes, Ord('a'));
      try
        Socket.SendBinary(Chunk, I = Fragments);
      except
        // the server ends the stream after the limit; the send then fails, and the
        // close is checked below
        on E: EHttpWebSocketError do
        begin
          SendFailure := E.ClassName + ': ' + E.Message;
          Break;
        end;
        on E: EHttpConnectionError do
        begin
          SendFailure := E.ClassName + ': ' + E.Message;
          Break;
        end;
      end;
    end;
    if Listener.Done.WaitFor(cWaitMs) <> wrSignaled then
      Fail('the close of the server within 10 s; client input closed: ' +
        BoolToStr(Socket.InputClosed, True) + ', client output closed: ' +
        BoolToStr(Socket.OutputClosed, True) + ', server closed: ' +
        BoolToStr(FRecord.ClosedSeen.WaitFor(0) = wrSignaled, True) +
        ', server failure: "' + FRecord.Failure + '", send failure: "' +
        SendFailure + '"');
    AssertEquals('the session ended with a close, not an error', cKindClosed,
      Listener.Kind);
    AssertEquals('close code of the limit', cCloseTooBig, Listener.CloseCode);
    // the message is longer than the inline limit, so the handler starts before the limit
    AwaitEvent(FRecord.MessageStarted, 'the handler started to read the message');
    AwaitEvent(FRecord.MessageSeen, 'the read of the handler ended after the limit');
    AssertTrue('the read of the handler failed', FRecord.Failure <> '');
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2FlowIntegrationTest.TestServerStopClosesTheClientSocket;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(TWsOptions.Create, waRead, 0, nil, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(KeepListener));
    AwaitEvent(Listener.Opened, 'OnOpen');
    FServer.Stop;
    AwaitEvent(Listener.Done, 'OnClose or OnError after the server stopped');
    AssertTrue('the listener got OnClose or OnError, not a message',
      Listener.Kind <> cKindOpen);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2FlowIntegrationTest.TestServerResetsTheStream;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  // the handler closes with 1008 when it reads the first message
  StartServer(TWsOptions.Create, waClose, cClosePolicy, nil, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(KeepListener));
    AwaitEvent(Listener.Opened, 'OnOpen');
    Socket.SendText(cGoText, True);
    AwaitEvent(Listener.Done, 'OnClose of the server');
    AssertEquals('the session ended with a close', cKindClosed, Listener.Kind);
    AssertEquals('close code of the server', cClosePolicy, Listener.CloseCode);
    AssertEquals('close reason of the server', cResetReason, Listener.CloseReason);
    AwaitEvent(FRecord.ClosedSeen, 'Closed on the server');
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2FlowIntegrationTest.TestServerAbortGivesOnError;
var
  Listener: TWsFlowListener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  // the handler aborts the session: no Close frame goes out, and the client sees a reset
  StartServer(TWsOptions.Create, waAbort, 0, nil, 250);
  FClient := NewClient;
  Listener := TWsFlowListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(KeepListener));
    AwaitEvent(Listener.Opened, 'OnOpen');
    Socket.SendText(cGoText, True);
    AwaitEvent(Listener.Done, 'the end of the session after the abort');
    AssertEquals('the session ended with an error, not a close', cKindError,
      Listener.Kind);
    AssertTrue('OnError has a message', Listener.ErrorText <> '');
    AwaitEvent(FRecord.MessageSeen, 'the server read the message');
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

initialization
  RegisterTest(TWsH2FlowIntegrationTest);

end.
