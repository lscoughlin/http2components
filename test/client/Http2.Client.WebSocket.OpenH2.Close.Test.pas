{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, websocket, extended connect, rfc 8441, close
notes:
  - this tests the closing handshake of a WebSocket over HTTP/2 when the server ends its side of the stream (story B4)
  - the helpers of the OpenH2 tests are copied here, because that unit is at its size limit
  - the server sends its Close frame in one DATA frame with END_STREAM, or in a separate frame, or the END_STREAM comes later
  - the case without credit gives the client a zero stream window, so its echo has no credit
  - every wait has a time limit
---
}
unit Http2.Client.WebSocket.OpenH2.Close.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Errors, Http2.Common.Hpack,
  Http2.Client.Tls, Http2.Client.Tls.Types, Http2.Client.Pool, Http2.Client.Proxy,
  Http2.Client.SocketFactory.Types, Http2.Client.RequestObserver,
  Http2.Client.Stream.Types, Http2.Client.WebSocket, Http2.Client.WebSocket.Connection.Types,
  Http2.Client.WebSocket.Connection.OpenH2, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.Frames;

type
  /// a socket factory whose sockets answer the extended CONNECT with 200
  // - AWindow (when not negative) is the INITIAL_WINDOW_SIZE of the peer; 0 leaves the client no credit
  TWsCloseFactory = class(TInterfacedObject, IHttp2SocketFactory, ICleartextSocketFactory)
  private
    FWindow: Integer;
    FCodec: THpackCodec;
    FSockets: TList<IHttp2Socket>;
    procedure OnClientFrame(const AFrame: TFrame);
  public
    constructor Create(const AWindow: Integer);
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    /// the socket of the first dial
    function Sock: TMockSocket;
    /// no hook is called after the test ends
    procedure DetachHooks;
  end;

  /// records the listener callbacks, one text item each
  TWsCloseRecorder = class(TInterfacedObject, IWebSocketListener)
  private
    FLock: TCriticalSection;
    FItems: TStringList;
    procedure Add(const AText: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket);
    procedure OnText(const ASocket: IWebSocket; const AText: string; const ALast: Boolean);
    procedure OnBytes(const ASocket: IWebSocket; const AData: TBytes; const ALast: Boolean);
    procedure OnPing(const ASocket: IWebSocket; const AData: TBytes);
    procedure OnPong(const ASocket: IWebSocket; const AData: TBytes);
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string);
    procedure OnError(const ASocket: IWebSocket; const AError: Exception);
    /// how many items start with APrefix
    function Count(const APrefix: string): Integer;
    /// wait until Count(APrefix) reaches AExpected
    function WaitForCount(const APrefix: string; const AExpected: Integer;
      const ATimeoutMs: Integer): Boolean;
  end;

  TOpenH2CloseTest = class(TTestCase)
  private
    FFactory: TWsCloseFactory;
    FFactoryRef: IHttp2SocketFactory;
    FPool: TConnectionPool;
    FRec: TWsCloseRecorder;
    FRecRef: IWebSocketListener;
    FSess: IWebSocket;
    procedure Build(const AWindow: Integer);
    function Request(const AUrl: string): IWebSocketRequest;
    function Open(const AReq: IWebSocketRequest; out AOutcome: TTunnelOutcome): IWebSocket;
    /// the octets that the client sent on stream 1 (its DATA payloads, in order)
    function ClientStream: TBytes;
    /// the client WebSocket frame with AOpcode and APayload (payload compared as octets)
    function WaitForClientFrame(const AOpcode: Byte; const APayload: string;
      const ATimeoutMs: Integer; out AMasked: Boolean): Boolean;
    /// how many DATA frames of the client carry END_STREAM on stream 1
    function ClientEndCount: Integer;
    /// how many frames of AType on AStreamId the client sent
    function ClientFrameCount(const AType: TFrameType; const AStreamId: LongWord): Integer;
    /// wait until the client sent END_STREAM on stream 1
    function WaitForEnd(const ATimeoutMs: Integer): Boolean;
    /// send AText as one text message and tell whether the call raised
    function SendRaises(const AText: string): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestOneFrameCloseAndEndGivesOnClose;
    procedure TestSeparateEndFrameGivesOnClose;
    procedure TestLateEndFrameGivesOnCloseOnce;
    procedure TestNoCreditEchoStillGivesOnClose;
    procedure TestSendAfterPeerResetRaises;
    procedure TestSendAfterSessionEndRaisesAndEndsOnce;
  end;

implementation

const
  cTestUrl = 'ws://tunnel.test:80/chat';
  cWaitMs = 5000;
  /// the payload of a Close frame with the status 1001 (going away)
  cCode1001 = #3#$E9;

/// the octets of an ASCII text (one octet per character)
function ToBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

/// the octets as a string (one character per octet)
function OctetsOf(const ABytes: TBytes): string;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], Result[1], Length(ABytes));
end;

/// an unmasked WebSocket frame as the server sends it (FIN set)
function ServerFrame(const AOpcode: Byte; const APayload: TBytes): TBytes;
var
  N, Hdr: Integer;
begin
  N := Length(APayload);
  if N < 126 then
    Hdr := 2
  else
    Hdr := 4;
  SetLength(Result, Hdr + N);
  Result[0] := $80 or AOpcode;
  if N < 126 then
    Result[1] := N
  else
  begin
    Result[1] := 126;
    Result[2] := N shr 8;
    Result[3] := N and $FF;
  end;
  if N > 0 then
    Move(APayload[0], Result[Hdr], N);
end;

/// read one client frame at AOffset; ANext is the offset after it
function ParseClientFrame(const AData: TBytes; const AOffset: Integer;
  out AOpcode: Byte; out APayload: TBytes; out AMasked: Boolean;
  out ANext: Integer): Boolean;
var
  P, Len, I: Integer;
  Key: array[0..3] of Byte;
begin
  Result := False;
  ANext := AOffset;
  if AOffset + 2 > Length(AData) then
    Exit;
  AOpcode := AData[AOffset] and $0F;
  AMasked := (AData[AOffset + 1] and $80) <> 0;
  Len := AData[AOffset + 1] and $7F;
  P := AOffset + 2;
  if Len = 126 then
  begin
    if P + 2 > Length(AData) then Exit;
    Len := (AData[P] shl 8) or AData[P + 1];
    Inc(P, 2);
  end;
  if AMasked then
  begin
    if P + 4 > Length(AData) then Exit;
    for I := 0 to 3 do
      Key[I] := AData[P + I];
    Inc(P, 4);
  end;
  if P + Len > Length(AData) then
    Exit;
  SetLength(APayload, Len);
  for I := 0 to Len - 1 do
    if AMasked then
      APayload[I] := AData[P + I] xor Key[I mod 4]
    else
      APayload[I] := AData[P + I];
  ANext := P + Len;
  Result := True;
end;

{ TWsCloseFactory }

constructor TWsCloseFactory.Create(const AWindow: Integer);
begin
  inherited Create;
  FWindow := AWindow;
  FCodec := THpackCodec.Create;
  FSockets := TList<IHttp2Socket>.Create;
end;

destructor TWsCloseFactory.Destroy;
begin
  FSockets.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure TWsCloseFactory.OnClientFrame(const AFrame: TFrame);
var
  Block: THeaderBlock;
  Enc: TBytes;
begin
  // the extended CONNECT of stream 1 gets 200 without END_STREAM
  if (AFrame.Header.FrameType <> ftHeaders) or (AFrame.Header.StreamId <> 1) then
    Exit;
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := '200';
  Block[0].Sensitive := False;
  Enc := FCodec.Encode(Block);
  Sock.FeedLocked(FrameToBytes(BuildHeadersFrame(1, Enc, True, False)));
end;

function TWsCloseFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  S: TMockSocket;
  Settings: TConnectionSettings;
begin
  S := TMockSocket.Create;
  S.OnClientFrame := OnClientFrame;
  Settings := TConnectionSettings.Defaults;
  Settings.EnableConnectProtocol := True;
  if FWindow >= 0 then
    Settings.InitialWindowSize := LongWord(FWindow);
  S.EnqueueSettings(Settings);
  FSockets.Add(S);
  Result := S;
end;

function TWsCloseFactory.DialProtocol(const AHost: string; const APort: Word;
  const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  AProtocol := npHttp2Cleartext;
  Result := Dial(AHost, APort, ATimeoutMs);
end;

function TWsCloseFactory.Sock: TMockSocket;
begin
  Result := FSockets[0] as TMockSocket;
end;

procedure TWsCloseFactory.DetachHooks;
var
  I: Integer;
begin
  for I := 0 to FSockets.Count - 1 do
    (FSockets[I] as TMockSocket).OnClientFrame := nil;
end;

{ TWsCloseRecorder }

constructor TWsCloseRecorder.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TStringList.Create;
end;

destructor TWsCloseRecorder.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TWsCloseRecorder.Add(const AText: string);
begin
  FLock.Acquire;
  try
    FItems.Add(AText);
  finally
    FLock.Release;
  end;
end;

procedure TWsCloseRecorder.OnOpen(const ASocket: IWebSocket);
begin
  Add('open');
end;

procedure TWsCloseRecorder.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Add('text:' + AText);
end;

procedure TWsCloseRecorder.OnBytes(const ASocket: IWebSocket; const AData: TBytes;
  const ALast: Boolean);
begin
  Add('bytes:' + IntToStr(Length(AData)));
end;

procedure TWsCloseRecorder.OnPing(const ASocket: IWebSocket; const AData: TBytes);
begin
  Add('ping:' + OctetsOf(AData));
end;

procedure TWsCloseRecorder.OnPong(const ASocket: IWebSocket; const AData: TBytes);
begin
  Add('pong:' + OctetsOf(AData));
end;

procedure TWsCloseRecorder.OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
  const AReason: string);
begin
  Add('close:' + IntToStr(AStatusCode) + ':' + AReason);
end;

procedure TWsCloseRecorder.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  Add('error:' + AError.ClassName);
end;

function TWsCloseRecorder.Count(const APrefix: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for I := 0 to FItems.Count - 1 do
      if Copy(FItems[I], 1, Length(APrefix)) = APrefix then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TWsCloseRecorder.WaitForCount(const APrefix: string; const AExpected: Integer;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (Count(APrefix) < AExpected) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := Count(APrefix) >= AExpected;
end;

{ TOpenH2CloseTest }

procedure TOpenH2CloseTest.Build(const AWindow: Integer);
begin
  FFactory := TWsCloseFactory.Create(AWindow);
  FFactoryRef := FFactory;
  // the cleartext policy of the pool: the ws URL gets HTTP/2 by prior knowledge
  FPool := TConnectionPool.Create(FFactoryRef, 2, 4, 100, 1000, 1000, 0, nil, False,
    ctPriorKnowledge);
  FRec := TWsCloseRecorder.Create;
  FRecRef := FRec;
end;

function TOpenH2CloseTest.Request(const AUrl: string): IWebSocketRequest;
begin
  // the listener gets every callback, OnClose included, only with demand
  Result := TWebSocketRequest.Create(AUrl, FRecRef).WithAutoRequest;
end;

function TOpenH2CloseTest.Open(const AReq: IWebSocketRequest;
  out AOutcome: TTunnelOutcome): IWebSocket;
begin
  Result := OpenWebSocketH2(FPool, AReq, nil, nil, 1000, nil, nil, AOutcome);
end;

function TOpenH2CloseTest.ClientStream: TBytes;
var
  Frames: TArray<TFrame>;
  I, N: Integer;
begin
  SetLength(Result, 0);
  Frames := FFactory.Sock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if (Frames[I].Header.FrameType = ftData) and (Frames[I].Header.StreamId = 1) and
       (Length(Frames[I].Payload) > 0) then
    begin
      N := Length(Result);
      SetLength(Result, N + Length(Frames[I].Payload));
      Move(Frames[I].Payload[0], Result[N], Length(Frames[I].Payload));
    end;
end;

function TOpenH2CloseTest.WaitForClientFrame(const AOpcode: Byte; const APayload: string;
  const ATimeoutMs: Integer; out AMasked: Boolean): Boolean;
var
  Data, Payload: TBytes;
  Offset, Next: Integer;
  Op: Byte;
  Deadline: QWord;
  Masked: Boolean;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Data := ClientStream;
    Offset := 0;
    while ParseClientFrame(Data, Offset, Op, Payload, Masked, Next) do
    begin
      if (Op = AOpcode) and (OctetsOf(Payload) = APayload) then
      begin
        AMasked := Masked;
        Exit(True);
      end;
      Offset := Next;
    end;
    Sleep(5);
  until GetTickCount64 >= Deadline;
  AMasked := False;
  Result := False;
end;

function TOpenH2CloseTest.ClientEndCount: Integer;
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  // a DATA frame of the client with END_STREAM on stream 1 (an empty one too)
  Result := 0;
  Frames := FFactory.Sock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if (Frames[I].Header.FrameType = ftData) and (Frames[I].Header.StreamId = 1) and
       Frames[I].IsEndStream then
      Inc(Result);
end;

function TOpenH2CloseTest.ClientFrameCount(const AType: TFrameType;
  const AStreamId: LongWord): Integer;
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Result := 0;
  Frames := FFactory.Sock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if (Frames[I].Header.FrameType = AType) and (Frames[I].Header.StreamId = AStreamId) then
      Inc(Result);
end;

function TOpenH2CloseTest.WaitForEnd(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (ClientEndCount = 0) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := ClientEndCount > 0;
end;

function TOpenH2CloseTest.SendRaises(const AText: string): Boolean;
begin
  Result := False;
  try
    FSess.SendText(AText, True);
  except
    Result := True;
  end;
end;

procedure TOpenH2CloseTest.TearDown;
begin
  if FSess <> nil then
    try
      FSess.Abort;
    except
    end;
  FSess := nil;
  Sleep(100);
  if FFactory <> nil then
    FFactory.DetachHooks;
  FreeAndNil(FPool);
  FFactory := nil;
  FFactoryRef := nil;
  FRec := nil;
  FRecRef := nil;
  inherited TearDown;
end;

procedure TOpenH2CloseTest.TestOneFrameCloseAndEndGivesOnClose;
var
  Outcome: TTunnelOutcome;
  Masked: Boolean;
begin
  // case (a): the Close frame and END_STREAM come in one DATA frame
  Build(-1);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(cCode1001)), True);
  AssertTrue('OnClose with the server code', FRec.WaitForCount('close:1001', 1, cWaitMs));
  AssertTrue('the client echoes the close frame',
    WaitForClientFrame($8, cCode1001, cWaitMs, Masked));
  AssertTrue('the echo is masked', Masked);
  AssertTrue('the client END_STREAM follows', WaitForEnd(cWaitMs));
  Sleep(100);
  AssertEquals('exactly one OnClose', 1, FRec.Count('close:'));
  AssertEquals('no OnError', 0, FRec.Count('error:'));
  AssertEquals('no RST_STREAM for a complete close', 0, ClientFrameCount(ftRstStream, 1));
end;

procedure TOpenH2CloseTest.TestSeparateEndFrameGivesOnClose;
var
  Outcome: TTunnelOutcome;
  Masked: Boolean;
begin
  // case (b): the Close frame, then END_STREAM in an empty DATA frame at once
  Build(-1);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(cCode1001)), False);
  FFactory.Sock.EnqueueData(1, nil, True);
  AssertTrue('OnClose with the server code', FRec.WaitForCount('close:1001', 1, cWaitMs));
  AssertTrue('the client echoes the close frame',
    WaitForClientFrame($8, cCode1001, cWaitMs, Masked));
  AssertTrue('the client END_STREAM follows', WaitForEnd(cWaitMs));
  Sleep(100);
  AssertEquals('exactly one OnClose', 1, FRec.Count('close:'));
  AssertEquals('no OnError', 0, FRec.Count('error:'));
  AssertEquals('no RST_STREAM for a complete close', 0, ClientFrameCount(ftRstStream, 1));
end;

procedure TOpenH2CloseTest.TestLateEndFrameGivesOnCloseOnce;
var
  Outcome: TTunnelOutcome;
  Masked: Boolean;
begin
  // case (c): the Close frame comes first, END_STREAM much later
  Build(-1);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(cCode1001)), False);
  AssertTrue('the client echoes the close frame',
    WaitForClientFrame($8, cCode1001, cWaitMs, Masked));
  Sleep(300);
  AssertEquals('no OnClose before the server END_STREAM', 0, FRec.Count('close:'));
  AssertEquals('no client END_STREAM before the server END_STREAM', 0, ClientEndCount);
  FFactory.Sock.EnqueueData(1, nil, True);
  AssertTrue('OnClose with the server code', FRec.WaitForCount('close:1001', 1, cWaitMs));
  AssertTrue('the client END_STREAM follows', WaitForEnd(cWaitMs));
  Sleep(100);
  AssertEquals('exactly one OnClose', 1, FRec.Count('close:'));
  AssertEquals('no OnError', 0, FRec.Count('error:'));
  AssertEquals('no RST_STREAM for a complete close', 0, ClientFrameCount(ftRstStream, 1));
end;

procedure TOpenH2CloseTest.TestNoCreditEchoStillGivesOnClose;
var
  Outcome: TTunnelOutcome;
begin
  // case (d): as case (a), but the client has no send credit for its echo
  Build(0);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(cCode1001)), True);
  AssertTrue('OnClose with the server code', FRec.WaitForCount('close:1001', 1, cWaitMs));
  Sleep(200);
  AssertEquals('exactly one OnClose', 1, FRec.Count('close:'));
  AssertEquals('no OnError', 0, FRec.Count('error:'));
  // no echo went out, and the refused echo posted one RST_STREAM CANCEL
  AssertEquals('no DATA frame for the echo', 0, ClientFrameCount(ftData, 1));
  AssertEquals('one RST_STREAM for the refused echo', 1, ClientFrameCount(ftRstStream, 1));
end;

procedure TOpenH2CloseTest.TestSendAfterPeerResetRaises;
var
  Outcome: TTunnelOutcome;
begin
  Build(-1);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueRstStream(1, ecCancel);
  AssertTrue('OnError after the server reset', FRec.WaitForCount('error:', 1, cWaitMs));
  AssertTrue('a send after the peer reset raises', SendRaises('late'));
  AssertEquals('no DATA after the peer reset', 0, ClientFrameCount(ftData, 1));
end;

procedure TOpenH2CloseTest.TestSendAfterSessionEndRaisesAndEndsOnce;
var
  Outcome: TTunnelOutcome;
  Masked: Boolean;
begin
  // the client ends its side once, and a send after that raises
  Build(-1);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(cCode1001)), False);
  AssertTrue('the client echoes the close frame',
    WaitForClientFrame($8, cCode1001, cWaitMs, Masked));
  FFactory.Sock.EnqueueData(1, nil, True);
  AssertTrue('OnClose with the server code', FRec.WaitForCount('close:1001', 1, cWaitMs));
  AssertTrue('the client END_STREAM follows', WaitForEnd(cWaitMs));
  Sleep(100);
  AssertEquals('one END_STREAM from the client', 1, ClientEndCount);
  AssertTrue('a send after the client side ended raises', SendRaises('late'));
  AssertEquals('still one END_STREAM from the client', 1, ClientEndCount);
end;

initialization
  RegisterTest(TOpenH2CloseTest);
end.
