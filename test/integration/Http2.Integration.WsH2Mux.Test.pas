{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, multiplexing, concurrency, connection sharing, integration, test
notes:
  - This unit holds multiplexing and concurrency tests between the library client and
    the library server. The WebSockets run over HTTP/2 (RFC 8441) on a cleartext
    connection with prior knowledge (h2c).
  - Each test starts its own server on a port that the system picks. TearDown
    stops the server and closes the client.
  - Every wait has a limit of 10 s and fails with a message. No test sleeps for more
    than 2 s; the waits poll every 5 ms.
  - The server counts the connections that the observer reports, so a test can show
    that several sockets share one connection.
  - A message has the form thread|sequence|payload. The server checks each message it
    reads, so a frame of one message that mixes with another one fails the test.
---
}
/// Multiplexing and concurrency tests of a WebSocket over HTTP/2 between the library
/// client and the library server
// - each test starts its own server and stops it in TearDown
unit Http2.Integration.WsH2Mux.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common, Http2.Common.Body, Http2.Common.Headers, Http2.Common.Status,
  Http2.Client, Http2.Client.Errors, Http2.Client.Messages, Http2.Client.Stream,
  Http2.Server, Http2.Server.Observer, Http2.Server.StreamAdapters;

type
  /// the counters of the server side, shared by the handler and the observer
  // - a counter is changed only with InterlockedIncrement, and it is read with
  //   InterlockedExchangeAdd of 0
  TMuxState = class
  public
    /// connections that the server accepted
    Accepted: Integer;
    /// requests on the WebSocket path
    Upgrades: Integer;
    /// complete messages that passed the check of the format
    Messages: Integer;
    /// complete messages that failed the check of the format
    BadMessages: Integer;
    /// sessions whose handler got the Closed call
    SessionsClosed: Integer;
    /// WebSocket sessions that the server opened
    WsOpened: Integer;
    /// WebSocket callbacks that raised an exception
    WsFailed: Integer;
    /// handler exceptions
    HandlerErrors: Integer;
    /// streams that the server refused
    Refused: Integer;
    /// streams that the peer or the server reset
    Resets: Integer;
  end;

  /// the observer that counts the events of the server into a TMuxState
  TMuxObserver = class(TInterfacedObject, IHttp2ServerObserver)
  private
    FState: TMuxState;
  public
    constructor Create(const AState: TMuxState);
    procedure OnEvent(const AEvent: TServerEvent);
  end;

  /// a server handler that serves the paths of the tests
  // - /ws accepts a WebSocket, /echo answers 200 with the text ok, others answer 404
  TMuxHttpHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FState: TMuxState;
  public
    constructor Create(const AState: TMuxState);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the WebSocket handler: it checks each message and echoes it
  TMuxWsHandler = class(TInterfacedObject, IWsHandler)
  private
    FState: TMuxState;
  public
    constructor Create(const AState: TMuxState);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// a client listener that counts the callbacks and keeps the texts in order
  // - the counters are read with InterlockedExchangeAdd of 0 by the test
  TMuxListener = class(TWebSocketListener)
  private
    FPartial: string;
    FTexts: TStringList;
  public
    Lock: TCriticalSection;
    Opened: Integer;
    TextCount: Integer;
    Closed: Integer;
    Errors: Integer;
    CloseCode: Integer;
    ErrorText: string;
    constructor Create;
    destructor Destroy; override;
    /// copies the complete texts, in the order of arrival, into AList
    procedure Snapshot(const AList: TStringList);
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket; const AError: Exception); override;
  end;

  /// a thread that sends messages through one socket
  // - the thread records how many sends returned, and the class and the message of
  //   the exception that ended it, if one did
  TMuxSenderThread = class(TThread)
  private
    FSocket: IWebSocket;
    FThreadNo: Integer;
    FLimit: Integer;
  protected
    procedure Execute; override;
  public
    /// the number of sends that returned; read it with InterlockedExchangeAdd of 0
    Sent: Integer;
    ErrorClass: string;
    ErrorText: string;
    constructor Create(const ASocket: IWebSocket; const AThreadNo, ALimit: Integer);
    /// the number of sends that returned
    function SentCount: Integer;
  end;

  /// the multiplexing and concurrency tests of a WebSocket over HTTP/2
  TWsH2MuxIntegrationTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FObserver: IHttp2ServerObserver;
    FState: TMuxState;
    FClient: IHttpClient;
    procedure StartServer;
    function NewClient: IHttpClient;
    function WsUrl(const APath: string): string;
    function HttpUrl(const APath: string): string;
    function WsRequest(const AListener: IWebSocketListener;
      const AMode: TWsProtocolMode): IWebSocketRequest;
    function OpenStreams: Integer;
    procedure AwaitAtLeast(const ACounter: PInteger; const ATarget: Integer;
      const AWhat: string);
    procedure AwaitOpenStreams(const AValue: Integer; const AWhat: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestManySocketsShareOneConnection;
    procedure TestWebSocketAndHttpRequestShareAConnection;
    procedure TestParallelSendersOnOneSocket;
    procedure TestCloseWhileSending;
    procedure TestRepeatedOpenAndClose;
  end;

implementation

const
  /// the path of the WebSocket route
  cPathWs = '/ws';
  /// the path of an ordinary request that answers 200
  cPathEcho = '/echo';
  /// the body of the ordinary answer on cPathEcho
  cEchoBody = 'ok';
  /// the wait limit of every wait, in milliseconds
  cWaitMs = 10000;
  /// the poll interval of a wait, in milliseconds
  cPollMs = 5;
  /// the limit of the streams of one connection, set on the client and the server
  cStreamLimit = 100;
  /// the close code of a normal close (RFC 6455 section 7.4.1)
  cCloseCodeNormal = 1000;
  /// the socket count of the sharing test
  cSharedSockets = 20;
  /// the messages that each socket sends in the sharing test
  cSharedMessages = 100;
  /// the sender threads of the parallel test
  cSenderThreads = 4;
  /// the messages that each sender thread sends in the parallel test
  cSenderMessages = 250;
  /// the sends that the closing test waits for before it closes the socket
  cSendsBeforeClose = 50;
  /// the send limit of the closing test: the sender must see the close first
  cSendLimit = 1000000;
  /// the number of sockets that open and close one after the other
  cRepeatedRounds = 200;
  /// the time limit for the open streams to return to 0, in milliseconds
  cDrainMs = 5000;
  /// the messages that a session may hold for the application; the tests send
  // bursts with no pause, and the server closes a session past this count, so the
  // test server holds a large queue (the design names a larger queue for bursts)
  cQueuedMessages = 10000;
  /// the tokens of the message bucket and its refill per second; the tests send
  // fewer messages than this, so the bucket never trips
  cMessageTokens = 1000000;

/// the text of a message: thread|sequence|payload, with a payload whose length
/// varies with the sequence
function MuxMessage(const AThread, ASequence: Integer): string;
begin
  Result := IntToStr(AThread) + '|' + IntToStr(ASequence) + '|' +
    StringOfChar(Chr(Ord('a') + (AThread mod 26)), 32 + (ASequence * 7) mod 200);
end;

/// true when AText is the message that MuxMessage builds from its own prefix
function IsMuxMessage(const AText: string): Boolean;
var
  First, Second, ThreadNo, SequenceNo: Integer;
begin
  Result := False;
  First := Pos('|', AText);
  if First < 2 then
    Exit;
  Second := Pos('|', Copy(AText, First + 1, Length(AText)));
  if Second < 1 then
    Exit;
  Second := First + Second;
  ThreadNo := StrToIntDef(Copy(AText, 1, First - 1), -1);
  SequenceNo := StrToIntDef(Copy(AText, First + 1, Second - First - 1), -1);
  if (ThreadNo < 0) or (SequenceNo < 1) then
    Exit;
  Result := AText = MuxMessage(ThreadNo, SequenceNo);
end;

/// the text of a byte string; the bytes are copied, not converted
function TextOf(const AData: TBytes): string;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

/// the bytes of a text; the octets are copied, not converted
function BytesOfText(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

/// closes the socket and does not raise; the test has already checked its result
procedure AbortQuietly(const ASocket: IWebSocket);
begin
  try
    if ASocket <> nil then
      ASocket.Abort;
  except
    // the test has already checked its result
  end;
end;

/// waits until the thread ends, at most AMs ms; answers True when it ended
function WaitThreadEnd(const AThread: TThread; const AMs: Cardinal): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + AMs;
  while (not AThread.Finished) and (GetTickCount64 < Deadline) do
    Sleep(cPollMs);
  Result := AThread.Finished;
end;

/// the WebSocket options of the test server: a large queue and a large message
/// bucket, so that a burst of the tests reaches the handler; the other options are
/// the defaults
function MuxWsOptions: TWsOptions;
begin
  Result := TWsOptions.Create.WithQueuedMessages(cQueuedMessages)
    .WithMessageBucket(TTokenBucketOptions.Create.WithCapacity(cMessageTokens)
      .WithRefillPerSecond(cMessageTokens));
end;

constructor TMuxObserver.Create(const AState: TMuxState);
begin
  inherited Create;
  FState := AState;
end;

procedure TMuxObserver.OnEvent(const AEvent: TServerEvent);
begin
  case AEvent.Kind of
    seConnectionAccepted: InterlockedIncrement(FState.Accepted);
    seWsOpened: InterlockedIncrement(FState.WsOpened);
    seWsFailed: InterlockedIncrement(FState.WsFailed);
    seHandlerException: InterlockedIncrement(FState.HandlerErrors);
    seStreamRefused: InterlockedIncrement(FState.Refused);
    seStreamReset: InterlockedIncrement(FState.Resets);
  end;
end;

constructor TMuxHttpHandler.Create(const AState: TMuxState);
begin
  inherited Create;
  FState := AState;
end;

procedure TMuxHttpHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Headers: THeaderBlock;
  Body: array[0..1] of Byte;
begin
  if ARequest.Path = cPathWs then
  begin
    InterlockedIncrement(FState.Upgrades);
    AcceptWebSocket(ARequest, AResponse, TMuxWsHandler.Create(FState));
    Exit;
  end;
  SetLength(Headers, 0);
  if ARequest.Path = cPathEcho then
  begin
    AResponse.SendHeaders(HttpStatusOk, Headers, False);
    Body[0] := Ord(cEchoBody[1]);
    Body[1] := Ord(cEchoBody[2]);
    AResponse.Write(Body, 2);
    AResponse.Finish;
    Exit;
  end;
  AResponse.SendHeaders(HttpStatusNotFound, Headers, False);
  AResponse.Finish;
end;

constructor TMuxWsHandler.Create(const AState: TMuxState);
begin
  inherited Create;
  FState := AState;
end;

function TMuxWsHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TMuxWsHandler.Message(const ASession: IWsSession;
  const AMessage: IBodyReader; const AText: Boolean);
var
  Data: string;
begin
  Data := TextOf(ReadAllBody(AMessage));
  if AText and IsMuxMessage(Data) then
    InterlockedIncrement(FState.Messages)
  else
    InterlockedIncrement(FState.BadMessages);
  ASession.Send(BytesOfText(Data), AText);
end;

procedure TMuxWsHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TMuxWsHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  InterlockedIncrement(FState.SessionsClosed);
end;

procedure TMuxWsHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

constructor TMuxListener.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  FTexts := TStringList.Create;
  FTexts.Duplicates := dupAccept;
  FPartial := '';
  CloseCode := 0;
end;

destructor TMuxListener.Destroy;
begin
  FTexts.Free;
  Lock.Free;
  inherited Destroy;
end;

procedure TMuxListener.Snapshot(const AList: TStringList);
var
  I: Integer;
begin
  Lock.Acquire;
  try
    AList.Clear;
    for I := 0 to FTexts.Count - 1 do
      AList.Add(FTexts[I]);
  finally
    Lock.Release;
  end;
end;

procedure TMuxListener.OnOpen(const ASocket: IWebSocket);
begin
  InterlockedIncrement(Opened);
end;

procedure TMuxListener.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Lock.Acquire;
  try
    FPartial := FPartial + AText;
    if ALast then
    begin
      FTexts.Add(FPartial);
      FPartial := '';
      InterlockedIncrement(TextCount);
    end;
  finally
    Lock.Release;
  end;
end;

procedure TMuxListener.OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
  const AReason: string);
begin
  Lock.Acquire;
  try
    CloseCode := AStatusCode;
  finally
    Lock.Release;
  end;
  InterlockedIncrement(Closed);
end;

procedure TMuxListener.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  Lock.Acquire;
  try
    if Errors = 0 then
      ErrorText := AError.ClassName + ': ' + AError.Message;
  finally
    Lock.Release;
  end;
  InterlockedIncrement(Errors);
end;

constructor TMuxSenderThread.Create(const ASocket: IWebSocket;
  const AThreadNo, ALimit: Integer);
begin
  FSocket := ASocket;
  FThreadNo := AThreadNo;
  FLimit := ALimit;
  Sent := 0;
  ErrorClass := '';
  ErrorText := '';
  inherited Create(False);
end;

function TMuxSenderThread.SentCount: Integer;
begin
  Result := InterlockedExchangeAdd(Sent, 0);
end;

procedure TMuxSenderThread.Execute;
var
  N: Integer;
begin
  N := 0;
  try
    while N < FLimit do
    begin
      Inc(N);
      FSocket.SendText(MuxMessage(FThreadNo, N), True);
      InterlockedIncrement(Sent);
    end;
  except
    on E: Exception do
    begin
      ErrorClass := E.ClassName;
      ErrorText := E.Message;
    end;
  end;
end;

procedure TWsH2MuxIntegrationTest.SetUp;
begin
  inherited SetUp;
  FServer := nil;
  FObserver := nil;
  FState := nil;
  FClient := nil;
end;

procedure TWsH2MuxIntegrationTest.TearDown;
begin
  try
    if FClient <> nil then
    begin
      try
        FClient.Close;
      except
        // the test has already checked its result
      end;
    end;
    if FServer <> nil then
      FServer.Stop;
  finally
    FClient := nil;
    FServer := nil;
    FObserver := nil;
    FreeAndNil(FState);
    inherited TearDown;
  end;
end;

procedure TWsH2MuxIntegrationTest.StartServer;
var
  Factory: THttp2ServerFactory;
begin
  FState := TMuxState.Create;
  FObserver := TMuxObserver.Create(FState);
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithHandler(TMuxHttpHandler.Create(FState))
    .WithHandlerThreads(2).WithIOThreads(1).WithGracefulStopTimeout(250)
    .WithClearTextAllowed(True)
    .WithMaxConcurrentStreams(LongWord(cStreamLimit))
    .WithWebSockets(MuxWsOptions);
  FServer := Factory.Build(FObserver);
  FServer.Start;
end;

function TWsH2MuxIntegrationTest.NewClient: IHttpClient;
begin
  Result := THttpClientFactory.Create.WithClearText(ctPriorKnowledge)
    .WithConnectTimeout(2000).WithHeaderTimeout(3000)
    .WithMaxStreamsPerConnection(cStreamLimit).Build;
end;

function TWsH2MuxIntegrationTest.WsUrl(const APath: string): string;
begin
  Result := 'ws://127.0.0.1:' + IntToStr(FServer.Port) + APath;
end;

function TWsH2MuxIntegrationTest.HttpUrl(const APath: string): string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FServer.Port) + APath;
end;

function TWsH2MuxIntegrationTest.WsRequest(const AListener: IWebSocketListener;
  const AMode: TWsProtocolMode): IWebSocketRequest;
begin
  Result := TWebSocketRequest.Create(WsUrl(cPathWs), AListener).WithProtocolMode(AMode)
    .WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000).WithAutoRequest(True);
end;

function TWsH2MuxIntegrationTest.OpenStreams: Integer;
begin
  Result := FServer.Stats.OpenStreams;
end;

procedure TWsH2MuxIntegrationTest.AwaitAtLeast(const ACounter: PInteger;
  const ATarget: Integer; const AWhat: string);
var
  Deadline: QWord;
  Value: Integer;
begin
  Deadline := GetTickCount64 + cWaitMs;
  repeat
    Value := InterlockedExchangeAdd(ACounter^, 0);
    if Value >= ATarget then
      Exit;
    Sleep(cPollMs);
  until GetTickCount64 >= Deadline;
  Fail(AWhat + ': ' + IntToStr(Value) + ' of ' + IntToStr(ATarget) + ' within 10 s');
end;

procedure TWsH2MuxIntegrationTest.AwaitOpenStreams(const AValue: Integer;
  const AWhat: string);
var
  Deadline: QWord;
  Value: Integer;
begin
  Deadline := GetTickCount64 + cDrainMs;
  repeat
    Value := OpenStreams;
    if Value = AValue then
      Exit;
    Sleep(cPollMs);
  until GetTickCount64 >= Deadline;
  Fail(AWhat + ': ' + IntToStr(Value) + ' open streams, expected ' + IntToStr(AValue) +
    ' within 5 s');
end;

procedure TWsH2MuxIntegrationTest.TestManySocketsShareOneConnection;
var
  Listeners: array of TMuxListener;
  Keep: array of IWebSocketListener;
  Sockets: array of IWebSocket;
  Expected, Received: TStringList;
  I, M: Integer;
begin
  StartServer;
  FClient := NewClient;
  SetLength(Listeners, cSharedSockets);
  SetLength(Keep, cSharedSockets);
  SetLength(Sockets, cSharedSockets);
  Expected := TStringList.Create;
  Received := TStringList.Create;
  try
    for I := 0 to cSharedSockets - 1 do
    begin
      Listeners[I] := TMuxListener.Create;
      Keep[I] := Listeners[I];
      Sockets[I] := FClient.Send(WsRequest(Keep[I], wpmHttp2));
      AwaitAtLeast(@Listeners[I].Opened, 1, 'OnOpen of socket ' + IntToStr(I));
      AssertEquals('connections after socket ' + IntToStr(I), 1, InterlockedExchangeAdd(FState.Accepted, 0));
    end;
    AssertEquals('server streams with all sockets open', cSharedSockets, OpenStreams);
    // the sockets send in turns, so their frames interleave on the one connection
    for M := 1 to cSharedMessages do
      for I := 0 to cSharedSockets - 1 do
        Sockets[I].SendText(MuxMessage(I + 1, M), True);
    for I := 0 to cSharedSockets - 1 do
    begin
      AwaitAtLeast(@Listeners[I].TextCount, cSharedMessages,
        'echoes of socket ' + IntToStr(I));
      AssertEquals('no listener error of socket ' + IntToStr(I), '', Listeners[I].ErrorText);
      Expected.Clear;
      for M := 1 to cSharedMessages do
        Expected.Add(MuxMessage(I + 1, M));
      Listeners[I].Snapshot(Received);
      AssertEquals('echoed texts of socket ' + IntToStr(I), Expected.Text, Received.Text);
    end;
    AwaitAtLeast(@FState.Messages, cSharedSockets * cSharedMessages, 'messages at the server');
    AssertEquals('no bad message at the server', 0, InterlockedExchangeAdd(FState.BadMessages, 0));
    AssertEquals('WebSockets requested', cSharedSockets, InterlockedExchangeAdd(FState.Upgrades, 0));
    AssertEquals('one connection for all sockets', 1, InterlockedExchangeAdd(FState.Accepted, 0));
    AssertEquals('one connection open on the server', 1, FServer.Stats.OpenConnections);
    AssertEquals('no server error', 0, InterlockedExchangeAdd(FState.HandlerErrors, 0));
    AssertEquals('no refused stream', 0, InterlockedExchangeAdd(FState.Refused, 0));
  finally
    for I := 0 to cSharedSockets - 1 do
      AbortQuietly(Sockets[I]);
    Received.Free;
    Expected.Free;
  end;
end;

procedure TWsH2MuxIntegrationTest.TestWebSocketAndHttpRequestShareAConnection;
var
  Listener: TMuxListener;
  Keep: IWebSocketListener;
  Socket: IWebSocket;
  Response: IHttpResponse;
begin
  StartServer;
  FClient := NewClient;
  Listener := TMuxListener.Create;
  Keep := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(Keep, wpmHttp2));
    AwaitAtLeast(@Listener.Opened, 1, 'OnOpen');
    Socket.SendText(MuxMessage(1, 1), True);
    AwaitAtLeast(@Listener.TextCount, 1, 'the first echo');
    AssertEquals('one connection with the WebSocket open', 1,
      InterlockedExchangeAdd(FState.Accepted, 0));
    // the ordinary request runs while the WebSocket stream is open
    Response := FClient.Send(THttpRequest.Create(hmGet, HttpUrl(cPathEcho)));
    AssertEquals('status of the ordinary request', HttpStatusOk, Response.StatusCode);
    AssertEquals('body of the ordinary request', cEchoBody, ReadText(Response));
    Response := nil;
    AssertEquals('the request used the connection of the WebSocket', 1,
      InterlockedExchangeAdd(FState.Accepted, 0));
    // the WebSocket still works after the request
    Socket.SendText(MuxMessage(1, 2), True);
    AwaitAtLeast(@Listener.TextCount, 2, 'the second echo');
    Socket.SendText(MuxMessage(1, 3), True);
    AwaitAtLeast(@Listener.TextCount, 3, 'the third echo');
    AssertEquals('one connection at the end', 1, InterlockedExchangeAdd(FState.Accepted, 0));
    AssertEquals('one WebSocket request', 1, InterlockedExchangeAdd(FState.Upgrades, 0));
  finally
    AbortQuietly(Socket);
    Socket := nil;
    Keep := nil;
  end;
end;

procedure TWsH2MuxIntegrationTest.TestParallelSendersOnOneSocket;
const
  cTotal = cSenderThreads * cSenderMessages;
var
  Listener: TMuxListener;
  Keep: IWebSocketListener;
  Socket: IWebSocket;
  Senders: array of TMuxSenderThread;
  Expected, Received: TStringList;
  Prefix: string;
  I, M, Mismatch, Last, Index: Integer;
  ThreadNo, SequenceNo, Pipe: Integer;
  Lasts: array of Integer;
  Text: string;
begin
  StartServer;
  FClient := NewClient;
  Listener := TMuxListener.Create;
  Keep := Listener;
  Socket := nil;
  SetLength(Senders, cSenderThreads);
  SetLength(Lasts, cSenderThreads + 1);
  Expected := TStringList.Create;
  Received := TStringList.Create;
  try
    Socket := FClient.Send(WsRequest(Keep, wpmHttp2));
    AwaitAtLeast(@Listener.Opened, 1, 'OnOpen');
    for I := 0 to cSenderThreads - 1 do
      Senders[I] := TMuxSenderThread.Create(Socket, I + 1, cSenderMessages);
    for I := 0 to cSenderThreads - 1 do
    begin
      if not WaitThreadEnd(Senders[I], cWaitMs) then
        Fail('sender thread ' + IntToStr(I + 1) + ' did not end within 10 s');
      AssertEquals('sender ' + IntToStr(I + 1) + ' error class', '', Senders[I].ErrorClass);
      AssertEquals('sends of sender ' + IntToStr(I + 1), cSenderMessages, Senders[I].SentCount);
    end;
    AwaitAtLeast(@FState.Messages, cTotal, 'messages at the server');
    AwaitAtLeast(@Listener.TextCount, cTotal, 'echoes at the client');
    AssertEquals('no bad message at the server', 0, InterlockedExchangeAdd(FState.BadMessages, 0));
    AssertEquals('no listener error', '', Listener.ErrorText);
    // the echoes are the sent messages, each once
    for I := 1 to cSenderThreads do
      for M := 1 to cSenderMessages do
        Expected.Add(MuxMessage(I, M));
    Listener.Snapshot(Received);
    AssertEquals('count of echoes', cTotal, Received.Count);
    Expected.Sort;
    Received.Sort;
    Mismatch := 0;
    for Index := 0 to cTotal - 1 do
      if Expected[Index] <> Received[Index] then
        Inc(Mismatch);
    AssertEquals('echoes that differ from the sent messages', 0, Mismatch);
    // the messages of one sender keep their order on the wire
    Listener.Snapshot(Received);
    for Index := 0 to Received.Count - 1 do
    begin
      Text := Received[Index];
      Pipe := Pos('|', Text);
      ThreadNo := StrToIntDef(Copy(Text, 1, Pipe - 1), 0);
      Prefix := Copy(Text, Pipe + 1, Length(Text));
      SequenceNo := StrToIntDef(Copy(Prefix, 1, Pos('|', Prefix) - 1), 0);
      if (ThreadNo < 1) or (ThreadNo > cSenderThreads) then
        Fail('echo with an unknown sender: ' + Text);
      Last := Lasts[ThreadNo];
      if SequenceNo <= Last then
        Fail('sender ' + IntToStr(ThreadNo) + ' arrived out of order: ' +
          IntToStr(SequenceNo) + ' after ' + IntToStr(Last));
      Lasts[ThreadNo] := SequenceNo;
    end;
    AssertEquals('one connection', 1, InterlockedExchangeAdd(FState.Accepted, 0));
    AssertEquals('no server error', 0, InterlockedExchangeAdd(FState.HandlerErrors, 0));
    AssertEquals('no WebSocket failure at the server', 0, InterlockedExchangeAdd(FState.WsFailed, 0));
  finally
    for I := 0 to cSenderThreads - 1 do
      if Senders[I] <> nil then
      begin
        WaitThreadEnd(Senders[I], cWaitMs);
        Senders[I].Free;
      end;
    AbortQuietly(Socket);
    Socket := nil;
    Keep := nil;
    Received.Free;
    Expected.Free;
  end;
end;

procedure TWsH2MuxIntegrationTest.TestCloseWhileSending;
var
  Listener: TMuxListener;
  Keep: IWebSocketListener;
  Socket: IWebSocket;
  Sender: TMuxSenderThread;
begin
  StartServer;
  FClient := NewClient;
  Listener := TMuxListener.Create;
  Keep := Listener;
  Socket := nil;
  Sender := nil;
  try
    Socket := FClient.Send(WsRequest(Keep, wpmHttp2));
    AwaitAtLeast(@Listener.Opened, 1, 'OnOpen');
    Sender := TMuxSenderThread.Create(Socket, 1, cSendLimit);
    AwaitAtLeast(@Sender.Sent, cSendsBeforeClose, 'sends before the close');
    try
      Socket.Close(cCloseCodeNormal, 'bye');
    except
      on E: EHttpWebSocketClosedError do
        ; // the sender may have seen the close first; the test checks the sender below
    end;
    if not WaitThreadEnd(Sender, cWaitMs) then
      Fail('the sender still runs 10 s after the close');
    if Sender.ErrorClass = '' then
      Fail('the sender ran to its limit of ' + IntToStr(cSendLimit) +
        ' sends and never saw the close');
    AssertEquals('the sender ends with the closed error', 'EHttpWebSocketClosedError',
      Sender.ErrorClass);
    AwaitAtLeast(@Listener.Closed, 1, 'OnClose on the client');
    AssertEquals('close code on the client', cCloseCodeNormal, Listener.CloseCode);
    AwaitAtLeast(@FState.SessionsClosed, 1, 'Closed on the server');
    AwaitAtLeast(@FState.Messages, Sender.SentCount, 'messages of the sender at the server');
    AssertEquals('the server read exactly the sends that returned', Sender.SentCount,
      InterlockedExchangeAdd(FState.Messages, 0));
    AssertEquals('no bad message at the server', 0, InterlockedExchangeAdd(FState.BadMessages, 0));
    AssertEquals('no WebSocket failure at the server', 0, InterlockedExchangeAdd(FState.WsFailed, 0));
  finally
    if Sender <> nil then
    begin
      WaitThreadEnd(Sender, cWaitMs);
      Sender.Free;
    end;
    AbortQuietly(Socket);
    Socket := nil;
    Keep := nil;
  end;
end;

procedure TWsH2MuxIntegrationTest.TestRepeatedOpenAndClose;
var
  I: Integer;
  Listener: TMuxListener;
  Keep: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer;
  FClient := NewClient;
  Socket := nil;
  Keep := nil;
  try
    for I := 1 to cRepeatedRounds do
    begin
      Listener := TMuxListener.Create;
      Keep := Listener;
      Socket := FClient.Send(WsRequest(Keep, wpmHttp2));
      AwaitAtLeast(@Listener.Opened, 1, 'OnOpen of socket ' + IntToStr(I));
      Socket.SendText(MuxMessage(I, 1), True);
      AwaitAtLeast(@Listener.TextCount, 1, 'echo of socket ' + IntToStr(I));
      Socket.Close(cCloseCodeNormal, 'bye');
      AwaitAtLeast(@Listener.Closed, 1, 'OnClose of socket ' + IntToStr(I));
      AssertEquals('close code of socket ' + IntToStr(I), cCloseCodeNormal, Listener.CloseCode);
      Socket := nil;
      Keep := nil;
      // the stream of the closed socket leaves the connection
      AwaitOpenStreams(0, 'open streams after socket ' + IntToStr(I));
      AssertEquals('connections after socket ' + IntToStr(I), 1,
        InterlockedExchangeAdd(FState.Accepted, 0));
    end;
    AssertEquals('WebSocket requests', cRepeatedRounds, InterlockedExchangeAdd(FState.Upgrades, 0));
    AwaitAtLeast(@FState.SessionsClosed, cRepeatedRounds, 'Closed of every session');
    AwaitAtLeast(@FState.Messages, cRepeatedRounds, 'messages at the server');
    AssertEquals('no bad message at the server', 0, InterlockedExchangeAdd(FState.BadMessages, 0));
    AssertEquals('no WebSocket failure at the server', 0, InterlockedExchangeAdd(FState.WsFailed, 0));
    AssertEquals('no refused stream', 0, InterlockedExchangeAdd(FState.Refused, 0));
  finally
    AbortQuietly(Socket);
    Socket := nil;
    Keep := nil;
  end;
end;

initialization
  RegisterTest(TWsH2MuxIntegrationTest);

end.
