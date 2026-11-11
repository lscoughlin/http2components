{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves WebSocket client behavior tests
---
}
unit Http2.Client.WebSocketClient.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client.Tls, Http2.Client, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection, Http2.Client.WebSocketClient.Support;
type
  TWebSocketClientTest = class(TWebSocketClientTestBase)
  published
    procedure TestHandshakeRequestAndEchoWithMasking;
    procedure TestDemandHoldsBackDelivery;
    procedure TestPingIsAnsweredBeforeTheCallback;
    procedure TestClientCloseHandshake;
    procedure TestServerCloseIsEchoed;
    procedure TestMaskedServerFrameClosesWith1002;
    procedure TestBadUtf8ClosesWith1007;
    procedure TestHandshakeRefusalCarriesTheResponse;
    procedure TestWrongAcceptIsRefused;
    procedure TestSubprotocolIsReported;
    procedure TestBytesAfterTheUpgradeHeadAreKept;
    procedure TestConcurrentSendsAreWrittenWhole;
    procedure TestFragmentedSend;
    procedure TestMixedKindsInOneMessageRaise;
    procedure TestLargeBinaryEcho;
    procedure TestAbortStopsEverything;
    procedure TestSendAfterCloseRaises;
    procedure TestConnectTimeout;
    procedure TestDropWithoutCloseIsAnError;
    procedure TestFragmentedReceive;
    procedure TestSelectorSeesTheMappedUrl;
    procedure TestFactoryWithoutHttp1DialIsRefused;
    procedure TestAutoRequest;
    procedure TestCloseWithoutAnswerTimesOut;
    procedure TestPingIntervalSendsPingsAndGivesUp;
    procedure TestListenerExceptionIsReportedAndAborts;
    procedure TestOverLimitMessageClosesWith1009;
    procedure TestDroppedSocketKeepsDeliveringUntilItEnds;
    procedure TestMaskKeyIsDrawnPerFrame;
    procedure TestCloseTimeoutFiresWhileFramesKeepArriving;
    procedure TestServerCloseWithNoDemandReleasesTheSocket;
    procedure TestListenerHoldingTheSocketDoesNotLeakTheConnection;
  end;


implementation

procedure TWebSocketClientTest.TestHandshakeRequestAndEchoWithMasking;
var
  Sock: IWebSocket;
  Name: string;
  Raw: TBytes;
begin
  Start(ScriptEcho, 4);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.SendText('hello');
  AssertTrue('echo', FRec.WaitCount(2));
  AssertEquals('text:hello:1', FRec.Item(1));
  SetLength(Raw, 3);
  Raw[0] := 1; Raw[1] := 2; Raw[2] := 3;
  Sock.SendBinary(Raw);
  AssertTrue('echo bytes', FRec.WaitCount(3));
  AssertEquals('bytes:3:1', FRec.Item(2));
  Name := FServer.Head;
  AssertTrue('request line', Pos('GET /chat?room=1 HTTP/1.1'#13#10, Name) = 1);
  AssertEquals('127.0.0.1:' + IntToStr(FServer.Port), FServer.HeaderValue('Host'));
  AssertEquals('websocket', FServer.HeaderValue('Upgrade'));
  AssertEquals('Upgrade', FServer.HeaderValue('Connection'));
  AssertEquals('13', FServer.HeaderValue('Sec-WebSocket-Version'));
  AssertEquals('key is 16 octets', 24, Length(FServer.HeaderValue('Sec-WebSocket-Key')));
  AssertEquals('no subprotocol sent', '', FServer.HeaderValue('Sec-WebSocket-Protocol'));
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestDemandHoldsBackDelivery;
var
  Sock: IWebSocket;
begin
  Start(ScriptThreeTexts, 0);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  AssertFalse('nothing without demand', FRec.WaitCount(2, 300));
  Sock.Request(2);
  AssertTrue('two delivered', FRec.WaitCount(3));
  AssertEquals('text:one:1', FRec.Item(1));
  AssertEquals('text:two:1', FRec.Item(2));
  AssertFalse('third waits', FRec.WaitCount(4, 300));
  Sock.Request(1);
  AssertTrue('third delivered', FRec.WaitCount(4));
  AssertEquals('text:three:1', FRec.Item(3));
  try
    Sock.Request(0);
    Fail('Request(0) must raise');
  except
    on EHttpWebSocketError do ;
  end;
end;

procedure TWebSocketClientTest.TestPingIsAnsweredBeforeTheCallback;
begin
  // demand stays 0: the pong still goes out, the callback waits
  Start(ScriptPing, 0);
  Open;
  AssertTrue('open', FRec.WaitCount(1));
  AssertTrue('server saw the pong', FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
  AssertEquals('callback held back', 1, FRec.Count);
  FRec.Socket.Request(1);
  AssertTrue('ping delivered', FRec.WaitCount(2));
  AssertEquals('ping:3', FRec.Item(1));
end;

procedure TWebSocketClientTest.TestClientCloseHandshake;
var
  Sock: IWebSocket;
begin
  Start(ScriptClientClose, 1);
  Sock := Open;
  AssertTrue('open', FRec.WaitCount(1));
  Sock.Close(1000, 'bye');
  AssertTrue('output closed at once', Sock.OutputClosed);
  AssertTrue('close reported', FRec.WaitCount(2));
  AssertEquals('close:1000:bye', FRec.Item(1));
  AssertTrue('input closed', Sock.InputClosed);
  AssertEquals('', FServer.Failure);
  Sock.Close;                       // a second close does nothing
  AssertEquals('one terminal callback', 2, FRec.Count);
end;

procedure TWebSocketClientTest.TestServerCloseIsEchoed;
begin
  Start(ScriptServerClose, 0);
  Open;
  AssertTrue('open', FRec.WaitCount(1));
  // the echo does not wait for demand; the report does
  AssertTrue('server saw the echo', FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
  FRec.Socket.Request(1);
  AssertTrue(FRec.WaitCount(2));
  AssertEquals('close:1001:going', FRec.Item(1));
  AssertTrue(FRec.Socket.InputClosed);
  AssertTrue(FRec.Socket.OutputClosed);
end;

procedure TWebSocketClientTest.TestMaskedServerFrameClosesWith1002;
begin
  Start(ScriptMaskedFrame, 1);
  Open;
  AssertTrue('error reported', FRec.WaitCount(2));
  AssertEquals('error:EHttpWebSocketProtocolError', FRec.Item(1));
  AssertEquals(1002, FRec.ErrorCode);
  AssertTrue('server saw 1002', FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
  AssertEquals('no OnClose after a failure', 2, FRec.Count);
end;

procedure TWebSocketClientTest.TestBadUtf8ClosesWith1007;
begin
  Start(ScriptBadUtf8, 1);
  Open;
  AssertTrue(FRec.WaitCount(2));
  AssertEquals(1007, FRec.ErrorCode);
  AssertTrue(FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestHandshakeRefusalCarriesTheResponse;
var
  Raised: Boolean;
begin
  Start(ScriptReject401);
  Raised := False;
  try
    Open;
  except
    on E: EHttpWebSocketHandshakeError do
    begin
      Raised := True;
      AssertEquals(401, E.StatusCode);
      AssertEquals('denied', E.Body);
      AssertEquals('Basic', E.Header('www-authenticate'));
    end;
  end;
  AssertTrue('raised', Raised);
  AssertEquals('listener never opened', 0, FRec.Count);
end;

procedure TWebSocketClientTest.TestWrongAcceptIsRefused;
var
  Raised: Boolean;
begin
  Start(ScriptWrongAccept);
  Raised := False;
  try
    Open;
  except
    on EHttpWebSocketHandshakeError do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

procedure TWebSocketClientTest.TestSubprotocolIsReported;
var
  Sock: IWebSocket;
  Names: TArray<string>;
begin
  Start(ScriptSubprotocol);
  SetLength(Names, 2);
  Names[0] := 'chat'; Names[1] := 'superchat';
  Sock := Open(TWebSocketRequest.Create(Url, FRecRef).WithSubprotocols(Names));
  AssertEquals('superchat', Sock.Subprotocol);
  AssertTrue(FRec.WaitCount(1));
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestBytesAfterTheUpgradeHeadAreKept;
begin
  Start(ScriptLeftover, 1);
  Open;
  AssertTrue(FRec.WaitCount(2));
  AssertEquals('text:hi:1', FRec.Item(1));
end;

procedure TWebSocketClientTest.TestConcurrentSendsAreWrittenWhole;
var
  Sock: IWebSocket;
  T: array[0..3] of TSender;
  I: Integer;
begin
  Start(ScriptCollect, 1);
  Sock := Open;
  AssertTrue(FRec.WaitCount(1));
  for I := 0 to 3 do
    T[I] := TSender.Create(Sock, I);
  for I := 0 to 3 do
  begin
    T[I].WaitFor;
    T[I].Free;
  end;
  AssertTrue('server finished', FRec.WaitCount(2, 10000));
  AssertEquals('text:done:1', FRec.Item(1));
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestFragmentedSend;
var
  Sock: IWebSocket;
begin
  Start(ScriptFragments);
  Sock := Open;
  Sock.SendText('a', False);
  Sock.SendText('b', False);
  Sock.SendText('c', True);
  AssertTrue(FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestMixedKindsInOneMessageRaise;
var
  Sock: IWebSocket;
  Raised: Boolean;
  B: TBytes;
begin
  Start(ScriptFragments);
  Sock := Open;
  Sock.SendText('a', False);
  Raised := False;
  SetLength(B, 1);
  try
    Sock.SendBinary(B);
  except
    on EHttpWebSocketError do
      Raised := True;
  end;
  AssertTrue('binary inside an open text message', Raised);
  // an invalid text payload is refused before anything is written
  Raised := False;
  try
    Sock.SendText(#$FF#$FE, True);
  except
    on EHttpWebSocketError do
      Raised := True;
  end;
  AssertTrue('invalid UTF-8', Raised);
  Sock.SendText('b', False);
  Sock.SendText('c', True);
  AssertTrue(FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestLargeBinaryEcho;
var
  Sock: IWebSocket;
  B: TBytes;
begin
  Start(ScriptBigEcho, 1);
  Sock := Open;
  SetLength(B, 1024 * 1024);
  FillChar(B[0], Length(B), $A5);
  Sock.SendBinary(B);
  AssertTrue(FRec.WaitCount(2, 10000));
  AssertEquals('bytes:1048576:1', FRec.Item(1));
end;

procedure TWebSocketClientTest.TestAbortStopsEverything;
var
  Sock: IWebSocket;
  Raised: Boolean;
begin
  Start(ScriptThreeTexts);
  Sock := Open;
  AssertTrue(FRec.WaitCount(1));
  Sock.Abort;
  AssertTrue(Sock.InputClosed);
  AssertTrue(Sock.OutputClosed);
  Raised := False;
  try
    Sock.SendText('x');
  except
    on EHttpWebSocketClosedError do
      Raised := True;
  end;
  AssertTrue('send after abort', Raised);
  AssertFalse('no delivery after abort', FRec.WaitCount(2, 300));
end;

procedure TWebSocketClientTest.TestSendAfterCloseRaises;
var
  Sock: IWebSocket;
  Raised: Boolean;
begin
  Start(ScriptClientClose);
  Sock := Open;
  Sock.Close(1000, '');
  Raised := False;
  try
    Sock.SendText('late');
  except
    on EHttpWebSocketClosedError do
      Raised := True;
  end;
  AssertTrue(Raised);
  Raised := False;
  try
    Sock.Close(1005, '');
  except
    on EHttpWebSocketError do
      Raised := True;
  end;
  AssertTrue('1005 cannot be sent', Raised);
end;

procedure TWebSocketClientTest.TestConnectTimeout;
var
  Raised: Boolean;
  Started: QWord;
begin
  Start(ScriptSilent);
  Raised := False;
  Started := GetTickCount64;
  try
    Open(TWebSocketRequest.Create(Url, FRecRef).WithConnectTimeoutMs(400));
  except
    on EHttpTimeout do
      Raised := True;
  end;
  AssertTrue('timed out', Raised);
  AssertTrue('promptly', GetTickCount64 - Started < 3000);
  AssertEquals(0, FRec.Count);
end;

procedure TWebSocketClientTest.TestDropWithoutCloseIsAnError;
begin
  Start(ScriptDrop, 1);
  Open;
  AssertTrue(FRec.WaitCount(2));
  AssertEquals('error:EHttpConnectionError', FRec.Item(1));
end;

procedure TWebSocketClientTest.TestFragmentedReceive;
begin
  // a character split across fragments is delivered whole, in the next one
  Start(ScriptFragmentedText, 2);
  Open;
  AssertTrue(FRec.WaitCount(3));
  AssertEquals('text:A:0', FRec.Item(1));
  AssertEquals('text:'#$E2#$82#$AC'B:1', FRec.Item(2));
end;

type
  TRecordingSelector = class(TInterfacedObject, IProxySelector)
  public
    Seen: string;
    function SelectProxy(const AUri: string): IProxy;
  end;

function TRecordingSelector.SelectProxy(const AUri: string): IProxy;
begin
  Seen := AUri;
  Result := nil;
end;

procedure TWebSocketClientTest.TestSelectorSeesTheMappedUrl;
var
  Sel: TRecordingSelector;
  SelRef: IProxySelector;
begin
  Start(ScriptEcho, 1);
  Sel := TRecordingSelector.Create;
  SelRef := Sel;
  FClient := THttpClientFactory.Create.WithProxySelector(SelRef).Build;
  Open;
  AssertTrue(FRec.WaitCount(1));
  AssertEquals('http://127.0.0.1:' + IntToStr(FServer.Port) + '/chat?room=1',
    Sel.Seen);
end;

type
  TNoDialFactory = class(TInterfacedObject, IHttp2SocketFactory)
  public
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
  end;

function TNoDialFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  raise Exception.Create('not expected');
end;

procedure TWebSocketClientTest.TestFactoryWithoutHttp1DialIsRefused;
var
  Raised: Boolean;
  F: IHttp2SocketFactory;
begin
  FRec := TRecorder.Create;
  FRecRef := FRec;
  F := TNoDialFactory.Create;
  FClient := THttpClientFactory.Create.WithSocketFactory(F).Build;
  Raised := False;
  try
    FClient.Send(TWebSocketRequest.Create('ws://127.0.0.1:1/', FRecRef));
  except
    on EHttpWebSocketError do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

procedure TWebSocketClientTest.TestAutoRequest;
begin
  Start(ScriptThreeTexts, 0);
  Open(TWebSocketRequest.Create(Url, FRecRef).WithAutoRequest);
  AssertTrue('all three without a Request call', FRec.WaitCount(4));
  AssertEquals('text:three:1', FRec.Item(3));
end;

procedure TWebSocketClientTest.TestCloseWithoutAnswerTimesOut;
var
  Sock: IWebSocket;
  Started: QWord;
begin
  Start(ScriptNoReply, 1);
  Started := GetTickCount64;
  Sock := Open(TWebSocketRequest.Create(Url, FRecRef).WithCloseTimeoutMs(300));
  AssertTrue(FRec.WaitCount(1));
  Sock.Close(1000, '');
  AssertTrue('reported', FRec.WaitCount(2, 4000));
  AssertEquals('error:EHttpTimeout', FRec.Item(1));
  AssertTrue('after the close timeout, not long after',
    GetTickCount64 - Started < 3000);
end;

procedure TWebSocketClientTest.TestPingIntervalSendsPingsAndGivesUp;
begin
  Start(ScriptCountPings, 1);
  Open(TWebSocketRequest.Create(Url, FRecRef).WithPingIntervalMs(150));
  AssertTrue('gave up on a silent peer', FRec.WaitCount(2, 4000));
  AssertEquals('error:EHttpTimeout', FRec.Item(1));
  AssertTrue(FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestListenerExceptionIsReportedAndAborts;
var
  Sock: IWebSocket;
  T: TThrower;
begin
  Start(ScriptOneText, 1);
  FRecRef := nil;
  T := TThrower.Create(1);
  FRec := T;
  FRecRef := T;
  Sock := Open(TWebSocketRequest.Create(Url, FRecRef));
  AssertTrue(FRec.WaitCount(2));
  AssertEquals('error:Exception', FRec.Item(1));
  AssertTrue('aborted', Sock.InputClosed and Sock.OutputClosed);
end;

procedure TWebSocketClientTest.TestOverLimitMessageClosesWith1009;
begin
  Start(ScriptTooBig, 1);
  Open(TWebSocketRequest.Create(Url, FRecRef).WithMaxMessageBytes(10));
  AssertTrue(FRec.WaitCount(2));
  AssertEquals(1009, FRec.ErrorCode);
  AssertTrue(FServer.Done.WaitFor(3000) = wrSignaled);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestDroppedSocketKeepsDeliveringUntilItEnds;
var
  Sock: IWebSocket;
begin
  Start(ScriptOneText, 1);
  FRec.KeepSocket := False;
  Sock := Open;
  Sock := nil;                      // the caller keeps no reference
  AssertTrue('still delivering', FRec.WaitCount(2));
  AssertEquals('text:boom:1', FRec.Item(1));
  FServer.Release.SetEvent;
  FServer.CloseConnection;
  AssertTrue('ends with one terminal callback', FRec.WaitCount(3));
  AssertEquals('error:EHttpConnectionError', FRec.Item(2));
end;

var
  GMaskCalls: Integer;

function CountingMask: Cardinal;
begin
  Inc(GMaskCalls);
  Result := Cardinal(GMaskCalls) * $01010101;
end;

procedure TWebSocketClientTest.TestMaskKeyIsDrawnPerFrame;
var
  Sock: IWebSocket;
  F: TProtocolSocketFactory;
  Dial: IHttp1SocketFactory;
  Before: Integer;
begin
  Start(ScriptEcho, 4);
  F := TProtocolSocketFactory.Create;
  Dial := F;
  GMaskCalls := 0;
  Sock := OpenWebSocket(Dial, TWebSocketRequest.Create(Url, FRecRef), nil,
    5000, CountingMask);
  AssertTrue(FRec.WaitCount(1));
  Before := GMaskCalls;
  AssertEquals('four draws for the 16-octet handshake key', 4, Before);
  Sock.SendText('a');
  Sock.SendText('b');
  Sock.SendText('c');
  AssertTrue(FRec.WaitCount(4));
  AssertEquals('one key per frame', Before + 3, GMaskCalls);
  AssertEquals('', FServer.Failure);
end;

procedure TWebSocketClientTest.TestCloseTimeoutFiresWhileFramesKeepArriving;
var
  Sock: IWebSocket;
  Started: QWord;
begin
  Start(ScriptStreamIgnoreClose, 1);
  Sock := Open(TWebSocketRequest.Create(Url, FRecRef).WithAutoRequest
    .WithCloseTimeoutMs(300));
  AssertTrue(FRec.WaitCount(1));
  Started := GetTickCount64;
  Sock.Close(1000, '');
  AssertTrue('timed out although data kept arriving',
    FRec.WaitFor('error:EHttpTimeout', 3000));
  AssertTrue('promptly', GetTickCount64 - Started < 2000);
end;

procedure TWebSocketClientTest.TestServerCloseWithNoDemandReleasesTheSocket;
begin
  Start(ScriptCloseThenHalfClose, 0);
  Open;
  AssertTrue('open', FRec.WaitCount(1));
  AssertTrue('the server saw the client close TCP',
    FServer.Done.WaitFor(5000) = wrSignaled);
  AssertEquals('', FServer.Failure);
  AssertEquals('no demand, so no report yet', 1, FRec.Count);
  FRec.Socket.Request(1);
  AssertTrue('reported once demand arrives', FRec.WaitCount(2));
  AssertEquals('close:1000:', FRec.Item(1));
end;

type
  /// keeps the socket it is given and signals when it is freed
  TLeakProbe = class(TWebSocketListener)
  private
    FDestroyed: TEvent;
    FOpened: TEvent;
    FClosed: TEvent;
    FSocket: IWebSocket;
  public
    constructor Create(const ADestroyed, AOpened, AClosed: TEvent);
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
  end;

constructor TLeakProbe.Create(const ADestroyed, AOpened, AClosed: TEvent);
begin
  inherited Create;
  FDestroyed := ADestroyed;
  FOpened := AOpened;
  FClosed := AClosed;
end;

destructor TLeakProbe.Destroy;
begin
  FSocket := nil;
  FDestroyed.SetEvent;
  inherited Destroy;
end;

procedure TLeakProbe.OnOpen(const ASocket: IWebSocket);
begin
  FSocket := ASocket;               // the usual JDK pattern
  ASocket.Request(1);
  FOpened.SetEvent;
end;

procedure TLeakProbe.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  FClosed.SetEvent;
end;

procedure TWebSocketClientTest.TestListenerHoldingTheSocketDoesNotLeakTheConnection;
var
  Destroyed, Opened, Closed: TEvent;
  Probe: IWebSocketListener;
  Req: IWebSocketRequest;
  Sock: IWebSocket;
begin
  Destroyed := TEvent.Create(nil, True, False, '');
  Opened := TEvent.Create(nil, True, False, '');
  Closed := TEvent.Create(nil, True, False, '');
  try
    Start(ScriptServerClose, 0);
    Probe := TLeakProbe.Create(Destroyed, Opened, Closed);
    Req := TWebSocketRequest.Create(Url, Probe);
    Sock := FClient.Send(Req);
    AssertTrue(Opened.WaitFor(3000) = wrSignaled);
    Sock.Request(1);
    AssertTrue('close delivered', Closed.WaitFor(5000) = wrSignaled);
    Sock := nil;
    Req := nil;
    Probe := nil;
    AssertTrue('the listener, and with it the connection, is released',
      Destroyed.WaitFor(5000) = wrSignaled);
  finally
    Destroyed.Free;
    Opened.Free;
    Closed.Free;
  end;
end;

initialization
  RegisterTest(TWebSocketClientTest);
end.
