{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this provides WebSocket test peers and listener recorders
---
}
unit Http2.Client.WebSocketClient.Support;



{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client.Tls, Http2.Client, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection;

type
  TWsTestServer = class;
  TWsScript = procedure(const S: TWsTestServer) of object;

  /// plays one accepted connection from a script
  TWsTestServer = class(TThread)
  private
    FListenFd: Integer;
    FFd: Integer;
    FParser: TWebSocketFrameParser;
    FScript: TWsScript;
  protected
    procedure Execute; override;
  public
    Port: Word;
    Head: string;           // the request head the client sent
    Failure: string;        // a script exception, for the test to assert on
    Done: TEvent;
    Release: TEvent;        // set by the test when the script may end
    constructor Create(const AScript: TWsScript);
    destructor Destroy; override;
    procedure ReadHead;
    function FdForTest: Integer;
    function HeaderValue(const AName: string): string;
    procedure SendRaw(const AData: AnsiString); overload;
    procedure SendRaw(const AData: TBytes); overload;
    procedure Accept(const AExtra: string = ''; const ATail: TBytes = nil);
    procedure SendFrame(const AOp: Byte; const AFin: Boolean; const A: TBytes);
    procedure SendText(const S: string);
    function ReadFrame: TWsFrame;
    function TryReadFrame(out F: TWsFrame): Boolean;
    procedure CloseConnection;
    /// wake a script thread still blocked in accept
    procedure ShutdownListener;
  end;

  /// records listener events; waits are bounded
  TRecorder = class(TWebSocketListener)
  private
    FKeepSocket: Boolean;
    FLock: TCriticalSection;
    FEvent: TEvent;
    FLog: TStringList;
    FRequestOnOpen: Integer;
    procedure Add(const S: string);
  public
    Socket: IWebSocket;
    ErrorClass: string;
    ErrorCode: Integer;
    property KeepSocket: Boolean read FKeepSocket write FKeepSocket;
    constructor Create(const ARequestOnOpen: Integer = 0);
    destructor Destroy; override;
    function Count: Integer;
    function Item(const I: Integer): string;
    function WaitCount(const N: Integer; const AMs: Integer = 5000): Boolean;
    function WaitFor(const APrefix: string; const AMs: Integer = 5000): Boolean;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    procedure OnBytes(const ASocket: IWebSocket; const AData: TBytes;
      const ALast: Boolean); override;
    procedure OnPing(const ASocket: IWebSocket; const AData: TBytes); override;
    procedure OnPong(const ASocket: IWebSocket; const AData: TBytes); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket;
      const AError: Exception); override;
  end;

  TSender = class(TThread)
  private
    FSock: IWebSocket;
    FIndex: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASock: IWebSocket; const AIndex: Integer);
  end;

  TThrower = class(TRecorder)
  public
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
  end;

  TWebSocketClientTestBase = class(TTestCase)
  protected
    FServer: TWsTestServer;
    FRec: TRecorder;
    FRecRef: IWebSocketListener;
    FClient: IHttpClient;
    procedure Start(const AScript: TWsScript; const ARequestOnOpen: Integer = 0);
    function Url(const APath: string = '/'): string;
    function Open(const ARequest: IWebSocketRequest = nil): IWebSocket;
    procedure Finish;
    // scripts
    procedure ScriptEcho(const S: TWsTestServer);
    procedure ScriptThreeTexts(const S: TWsTestServer);
    procedure ScriptPing(const S: TWsTestServer);
    procedure ScriptClientClose(const S: TWsTestServer);
    procedure ScriptServerClose(const S: TWsTestServer);
    procedure ScriptMaskedFrame(const S: TWsTestServer);
    procedure ScriptBadUtf8(const S: TWsTestServer);
    procedure ScriptReject401(const S: TWsTestServer);
    procedure ScriptWrongAccept(const S: TWsTestServer);
    procedure ScriptSubprotocol(const S: TWsTestServer);
    procedure ScriptLeftover(const S: TWsTestServer);
    procedure ScriptCollect(const S: TWsTestServer);
    procedure ScriptSilent(const S: TWsTestServer);
    procedure ScriptBigEcho(const S: TWsTestServer);
    procedure ScriptDrop(const S: TWsTestServer);
    procedure ScriptFragments(const S: TWsTestServer);
    procedure ScriptFragmentedText(const S: TWsTestServer);
    procedure ScriptNoReply(const S: TWsTestServer);
    procedure ScriptCountPings(const S: TWsTestServer);
    procedure ScriptTooBig(const S: TWsTestServer);
    procedure ScriptOneText(const S: TWsTestServer);
    procedure ScriptStreamIgnoreClose(const S: TWsTestServer);
    procedure ScriptCloseThenHalfClose(const S: TWsTestServer);
    procedure TearDown; override;
  end;

implementation


{ TWsTestServer }

constructor TWsTestServer.Create(const AScript: TWsScript);
var
  Addr: TSockAddr;
  ALen, One: LongInt;
begin
  inherited Create(True);
  FScript := AScript;
  FFd := -1;
  Done := TEvent.Create(nil, True, False, '');
  Release := TEvent.Create(nil, True, False, '');
  FParser := TWebSocketFrameParser.Create;
  FParser.RequireMasked := True;
  FListenFd := fpsocket(AF_INET, SOCK_STREAM, 0);
  One := 1;
  fpSetSockOpt(FListenFd, SOL_SOCKET, SO_REUSEADDR, @One, SizeOf(One));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(0);
  Addr.sin_addr.s_addr := htonl($7f000001);
  if (fpbind(FListenFd, @Addr, SizeOf(Addr)) <> 0) or
     (fplisten(FListenFd, 4) <> 0) then
    raise Exception.Create('cannot listen on loopback');
  ALen := SizeOf(Addr);
  fpgetsockname(FListenFd, @Addr, @ALen);
  Port := ntohs(Addr.sin_port);
end;

destructor TWsTestServer.Destroy;
begin
  if FFd >= 0 then
  begin
    fpshutdown(FFd, SHUT_RDWR);
    fpclose(FFd);
  end;
  if FListenFd >= 0 then
  begin
    fpshutdown(FListenFd, SHUT_RDWR);
    fpclose(FListenFd);
  end;
  FParser.Free;
  Release.Free;
  Done.Free;
  inherited Destroy;
end;

procedure TWsTestServer.Execute;
var
  One: LongInt;
begin
  try
    FFd := fpaccept(FListenFd, nil, nil);
    if FFd < 0 then
      Exit;
    One := 1;
    {$IFDEF DARWIN}
    fpSetSockOpt(FFd, SOL_SOCKET, SO_NOSIGPIPE, @One, SizeOf(One));
    {$ENDIF}
    FScript(Self);
  except
    on E: Exception do
      Failure := E.ClassName + ': ' + E.Message;
  end;
  Done.SetEvent;
end;

function TWsTestServer.FdForTest: Integer;
begin
  Result := FFd;
end;

procedure TWsTestServer.ReadHead;
var
  C: AnsiChar;
  N: Integer;
begin
  Head := '';
  while Pos(#13#10#13#10, Head) = 0 do
  begin
    N := fprecv(FFd, @C, 1, 0);
    if N <= 0 then
      raise Exception.Create('client closed before the head ended');
    Head := Head + C;
  end;
end;

function TWsTestServer.HeaderValue(const AName: string): string;
var
  L: TStringList;
  I, P: Integer;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Head;
    for I := 1 to L.Count - 1 do
    begin
      P := Pos(':', L[I]);
      if (P > 0) and SameText(Trim(Copy(L[I], 1, P - 1)), AName) then
        Exit(Trim(Copy(L[I], P + 1, MaxInt)));
    end;
  finally
    L.Free;
  end;
end;

procedure TWsTestServer.SendRaw(const AData: AnsiString);
var
  Sent, N: Integer;
begin
  Sent := 0;
  while Sent < Length(AData) do
  begin
    N := fpsend(FFd, @AData[1 + Sent], Length(AData) - Sent, 0);
    if N <= 0 then
      raise Exception.Create('send failed');
    Inc(Sent, N);
  end;
end;

procedure TWsTestServer.SendRaw(const AData: TBytes);
var
  S: AnsiString;
begin
  SetLength(S, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], S[1], Length(AData));
  SendRaw(S);
end;

procedure TWsTestServer.Accept(const AExtra: string; const ATail: TBytes);
var
  Key, Resp: string;
  Wire: TBytes;
begin
  Key := HeaderValue('Sec-WebSocket-Key');
  Resp := 'HTTP/1.1 101 Switching Protocols'#13#10 +
    'Upgrade: websocket'#13#10'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: ' + WsComputeAccept(Key) + #13#10 + AExtra + #13#10;
  SetLength(Wire, Length(Resp) + Length(ATail));
  Move(Resp[1], Wire[0], Length(Resp));
  if Length(ATail) > 0 then
    Move(ATail[0], Wire[Length(Resp)], Length(ATail));
  SendRaw(Wire);
end;

procedure TWsTestServer.SendFrame(const AOp: Byte; const AFin: Boolean;
  const A: TBytes);
var
  K: TWsMaskKey;
begin
  FillChar(K, SizeOf(K), 0);
  SendRaw(WsEncodeFrame(AOp, AFin, A, False, K));
end;

procedure TWsTestServer.SendText(const S: string);
var
  B: TBytes;
begin
  SetLength(B, Length(S));
  if S <> '' then
    Move(S[1], B[0], Length(S));
  SendFrame(cWsOpText, True, B);
end;

function TWsTestServer.TryReadFrame(out F: TWsFrame): Boolean;
var
  Buf: array[0..16383] of Byte;
  N: Integer;
begin
  while not FParser.Next(F) do
  begin
    N := fprecv(FFd, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then
      Exit(False);
    FParser.Feed(Buf[0], N);
  end;
  Result := True;
end;

function TWsTestServer.ReadFrame: TWsFrame;
begin
  if not TryReadFrame(Result) then
    raise Exception.Create('client closed before a frame arrived');
end;

procedure TWsTestServer.CloseConnection;
begin
  if FFd >= 0 then
  begin
    fpshutdown(FFd, SHUT_RDWR);
    fpclose(FFd);
    FFd := -1;
  end;
end;

procedure TWsTestServer.ShutdownListener;
begin
  if FListenFd >= 0 then
    fpshutdown(FListenFd, SHUT_RDWR);
end;

{ TRecorder }

constructor TRecorder.Create(const ARequestOnOpen: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FLog := TStringList.Create;
  FRequestOnOpen := ARequestOnOpen;
  FKeepSocket := True;
end;

destructor TRecorder.Destroy;
begin
  FLog.Free;
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRecorder.Add(const S: string);
begin
  FLock.Enter;
  try
    FLog.Add(S);
  finally
    FLock.Leave;
  end;
  FEvent.SetEvent;
end;

function TRecorder.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FLog.Count;
  finally
    FLock.Leave;
  end;
end;

function TRecorder.Item(const I: Integer): string;
begin
  FLock.Enter;
  try
    if I < FLog.Count then Result := FLog[I] else Result := '';
  finally
    FLock.Leave;
  end;
end;

function TRecorder.WaitCount(const N: Integer; const AMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(AMs);
  while Count < N do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    FEvent.ResetEvent;
    if Count >= N then
      Break;
    FEvent.WaitFor(50);
  end;
  Result := True;
end;

function TRecorder.WaitFor(const APrefix: string; const AMs: Integer): Boolean;
var
  Deadline: QWord;
  I: Integer;
begin
  Deadline := GetTickCount64 + QWord(AMs);
  repeat
    FEvent.ResetEvent;
    for I := 0 to Count - 1 do
      if Copy(Item(I), 1, Length(APrefix)) = APrefix then
        Exit(True);
    FEvent.WaitFor(50);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

procedure TRecorder.OnOpen(const ASocket: IWebSocket);
begin
  if FKeepSocket then
    Socket := ASocket;
  Add('open');
  if FRequestOnOpen > 0 then
    ASocket.Request(FRequestOnOpen);
end;

procedure TRecorder.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Add('text:' + AText + ':' + IntToStr(Ord(ALast)));
end;

procedure TRecorder.OnBytes(const ASocket: IWebSocket; const AData: TBytes;
  const ALast: Boolean);
begin
  Add('bytes:' + IntToStr(Length(AData)) + ':' + IntToStr(Ord(ALast)));
end;

procedure TRecorder.OnPing(const ASocket: IWebSocket; const AData: TBytes);
begin
  Add('ping:' + IntToStr(Length(AData)));
end;

procedure TRecorder.OnPong(const ASocket: IWebSocket; const AData: TBytes);
begin
  Add('pong:' + IntToStr(Length(AData)));
end;

procedure TRecorder.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  Add('close:' + IntToStr(AStatusCode) + ':' + AReason);
end;

procedure TRecorder.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  ErrorClass := AError.ClassName;
  if AError is EHttpWebSocketProtocolError then
    ErrorCode := EHttpWebSocketProtocolError(AError).CloseCode;
  Add('error:' + AError.ClassName);
end;

{ TWebSocketClientTest }

procedure TWebSocketClientTestBase.TearDown;
begin
  Finish;
  inherited TearDown;
end;

procedure TWebSocketClientTestBase.Finish;
begin
  if FRec <> nil then
  begin
    if FRec.Socket <> nil then
    begin
      FRec.Socket.Abort;
      FRec.Socket := nil;
    end;
  end;
  if FServer <> nil then
  begin
    FServer.Terminate;
    FServer.Release.SetEvent;
    FServer.CloseConnection;
    fpshutdown(FServer.FListenFd, SHUT_RDWR);
    FServer.Done.WaitFor(3000);
    FServer.Free;
    FServer := nil;
  end;
  FRecRef := nil;
  FRec := nil;
  FClient := nil;
end;

procedure TWebSocketClientTestBase.Start(const AScript: TWsScript;
  const ARequestOnOpen: Integer);
begin
  FServer := TWsTestServer.Create(AScript);
  FServer.Start;
  FRec := TRecorder.Create(ARequestOnOpen);
  FRecRef := FRec;
  FClient := THttpClientFactory.Create.Build;
end;

function TWebSocketClientTestBase.Url(const APath: string): string;
begin
  Result := 'ws://127.0.0.1:' + IntToStr(FServer.Port) + APath;
end;

function TWebSocketClientTestBase.Open(const ARequest: IWebSocketRequest): IWebSocket;
var
  R: IWebSocketRequest;
begin
  R := ARequest;
  if R = nil then
    R := TWebSocketRequest.Create(Url('/chat?room=1'), FRecRef);
  Result := FClient.Send(R);
end;

procedure TWebSocketClientTestBase.ScriptEcho(const S: TWsTestServer);
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
end;

procedure TWebSocketClientTestBase.ScriptThreeTexts(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.SendText('one');
  S.SendText('two');
  S.SendText('three');
  S.Release.WaitFor(3000);
end;

procedure TWebSocketClientTestBase.ScriptPing(const S: TWsTestServer);
var
  F: TWsFrame;
  B: TBytes;
begin
  S.ReadHead;
  S.Accept;
  SetLength(B, 3);
  B[0] := 97; B[1] := 98; B[2] := 99;
  S.SendFrame(cWsOpPing, True, B);
  F := S.ReadFrame;
  if (F.Opcode <> cWsOpPong) or (Length(F.Payload) <> 3) or (F.Payload[0] <> 97) then
    S.Failure := 'expected a pong echoing abc';
  S.Release.WaitFor(1000);
end;

procedure TWebSocketClientTestBase.ScriptClientClose(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  F := S.ReadFrame;
  if (F.Opcode <> cWsOpClose) or (Length(F.Payload) < 2) or
     (F.Payload[0] <> $03) or (F.Payload[1] <> $E8) then
    S.Failure := 'expected close 1000';
  S.SendFrame(cWsOpClose, True, F.Payload);
  S.CloseConnection;
end;

procedure TWebSocketClientTestBase.ScriptServerClose(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  S.SendFrame(cWsOpClose, True, WsBuildClosePayload(1001, 'going'));
  F := S.ReadFrame;
  if (F.Opcode <> cWsOpClose) or (Length(F.Payload) <> 2) or
     (F.Payload[1] <> $E9) then
    S.Failure := 'expected an echoed 1001';
  S.CloseConnection;
end;

procedure TWebSocketClientTestBase.ScriptMaskedFrame(const S: TWsTestServer);
var
  F: TWsFrame;
  K: TWsMaskKey;
  Raw: TBytes;
  B: TBytes;
begin
  S.ReadHead;
  S.Accept;
  K[0] := 1; K[1] := 2; K[2] := 3; K[3] := 4;
  SetLength(B, 1);
  B[0] := 65;
  Raw := WsEncodeFrame(cWsOpText, True, B, True, K);
  S.SendRaw(Raw);
  F := S.ReadFrame;
  if (F.Opcode <> cWsOpClose) or (Length(F.Payload) < 2) or
     (F.Payload[0] * 256 + F.Payload[1] <> 1002) then
    S.Failure := 'expected close 1002';
  S.CloseConnection;
end;

procedure TWebSocketClientTestBase.ScriptBadUtf8(const S: TWsTestServer);
var
  F: TWsFrame;
  B: TBytes;
begin
  S.ReadHead;
  S.Accept;
  SetLength(B, 2);
  B[0] := 65; B[1] := $FF;
  S.SendFrame(cWsOpText, True, B);
  F := S.ReadFrame;
  if (F.Opcode <> cWsOpClose) or (Length(F.Payload) < 2) or
     (F.Payload[0] * 256 + F.Payload[1] <> 1007) then
    S.Failure := 'expected close 1007';
  S.CloseConnection;
end;

procedure TWebSocketClientTestBase.ScriptReject401(const S: TWsTestServer);
begin
  S.ReadHead;
  S.SendRaw('HTTP/1.1 401 Unauthorized'#13#10'WWW-Authenticate: Basic'#13#10 +
    'Content-Length: 6'#13#10#13#10'denied');
end;

procedure TWebSocketClientTestBase.ScriptWrongAccept(const S: TWsTestServer);
begin
  S.ReadHead;
  S.SendRaw('HTTP/1.1 101 Switching Protocols'#13#10'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10'Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA='#13#10#13#10);
end;

procedure TWebSocketClientTestBase.ScriptSubprotocol(const S: TWsTestServer);
begin
  S.ReadHead;
  if S.HeaderValue('Sec-WebSocket-Protocol') <> 'chat, superchat' then
    S.Failure := 'subprotocols not offered as a list';
  S.Accept('Sec-WebSocket-Protocol: superchat'#13#10);
  S.Release.WaitFor(1000);
end;

procedure TWebSocketClientTestBase.ScriptLeftover(const S: TWsTestServer);
var
  K: TWsMaskKey;
  B: TBytes;
begin
  S.ReadHead;
  FillChar(K, SizeOf(K), 0);
  SetLength(B, 2);
  B[0] := 104; B[1] := 105;
  // the first frame rides in the same write as the upgrade head
  S.Accept('', WsEncodeFrame(cWsOpText, True, B, False, K));
  S.Release.WaitFor(1000);
end;

procedure TWebSocketClientTestBase.ScriptCollect(const S: TWsTestServer);
var
  F: TWsFrame;
  N: Integer;
  Seen: TStringList;
  I: Integer;
  Msg: string;
begin
  S.ReadHead;
  S.Accept;
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    for N := 1 to 200 do
    begin
      F := S.ReadFrame;
      if (F.Opcode <> cWsOpText) or (not F.Fin) then
        S.Failure := 'unexpected frame';
      begin
        SetString(Msg, PAnsiChar(@F.Payload[0]), Length(F.Payload));
        Seen.Add(Msg);
      end;
    end;
    for I := 0 to 199 do
      if Seen.IndexOf(Format('t%d-m%.3d', [I div 50, I mod 50])) < 0 then
        S.Failure := 'a message arrived damaged or missing';
  finally
    Seen.Free;
  end;
  S.SendText('done');
end;

constructor TSender.Create(const ASock: IWebSocket; const AIndex: Integer);
begin
  FSock := ASock;
  FIndex := AIndex;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TSender.Execute;
var
  I: Integer;
begin
  for I := 0 to 49 do
    FSock.SendText(Format('t%d-m%.3d', [FIndex, I]));
end;

procedure TWebSocketClientTestBase.ScriptFragments(const S: TWsTestServer);
var
  F1, F2, F3: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  F1 := S.ReadFrame;
  F2 := S.ReadFrame;
  F3 := S.ReadFrame;
  if (F1.Opcode <> cWsOpText) or F1.Fin or (F2.Opcode <> cWsOpContinuation) or
     F2.Fin or (F3.Opcode <> cWsOpContinuation) or (not F3.Fin) then
    S.Failure := 'fragmentation not as sent';
  S.Release.WaitFor(1000);
end;

procedure TWebSocketClientTestBase.ScriptBigEcho(const S: TWsTestServer);
var
  F: TWsFrame;
begin
  S.ReadHead;
  S.Accept;
  F := S.ReadFrame;
  S.SendFrame(cWsOpBinary, True, F.Payload);
  S.Release.WaitFor(2000);
end;

procedure TWebSocketClientTestBase.ScriptSilent(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Release.WaitFor(3000);
end;

procedure TWebSocketClientTestBase.ScriptDrop(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.CloseConnection;
end;

procedure TWebSocketClientTestBase.ScriptFragmentedText(const S: TWsTestServer);
var
  A, B: TBytes;
begin
  S.ReadHead;
  S.Accept;
  SetLength(A, 3);
  A[0] := 65; A[1] := $E2; A[2] := $82;
  SetLength(B, 2);
  B[0] := $AC; B[1] := 66;
  S.SendFrame(cWsOpText, False, A);
  S.SendFrame(cWsOpContinuation, True, B);
  S.Release.WaitFor(2000);
end;

procedure TWebSocketClientTestBase.ScriptNoReply(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.Release.WaitFor(5000);
end;

procedure TWebSocketClientTestBase.ScriptCountPings(const S: TWsTestServer);
var
  F: TWsFrame;
  Pings: Integer;
begin
  S.ReadHead;
  S.Accept;
  Pings := 0;
  while S.TryReadFrame(F) do
    if F.Opcode = cWsOpPing then
      Inc(Pings)
    else if F.Opcode = cWsOpClose then
      Break;
  if Pings < 1 then
    S.Failure := 'no ping arrived';
end;

procedure TWebSocketClientTestBase.ScriptOneText(const S: TWsTestServer);
begin
  S.ReadHead;
  S.Accept;
  S.SendText('boom');
  S.Release.WaitFor(3000);
end;

procedure TThrower.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  raise Exception.Create('listener failed');
end;

procedure TWebSocketClientTestBase.ScriptTooBig(const S: TWsTestServer);
var
  F: TWsFrame;
  B: TBytes;
begin
  S.ReadHead;
  S.Accept;
  SetLength(B, 11);
  S.SendFrame(cWsOpBinary, True, B);
  F := S.ReadFrame;
  if (F.Opcode <> cWsOpClose) or (Length(F.Payload) < 2) or
     (F.Payload[0] * 256 + F.Payload[1] <> 1009) then
    S.Failure := 'expected close 1009';
  S.CloseConnection;
end;

procedure TWebSocketClientTestBase.ScriptStreamIgnoreClose(const S: TWsTestServer);
var
  I: Integer;
begin
  S.ReadHead;
  S.Accept;
  // a chatty server that never answers the close frame
  for I := 1 to 400 do
  begin
    if S.Release.WaitFor(20) = wrSignaled then
      Break;
    S.SendText('x');
  end;
end;

procedure TWebSocketClientTestBase.ScriptCloseThenHalfClose(const S: TWsTestServer);
var
  F: TWsFrame;
  Tv: record
    Sec: Int64;
    Usec: LongInt;
  end;
  C: Byte;
begin
  S.ReadHead;
  S.Accept;
  S.SendFrame(cWsOpClose, True, WsBuildClosePayload(1000, ''));
  F := S.ReadFrame;
  if F.Opcode <> cWsOpClose then
    S.Failure := 'expected the close echo';
  fpshutdown(S.FdForTest, SHUT_WR);
  // the client must close its side without being asked for more input
  Tv.Sec := 3;
  Tv.Usec := 0;
  fpSetSockOpt(S.FdForTest, SOL_SOCKET, SO_RCVTIMEO, @Tv, SizeOf(Tv));
  if fprecv(S.FdForTest, @C, 1, 0) <> 0 then
    S.Failure := 'the client did not close TCP';
end;
end.
