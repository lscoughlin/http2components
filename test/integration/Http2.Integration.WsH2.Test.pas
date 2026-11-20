{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, extended connect, rfc 8441, integration, test
notes:
  - This unit holds integration tests between the library client and the library
    server. The client opens a WebSocket over HTTP/2 with the extended CONNECT of
    RFC 8441 on a cleartext connection with prior knowledge (h2c).
  - Each test starts its own server on a port that the system picks. TearDown
    stops the server and closes the client.
  - Every wait has a limit of 10 s and fails with a message.
  - The server handler records the request that it sees: the method, whether the
    request is an HTTP/2 request, and the value of :protocol.
  - A test reads a field of the record only after the event that the handler set
    for that field.
---
}
/// Integration tests of a WebSocket over HTTP/2 between the library client and the
/// library server
// - each test starts its own server and stops it in TearDown
unit Http2.Integration.WsH2.Test;

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
  Http2.Server, Http2.Server.StreamAdapters;

type
  /// what the server handler saw, with one event for each group of fields
  // - the test reads a field only after the event of its group
  TWsH2Record = class
  public
    /// set when the handler sees a request on the WebSocket path
    RequestSeen: TEvent;
    /// set when the handler has the offered subprotocols
    InitSeen: TEvent;
    /// set when the handler has a complete message
    MessageSeen: TEvent;
    /// set when the session has ended
    ClosedSeen: TEvent;
    Method: string;
    IsH2: Boolean;
    Protocol: string;
    Offered: string;
    MessageCount: Integer;
    LastMessage: string;
    LastWasText: Boolean;
    ClosedCode: Integer;
    ClosedClean: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  /// a server handler that serves the paths of the tests
  // - /ws accepts a WebSocket, /echo answers 200 with the text ok, others answer 404
  TWsH2HttpHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FRecord: TWsH2Record;
  public
    constructor Create(const ARecord: TWsH2Record);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the WebSocket handler: it echoes each message, except that the text
  /// close-now makes the server close the session
  TWsH2Handler = class(TInterfacedObject, IWsHandler)
  private
    FRecord: TWsH2Record;
  public
    constructor Create(const ARecord: TWsH2Record);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// a client listener with one event for each kind of callback
  // - the test reads a field only after the event of its callback
  TWsH2Listener = class(TWebSocketListener)
  public
    Opened: TEvent;
    TextDone: TEvent;
    BytesDone: TEvent;
    PongSeen: TEvent;
    ClosedSeen: TEvent;
    ErrorSeen: TEvent;
    Text: string;
    Bytes: TBytes;
    PongData: string;
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
    procedure OnPong(const ASocket: IWebSocket; const AData: TBytes); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket; const AError: Exception); override;
  end;

  /// the integration tests of a WebSocket over HTTP/2
  TWsH2IntegrationTest = class(TTestCase)
  private
    FServer: IHttp2Server;
    FClient: IHttpClient;
    FRecord: TWsH2Record;
    procedure StartServer(const AWithWebSockets: Boolean;
      const AOptions: TWsOptions);
    function NewClient: IHttpClient;
    function WsUrl(const APath: string): string;
    function HttpUrl(const APath: string): string;
    function WsRequest(const AUrl: string; const AListener: IWebSocketListener;
      const AMode: TWsProtocolMode): IWebSocketRequest;
    procedure AwaitEvent(const AEvent: TEvent; const AWhat: string);
    procedure AssertHandshakeRefused(const ARequest: IWebSocketRequest;
      const AStatus: Integer; const AWhat: string);
    procedure AssertNoExtendedConnect(const ARequest: IWebSocketRequest;
      const AWhat: string);
    procedure AwaitRequest(const AMethod: string; const AIsH2: Boolean;
      const AProtocol: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestTextEchoOverHttp2;
    procedure TestBinaryEchoOverHttp2;
    procedure TestTheServerSawHttp2;
    procedure TestSubprotocolIsChosen;
    procedure TestClientCloseEndsBothSides;
    procedure TestServerCloseReachesTheClient;
    procedure TestAbortIsSeenAsAbnormalEnd;
    procedure TestPingPong;
    procedure TestFragmentedMessage;
    procedure TestRefusedPathGives404;
    procedure TestRefusedOriginGives403;
    procedure TestAutoModeUsesHttp2WhenAPooledConnectionExists;
    procedure TestAutoModeWithoutAPooledConnectionUsesHttp1;
    procedure TestHttp2OnlyFailsAgainstAServerWithoutWebSockets;
    procedure TestHttp1ModeStillWorksAgainstTheSameServer;
  end;

implementation

const
  /// the path of the WebSocket route
  cPathWs = '/ws';
  /// the path of an ordinary request that answers 200
  cPathEcho = '/echo';
  /// a path with no route; it answers 404
  cPathMissing = '/nope';
  /// the body of the ordinary answer on cPathEcho
  cEchoBody = 'ok';
  /// the wait for an event, in milliseconds
  cWaitMs = 10000;
  /// the close code of a normal close (RFC 6455 section 7.4.1)
  cCloseCodeNormal = 1000;
  /// the text that makes the server close the session
  cCloseNowText = 'close-now';
  /// the reason that the server sends with its Close frame
  cServerReason = 'server bye';
  /// the origin of a foreign site
  cOriginForeign = 'https://evil.example';
  /// the origin of an allowed partner site
  cOriginPartner = 'https://partner.example';
  /// the first subprotocol that the server offers
  cSubprotocolFirst = 'chat.v1';
  /// the second subprotocol that the server offers and the client asks for
  cSubprotocolSecond = 'chat.v2';
  /// the method of an extended CONNECT request
  cMethodConnect = 'CONNECT';
  /// the value of :protocol for a WebSocket
  cProtocolWebSocket = 'websocket';
  /// the method of an HTTP/1.1 Upgrade request
  cMethodGet = 'GET';

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

/// true when two byte arrays hold the same octets
function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := Length(A) = Length(B);
  if Result and (Length(A) > 0) then
    Result := CompareMem(@A[0], @B[0], Length(A));
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

constructor TWsH2Record.Create;
begin
  inherited Create;
  RequestSeen := TEvent.Create(nil, True, False, '');
  InitSeen := TEvent.Create(nil, True, False, '');
  MessageSeen := TEvent.Create(nil, True, False, '');
  ClosedSeen := TEvent.Create(nil, True, False, '');
end;

destructor TWsH2Record.Destroy;
begin
  RequestSeen.Free;
  InitSeen.Free;
  MessageSeen.Free;
  ClosedSeen.Free;
  inherited Destroy;
end;

constructor TWsH2HttpHandler.Create(const ARecord: TWsH2Record);
begin
  inherited Create;
  FRecord := ARecord;
end;

procedure TWsH2HttpHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Headers: THeaderBlock;
  Connect: IH2ConnectRequest;
  IsH2: Boolean;
  Protocol: string;
  Body: array[0..1] of Byte;
begin
  if ARequest.Path = cPathWs then
  begin
    IsH2 := Supports(ARequest, IH2ConnectRequest, Connect);
    Protocol := '';
    if IsH2 then
      Protocol := Connect.Protocol;
    FRecord.Method := ARequest.Method;
    FRecord.IsH2 := IsH2;
    FRecord.Protocol := Protocol;
    FRecord.RequestSeen.SetEvent;
    AcceptWebSocket(ARequest, AResponse, TWsH2Handler.Create(FRecord));
    Exit;
  end;
  if ARequest.Path = cPathEcho then
  begin
    SetLength(Headers, 0);
    AResponse.SendHeaders(HttpStatusOk, Headers, False);
    Body[0] := Ord(cEchoBody[1]);
    Body[1] := Ord(cEchoBody[2]);
    AResponse.Write(Body, 2);
    AResponse.Finish;
    Exit;
  end;
  SetLength(Headers, 0);
  AResponse.SendHeaders(HttpStatusNotFound, Headers, False);
  AResponse.Finish;
end;

constructor TWsH2Handler.Create(const ARecord: TWsH2Record);
begin
  inherited Create;
  FRecord := ARecord;
end;

function TWsH2Handler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
var
  I: Integer;
  Names: string;
begin
  Names := '';
  for I := 0 to High(AOffered) do
    Names := Names + AOffered[I] + ',';
  FRecord.Offered := Names;
  FRecord.InitSeen.SetEvent;
  for I := 0 to High(AOffered) do
    if AOffered[I] = cSubprotocolSecond then
      Exit(TWsInitResult.AcceptedWith(cSubprotocolSecond));
  Result := TWsInitResult.Accepted;
end;

procedure TWsH2Handler.Message(const ASession: IWsSession;
  const AMessage: IBodyReader; const AText: Boolean);
var
  Data: string;
begin
  Data := TextOf(ReadAllBody(AMessage));
  FRecord.MessageCount := FRecord.MessageCount + 1;
  FRecord.LastMessage := Data;
  FRecord.LastWasText := AText;
  FRecord.MessageSeen.SetEvent;
  if AText and (Data = cCloseNowText) then
    ASession.Close(cCloseCodeNormal, cServerReason)
  else
    ASession.Send(BytesOfText(Data), AText);
end;

procedure TWsH2Handler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TWsH2Handler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  FRecord.ClosedCode := ACode;
  FRecord.ClosedClean := AClean;
  FRecord.ClosedSeen.SetEvent;
end;

procedure TWsH2Handler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

constructor TWsH2Listener.Create;
begin
  inherited Create;
  Opened := TEvent.Create(nil, True, False, '');
  TextDone := TEvent.Create(nil, True, False, '');
  BytesDone := TEvent.Create(nil, True, False, '');
  PongSeen := TEvent.Create(nil, True, False, '');
  ClosedSeen := TEvent.Create(nil, True, False, '');
  ErrorSeen := TEvent.Create(nil, True, False, '');
end;

destructor TWsH2Listener.Destroy;
begin
  Opened.Free;
  TextDone.Free;
  BytesDone.Free;
  PongSeen.Free;
  ClosedSeen.Free;
  ErrorSeen.Free;
  inherited Destroy;
end;

procedure TWsH2Listener.OnOpen(const ASocket: IWebSocket);
begin
  Opened.SetEvent;
end;

procedure TWsH2Listener.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Text := Text + AText;
  if ALast then
    TextDone.SetEvent;
end;

procedure TWsH2Listener.OnBytes(const ASocket: IWebSocket; const AData: TBytes;
  const ALast: Boolean);
var
  Old: Integer;
begin
  Old := Length(Bytes);
  SetLength(Bytes, Old + Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Bytes[Old], Length(AData));
  if ALast then
    BytesDone.SetEvent;
end;

procedure TWsH2Listener.OnPong(const ASocket: IWebSocket; const AData: TBytes);
begin
  PongData := TextOf(AData);
  PongSeen.SetEvent;
end;

procedure TWsH2Listener.OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
  const AReason: string);
begin
  CloseCode := AStatusCode;
  CloseReason := AReason;
  ClosedSeen.SetEvent;
end;

procedure TWsH2Listener.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  ErrorText := AError.Message;
  ErrorSeen.SetEvent;
end;

procedure TWsH2IntegrationTest.SetUp;
begin
  inherited SetUp;
  FServer := nil;
  FClient := nil;
  FRecord := nil;
end;

procedure TWsH2IntegrationTest.TearDown;
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
    FreeAndNil(FRecord);
    inherited TearDown;
  end;
end;

procedure TWsH2IntegrationTest.StartServer(const AWithWebSockets: Boolean;
  const AOptions: TWsOptions);
var
  Factory: THttp2ServerFactory;
begin
  FRecord := TWsH2Record.Create;
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithHandler(TWsH2HttpHandler.Create(FRecord))
    .WithHandlerThreads(2).WithIOThreads(1).WithGracefulStopTimeout(250)
    .WithClearTextAllowed(True);
  if AWithWebSockets then
    Factory := Factory.WithWebSockets(AOptions);
  FServer := Factory.Build;
  FServer.Start;
end;

function TWsH2IntegrationTest.NewClient: IHttpClient;
begin
  Result := THttpClientFactory.Create.WithClearText(ctPriorKnowledge)
    .WithConnectTimeout(2000).WithHeaderTimeout(3000).Build;
end;

function TWsH2IntegrationTest.WsUrl(const APath: string): string;
begin
  Result := 'ws://127.0.0.1:' + IntToStr(FServer.Port) + APath;
end;

function TWsH2IntegrationTest.HttpUrl(const APath: string): string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FServer.Port) + APath;
end;

function TWsH2IntegrationTest.WsRequest(const AUrl: string;
  const AListener: IWebSocketListener; const AMode: TWsProtocolMode): IWebSocketRequest;
begin
  // the listener gets every notification: the demand is one more after each one
  Result := TWebSocketRequest.Create(AUrl, AListener).WithProtocolMode(AMode)
    .WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000).WithAutoRequest(True);
end;

procedure TWsH2IntegrationTest.AwaitEvent(const AEvent: TEvent; const AWhat: string);
begin
  AssertEquals(AWhat + ' within 10 s', Ord(wrSignaled), Ord(AEvent.WaitFor(cWaitMs)));
end;

procedure TWsH2IntegrationTest.AwaitRequest(const AMethod: string;
  const AIsH2: Boolean; const AProtocol: string);
begin
  AwaitEvent(FRecord.RequestSeen, 'the server saw the request');
  AssertEquals('method of the request', AMethod, FRecord.Method);
  AssertEquals('the request is an HTTP/2 request', AIsH2, FRecord.IsH2);
  AssertEquals('value of :protocol', AProtocol, FRecord.Protocol);
end;

procedure TWsH2IntegrationTest.AssertHandshakeRefused(const ARequest: IWebSocketRequest;
  const AStatus: Integer; const AWhat: string);
var
  Socket: IWebSocket;
  Refused: Boolean;
  Status: Integer;
begin
  Socket := nil;
  Refused := False;
  Status := 0;
  try
    Socket := FClient.Send(ARequest);
  except
    on E: EHttpWebSocketHandshakeError do
    begin
      Refused := True;
      Status := E.StatusCode;
    end;
  end;
  if not Refused then
  begin
    AbortQuietly(Socket);
    Fail(AWhat + ': the handshake was not refused');
  end;
  AssertEquals(AWhat + ': status of the refusal', AStatus, Status);
end;

procedure TWsH2IntegrationTest.AssertNoExtendedConnect(const ARequest: IWebSocketRequest;
  const AWhat: string);
var
  Socket: IWebSocket;
  Refused: Boolean;
  ClassOk: Boolean;
begin
  Socket := nil;
  Refused := False;
  ClassOk := False;
  try
    Socket := FClient.Send(ARequest);
  except
    on E: EHttpWebSocketError do
    begin
      Refused := True;
      ClassOk := E.ClassType = EHttpWebSocketError;
    end;
  end;
  if not Refused then
  begin
    AbortQuietly(Socket);
    Fail(AWhat + ': the WebSocket was opened');
  end;
  AssertTrue(AWhat + ': the error is an EHttpWebSocketError, not a subclass', ClassOk);
end;

procedure TWsH2IntegrationTest.TestTextEchoOverHttp2;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    AwaitEvent(Listener.Opened, 'OnOpen');
    Socket.SendText('hello', True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('echoed text', 'hello', Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestBinaryEchoOverHttp2;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Sent: TBytes;
  I: Integer;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    SetLength(Sent, 1000);
    for I := 0 to High(Sent) do
      Sent[I] := Byte(I * 7);
    Socket.SendBinary(Sent, True);
    AwaitEvent(Listener.BytesDone, 'the binary echo');
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('echoed octet count', Length(Sent), Length(Listener.Bytes));
    AssertTrue('echoed octets are the sent octets', SameBytes(Sent, Listener.Bytes));
    AwaitEvent(FRecord.MessageSeen, 'the server message');
    AssertFalse('the server saw a binary message', FRecord.LastWasText);
    AssertEquals('server octet count', Length(Sent), Length(FRecord.LastMessage));
    AssertTrue('server octets are the sent octets', FRecord.LastMessage = TextOf(Sent));
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestTheServerSawHttp2;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestSubprotocolIsChosen;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create.WithSubprotocols(
    [cSubprotocolFirst, cSubprotocolSecond]));
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2)
      .WithSubprotocol(cSubprotocolSecond));
    AwaitEvent(FRecord.InitSeen, 'Init');
    AssertTrue('the server offered the second subprotocol',
      Pos(cSubprotocolSecond + ',', FRecord.Offered) > 0);
    AssertEquals('the client chose the second subprotocol',
      cSubprotocolSecond, Socket.Subprotocol);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestClientCloseEndsBothSides;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    Socket.Close(cCloseCodeNormal, 'client bye');
    AwaitEvent(Listener.ClosedSeen, 'OnClose on the client');
    AssertEquals('client close code', cCloseCodeNormal, Listener.CloseCode);
    AwaitEvent(FRecord.ClosedSeen, 'Closed on the server');
    AssertEquals('server close code', cCloseCodeNormal, FRecord.ClosedCode);
    AssertTrue('the closing handshake completed on the server', FRecord.ClosedClean);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestServerCloseReachesTheClient;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    Socket.SendText(cCloseNowText, True);
    AwaitEvent(Listener.ClosedSeen, 'OnClose on the client');
    AssertEquals('close code from the server', cCloseCodeNormal, Listener.CloseCode);
    AssertEquals('close reason from the server', cServerReason, Listener.CloseReason);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestAbortIsSeenAsAbnormalEnd;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    Socket.Abort;
    AwaitEvent(FRecord.ClosedSeen, 'Closed on the server after the abort');
    AssertTrue('the server close code is not 1000, the code of a normal close',
      FRecord.ClosedCode <> cCloseCodeNormal);
    AssertFalse('the closing handshake did not complete', FRecord.ClosedClean);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestPingPong;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    Socket.SendPing(BytesOfText('p1'));
    AwaitEvent(Listener.PongSeen, 'the pong');
    AssertEquals('pong data', 'p1', Listener.PongData);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestFragmentedMessage;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2));
    Socket.SendText('a', False);
    Socket.SendText('b', False);
    Socket.SendText('c', True);
    AwaitEvent(FRecord.MessageSeen, 'the server message');
    AssertEquals('the server got one message', 1, FRecord.MessageCount);
    AssertEquals('the fragments arrive in order', 'abc', FRecord.LastMessage);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('the echo has the octets in order', 'abc', Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestRefusedPathGives404;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  AssertHandshakeRefused(WsRequest(WsUrl(cPathMissing), KeepListener, wpmHttp2),
    HttpStatusNotFound, 'the path with no route');
end;

procedure TWsH2IntegrationTest.TestRefusedOriginGives403;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create.WithOriginPolicy(opAllowListOnly)
    .WithAllowedOrigins([cOriginPartner]));
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  AssertHandshakeRefused(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2)
    .WithHeader(HeaderOrigin, cOriginForeign), HttpStatusForbidden,
    'a foreign origin');
  // the allowed origin of the allow-list opens the WebSocket
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2)
      .WithHeader(HeaderOrigin, cOriginPartner));
    AwaitEvent(Listener.Opened, 'OnOpen for the allowed origin');
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestAutoModeUsesHttp2WhenAPooledConnectionExists;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
  Response: IHttpResponse;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  // an ordinary request leaves a pooled HTTP/2 connection for the origin
  Response := FClient.Send(THttpRequest.Create(hmGet, HttpUrl(cPathEcho)));
  AssertEquals('ordinary request status', HttpStatusOk, Response.StatusCode);
  AssertEquals('ordinary request body', cEchoBody, ReadText(Response));
  Response := nil;
  AssertEquals('one connection before the WebSocket', 1,
    FServer.Stats.OpenConnections);
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmAuto));
    AwaitRequest(cMethodConnect, True, cProtocolWebSocket);
    AssertEquals('still one connection: the WebSocket reused the pooled one', 1,
      FServer.Stats.OpenConnections);
    Socket.SendText('auto', True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', 'auto', Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestAutoModeWithoutAPooledConnectionUsesHttp1;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    // no request has run on this client, so no pooled connection exists
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmAuto));
    // wpmAuto never dials HTTP/2 for a WebSocket: the server sees the HTTP/1.1 Upgrade
    AwaitRequest(cMethodGet, False, '');
    Socket.SendText('http1', True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', 'http1', Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

procedure TWsH2IntegrationTest.TestHttp2OnlyFailsAgainstAServerWithoutWebSockets;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
begin
  StartServer(False, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  AssertNoExtendedConnect(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp2),
    'wpmHttp2 against a server without WebSockets');
end;

procedure TWsH2IntegrationTest.TestHttp1ModeStillWorksAgainstTheSameServer;
var
  Listener: TWsH2Listener;
  KeepListener: IWebSocketListener;
  Socket: IWebSocket;
begin
  StartServer(True, TWsOptions.Create);
  FClient := NewClient;
  Listener := TWsH2Listener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := FClient.Send(WsRequest(WsUrl(cPathWs), KeepListener, wpmHttp1));
    AwaitRequest(cMethodGet, False, '');
    Socket.SendText('http1 mode', True);
    AwaitEvent(Listener.TextDone, 'the echo');
    AssertEquals('echoed text', 'http1 mode', Listener.Text);
  finally
    AbortQuietly(Socket);
    Socket := nil;
    KeepListener := nil;
  end;
end;

initialization
  RegisterTest(TWsH2IntegrationTest);

end.
