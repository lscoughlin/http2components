{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Integration.Events.Test;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
interface
uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client, Http2.Client.Sse, Http2.Server;
type
  TCombinedEventsTest = class(TTestCase)
  private
    procedure SseExchange(const AHttp1: Boolean);
    procedure WebSocketExchange(const ATls: Boolean);
  published
    procedure TestSseHttp2Resume;
    procedure TestSseHttp1Resume;
    procedure TestWebSocketClearText;
    procedure TestWebSocketTls;
  end;
implementation
type
  TEcho = class(TInterfacedObject, IWsHandler)
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes; const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;
  TEventHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
  end;
  TListener = class(TWebSocketListener)
    Done: TEvent;
    Received, ErrorText: string;
    CloseCode: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string; const ALast: Boolean); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket; const AError: Exception); override;
  end;
function TEcho.Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
  const ASession: IWsSession): TWsInitResult;
begin Result := TWsInitResult.AcceptedWith('echo'); end;
procedure TEcho.Message(const ASession: IWsSession; const AData: TBytes; const AText: Boolean);
begin ASession.Send(AData, AText); end;
procedure TEcho.Pong(const ASession: IWsSession; const AData: TBytes);
begin end;
procedure TEcho.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin end;
procedure TEcho.Failed(const ASession: IWsSession; const E: Exception);
begin end;
procedure TEventHandler.Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
var
  Stream: ISseStream;
  Event: Http2.Server.TSseEvent;
  Number: Integer;
begin
  if ARequest.Path = '/ws' then
  begin
    AcceptWebSocket(ARequest, AResponse, TEcho.Create);
    Exit;
  end;
  Stream := StartSse(ARequest, AResponse);
  Number := StrToIntDef(string(Stream.LastEventId), 0) + 1;
  Event := Http2.Server.TSseEvent.Text(UTF8String('event-' + IntToStr(Number)));
  Event.Id := UTF8String(IntToStr(Number));
  Stream.Send(Event);
  Stream.Close;
end;
function EventServer(const ATls: Boolean): IHttp2Server;
var Factory: THttp2ServerFactory; Pki: string;
begin
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithClearTextAllowed(not ATls).WithHandlerThreads(2).WithIOThreads(1)
    .WithGracefulStopTimeout(250).WithHandler(TEventHandler.Create);
  if ATls then
  begin
    Pki := GetEnvironmentVariable('HTTP2_TEST_PKI');
    Factory := Factory.WithTls(TTlsServerOptions.Create
      .WithCertificateFile(Pki + '/server.crt').WithKeyFile(Pki + '/server.key'));
  end;
  Result := Factory.Build;
  Result.Start;
end;
procedure TCombinedEventsTest.SseExchange(const AHttp1: Boolean);
var
  Server: IHttp2Server;
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Response: IHttpResponse;
  Source: IHttpSseSource;
  Event: Http2.Client.Sse.TSseEvent;
  Request: THttpRequest;
  Number: Integer;
  LastId: string;
begin
  Server := EventServer(False);
  Factory := THttpClientFactory.Create.WithHeaderTimeout(3000);
  if AHttp1 then Factory := Factory.WithClearText(ctHttp1)
  else Factory := Factory.WithClearText(ctPriorKnowledge);
  Client := Factory.Build;
  try
    LastId := '';
    for Number := 1 to 2 do
    begin
      Request := THttpRequest.Create(hmGet, 'http://localhost:' + IntToStr(Server.Port) + '/events')
        .WithSseReadTimeout(3000);
      if LastId <> '' then Request := Request.WithHeader('last-event-id', LastId);
      Response := Client.Send(Request);
      Source := TSseSource.Create(Response);
      AssertTrue('event received', Source.ReadEvent(Event));
      AssertEquals('event ID', IntToStr(Number), Event.Id);
      AssertEquals('event data', 'event-' + IntToStr(Number), Event.Data);
      LastId := Source.LastEventId;
      AssertFalse('stream ended', Source.ReadEvent(Event));
      Source.Close;
      Source := nil;
      Response := nil;
    end;
  finally
    if Source <> nil then Source.Close;
    Client.Close;
    Server.Stop;
  end;
end;
constructor TListener.Create;
begin inherited Create; Done := TEvent.Create(nil, True, False, ''); end;
destructor TListener.Destroy;
begin Done.Free; inherited Destroy; end;
procedure TListener.OnOpen(const ASocket: IWebSocket);
begin ASocket.Request(4); end;
procedure TListener.OnText(const ASocket: IWebSocket; const AText: string; const ALast: Boolean);
begin
  Received := Received + AText;
  if ALast then ASocket.Close(1000, 'done');
end;
procedure TListener.OnClose(const ASocket: IWebSocket; const AStatusCode: Integer; const AReason: string);
begin CloseCode := AStatusCode; Done.SetEvent; end;
procedure TListener.OnError(const ASocket: IWebSocket; const AError: Exception);
begin ErrorText := AError.Message; Done.SetEvent; end;
procedure TCombinedEventsTest.WebSocketExchange(const ATls: Boolean);
var
  Server: IHttp2Server;
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Socket: IWebSocket;
  Listener: TListener;
  KeepListener: IWebSocketListener;
  Scheme: string;
begin
  Server := EventServer(ATls);
  Factory := THttpClientFactory.Create;
  if ATls then Factory := Factory.WithCACertFile(GetEnvironmentVariable('HTTP2_TEST_PKI') + '/ca.crt');
  Client := Factory.Build;
  Listener := TListener.Create;
  KeepListener := Listener;
  try
    if ATls then Scheme := 'wss' else Scheme := 'ws';
    Socket := Client.Send(TWebSocketRequest.Create(Scheme + '://localhost:' + IntToStr(Server.Port) + '/ws', KeepListener)
      .WithSubprotocol('echo').WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000));
    AssertEquals('selected subprotocol', 'echo', Socket.Subprotocol);
    Socket.SendText('hello ', False);
    Socket.SendText('world', True);
    AssertEquals('bounded close', Ord(wrSignaled), Ord(Listener.Done.WaitFor(5000)));
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('fragmented text echo', 'hello world', Listener.Received);
    AssertEquals('close status', 1000, Listener.CloseCode);
  finally
    if Socket <> nil then Socket.Abort;
    Socket := nil;
    Client.Close;
    Server.Stop;
    KeepListener := nil;
  end;
end;
procedure TCombinedEventsTest.TestSseHttp2Resume;
begin SseExchange(False); end;
procedure TCombinedEventsTest.TestSseHttp1Resume;
begin SseExchange(True); end;
procedure TCombinedEventsTest.TestWebSocketClearText;
begin WebSocketExchange(False); end;
procedure TCombinedEventsTest.TestWebSocketTls;
begin WebSocketExchange(True); end;
initialization
  RegisterTest(TCombinedEventsTest);
end.
