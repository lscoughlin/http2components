{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, backpressure, test
notes:
  - This unit holds integration tests for a streamed WebSocket message. The
    server sends the message with SendStream and a body writer. A real client
    reads it over a Unix socket file.
  - The first test checks that the octets arrive in order, as the fragments of
    one message, and that the writer is asked once per chunk and once more for
    the end of the body.
  - The second test checks backpressure. The client holds its demand at zero,
    so the stream parks and the writer is not asked for every chunk. Then the
    client requests the rest, and the stream completes.
  - Each test uses a path under /tmp that TearDown removes.
---
}
/// Integration tests for a WebSocket message that the server streams to a client
// - each test starts its own server on a fresh socket file
unit Http2.Integration.WsStream.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Body, Http2.Common, Http2.Client, Http2.Server,
  Http2.Client.Messages, Http2.Client.Stream, Http2.Server.Unix.TestKit;

type
  /// a body writer that counts its calls and writes the expected text
  // - call 1 to 50 write one chunk each and answer True
  // - call 51 writes nothing and answers False, which ends the body
  TCountingWriter = class(TInterfacedObject, IBodyWriter)
  private
    FText: string;
    FCalls: Integer;
  public
    constructor Create(const AText: string);
    function NextChunk(const ABuffer: TStream): Boolean;
    /// the number of calls so far; safe to read from the test thread
    function Calls: Integer;
  end;

  /// the integration tests of a streamed WebSocket message
  TWsStreamIntegrationTest = class(TTestCase)
  private
    FPath: string;
    FServer: IHttp2Server;
    FWriterIntf: IBodyWriter;
    FCounter: TCountingWriter;
    procedure StartServer;
    function NewClient: IHttpClient;
    function UrlOf(const APath: string): string;
    procedure AssertWriterParks(const AMaxCalls: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestStreamedMessageReachesTheClient;
    procedure TestSlowReaderGetsBackpressure;
  end;

implementation

const
  /// the octets of one chunk that the writer sends
  // - the test uses 65536 octets, so 200 chunks make 13 107 200 octets
  // - 1000 octets and 50 chunks fit in the buffers of a Linux loopback, so
  //   the stream never parked
  // - the client limit is 16 MiB for one message, so 200 chunks stay under it
  cChunkBytes = 65536;
  /// the chunks of the body, before the writer answers False
  cChunkCount = 200;
  /// the octets of the whole message
  cTotalBytes = cChunkBytes * cChunkCount;
  /// the wait for a message, in milliseconds
  cWaitMs = 10000;

type
  /// the server handler: /ws accepts a WebSocket, any other path answers 404
  TWsStreamHttpHandler = class(TInterfacedObject, IHttp2Handler)
  private
    FWriter: IBodyWriter;
  public
    constructor Create(const AWriter: IBodyWriter);
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// a WebSocket handler that streams the writer for each message it gets
  TWsStreamHandler = class(TInterfacedObject, IWsHandler)
  private
    FWriter: IBodyWriter;
  public
    constructor Create(const AWriter: IBodyWriter);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// a WebSocket client listener that collects the text and its ALast flags
  // - Done is set at the first fragment with ALast, or on an error or a close
  TWsStreamListener = class(TWebSocketListener)
  public
    Done: TEvent;
    Text: string;
    Callbacks: Integer;
    LastFlagCount: Integer;
    LastFlagIndex: Integer;
    ErrorText: string;
    Closed: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket; const AError: Exception); override;
  end;

/// the text that the writer sends: the octets 'a' to 'z' in a repeating order
function ExpectedText: string;
var
  I: Integer;
begin
  SetLength(Result, cTotalBytes);
  for I := 1 to cTotalBytes do
    Result[I] := Chr(Ord('a') + ((I - 1) mod 26));
end;

constructor TCountingWriter.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FCalls := 0;
end;

function TCountingWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  Index: Integer;
begin
  Index := InterlockedIncrement(FCalls) - 1;
  if Index < cChunkCount then
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

constructor TWsStreamHttpHandler.Create(const AWriter: IBodyWriter);
begin
  inherited Create;
  FWriter := AWriter;
end;

procedure TWsStreamHttpHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Headers: THeaderBlock;
begin
  if ARequest.Path = '/ws' then
  begin
    AcceptWebSocket(ARequest, AResponse, TWsStreamHandler.Create(FWriter));
    Exit;
  end;
  SetLength(Headers, 0);
  AResponse.SendHeaders(404, Headers, False);
  AResponse.Finish;
end;

constructor TWsStreamHandler.Create(const AWriter: IBodyWriter);
begin
  inherited Create;
  FWriter := AWriter;
end;

function TWsStreamHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TWsStreamHandler.Message(const ASession: IWsSession; const AData: TBytes;
  const AText: Boolean);
begin
  // the client sends one message to start the stream
  ASession.SendStream(FWriter, True);
end;

procedure TWsStreamHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TWsStreamHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
end;

procedure TWsStreamHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

constructor TWsStreamListener.Create;
begin
  inherited Create;
  Done := TEvent.Create(nil, True, False, '');
  LastFlagIndex := -1;
end;

destructor TWsStreamListener.Destroy;
begin
  Done.Free;
  inherited Destroy;
end;

procedure TWsStreamListener.OnOpen(const ASocket: IWebSocket);
begin
  // the demand is set by the test, so OnOpen asks for nothing
end;

procedure TWsStreamListener.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Text := Text + AText;
  Inc(Callbacks);
  if ALast then
  begin
    Inc(LastFlagCount);
    LastFlagIndex := Callbacks - 1;
    Done.SetEvent;
  end;
end;

procedure TWsStreamListener.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  Closed := True;
  Done.SetEvent;
end;

procedure TWsStreamListener.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  ErrorText := AError.Message;
  Done.SetEvent;
end;

procedure TWsStreamIntegrationTest.SetUp;
begin
  inherited SetUp;
  FPath := NewUnixTestPath;
  FServer := nil;
  FWriterIntf := nil;
  FCounter := nil;
end;

procedure TWsStreamIntegrationTest.TearDown;
begin
  try
    if FServer <> nil then
      FServer.Stop;
  finally
    FServer := nil;
    // the writer lives as long as the test, so the server never sees a freed writer
    FWriterIntf := nil;
    FCounter := nil;
    if FPath <> '' then
      DeleteFile(FPath);
    inherited TearDown;
  end;
end;

procedure TWsStreamIntegrationTest.StartServer;
var
  Factory: THttp2ServerFactory;
begin
  // the class reference is kept for the call count; the interface keeps the object alive
  FCounter := TCountingWriter.Create(ExpectedText);
  FWriterIntf := FCounter;
  Factory := THttp2ServerFactory.Create.WithUnixSocket(FPath)
    .WithClearTextAllowed(True)
    .WithHandler(TWsStreamHttpHandler.Create(FWriterIntf))
    .WithHandlerThreads(2).WithIOThreads(1).WithGracefulStopTimeout(250);
  FServer := Factory.Build;
  FServer.Start;
end;

function TWsStreamIntegrationTest.NewClient: IHttpClient;
var
  Factory: THttpClientFactory;
begin
  Factory := THttpClientFactory.Create.WithUnixSocket(FPath)
    .WithClearText(ctHttp1).WithConnectTimeout(2000).WithHeaderTimeout(3000);
  Result := Factory.Build;
end;

function TWsStreamIntegrationTest.UrlOf(const APath: string): string;
begin
  Result := 'http://localhost' + APath;
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

/// checks that the writer stops at fewer than AMaxCalls calls
// - polls for at most 10 s, until the call count is the same for 500 ms
procedure TWsStreamIntegrationTest.AssertWriterParks(const AMaxCalls: Integer);
var
  Writer: TCountingWriter;
  Deadline: QWord;
  Previous, Current, Stable: Integer;
begin
  Writer := FCounter;
  Deadline := GetTickCount64 + cWaitMs;
  Previous := -1;
  Stable := 0;
  while (GetTickCount64 < Deadline) and (Stable < 10) do
  begin
    Sleep(50);
    Current := Writer.Calls;
    if Current = Previous then
      Inc(Stable)
    else
    begin
      Previous := Current;
      Stable := 0;
    end;
  end;
  AssertTrue('the writer was never asked for a chunk', Writer.Calls > 0);
  AssertTrue('the stream did not park within 10 s (the count still grows)',
    Stable >= 10);
  AssertTrue('the parked stream was asked ' + IntToStr(Writer.Calls) +
    ' times; expected fewer than ' + IntToStr(AMaxCalls),
    Writer.Calls < AMaxCalls);
end;

procedure TWsStreamIntegrationTest.TestStreamedMessageReachesTheClient;
var
  Client: IHttpClient;
  Socket: IWebSocket;
  Listener: TWsStreamListener;
  KeepListener: IWebSocketListener;
  Writer: TCountingWriter;
begin
  StartServer;
  Writer := FCounter;
  Client := NewClient;
  Listener := TWsStreamListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    Socket := Client.Send(TWebSocketRequest.Create(UrlOf('/ws'), KeepListener)
      .WithAutoRequest(True).WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000));
    Socket.SendText('go', True);
    AssertEquals('the last fragment within 10 s', Ord(wrSignaled),
      Ord(Listener.Done.WaitFor(cWaitMs)));
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertFalse('the socket closed before the message ended', Listener.Closed);
    // one chunk is at least one fragment, so the client sees at least one callback per chunk
    AssertTrue('the message came in one piece, not one fragment per chunk',
      Listener.Callbacks >= cChunkCount);
    AssertEquals('only one fragment has ALast', 1, Listener.LastFlagCount);
    AssertEquals('the fragment with ALast is the last callback',
      Listener.Callbacks - 1, Listener.LastFlagIndex);
    AssertEquals('octet count', cTotalBytes, Length(Listener.Text));
    AssertTrue('the octets arrive in order', Listener.Text = ExpectedText);
    AssertEquals('writer calls: 50 chunks and the end', cChunkCount + 1, Writer.Calls);
  finally
    if Socket <> nil then
      Socket.Abort;
    Socket := nil;
    KeepListener := nil;
    CloseClientQuietly(Client);
  end;
end;

procedure TWsStreamIntegrationTest.TestSlowReaderGetsBackpressure;
var
  Client: IHttpClient;
  Socket: IWebSocket;
  Listener: TWsStreamListener;
  KeepListener: IWebSocketListener;
  Writer: TCountingWriter;
  Parked: Integer;
begin
  StartServer;
  Writer := FCounter;
  Client := NewClient;
  Listener := TWsStreamListener.Create;
  KeepListener := Listener;
  Socket := nil;
  try
    // auto request is off, so the demand stays at zero after OnOpen
    Socket := Client.Send(TWebSocketRequest.Create(UrlOf('/ws'), KeepListener)
      .WithAutoRequest(False).WithConnectTimeoutMs(3000).WithCloseTimeoutMs(1000));
    Socket.SendText('go', True);
    // the server stream parks: the writer is not asked for every chunk, and it stops
    AssertWriterParks(cChunkCount);
    Parked := Writer.Calls;
    AssertEquals('no fragment reached the client while the demand is zero',
      0, Listener.Callbacks);
    AssertEquals('the message is not complete while the demand is zero',
      Ord(wrTimeout), Ord(Listener.Done.WaitFor(0)));
    // the count is still the same after the stream has parked
    Sleep(500);
    AssertEquals('the writer count stays the same while parked', Parked, Writer.Calls);
    // the client gives demand; the stream then completes
    Socket.Request(1000);
    AssertEquals('the last fragment within 10 s after Request', Ord(wrSignaled),
      Ord(Listener.Done.WaitFor(cWaitMs)));
    AssertEquals('no listener error', '', Listener.ErrorText);
    AssertEquals('only one fragment has ALast', 1, Listener.LastFlagCount);
    AssertEquals('octet count', cTotalBytes, Length(Listener.Text));
    AssertTrue('the octets arrive in order', Listener.Text = ExpectedText);
    AssertEquals('writer calls: 50 chunks and the end', cChunkCount + 1, Writer.Calls);
  finally
    if Socket <> nil then
      Socket.Abort;
    Socket := nil;
    KeepListener := nil;
    CloseClientQuietly(Client);
  end;
end;

initialization
  RegisterTest(TWsStreamIntegrationTest);

end.
