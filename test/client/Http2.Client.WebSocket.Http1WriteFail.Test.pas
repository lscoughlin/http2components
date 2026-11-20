{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, websocket, http1, write_failure
notes:
  - this checks a failed write of a WebSocket over the HTTP/1.1 route against a loopback peer
  - the socket wraps a real TCP socket; an armed write raises EHttpConnectionError before it reaches the wire
  - the peer waits for the test before it sends its Close frame, so the reader cannot take the frame before the write fails
---
}
unit Http2.Client.WebSocket.Http1WriteFail.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client.Tls, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection, Http2.Client.WebSocketClient.Support;

type
  /// a socket that passes every call to a real socket; once armed, every write raises
  TFailingSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader)
  private
    FInner: IHttp2Socket;
    FPartial: IPartialReader;
    FArmed: Integer;      // 1 once the test has armed the socket
    FFailures: Integer;   // the writes that the switch failed
  public
    constructor Create(const AInner: IHttp2Socket);
    /// the next and every later write raises EHttpConnectionError
    procedure Arm;
    function Failures: Integer;
    // IHttp2Socket
    function Read(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
    // IPartialReader
    function ReadSome(var ABuffer; ACount: Integer): Integer;
  end;

  /// an HTTP/1.1 dialer whose sockets are TFailingSocket; Last is the socket of the newest dial
  TFailingDialer = class(TInterfacedObject, IHttp1SocketFactory)
  private
    FInner: IHttp1SocketFactory;
    FLast: TFailingSocket;
    FLastRef: IHttp2Socket;  // keeps the newest socket alive
  public
    constructor Create;
    function DialHttp1(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy): IHttp2Socket;
    property Last: TFailingSocket read FLast;
  end;

  /// the failed write of a WebSocket over the HTTP/1.1 route: the callbacks go on
  TWebSocketHttp1WriteFailTest = class(TWebSocketClientTestBase)
  private
    FGo: TEvent;          // set by the test when the peer may send its Close frame
    FDial: TFailingDialer;
    FDialRef: IHttp1SocketFactory;
    FSock: IWebSocket;
    function OpenFailing(const ARequest: IWebSocketRequest): IWebSocket;
    function SendError(const ASock: IWebSocket; const AText: string): string;
    function CountOf(const APrefix: string): Integer;
    procedure ScriptCloseAfterGo(const S: TWsTestServer);
    procedure ScriptSilentPeer(const S: TWsTestServer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestCloseAfterFailedWriteGivesOnClose;
    procedure TestFailedWriteWithoutCloseGivesOneOnError;
    procedure TestFailedCloseEchoStillGivesOnClose;
    procedure TestAbortAfterFailedWriteGivesNoCallback;
    procedure TestSendAfterFailedWriteRaisesClosed;
  end;

implementation

{ TFailingSocket }

constructor TFailingSocket.Create(const AInner: IHttp2Socket);
begin
  inherited Create;
  FInner := AInner;
  Supports(AInner, IPartialReader, FPartial);
end;

procedure TFailingSocket.Arm;
begin
  InterlockedExchange(FArmed, 1);
end;

function TFailingSocket.Failures: Integer;
begin
  Result := InterlockedCompareExchange(FFailures, 0, 0);
end;

function TFailingSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := FInner.Read(ABuffer, ACount);
end;

function TFailingSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  if InterlockedCompareExchange(FArmed, 0, 0) = 1 then
  begin
    InterlockedIncrement(FFailures);
    raise EHttpConnectionError.Create('the test fails this write');
  end;
  Result := FInner.Write(ABuffer, ACount);
end;

procedure TFailingSocket.Close;
begin
  FInner.Close;
end;

function TFailingSocket.GetConnected: Boolean;
begin
  Result := FInner.Connected;
end;

function TFailingSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FInner.ConnectTimeoutMs;
end;

procedure TFailingSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FInner.ConnectTimeoutMs := AValue;
end;

function TFailingSocket.GetReadTimeoutMs: Integer;
begin
  Result := FInner.ReadTimeoutMs;
end;

procedure TFailingSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FInner.ReadTimeoutMs := AValue;
end;

function TFailingSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FInner.WriteTimeoutMs;
end;

procedure TFailingSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FInner.WriteTimeoutMs := AValue;
end;

function TFailingSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
begin
  if FPartial <> nil then
    Result := FPartial.ReadSome(ABuffer, ACount)
  else
    Result := FInner.Read(ABuffer, ACount);
end;

{ TFailingDialer }

constructor TFailingDialer.Create;
begin
  inherited Create;
  FInner := TProtocolSocketFactory.Create;
end;

function TFailingDialer.DialHttp1(const AHost: string; const APort: Word;
  const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy): IHttp2Socket;
var
  Sock: TFailingSocket;
begin
  Sock := TFailingSocket.Create(
    FInner.DialHttp1(AHost, APort, AScheme, ATimeoutMs, AProxy));
  FLast := Sock;
  FLastRef := Sock;
  Result := Sock;
end;

{ TWebSocketHttp1WriteFailTest }

procedure TWebSocketHttp1WriteFailTest.SetUp;
begin
  inherited SetUp;
  FGo := TEvent.Create(nil, True, False, '');
end;

procedure TWebSocketHttp1WriteFailTest.TearDown;
begin
  if FGo <> nil then
    FGo.SetEvent;
  if FSock <> nil then
  begin
    FSock.Abort;
    FSock := nil;
  end;
  inherited TearDown;
  FDialRef := nil;
  FDial := nil;
  FreeAndNil(FGo);
end;

function TWebSocketHttp1WriteFailTest.OpenFailing(
  const ARequest: IWebSocketRequest): IWebSocket;
begin
  FDial := TFailingDialer.Create;
  FDialRef := FDial;
  FSock := OpenWebSocket(FDialRef, ARequest, nil, 5000);
  Result := FSock;
end;

function TWebSocketHttp1WriteFailTest.SendError(const ASock: IWebSocket;
  const AText: string): string;
begin
  Result := '';
  try
    ASock.SendText(AText);
  except
    on E: Exception do
      Result := E.ClassName;
  end;
end;

function TWebSocketHttp1WriteFailTest.CountOf(const APrefix: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FRec.Count - 1 do
    if Copy(FRec.Item(I), 1, Length(APrefix)) = APrefix then
      Inc(Result);
end;

procedure TWebSocketHttp1WriteFailTest.ScriptCloseAfterGo(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  // the Close frame goes out only after the client's send has failed
  if FGo.WaitFor(3000) <> wrSignaled then
    S.Failure := 'the test did not release the Close frame';
  S.SendFrame(cWsOpClose, True, WsBuildClosePayload(1001, 'going'));
  S.CloseConnection;
end;

procedure TWebSocketHttp1WriteFailTest.ScriptSilentPeer(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  // no Close frame: the peer waits until the test ends
  S.Release.WaitFor(5000);
end;

procedure TWebSocketHttp1WriteFailTest.TestCloseAfterFailedWriteGivesOnClose;
var
  Sock: IWebSocket;
begin
  Start(ScriptCloseAfterGo, 0);
  Sock := OpenFailing(TWebSocketRequest.Create(Url('/chat'), FRecRef)
    .WithAutoRequest.WithCloseTimeoutMs(1000));
  AssertTrue('open', FRec.WaitCount(1));
  FDial.Last.Arm;
  AssertEquals('the send fails', 'EHttpConnectionError', SendError(Sock, 'late'));
  FGo.SetEvent;
  AssertTrue('OnClose with the peer code', FRec.WaitFor('close:1001:going', 3000));
  Sleep(300);
  AssertEquals('exactly one OnClose', 1, CountOf('close:'));
  AssertEquals('no OnError', 0, CountOf('error:'));
  AssertEquals('one failed write, the send', 1, FDial.Last.Failures);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketHttp1WriteFailTest.TestFailedWriteWithoutCloseGivesOneOnError;
var
  Sock: IWebSocket;
  Started: QWord;
begin
  Start(ScriptSilentPeer, 0);
  Sock := OpenFailing(TWebSocketRequest.Create(Url('/chat'), FRecRef)
    .WithAutoRequest.WithCloseTimeoutMs(300));
  AssertTrue('open', FRec.WaitCount(1));
  FDial.Last.Arm;
  AssertEquals('the send fails', 'EHttpConnectionError', SendError(Sock, 'late'));
  Started := GetTickCount64;
  AssertTrue('one OnError after the close timeout',
    FRec.WaitFor('error:EHttpConnectionError', 3000));
  AssertTrue('not before the close timeout', GetTickCount64 - Started >= 250);
  AssertTrue('promptly', GetTickCount64 - Started < 2000);
  Sleep(500);
  AssertEquals('exactly one OnError', 1, CountOf('error:'));
  AssertEquals('no OnClose', 0, CountOf('close:'));
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketHttp1WriteFailTest.TestFailedCloseEchoStillGivesOnClose;
var
  Sock: IWebSocket;
begin
  Start(ScriptCloseAfterGo, 0);
  Sock := OpenFailing(TWebSocketRequest.Create(Url('/chat'), FRecRef)
    .WithAutoRequest.WithCloseTimeoutMs(1000));
  AssertTrue('open', FRec.WaitCount(1));
  // the first write after the mark is the echo of the server's Close frame
  FDial.Last.Arm;
  FGo.SetEvent;
  AssertTrue('OnClose with the server code', FRec.WaitFor('close:1001:going', 3000));
  Sleep(300);
  AssertEquals('exactly one OnClose', 1, CountOf('close:'));
  AssertEquals('no OnError', 0, CountOf('error:'));
  AssertEquals('the echo was the failed write', 1, FDial.Last.Failures);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketHttp1WriteFailTest.TestAbortAfterFailedWriteGivesNoCallback;
var
  Sock: IWebSocket;
begin
  Start(ScriptSilentPeer, 0);
  Sock := OpenFailing(TWebSocketRequest.Create(Url('/chat'), FRecRef)
    .WithAutoRequest.WithCloseTimeoutMs(1000));
  AssertTrue('open', FRec.WaitCount(1));
  FDial.Last.Arm;
  AssertEquals('the send fails', 'EHttpConnectionError', SendError(Sock, 'late'));
  Sock.Abort;
  // longer than the close timeout: the timeout would give OnError if it still counted
  Sleep(1300);
  AssertEquals('only OnOpen: the user abort wins', 1, FRec.Count);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketHttp1WriteFailTest.TestSendAfterFailedWriteRaisesClosed;
var
  Sock: IWebSocket;
begin
  Start(ScriptSilentPeer, 0);
  Sock := OpenFailing(TWebSocketRequest.Create(Url('/chat'), FRecRef)
    .WithAutoRequest.WithCloseTimeoutMs(5000));
  AssertTrue('open', FRec.WaitCount(1));
  FDial.Last.Arm;
  AssertEquals('the first send fails', 'EHttpConnectionError', SendError(Sock, 'late'));
  AssertEquals('a later send raises the closed error', 'EHttpWebSocketClosedError',
    SendError(Sock, 'again'));
  AssertEquals('no second write reaches the socket', 1, FDial.Last.Failures);
  Sock.Abort;
end;

initialization
  RegisterTest(TWebSocketHttp1WriteFailTest);
end.
