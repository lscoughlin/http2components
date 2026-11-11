{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this provides WebSocket observation test support
---
}
unit Http2.Client.WebSocketObservability.Support;



{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Common.Headers, Http2.Client.Messages, Http2.Client.Http1,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames,
  Http2.Client.RequestObserver.Support, Http2.Client.WebSocketClient.Support;

type
  /// a message-recording observer that also keeps what the handshake showed
  /// and can try to inject the names the handshake owns
  TWsObserver = class(TMessageRecordingObserver, IHttpMessageObserver)
  private
    FMsgEvent: PRTLEvent;
  public
    /// the status and chosen subprotocol OnResponseHeaders saw
    SeenStatus: Integer;
    SeenSubprotocol: string;
    SeenHeaders: Integer;
    /// names OnAttemptStart tries to inject, and what each attempt raised
    TryNames: TStringList;
    Rejected: TStringList;
    constructor Create(const AWants: TMessageKinds);
    destructor Destroy; override;
    function OnAttemptStart(const A: THttpAttempt): IInterface; override;
    procedure OnResponseHeaders(const AToken: IInterface;
      const AResponse: IHttpResponse); override;
    procedure OnMessage(const AToken: IInterface; const M: TMessageInfo);
    function WaitMessages(const ACount, ATimeoutMs: Integer): Boolean;
  end;

  /// an IWebSocketAttempt that only counts, to drive a connection directly
  TFakeWsAttempt = class(TInterfacedObject, IWebSocketAttempt, IAttemptProgress)
  private
    FEnds: LongInt;
    FLast: TWsSessionEnd;
    FLastErrorClass: string;
  public
    function HandshakeHeaders: TArray<TWsHeaderField>;
    procedure HandshakeWritten;
    procedure HandshakeAccepted(const AStatus: Integer;
      const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
    procedure SessionEnded(const AEnd: TWsSessionEnd);
    function WantedKinds: TMessageKinds;
    procedure ReportMessage(const AKind: TMessageKind;
      const ADirection: TDirection; const AArrivedUs: Int64;
      const ASize: Integer; const ASse: PSseEvent);
    procedure ReadBegin;
    procedure ReadEnd;
    procedure Finish(const ABytesIn: Int64);
    property Ends: LongInt read FEnds;
    property Last: TWsSessionEnd read FLast;
    property LastErrorClass: string read FLastErrorClass;
  end;

  /// a listener whose OnText raises
  TRaisingListener = class(TWebSocketListener)
  public
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
  end;

  TWsSendThread = class(TThread)
  private
    FSocket: IWebSocket;
    FCount: Integer;
    FStart: TEvent;
  protected
    procedure Execute; override;
  public
    Failure: string;
    constructor Create(const ASocket: IWebSocket; const ACount: Integer;
      const AStart: TEvent);
  end;

  /// runs one ending path (0 Abort, 1 Close) once released
  TWsActThread = class(TThread)
  private
    FSocket: IWebSocket;
    FMode: Integer;
    FStart: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: IWebSocket; const AMode: Integer;
      const AStart: TEvent);
  end;

  TTag = class(TInterfacedObject)
  end;

  TWsObservabilityTestBase = class(TTestCase)
  protected
    FServer: TWsTestServer;
    FRec: TRecorder;
    FRecRef: IWebSocketListener;
    FObs: TWsObserver;
    FObsRef: IHttpClientObserver;
    FClient: IHttpClient;
    FGo: TEvent;
    FSeen: TEvent;
    FStartedBeforeHead: Boolean;
    FSrvTexts: LongInt;
    FSrvBytes: LongInt;
    procedure Start(const AScript: TWsScript; const AWants: TMessageKinds);
    function Url: string;
    function Req: IWebSocketRequest;
    function Open(const ARequest: IWebSocketRequest = nil): IWebSocket;
    function Ended(const AMs: Integer = 5000): Boolean;
    /// the callbacks the observer saw, as 'S0 H0 E0'
    function Flow: string;
    function KindsOf(const ADirection: TDirection): string;
    procedure StopServer;
    // scripts
    procedure ScriptHold(const S: TWsTestServer);
    procedure ScriptHoldSubprotocol(const S: TWsTestServer);
    procedure ScriptHeadCheck(const S: TWsTestServer);
    procedure ScriptRefuse403(const S: TWsTestServer);
    procedure ScriptEchoClose(const S: TWsTestServer);
    procedure ScriptRemoteClose(const S: TWsTestServer);
    procedure ScriptDrop(const S: TWsTestServer);
    procedure ScriptSeven(const S: TWsTestServer);
    procedure ScriptKinds(const S: TWsTestServer);
    procedure ScriptStamps(const S: TWsTestServer);
    procedure ScriptFragmentStamp(const S: TWsTestServer);
    procedure ScriptPingThenText(const S: TWsTestServer);
    procedure ScriptCountFrames(const S: TWsTestServer);
    procedure ScriptBadUtf8(const S: TWsTestServer);
    procedure ScriptNoReply(const S: TWsTestServer);
    procedure ScriptOneText(const S: TWsTestServer);
    procedure SetUp; override;
    procedure TearDown; override;
  end;

const
  cCrLf = #13#10;

var
  GFakeNowUs: Int64;

function FakeNow: Int64;
function ZeroMask: Cardinal;
function BytesOf(const S: string): TBytes;
function NewDirectConnection(const AAttempt: IWebSocketAttempt): IWebSocket;

implementation



function FakeNow: Int64;
begin
  Result := GFakeNowUs;
end;

function ZeroMask: Cardinal;
begin
  Result := 0;
end;

function BytesOf(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if S <> '' then
    Move(S[1], Result[0], Length(S));
end;

function KindName(const AKind: TMessageKind): string;
begin
  case AKind of
    mkSseEvent: Result := 'event';
    mkWsText: Result := 'text';
    mkWsBinary: Result := 'binary';
    mkWsPing: Result := 'ping';
    mkWsPong: Result := 'pong';
    mkWsClose: Result := 'close';
  else
    Result := '?';
  end;
end;

{ TWsObserver }

constructor TWsObserver.Create(const AWants: TMessageKinds);
begin
  inherited Create(AWants);
  FMsgEvent := RTLEventCreate;
  TryNames := TStringList.Create;
  Rejected := TStringList.Create;
end;

destructor TWsObserver.Destroy;
begin
  Rejected.Free;
  TryNames.Free;
  RTLEventDestroy(FMsgEvent);
  inherited Destroy;
end;

function TWsObserver.OnAttemptStart(const A: THttpAttempt): IInterface;
var
  I: Integer;
begin
  Result := inherited OnAttemptStart(A);
  for I := 0 to TryNames.Count - 1 do
    try
      A.Headers.SetValue(TryNames[I], 'x');
      Rejected.Add('');
    except
      on E: Exception do
        Rejected.Add(E.ClassName);
    end;
end;

procedure TWsObserver.OnResponseHeaders(const AToken: IInterface;
  const AResponse: IHttpResponse);
begin
  SeenStatus := AResponse.StatusCode;
  SeenSubprotocol := AResponse.Headers.GetFirst('sec-websocket-protocol');
  Inc(SeenHeaders);
  inherited OnResponseHeaders(AToken, AResponse);
end;

procedure TWsObserver.OnMessage(const AToken: IInterface;
  const M: TMessageInfo);
begin
  try
    inherited OnMessage(AToken, M);
  finally
    RTLEventSetEvent(FMsgEvent);
  end;
end;

function TWsObserver.WaitMessages(const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if MessageCount >= ACount then
      Exit(True);
    if GetTickCount64 >= Deadline then
      Exit(False);
    RTLEventWaitFor(FMsgEvent, 20);
  end;
end;

{ TFakeWsAttempt }

function TFakeWsAttempt.HandshakeHeaders: TArray<TWsHeaderField>;
begin
  Result := nil;
end;

procedure TFakeWsAttempt.HandshakeWritten;
begin
end;

procedure TFakeWsAttempt.HandshakeAccepted(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
begin
end;

procedure TFakeWsAttempt.SessionEnded(const AEnd: TWsSessionEnd);
begin
  FLast := AEnd;
  FLast.Error := nil;
  if AEnd.Error <> nil then
    FLastErrorClass := AEnd.Error.ClassName;
  InterlockedIncrement(FEnds);
end;

function TFakeWsAttempt.WantedKinds: TMessageKinds;
begin
  Result := [];
end;

procedure TFakeWsAttempt.ReportMessage(const AKind: TMessageKind;
  const ADirection: TDirection; const AArrivedUs: Int64; const ASize: Integer;
  const ASse: PSseEvent);
begin
end;

procedure TFakeWsAttempt.ReadBegin;
begin
end;

procedure TFakeWsAttempt.ReadEnd;
begin
end;

procedure TFakeWsAttempt.Finish(const ABytesIn: Int64);
begin
end;

{ TRaisingListener }

procedure TRaisingListener.OnText(const ASocket: IWebSocket;
  const AText: string; const ALast: Boolean);
begin
  raise EListError.Create('the listener failed');
end;

{ TWsSendThread }

constructor TWsSendThread.Create(const ASocket: IWebSocket;
  const ACount: Integer; const AStart: TEvent);
begin
  FSocket := ASocket;
  FCount := ACount;
  FStart := AStart;
  inherited Create(False);
end;

procedure TWsSendThread.Execute;
var
  I: Integer;
begin
  FStart.WaitFor(5000);
  try
    for I := 1 to FCount do
      FSocket.SendText('abc');
  except
    on E: Exception do
      Failure := E.ClassName + ': ' + E.Message;
  end;
end;

{ TWsActThread }

constructor TWsActThread.Create(const ASocket: IWebSocket; const AMode: Integer;
  const AStart: TEvent);
begin
  FSocket := ASocket;
  FMode := AMode;
  FStart := AStart;
  inherited Create(False);
end;

procedure TWsActThread.Execute;
begin
  FStart.WaitFor(5000);
  try
    if FMode = 0 then
      FSocket.Abort
    else
      FSocket.Close(1000, 'r');
  except
    // a send on a socket another path just closed may raise; only the end
    // is under test
  end;
end;

procedure TWsObservabilityTestBase.SetUp;
begin
  inherited SetUp;
  FGo := TEvent.Create(nil, False, False, '');
  FSeen := TEvent.Create(nil, True, False, '');
end;

procedure TWsObservabilityTestBase.TearDown;
begin
  ResetNowUsHook;
  if (FRec <> nil) and (FRec.Socket <> nil) then
  begin
    FRec.Socket.Abort;
    FRec.Socket := nil;
  end;
  StopServer;
  FRecRef := nil;
  FRec := nil;
  FObsRef := nil;
  FObs := nil;
  FClient := nil;
  FSeen.Free;
  FGo.Free;
  inherited TearDown;
end;

procedure TWsObservabilityTestBase.StopServer;
begin
  if FServer <> nil then
  begin
    FServer.Terminate;
    FServer.Release.SetEvent;
    FGo.SetEvent;
    FServer.CloseConnection;
    FServer.ShutdownListener;
    FServer.Done.WaitFor(3000);
    FServer.Free;
    FServer := nil;
  end;
end;

procedure TWsObservabilityTestBase.Start(const AScript: TWsScript;
  const AWants: TMessageKinds);
begin
  FServer := TWsTestServer.Create(AScript);
  FServer.Start;
  FRec := TRecorder.Create(0);
  FRecRef := FRec;
  FObs := TWsObserver.Create(AWants);
  FObsRef := FObs;
  FClient := THttpClientFactory.Create.WithRequestObserver(FObsRef).Build;
end;

function TWsObservabilityTestBase.Url: string;
begin
  Result := 'ws://127.0.0.1:' + IntToStr(FServer.Port) + '/obs';
end;

function TWsObservabilityTestBase.Req: IWebSocketRequest;
begin
  Result := TWebSocketRequest.Create(Url, FRecRef).WithAutoRequest;
end;

function TWsObservabilityTestBase.Open(const ARequest: IWebSocketRequest): IWebSocket;
var
  R: IWebSocketRequest;
begin
  R := ARequest;
  if R = nil then
    R := Req;
  Result := FClient.Send(R);
end;

function TWsObservabilityTestBase.Ended(const AMs: Integer): Boolean;
begin
  Result := FObs.WaitForEnds(1, AMs);
end;

function TWsObservabilityTestBase.Flow: string;
begin
  Result := Trim(StringReplace(FObs.Order, sLineBreak, ' ', [rfReplaceAll]));
end;

function TWsObservabilityTestBase.KindsOf(const ADirection: TDirection): string;
var
  I: Integer;
  M: TMessageInfo;
begin
  Result := '';
  for I := 0 to FObs.MessageCount - 1 do
  begin
    M := FObs.MessageAt(I);
    if M.Direction = ADirection then
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + KindName(M.Kind);
    end;
  end;
end;

{ scripts }

procedure TWsObservabilityTestBase.ScriptHold(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptHoldSubprotocol(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept('Sec-WebSocket-Protocol: chat' + cCrLf);
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptHeadCheck(const S: TWsTestServer);
begin
  S.ReadHead;
  // the observer's start must already have run when the head arrives
  FStartedBeforeHead := FObs.StartCount >= 1;
  S.Accept;
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptRefuse403(const S: TWsTestServer);
begin
  S.ReadHead;
  S.SendRaw('HTTP/1.1 403 Forbidden' + cCrLf + 'Content-Length: 0' + cCrLf +
    cCrLf);
  S.Release.WaitFor(2000);
end;

procedure TWsObservabilityTestBase.ScriptEchoClose(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  while S.TryReadFrame(F) do
  begin
    if F.Opcode = cWsOpClose then
    begin
      S.SendFrame(cWsOpClose, True, F.Payload);
      Break;
    end;
    S.SendFrame(F.Opcode, F.Fin, F.Payload);
  end;
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptRemoteClose(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.SendFrame(cWsOpClose, True, WsBuildClosePayload(1001, 'going'));
  S.ReadFrame;                       // the echo
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptDrop(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptSeven(const S: TWsTestServer);
var
  F: TWsFrame;
  I, Data: Integer;
begin
  S.ReadHead;
  S.Accept;
  for I := 1 to 7 do
  begin
    S.SendText('m' + IntToStr(I));
    if (I = 3) or (I = 5) then
      S.SendFrame(cWsOpPing, True, nil);
  end;
  // wait for the client's ten messages, then close from this side
  Data := 0;
  while Data < 10 do
  begin
    F := S.ReadFrame;
    if F.Opcode = cWsOpText then
      Inc(Data);
  end;
  S.SendFrame(cWsOpClose, True, WsBuildClosePayload(1000, 'done'));
  while S.TryReadFrame(F) do
    if F.Opcode = cWsOpClose then
      Break;
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptKinds(const S: TWsTestServer);
var
  F: TWsFrame;
  Got: Integer;
begin
  S.ReadHead;
  S.Accept;
  S.SendText('one');
  S.SendFrame(cWsOpBinary, True, BytesOf('bb'));
  S.SendFrame(cWsOpPing, True, BytesOf('p'));
  S.SendFrame(cWsOpPong, True, BytesOf('q'));
  // let the client's two data messages arrive, then close from this side
  Got := 0;
  while Got < 2 do
  begin
    F := S.ReadFrame;
    if (F.Opcode = cWsOpText) or (F.Opcode = cWsOpBinary) then
      Inc(Got);
  end;
  S.SendFrame(cWsOpClose, True, WsBuildClosePayload(1000, 'bye'));
  while S.TryReadFrame(F) do
    if F.Opcode = cWsOpClose then
      Break;
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptStamps(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.SendText('m1');
  FGo.WaitFor(5000);
  S.SendText('m2');
  FGo.WaitFor(5000);
  S.SendText('m3');
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptFragmentStamp(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.SendFrame(cWsOpText, False, BytesOf('ab'));
  FSeen.SetEvent;
  FGo.WaitFor(5000);
  S.SendFrame(cWsOpContinuation, True, BytesOf('cd'));
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptPingThenText(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  S.SendFrame(cWsOpPing, True, nil);
  F := S.ReadFrame;                  // the pong: the reader has read the ping
  if F.Opcode <> cWsOpPong then
    S.Failure := 'expected a pong';
  FSeen.SetEvent;
  S.SendText('m2');
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptCountFrames(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  while S.TryReadFrame(F) do
  begin
    if F.Opcode = cWsOpClose then
    begin
      S.SendFrame(cWsOpClose, True, F.Payload);
      Break;
    end;
    if F.Opcode = cWsOpText then
    begin
      InterlockedIncrement(FSrvTexts);
      InterlockedExchangeAdd(FSrvBytes, Length(F.Payload));
    end;
  end;
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptBadUtf8(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  S.SendFrame(cWsOpText, True, BytesOf(#$FF));
  S.TryReadFrame(F);                 // the client's 1007 close
  S.CloseConnection;
end;

procedure TWsObservabilityTestBase.ScriptNoReply(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.ReadFrame;                       // the close, which is never answered
  S.Release.WaitFor(5000);
end;

procedure TWsObservabilityTestBase.ScriptOneText(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.SendText('boom');
  S.Release.WaitFor(5000);
end;

{ 21.2 }

function NewDirectConnection(const AAttempt: IWebSocketAttempt): IWebSocket;
var
  Mock: IHttp2Socket;
  L: IWebSocketListener;
begin
  Mock := TMockSocket.Create;
  L := TWebSocketListener.Create;
  Result := TWebSocketConnection.Create(Mock, TBufferedReader.Create(Mock),
    TWebSocketRequest.Create('ws://127.0.0.1:1/', L), '', ZeroMask, False,
    AAttempt);
end;
end.
