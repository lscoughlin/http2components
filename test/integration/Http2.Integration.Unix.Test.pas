{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds integration tests for a Unix socket. The server listens
    on a socket file and the client connects to the same file.
  - The tests cover cleartext HTTP/2 and HTTP/1.1, a body echo, parallel
    requests, server-sent events, WebSocket, TLS with ALPN, the removal of
    the socket file on Stop, and a connect to a missing file.
  - The TLS test with openssl s_client runs only when the openssl command
    has the -unix option. Otherwise the test is ignored.
  - Each test uses a path under /tmp that TearDown removes.
---
}
/// Integration tests for the server and the client over a Unix socket file
// - each test starts its own server on a fresh socket file
unit Http2.Integration.Unix.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, process, SyncObjs, fpcunit, testregistry,
  Http2.Common, Http2.Client, Http2.Client.Sse, Http2.Server,
  Http2.OpenSSL, Http2.Client.Messages, Http2.Client.Stream,
  Http2.Client.Tls, Http2.Server.Unix.TestKit;

type
  /// the integration tests of the Unix socket file transport
  TUnixIntegrationTest = class(TTestCase)
  private
    FPath: string;
    FServer: IHttp2Server;
    procedure StartServer(const ATls: Boolean);
    function NewClient(const ATls: Boolean;
      const APolicy: TClearTextPolicy): IHttpClient;
    function UrlOf(const ATls: Boolean; const APath: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestH2cPriorKnowledgeGet;
    procedure TestHttp1Get;
    procedure TestPostOneMiBodyEchoes;
    procedure TestTenParallelRequests;
    procedure TestSseThreeEvents;
    procedure TestWebSocketEchoOverHttp1;
    procedure TestTlsH2OverUnix;
    procedure TestTlsOverUnix;
    procedure TestStopRemovesTheFile;
    procedure TestConnectToMissingPathFailsWithinConnectTimeout;
  end;

implementation

type
  /// the server handler: /ws echoes WebSocket messages, /events sends three
  /// server-sent events, / answers hi, and any other path echoes the body
  TUnixIntegrationHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a WebSocket handler that echoes each message
  TUnixEcho = class(TInterfacedObject, IWsHandler)
  public
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// a WebSocket client listener that keeps the text it receives
  TUnixWsListener = class(TWebSocketListener)
  public
    Done: TEvent;
    Received, ErrorText: string;
    CloseCode: Integer;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket; const AError: Exception); override;
  end;

  /// a thread that sends one GET request and checks the answer hi
  TUnixGetThread = class(TThread)
  private
    FClient: IHttpClient;
    FUrl: string;
    FOk: Boolean;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const AUrl: string);
    /// true when the answer is a 200 with the body hi
    property Ok: Boolean read FOk;
    /// the exception text when the request failed
    property ErrorText: string read FErrorText;
  end;

  /// a thread that closes a client or stops a server, so that a hang can be bounded
  TUnixCloseThread = class(TThread)
  private
    FClient: IHttpClient;
    FServer: IHttp2Server;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const AServer: IHttp2Server);
  end;

  /// a thread that posts a body, reads the whole answer and keeps the result
  TUnixPostThread = class(TThread)
  private
    FClient: IHttpClient;
    FUrl: string;
    FSent: TBytes;
    FStatus: Integer;
    FReceived: TBytes;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const AUrl: string;
      const ASent: TBytes);
    property Status: Integer read FStatus;
    property Received: TBytes read FReceived;
    property ErrorText: string read FErrorText;
  end;

/// the path of a file in the PKI directory of the test run
function PkiFile(const AName: string): string;
begin
  Result := GetEnvironmentVariable('HTTP2_TEST_PKI') + '/' + AName;
end;

/// copies what the process wrote so far to AMem
procedure DrainOutput(const AProcess: TProcess; const AMem: TMemoryStream);
var
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  while AProcess.Output.NumBytesAvailable > 0 do
  begin
    N := AProcess.Output.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    AMem.Write(Buf, N);
  end;
end;

/// runs a command with the input text and answers its output, stderr included
// - answers False when the command does not end within 15 s; its output is kept
function RunCommand(const AExe: string; const AArgs: array of string;
  const AInput: string; out AOutput: string): Boolean;
var
  P: TProcess;
  Mem: TMemoryStream;
  I: Integer;
  Deadline: QWord;
  Text: RawByteString;
  TimedOut: Boolean;
begin
  AOutput := '';
  Result := False;
  P := TProcess.Create(nil);
  Mem := TMemoryStream.Create;
  try
    P.Executable := AExe;
    for I := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[I]);
    P.Options := [poUsePipes, poStderrToOutput];
    P.Execute;
    if AInput <> '' then
    begin
      Text := RawByteString(AInput);
      P.Input.Write(Text[1], Length(Text));
    end;
    P.CloseInput;
    Deadline := GetTickCount64 + 15000;
    while P.Running and (GetTickCount64 < Deadline) do
    begin
      DrainOutput(P, Mem);
      Sleep(10);
    end;
    // a command that still runs is stopped, and its output is kept
    TimedOut := P.Running;
    if TimedOut then
      P.Terminate(1);
    DrainOutput(P, Mem);
    SetLength(AOutput, Mem.Size);
    if Mem.Size > 0 then
      Move(Mem.Memory^, AOutput[1], Mem.Size);
    Result := not TimedOut;
  finally
    Mem.Free;
    P.Free;
  end;
end;

procedure TUnixIntegrationHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Buffer: array[0..4095] of Byte;
  Count, N: Integer;
  Headers: THeaderBlock;
  Stream: ISseStream;
  Event: Http2.Server.TSseEvent;
begin
  if ARequest.Path = '/ws' then
  begin
    AcceptWebSocket(ARequest, AResponse, TUnixEcho.Create);
    Exit;
  end;
  if ARequest.Path = '/events' then
  begin
    Stream := StartSse(ARequest, AResponse);
    for N := 1 to 3 do
    begin
      Event := Http2.Server.TSseEvent.Text(UTF8String('event-' + IntToStr(N)));
      Event.Id := UTF8String(IntToStr(N));
      Stream.Send(Event);
    end;
    Stream.Close;
    Exit;
  end;
  SetLength(Headers, 0);
  AResponse.SendHeaders(200, Headers, False);
  if ARequest.Path = '/' then
    AResponse.Write(TEncoding.UTF8.GetBytes('hi'))
  else
    repeat
      Count := ARequest.Read(Buffer, SizeOf(Buffer));
      if Count > 0 then
        AResponse.Write(Buffer, Count);
    until Count = 0;
  AResponse.Finish;
end;

function TUnixEcho.Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
  const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.AcceptedWith('echo');
end;

procedure TUnixEcho.Message(const ASession: IWsSession; const AData: TBytes;
  const AText: Boolean);
begin
  ASession.Send(AData, AText);
end;

procedure TUnixEcho.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TUnixEcho.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
end;

procedure TUnixEcho.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

constructor TUnixWsListener.Create;
begin
  inherited Create;
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TUnixWsListener.Destroy;
begin
  Done.Free;
  inherited Destroy;
end;

procedure TUnixWsListener.OnOpen(const ASocket: IWebSocket);
begin
  ASocket.Request(4);
end;

procedure TUnixWsListener.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Received := Received + AText;
  if ALast then
    ASocket.Close(1000, 'done');
end;

procedure TUnixWsListener.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  CloseCode := AStatusCode;
  Done.SetEvent;
end;

procedure TUnixWsListener.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  ErrorText := AError.Message;
  Done.SetEvent;
end;

constructor TUnixGetThread.Create(const AClient: IHttpClient; const AUrl: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FUrl := AUrl;
end;

procedure TUnixGetThread.Execute;
var
  Response: IHttpResponse;
begin
  try
    Response := FClient.Send(THttpRequest.Create(hmGet, FUrl));
    FOk := (Response.StatusCode = 200) and (ReadText(Response) = 'hi');
  except
    on E: Exception do
      FErrorText := E.ClassName + ': ' + E.Message;
  end;
end;

constructor TUnixPostThread.Create(const AClient: IHttpClient;
  const AUrl: string; const ASent: TBytes);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FUrl := AUrl;
  FSent := ASent;
end;

procedure TUnixPostThread.Execute;
var
  Response: IHttpResponse;
begin
  try
    Response := FClient.Send(THttpRequest.Create(hmPost, FUrl)
      .WithBody(THttpBody.FromBytes(FSent)));
    FStatus := Response.StatusCode;
    FReceived := ReadAllBodyBytes(Response.Body);
  except
    on E: Exception do
      FErrorText := E.ClassName + ': ' + E.Message;
  end;
end;

/// waits until the thread ends, at most AMs ms; answers True when it ended
function WaitThreadEnd(const AThread: TThread; const AMs: Cardinal): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + AMs;
  while (not AThread.Finished) and (GetTickCount64 < Deadline) do
    Sleep(10);
  Result := AThread.Finished;
end;

constructor TUnixCloseThread.Create(const AClient: IHttpClient;
  const AServer: IHttp2Server);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FServer := AServer;
end;

procedure TUnixCloseThread.Execute;
begin
  try
    if FClient <> nil then
      FClient.Close;
    if FServer <> nil then
      FServer.Stop;
  except
    // a failure while the object closes does not change the test result
  end;
end;

/// closes the client and stops the server within 10 s, each on its own thread
// - a Close or a Stop that blocks fails the test; its thread is then not freed
procedure CloseBounded(const AClient: IHttpClient; const AServer: IHttp2Server;
  const AContext: string = '');
var
  Worker: TUnixCloseThread;
begin
  if (AClient = nil) and (AServer = nil) then
    Exit;
  Worker := TUnixCloseThread.Create(AClient, AServer);
  Worker.Start;
  if WaitThreadEnd(Worker, 10000) then
    Worker.Free
  else
    raise EAssertionFailedError.Create(
      'Client.Close or Server.Stop did not end within 10 s' + AContext);
end;

procedure TUnixIntegrationTest.SetUp;
begin
  inherited SetUp;
  FPath := NewUnixTestPath;
  FServer := nil;
end;

procedure TUnixIntegrationTest.TearDown;
begin
  try
    CloseBounded(nil, FServer);
  finally
    FServer := nil;
  end;
  if FPath <> '' then
    DeleteFile(FPath);
  inherited TearDown;
end;

procedure TUnixIntegrationTest.StartServer(const ATls: Boolean);
var
  Factory: THttp2ServerFactory;
  Policy: TTlsServerPolicy;
begin
  Factory := THttp2ServerFactory.Create.WithUnixSocket(FPath)
    .WithClearTextAllowed(not ATls).WithHandler(TUnixIntegrationHandler.Create)
    .WithHandlerThreads(2).WithIOThreads(1).WithGracefulStopTimeout(250);
  if ATls then
  begin
    Policy := TTlsServerPolicy.SecureDefault.WithServerIdentity(
      TOpenSSLIdentity.FromPemFiles(PkiFile('server.crt'), PkiFile('server.key')));
    Factory := Factory.WithTlsContext(TOpenSSLTlsContextFactory.Create
      .WithServerPolicy(Policy).Build);
  end;
  FServer := Factory.Build;
  FServer.Start;
end;

function TUnixIntegrationTest.NewClient(const ATls: Boolean;
  const APolicy: TClearTextPolicy): IHttpClient;
var
  Factory: THttpClientFactory;
  TlsContext: ITLSContext;
begin
  Factory := THttpClientFactory.Create.WithUnixSocket(FPath)
    .WithClearText(APolicy).WithConnectTimeout(2000).WithHeaderTimeout(3000);
  if ATls then
  begin
    // WithCACertFile is refused by this library, so the trust anchor goes in the context
    TlsContext := TOpenSSLTlsContextFactory.Create
      .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithTrustAnchors([
        PkiFile('ca.crt')])).Build;
    Factory := Factory.WithTlsContext(TlsContext);
  end;
  Result := Factory.Build;
end;

function TUnixIntegrationTest.UrlOf(const ATls: Boolean; const APath: string): string;
begin
  if ATls then
    Result := 'https://localhost' + APath
  else
    Result := 'http://localhost' + APath;
end;

procedure TUnixIntegrationTest.TestH2cPriorKnowledgeGet;
var
  Client: IHttpClient;
  Response: IHttpResponse;
begin
  StartServer(False);
  Client := NewClient(False, ctPriorKnowledge);
  try
    Response := Client.Send(THttpRequest.Create(hmGet, UrlOf(False, '/')));
    AssertEquals('status', 200, Response.StatusCode);
    AssertEquals('body', 'hi', ReadText(Response));
  finally
    CloseBounded(Client, nil);
  end;
end;

procedure TUnixIntegrationTest.TestHttp1Get;
var
  Client: IHttpClient;
  Response: IHttpResponse;
begin
  StartServer(False);
  Client := NewClient(False, ctHttp1);
  try
    Response := Client.Send(THttpRequest.Create(hmGet, UrlOf(False, '/')));
    AssertEquals('status', 200, Response.StatusCode);
    AssertEquals('body', 'hi', ReadText(Response));
  finally
    CloseBounded(Client, nil);
  end;
end;

procedure TUnixIntegrationTest.TestPostOneMiBodyEchoes;
const
  cLimitMs = 30000;
var
  Client: IHttpClient;
  Worker: TUnixPostThread;
  Sent: TBytes;
  I: Integer;
  Ended: Boolean;
  Cause: string;
begin
  StartServer(False);
  SetLength(Sent, 1024 * 1024);
  for I := 0 to High(Sent) do
    Sent[I] := Byte(I mod 251);
  Client := NewClient(False, ctPriorKnowledge);
  Worker := TUnixPostThread.Create(Client, UrlOf(False, '/echo'), Sent);
  Cause := '';
  try
    try
      Worker.Start;
      // the request runs on a thread, so a stalled body fails the test
      Ended := WaitThreadEnd(Worker, cLimitMs);
      if not Ended then
      begin
        // Close aborts the stream so that the thread can end
        CloseBounded(Client, nil);
        if not WaitThreadEnd(Worker, 5000) then
          Worker := nil; // the thread still blocks: it is not freed
        Fail('the 1 MiB echo did not end within ' + IntToStr(cLimitMs div 1000) +
          ' s (stalled flow control)');
      end;
      AssertEquals('no error: ' + Worker.ErrorText, '', Worker.ErrorText);
      AssertEquals('status', 200, Worker.Status);
      AssertEquals('length of the echo', Length(Sent), Length(Worker.Received));
      AssertTrue('the echo preserves every byte',
        CompareMem(@Sent[0], @Worker.Received[0], Length(Sent)));
    except
      on E: Exception do
      begin
        Cause := ' (the request failed first: ' + E.Message + ')';
        raise;
      end;
    end;
  finally
    try
      CloseBounded(Client, nil, Cause);
    finally
      // a thread that still runs is not freed, because Free waits for it
      if (Worker <> nil) and Worker.Finished then
        Worker.Free;
    end;
  end;
end;

procedure TUnixIntegrationTest.TestTenParallelRequests;
const
  cWorkers = 10;
  cLimitMs = 30000;
var
  Client: IHttpClient;
  Workers: array of TUnixGetThread;
  I: Integer;
  Deadline, Now: QWord;
  Ended: Boolean;
begin
  StartServer(False);
  Client := NewClient(False, ctPriorKnowledge);
  SetLength(Workers, cWorkers);
  try
    for I := 0 to cWorkers - 1 do
      Workers[I] := TUnixGetThread.Create(Client, UrlOf(False, '/'));
    for I := 0 to cWorkers - 1 do
      Workers[I].Start;
    Deadline := GetTickCount64 + cLimitMs;
    for I := 0 to cWorkers - 1 do
    begin
      Now := GetTickCount64;
      if Now >= Deadline then
        Ended := Workers[I].Finished
      else
        Ended := WaitThreadEnd(Workers[I], Deadline - Now);
      if not Ended then
      begin
        CloseBounded(Client, nil);
        Fail('worker ' + IntToStr(I) + ' did not end within ' +
          IntToStr(cLimitMs div 1000) + ' s');
      end;
      AssertTrue('worker ' + IntToStr(I) + ' answers 200 hi: ' +
        Workers[I].ErrorText, Workers[I].Ok);
    end;
  finally
    CloseBounded(Client, nil);
    for I := 0 to cWorkers - 1 do
      if (Workers[I] <> nil) and Workers[I].Finished then
        Workers[I].Free;
  end;
end;

procedure TUnixIntegrationTest.TestSseThreeEvents;
var
  Client: IHttpClient;
  Response: IHttpResponse;
  Source: IHttpSseSource;
  Event: Http2.Client.Sse.TSseEvent;
  N: Integer;
begin
  StartServer(False);
  Client := NewClient(False, ctPriorKnowledge);
  try
    Response := Client.Send(THttpRequest.Create(hmGet, UrlOf(False, '/events'))
      .WithSseReadTimeout(3000));
    Source := TSseSource.Create(Response);
    try
      for N := 1 to 3 do
      begin
        AssertTrue('event ' + IntToStr(N) + ' arrives', Source.ReadEvent(Event));
        AssertEquals('event ID', IntToStr(N), Event.Id);
        AssertEquals('event data', 'event-' + IntToStr(N), Event.Data);
      end;
      AssertFalse('the stream ends after three events', Source.ReadEvent(Event));
    finally
      Source.Close;
      Source := nil;
    end;
    Response := nil;
  finally
    CloseBounded(Client, nil);
  end;
end;

procedure TUnixIntegrationTest.TestWebSocketEchoOverHttp1;
var
  Client: IHttpClient;
  Socket: IWebSocket;
  Listener: TUnixWsListener;
  KeepListener: IWebSocketListener;
begin
  StartServer(False);
  Client := NewClient(False, ctHttp1);
  Listener := TUnixWsListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := Client.Send(TWebSocketRequest.Create(UrlOf(False, '/ws'), KeepListener)
      .WithSubprotocol('echo').WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000));
    AssertEquals('selected subprotocol', 'echo', Socket.Subprotocol);
    Socket.SendText('hello ', False);
    Socket.SendText('world', True);
    AssertEquals('bounded close', Ord(wrSignaled),
      Ord(Listener.Done.WaitFor(5000)));
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('fragmented text echo', 'hello world', Listener.Received);
    AssertEquals('close status', 1000, Listener.CloseCode);
  finally
    if Socket <> nil then
      Socket.Abort;
    Socket := nil;
    CloseBounded(Client, nil);
    KeepListener := nil;
  end;
end;

procedure TUnixIntegrationTest.TestTlsH2OverUnix;
var
  Client: IHttpClient;
  Response: IHttpResponse;
begin
  if not FileExists(PkiFile('server.crt')) then
    Ignore('the PKI directory has no server.crt, so no TLS handshake runs');
  StartServer(True);
  Client := NewClient(True, ctReject);
  try
    Response := Client.Send(THttpRequest.Create(hmGet, UrlOf(True, '/')));
    AssertEquals('status', 200, Response.StatusCode);
    AssertEquals('body', 'hi', ReadText(Response));
  finally
    CloseBounded(Client, nil);
  end;
end;

procedure TUnixIntegrationTest.TestTlsOverUnix;
var
  Exe, Output: string;
  Ran: Boolean;
begin
  Exe := FileSearch('openssl', GetEnvironmentVariable('PATH'));
  if Exe = '' then
    Ignore('the openssl command is absent, so no handshake runs');
  if not FileExists(PkiFile('server.crt')) then
    Ignore('the PKI directory has no server.crt, so no TLS handshake runs');
  Ran := RunCommand(Exe, ['s_client', '-help'], '', Output);
  if (not Ran) or (Pos('-unix', Output) = 0) then
    Ignore('openssl s_client has no -unix option, so no handshake runs');
  StartServer(True);
  // -brief is not used: this OpenSSL prints no ALPN line in the brief summary
  Ran := RunCommand(Exe, ['s_client', '-unix', FPath, '-alpn', 'h2'],
    'Q' + #10, Output);
  AssertTrue('the openssl command ends within 15 s', Ran);
  AssertTrue('ALPN protocol: h2 expected, got: ' + Output,
    Pos('ALPN protocol: h2', Output) > 0);
end;

procedure TUnixIntegrationTest.TestStopRemovesTheFile;
begin
  StartServer(False);
  AssertTrue('the socket file exists after Start', UnixPathIsSocket(FPath));
  CloseBounded(nil, FServer);
  FServer := nil;
  AssertFalse('Stop removes the socket file', UnixPathExists(FPath));
end;

procedure TUnixIntegrationTest.TestConnectToMissingPathFailsWithinConnectTimeout;
var
  Client: IHttpClient;
  Response: IHttpResponse;
  Started, Elapsed: QWord;
  Raised: Boolean;
  Name: string;
begin
  // the path is never bound, so the connect finds no file
  Client := THttpClientFactory.Create.WithUnixSocket(FPath)
    .WithClearText(ctPriorKnowledge).WithConnectTimeout(300)
    .WithHeaderTimeout(3000).Build;
  Raised := False;
  Name := '';
  Started := GetTickCount64;
  try
    Response := Client.Send(THttpRequest.Create(hmGet, UrlOf(False, '/')));
    Response := nil;
  except
    on E: Exception do
    begin
      Raised := E is EHttpConnectionError;
      Name := E.ClassName;
    end;
  end;
  Elapsed := GetTickCount64 - Started;
  CloseBounded(Client, nil);
  AssertTrue('a missing path raises a connection error, got ' + Name, Raised);
  AssertTrue('the failure comes within the connect timeout, elapsed ms: ' +
    IntToStr(Elapsed), Elapsed < 3000);
end;

initialization
  RegisterTest(TUnixIntegrationTest);

end.
