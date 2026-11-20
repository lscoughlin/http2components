{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, websocket, extended connect, rfc 8441
notes:
  - this tests OpenWebSocketH2 over the pool and the scripted frame peer of the mock socket
  - the client writes its WebSocket frames as DATA of stream 1; the peer answers the extended CONNECT itself
  - every wait has a time limit; the close tests check the RST_STREAM and END_STREAM flags on the wire
---
}
unit Http2.Client.WebSocket.OpenH2.Test;

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
  /// a socket factory whose sockets answer the extended CONNECT with the status of the test
  TWsH2Factory = class(TInterfacedObject, IHttp2SocketFactory, ICleartextSocketFactory)
  private
    FStatus: string;
    FSubprotocol: string;
    FBody: string;
    FBig: Boolean;
    FCodec: THpackCodec;
    FSockets: TList<IHttp2Socket>;
    procedure OnClientFrame(const AFrame: TFrame);
  public
    /// AStatus answers the CONNECT; ASubprotocol (may be '') is sent as the chosen one;
    /// ABody (may be '') is sent as DATA with END_STREAM; ABig gives a 16 MiB window
    constructor Create(const AStatus, ASubprotocol, ABody: string; const ABig: Boolean);
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

  /// records what the listener receives, one text item per callback
  TWsRecorder = class(TInterfacedObject, IWebSocketListener)
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

  /// the attempt observer: the calls and the protocol it receives
  TRecordingAttempt = class(TInterfacedObject, IWebSocketAttempt, IExchangeObserver)
  private
    FLock: TCriticalSection;
    FItems: TStringList;
    procedure Add(const AText: string);
  public
    constructor Create;
    destructor Destroy; override;
    function HandshakeHeaders: TArray<TWsHeaderField>;
    procedure HandshakeWritten;
    procedure HandshakeAccepted(const AStatus: Integer;
      const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
    procedure SessionEnded(const AEnd: TWsSessionEnd);
    procedure RouteChosen(const AProtocol: TNegotiatedProtocol; const AReused: Boolean);
    procedure RequestWritten(const ABytesOut: Int64);
    procedure ExchangeEnded(const AEnd: TExchangeEnd);
    /// the first item that starts with APrefix, or ''
    function Find(const APrefix: string): string;
    function Count(const APrefix: string): Integer;
  end;

  TOpenH2Test = class(TTestCase)
  private
    FFactory: TWsH2Factory;
    FFactoryRef: IHttp2SocketFactory;
    FPool: TConnectionPool;
    FRec: TWsRecorder;
    FRecRef: IWebSocketListener;
    FAttempt: TRecordingAttempt;
    FAttemptRef: IWebSocketAttempt;
    FSess: IWebSocket;
    procedure Build(const AStatus, ASubprotocol, ABody: string; const ABig: Boolean);
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
    /// wait until the client sent RST_STREAM on stream 1, then return its code
    function WaitForRst(const ATimeoutMs: Integer; out ACode: LongWord): Boolean;
    function WaitForEnd(const ATimeoutMs: Integer): Boolean;
  protected
    procedure TearDown; override;
  published
    procedure TestSessionOverHttp2;
    procedure TestServerCloseWaitsForTheServerEnd;
    procedure TestAbortSendsResetCancel;
    procedure TestCloseTimeoutResetsWithCancel;
    procedure TestServerEndWithoutCloseGivesOnError;
    procedure TestServerResetGivesOnError;
    procedure TestRefusalGivesTheStatus;
    procedure TestSubprotocolIsChosen;
    procedure TestUnofferedSubprotocolResetsTheStream;
    procedure TestDemandZeroKeepsTheStreamWindowClosed;
    procedure TestThreeMegabyteMessageArrivesInFrames;
  end;

implementation

const
  cTestUrl = 'ws://tunnel.test:80/chat';
  cWaitMs = 5000;
  cPeerFrameSize = 16384;
  cMegabyte = 1048576;

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
  N, Hdr, I: Integer;
begin
  N := Length(APayload);
  if N < 126 then
    Hdr := 2
  else if N <= 65535 then
    Hdr := 4
  else
    Hdr := 10;
  SetLength(Result, Hdr + N);
  Result[0] := $80 or AOpcode;
  if N < 126 then
    Result[1] := N
  else if N <= 65535 then
  begin
    Result[1] := 126;
    Result[2] := N shr 8;
    Result[3] := N and $FF;
  end
  else
  begin
    Result[1] := 127;
    for I := 0 to 7 do
      Result[2 + I] := (N shr (8 * (7 - I))) and $FF;
  end;
  if N > 0 then
    Move(APayload[0], Result[Hdr], N);
end;

/// read one masked client frame at AOffset; ANext is the offset after it
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
  end
  else if Len = 127 then
  begin
    if P + 8 > Length(AData) then Exit;
    Len := 0;
    for I := 0 to 7 do
      Len := (Len shl 8) or AData[P + I];
    Inc(P, 8);
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

{ TWsH2Factory }

constructor TWsH2Factory.Create(const AStatus, ASubprotocol, ABody: string;
  const ABig: Boolean);
begin
  inherited Create;
  FStatus := AStatus;
  FSubprotocol := ASubprotocol;
  FBody := ABody;
  FBig := ABig;
  FCodec := THpackCodec.Create;
  FSockets := TList<IHttp2Socket>.Create;
end;

destructor TWsH2Factory.Destroy;
begin
  FSockets.Free;
  FCodec.Free;
  inherited Destroy;
end;

procedure TWsH2Factory.OnClientFrame(const AFrame: TFrame);
var
  Block: THeaderBlock;
  Enc: TBytes;
  Target: TMockSocket;
  Fields: Integer;
begin
  // the extended CONNECT of stream 1 gets the answer of the test
  if (AFrame.Header.FrameType <> ftHeaders) or (AFrame.Header.StreamId <> 1) then
    Exit;
  Target := Sock;
  Fields := 1;
  if FSubprotocol <> '' then
    Fields := 2;
  SetLength(Block, Fields);
  Block[0].Name := ':status';
  Block[0].Value := FStatus;
  Block[0].Sensitive := False;
  if FSubprotocol <> '' then
  begin
    Block[1].Name := 'sec-websocket-protocol';
    Block[1].Value := FSubprotocol;
    Block[1].Sensitive := False;
  end;
  Enc := FCodec.Encode(Block);
  // the answer ends with the headers when it has no body and is not 200
  Target.FeedLocked(FrameToBytes(BuildHeadersFrame(1, Enc, True,
    (FBody = '') and (FStatus <> '200'))));
  if FBody <> '' then
    Target.FeedLocked(FrameToBytes(BuildDataFrame(1, ToBytes(FBody), True)));
end;

function TWsH2Factory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  S: TMockSocket;
  Settings: TConnectionSettings;
begin
  S := TMockSocket.Create;
  S.OnClientFrame := OnClientFrame;
  Settings := TConnectionSettings.Defaults;
  Settings.EnableConnectProtocol := True;
  if FBig then
    Settings.InitialWindowSize := 16 * cMegabyte;
  S.EnqueueSettings(Settings);
  if FBig then
    // the connection window is not set by SETTINGS: it needs its own update
    S.EnqueueWindowUpdate(0, 16 * cMegabyte);
  FSockets.Add(S);
  Result := S;
end;

function TWsH2Factory.DialProtocol(const AHost: string; const APort: Word;
  const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  AProtocol := npHttp2Cleartext;
  Result := Dial(AHost, APort, ATimeoutMs);
end;

function TWsH2Factory.Sock: TMockSocket;
begin
  Result := FSockets[0] as TMockSocket;
end;

procedure TWsH2Factory.DetachHooks;
var
  I: Integer;
begin
  for I := 0 to FSockets.Count - 1 do
    (FSockets[I] as TMockSocket).OnClientFrame := nil;
end;

{ TWsRecorder }

constructor TWsRecorder.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TStringList.Create;
end;

destructor TWsRecorder.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TWsRecorder.Add(const AText: string);
begin
  FLock.Acquire;
  try
    FItems.Add(AText);
  finally
    FLock.Release;
  end;
end;

procedure TWsRecorder.OnOpen(const ASocket: IWebSocket);
begin
  Add('open');
end;

procedure TWsRecorder.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Add('text:' + AText);
end;

procedure TWsRecorder.OnBytes(const ASocket: IWebSocket; const AData: TBytes;
  const ALast: Boolean);
begin
  Add('bytes:' + IntToStr(Length(AData)));
end;

procedure TWsRecorder.OnPing(const ASocket: IWebSocket; const AData: TBytes);
begin
  Add('ping:' + OctetsOf(AData));
end;

procedure TWsRecorder.OnPong(const ASocket: IWebSocket; const AData: TBytes);
begin
  Add('pong:' + OctetsOf(AData));
end;

procedure TWsRecorder.OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
  const AReason: string);
begin
  Add('close:' + IntToStr(AStatusCode) + ':' + AReason);
end;

procedure TWsRecorder.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  Add('error:' + AError.ClassName);
end;

function TWsRecorder.Count(const APrefix: string): Integer;
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

function TWsRecorder.WaitForCount(const APrefix: string; const AExpected: Integer;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (Count(APrefix) < AExpected) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := Count(APrefix) >= AExpected;
end;

{ TRecordingAttempt }

constructor TRecordingAttempt.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TStringList.Create;
end;

destructor TRecordingAttempt.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRecordingAttempt.Add(const AText: string);
begin
  FLock.Acquire;
  try
    FItems.Add(AText);
  finally
    FLock.Release;
  end;
end;

function TRecordingAttempt.HandshakeHeaders: TArray<TWsHeaderField>;
begin
  Result := nil;
end;

procedure TRecordingAttempt.HandshakeWritten;
begin
  Add('written');
end;

procedure TRecordingAttempt.HandshakeAccepted(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
begin
  Add('accepted:' + IntToStr(AStatus) + ':' + ASubprotocol);
end;

procedure TRecordingAttempt.SessionEnded(const AEnd: TWsSessionEnd);
begin
  Add('ended:' + IntToStr(AEnd.CloseCode));
end;

procedure TRecordingAttempt.RouteChosen(const AProtocol: TNegotiatedProtocol;
  const AReused: Boolean);
begin
  Add('route:' + IntToStr(Ord(AProtocol)) + ':' + BoolToStr(AReused, True));
end;

procedure TRecordingAttempt.RequestWritten(const ABytesOut: Int64);
begin
  Add('request-written');
end;

procedure TRecordingAttempt.ExchangeEnded(const AEnd: TExchangeEnd);
begin
  Add('exchange-ended');
end;

function TRecordingAttempt.Find(const APrefix: string): string;
var
  I: Integer;
begin
  Result := '';
  FLock.Acquire;
  try
    for I := 0 to FItems.Count - 1 do
      if Copy(FItems[I], 1, Length(APrefix)) = APrefix then
      begin
        Result := FItems[I];
        Exit;
      end;
  finally
    FLock.Release;
  end;
end;

function TRecordingAttempt.Count(const APrefix: string): Integer;
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

{ TOpenH2Test }

procedure TOpenH2Test.Build(const AStatus, ASubprotocol, ABody: string;
  const ABig: Boolean);
begin
  FFactory := TWsH2Factory.Create(AStatus, ASubprotocol, ABody, ABig);
  FFactoryRef := FFactory;
  // the cleartext policy of the pool: the ws URL gets HTTP/2 by prior knowledge
  FPool := TConnectionPool.Create(FFactoryRef, 2, 4, 100, 1000, 1000, 0, nil, False,
    ctPriorKnowledge);
  FRec := TWsRecorder.Create;
  FRecRef := FRec;
  FAttempt := TRecordingAttempt.Create;
  FAttemptRef := FAttempt;
end;

function TOpenH2Test.Request(const AUrl: string): IWebSocketRequest;
begin
  // the listener gets every callback, OnClose included, only with demand
  Result := TWebSocketRequest.Create(AUrl, FRecRef).WithAutoRequest;
end;

function TOpenH2Test.Open(const AReq: IWebSocketRequest;
  out AOutcome: TTunnelOutcome): IWebSocket;
begin
  Result := OpenWebSocketH2(FPool, AReq, nil, nil, 1000, nil, FAttemptRef, AOutcome);
end;

function TOpenH2Test.ClientStream: TBytes;
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

function TOpenH2Test.WaitForClientFrame(const AOpcode: Byte; const APayload: string;
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

function TOpenH2Test.ClientEndCount: Integer;
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

function TOpenH2Test.ClientFrameCount(const AType: TFrameType;
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

function TOpenH2Test.WaitForRst(const ATimeoutMs: Integer; out ACode: LongWord): Boolean;
var
  Frames: TArray<TFrame>;
  I: Integer;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Frames := FFactory.Sock.OutboundFrames(True);
    for I := 0 to High(Frames) do
      if (Frames[I].Header.FrameType = ftRstStream) and (Frames[I].Header.StreamId = 1) then
      begin
        ACode := (LongWord(Frames[I].Payload[0]) shl 24) or
          (LongWord(Frames[I].Payload[1]) shl 16) or
          (LongWord(Frames[I].Payload[2]) shl 8) or LongWord(Frames[I].Payload[3]);
        Exit(True);
      end;
    Sleep(5);
  until GetTickCount64 >= Deadline;
  ACode := 0;
  Result := False;
end;

function TOpenH2Test.WaitForEnd(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (ClientEndCount = 0) and (GetTickCount64 < Deadline) do
    Sleep(5);
  Result := ClientEndCount > 0;
end;

procedure TOpenH2Test.TearDown;
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
  FAttempt := nil;
  FAttemptRef := nil;
  inherited TearDown;
end;

procedure TOpenH2Test.TestSessionOverHttp2;
var
  Outcome: TTunnelOutcome;
  Masked: Boolean;
begin
  Build('200', '', '', False);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertEquals('the tunnel is chosen', Ord(toTunnel), Ord(Outcome));
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  AssertEquals('the attempt is written once', 1, FAttempt.Count('written'));
  AssertEquals('the answer is 200', 'accepted:200:', FAttempt.Find('accepted:'));
  AssertEquals('the observer receives h2 (cleartext), not reused',
    'route:' + IntToStr(Ord(npHttp2Cleartext)) + ':False', FAttempt.Find('route:'));

  FSess.SendText('hello', True);
  AssertTrue('the text is a masked frame in DATA',
    WaitForClientFrame($1, 'hello', cWaitMs, Masked));
  AssertTrue('the client masks its frames', Masked);

  FFactory.Sock.EnqueueData(1, ServerFrame($1, ToBytes('from-server')), False);
  AssertTrue('a server text frame reaches OnText',
    FRec.WaitForCount('text:from-server', 1, cWaitMs));

  FFactory.Sock.EnqueueData(1, ServerFrame($9, ToBytes('p1')), False);
  AssertTrue('the client answers a ping with a masked pong',
    WaitForClientFrame($A, 'p1', cWaitMs, Masked));
  AssertTrue('pong is masked', Masked);

  FSess.SendPing(ToBytes('c1'));
  AssertTrue('the client sends a masked ping',
    WaitForClientFrame($9, 'c1', cWaitMs, Masked));
  FFactory.Sock.EnqueueData(1, ServerFrame($A, ToBytes('c1')), False);
  AssertTrue('a server pong reaches OnPong', FRec.WaitForCount('pong:c1', 1, cWaitMs));

  // the client Close: its frame, then the server Close and its END_STREAM
  AssertEquals('no END_STREAM from the client yet', 0, ClientEndCount);
  FSess.Close(1000, 'bye');
  AssertTrue('the client sends a masked close frame',
    WaitForClientFrame($8, Chr(3) + Chr($E8) + 'bye', cWaitMs, Masked));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(Chr(3) + Chr($E8))), False);
  FFactory.Sock.EnqueueData(1, nil, True);
  AssertTrue('one OnClose with the code', FRec.WaitForCount('close:1000', 1, cWaitMs));
  AssertEquals('exactly one OnClose', 1, FRec.Count('close:'));
  AssertTrue('the client ends its side with END_STREAM after the server END',
    WaitForEnd(cWaitMs));
  AssertEquals('no RST_STREAM on a clean close', 0,
    ClientFrameCount(ftRstStream, 1));
  AssertEquals('the observer sees the close code', 'ended:1000',
    FAttempt.Find('ended:'));
end;

procedure TOpenH2Test.TestServerCloseWaitsForTheServerEnd;
var
  Outcome: TTunnelOutcome;
  Masked: Boolean;
begin
  Build('200', '', '', False);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, ServerFrame($8, ToBytes(Chr(3) + Chr($E9))), False);
  AssertTrue('the client echoes the close frame',
    WaitForClientFrame($8, Chr(3) + Chr($E9), cWaitMs, Masked));
  Sleep(300);
  AssertEquals('no OnClose before the server END_STREAM', 0, FRec.Count('close:'));
  AssertEquals('no END_STREAM from the client before the server END_STREAM', 0,
    ClientEndCount);
  FFactory.Sock.EnqueueData(1, nil, True);
  AssertTrue('OnClose with the server code', FRec.WaitForCount('close:1001', 1, cWaitMs));
  AssertTrue('the client END_STREAM follows', WaitForEnd(cWaitMs));
  AssertEquals('no RST_STREAM', 0, ClientFrameCount(ftRstStream, 1));
end;

procedure TOpenH2Test.TestAbortSendsResetCancel;
var
  Outcome: TTunnelOutcome;
  Code: LongWord;
begin
  Build('200', '', '', False);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FSess.Abort;
  AssertTrue('RST_STREAM on the wire', WaitForRst(cWaitMs, Code));
  AssertEquals('the code is CANCEL', Ord(ecCancel), Integer(Code));
  AssertEquals('no OnClose after Abort', 0, FRec.Count('close:'));
  AssertEquals('no OnError after Abort', 0, FRec.Count('error:'));
end;

procedure TOpenH2Test.TestCloseTimeoutResetsWithCancel;
var
  Outcome: TTunnelOutcome;
  Code: LongWord;
  Req: IWebSocketRequest;
begin
  Build('200', '', '', False);
  Req := Request(cTestUrl).WithCloseTimeoutMs(300);
  FSess := Open(Req, Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FSess.Close(1000, '');
  AssertTrue('OnError with EHttpTimeout', FRec.WaitForCount('error:EHttpTimeout', 1, cWaitMs));
  AssertTrue('RST_STREAM on the wire', WaitForRst(cWaitMs, Code));
  AssertEquals('the code is CANCEL', Ord(ecCancel), Integer(Code));
  AssertEquals('no OnClose (as on HTTP/1.1)', 0, FRec.Count('close:'));
  AssertEquals('the observer sees 1006', 'ended:1006', FAttempt.Find('ended:'));
end;

procedure TOpenH2Test.TestServerEndWithoutCloseGivesOnError;
var
  Outcome: TTunnelOutcome;
begin
  Build('200', '', '', False);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueData(1, nil, True);
  AssertTrue('OnError', FRec.WaitForCount('error:', 1, cWaitMs));
  AssertEquals('no OnClose without a close frame', 0, FRec.Count('close:'));
end;

procedure TOpenH2Test.TestServerResetGivesOnError;
var
  Outcome: TTunnelOutcome;
begin
  Build('200', '', '', False);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  FFactory.Sock.EnqueueRstStream(1, ecCancel);
  AssertTrue('OnError', FRec.WaitForCount('error:', 1, cWaitMs));
  AssertEquals('no OnClose after a reset', 0, FRec.Count('close:'));
end;

procedure TOpenH2Test.TestRefusalGivesTheStatus;
var
  Outcome: TTunnelOutcome;
  Raised: Boolean;
  Status: Integer;
  Message: string;
begin
  Build('404', '', 'no route', False);
  Raised := False;
  Status := 0;
  Message := '';
  try
    FSess := Open(Request(cTestUrl), Outcome);
  except
    on E: EHttpWebSocketHandshakeError do
    begin
      Raised := True;
      Status := E.StatusCode;
      Message := E.Message;
    end;
  end;
  AssertTrue('the refusal raises EHttpWebSocketHandshakeError', Raised);
  AssertEquals('the status is kept', 404, Status);
  AssertEquals('the refusal is a tunnel refusal', Ord(toRefused), Ord(Outcome));
  AssertTrue('the message names the status', Pos('404', Message) > 0);
  AssertEquals('the observer still receives h2 for the refused attempt',
    'route:' + IntToStr(Ord(npHttp2Cleartext)) + ':False', FAttempt.Find('route:'));
  AssertEquals('no session was started', 0, FRec.Count('open'));
end;

procedure TOpenH2Test.TestSubprotocolIsChosen;
var
  Outcome: TTunnelOutcome;
  Subs: TArray<string>;
  Req: IWebSocketRequest;
begin
  Build('200', 'chat', '', False);
  SetLength(Subs, 2);
  Subs[0] := 'json';
  Subs[1] := 'chat';
  Req := Request(cTestUrl).WithSubprotocols(Subs);
  FSess := Open(Req, Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  AssertEquals('the chosen subprotocol', 'chat', FSess.Subprotocol);
  AssertEquals('the observer receives it', 'accepted:200:chat', FAttempt.Find('accepted:'));
end;

procedure TOpenH2Test.TestUnofferedSubprotocolResetsTheStream;
var
  Outcome: TTunnelOutcome;
  Raised: Boolean;
  Subs: TArray<string>;
  Code: LongWord;
  Req: IWebSocketRequest;
begin
  Build('200', 'evil', '', False);
  SetLength(Subs, 1);
  Subs[0] := 'chat';
  Req := Request(cTestUrl).WithSubprotocols(Subs);
  Raised := False;
  try
    FSess := Open(Req, Outcome);
  except
    on E: EHttpWebSocketHandshakeError do
      Raised := True;
  end;
  AssertTrue('a subprotocol that was not offered fails the handshake', Raised);
  AssertTrue('the stream is reset', WaitForRst(cWaitMs, Code));
  AssertEquals('the code is CANCEL', Ord(ecCancel), Integer(Code));
end;

procedure TOpenH2Test.TestDemandZeroKeepsTheStreamWindowClosed;
var
  Outcome: TTunnelOutcome;
  Payload: TBytes;
  I: Integer;
begin
  Build('200', '', '', False);
  // no WithAutoRequest here: the demand is zero until Request is called
  FSess := Open(TWebSocketRequest.Create(cTestUrl, FRecRef), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  SetLength(Payload, 1000);
  for I := 0 to High(Payload) do
    Payload[I] := Ord('x');
  // 40 messages of 1000 octets: more than one window update batch of unread DATA
  for I := 1 to 40 do
    FFactory.Sock.EnqueueData(1, ServerFrame($1, Payload), False);
  Sleep(400);
  AssertEquals('no message without demand', 0, FRec.Count('text:'));
  AssertEquals('no stream WINDOW_UPDATE for unread DATA', 0,
    ClientFrameCount(ftWindowUpdate, 1));
  FSess.Request(40);
  AssertTrue('the messages arrive with demand', FRec.WaitForCount('text:', 40, cWaitMs));
  AssertTrue('the window opens again once the data is read',
    ClientFrameCount(ftWindowUpdate, 1) > 0);
end;

procedure TOpenH2Test.TestThreeMegabyteMessageArrivesInFrames;
var
  Outcome: TTunnelOutcome;
  Payload: TBytes;
  Frames: TArray<TFrame>;
  I, Total, Largest, Count: Integer;
  Deadline: QWord;
begin
  Build('200', '', '', True);
  FSess := Open(Request(cTestUrl), Outcome);
  AssertTrue('open', FRec.WaitForCount('open', 1, cWaitMs));
  SetLength(Payload, 3 * cMegabyte);
  FillChar(Payload[0], Length(Payload), Ord('m'));
  FSess.SendBinary(Payload, True);
  // the frame header of a 3 MiB payload is 14 octets (2, 8 and 4)
  Deadline := GetTickCount64 + QWord(cWaitMs);
  repeat
    Total := 0;
    Frames := FFactory.Sock.OutboundFrames(True);
    for I := 0 to High(Frames) do
      if (Frames[I].Header.FrameType = ftData) and (Frames[I].Header.StreamId = 1) then
        Inc(Total, Length(Frames[I].Payload));
    if Total >= 3 * cMegabyte + 14 then
      Break;
    Sleep(5);
  until GetTickCount64 >= Deadline;
  AssertTrue('all octets of the message were sent', Total >= 3 * cMegabyte + 14);
  Largest := 0;
  Count := 0;
  Frames := FFactory.Sock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if (Frames[I].Header.FrameType = ftData) and (Frames[I].Header.StreamId = 1) then
    begin
      Inc(Count);
      if Length(Frames[I].Payload) > Largest then
        Largest := Length(Frames[I].Payload);
    end;
  AssertTrue('the message is in several DATA frames', Count >= (3 * cMegabyte) div cPeerFrameSize);
  AssertTrue('no DATA frame is above the peer frame size', Largest <= cPeerFrameSize);
end;

initialization
  RegisterTest(TOpenH2Test);
end.
