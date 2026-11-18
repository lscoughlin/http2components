{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, extended connect, raw client, frame client
notes:
  - This unit holds TH2WsClient, a raw h2c frame client for the live WebSocket over
    HTTP/2 tests. The unit registers no test suite and uses no test framework, so the load
    program can link it.
  - The client keeps the frames it receives while KeepFrames is True (the default). When
    KeepFrames is False, it keeps no DATA frame and counts the DATA octets of each stream.
  - The credit mode sets the WINDOW_UPDATE frames that answer a DATA frame. ccAuto
    answers at once, ccDelayed answers after CreditDelayMs, and ccNone sends none.
  - The socket sets TCP_NODELAY. Each frame goes out in one socket write.
---
}
/// A raw h2c frame client for the live WebSocket over HTTP/2 tests
unit Http2.Server.WebSocket.H2Client;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Generics.Collections,
  mormot.core.base, mormot.net.sock,
  Http2.Server, Http2.Server.Errors, Http2.Common.Hpack, Http2.Common.Headers,
  Http2.Common.Frames, Http2.Server.Seam, Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Types,
  Http2.Server.Http1.RawClient, Http2.Server.WebSocket.TestKit;

type
  /// the credit that the client returns for the DATA frames it receives
  // - ccAuto returns the credit at once, ccDelayed after CreditDelayMs, ccNone not at all
  THcCreditMode = (ccAuto, ccDelayed, ccNone);

  /// a raw h2c client that keeps the frames it receives, unless KeepFrames is False
  TH2WsClient = class
  private
    FSock: TCrtSocket;
    FEnc, FDec: THpackCodec;
    FBuf: RawByteString;
    FFrames: TList<TFrame>;
    FFields: TList<THeaderBlock>;
    FConnWindow: Int64;
    FStreamWindow: TDictionary<LongWord, Int64>;
    FDataCounts: TDictionary<LongWord, Int64>;
    FPeerAdvertisesConnect: Boolean;
    FCreditMode: THcCreditMode;
    FCreditDelayMs: Integer;
    FKeepFrames: Boolean;
    procedure Write(const AFrame: TFrame);
    function Credit(const AStreamId: LongWord): Int64;
  public
    constructor Create(const APort: Integer);
    destructor Destroy; override;
    /// read and answer the frames that arrive, waiting up to AWaitMs for the first
    procedure Pump(const AWaitMs: Integer);
    procedure OpenStream(const AId: LongWord; const AFields: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure OpenWebSocket(const AId: LongWord; const AExtra: THeaderBlock = nil);
    procedure OpenGet(const AId: LongWord; const APath: string);
    /// send AData as DATA frames, waiting for the windows of the server
    procedure SendData(const AId: LongWord; const AData: TBytes; const AEnd: Boolean = False);
    procedure SendRst(const AId: LongWord; const ACode: THttp2ErrorCode);
    /// the fields of the first HEADERS frame of the stream; False after the timeout
    function WaitHeaders(const AId: LongWord; const ATimeoutMs: Integer;
      out AFields: THeaderBlock): Boolean;
    /// the DATA octets that arrived on the stream so far
    function DataOf(const AId: LongWord): TBytes;
    /// wait until the WebSocket frames on the stream, decoded, contain AText
    function WaitFrames(const AId: LongWord; const AText: string;
      const ATimeoutMs: Integer = 5000): Boolean;
    function WaitEnded(const AId: LongWord; const ATimeoutMs: Integer = 5000): Boolean;
    function WaitReset(const AId: LongWord; const ATimeoutMs: Integer;
      out ACode: THttp2ErrorCode): Boolean;
    /// the received frames as text, for a failure message
    function Dump: string;
    /// send one WebSocket message of ATotal payload octets as masked fragments
    // - each fragment is at most AFragBytes (1 to 32768) octets; the message never
    //   exists in memory as a whole
    procedure SendWsMessage(const AId: LongWord; const ATotal: Int64;
      const AFragBytes: Integer; const APattern: Byte);
    /// send a WINDOW_UPDATE for the stream (0 is the connection)
    procedure SendWindowUpdate(const AStreamId: LongWord; const AIncrement: LongWord);
    /// the octets of DATA frame payload (padding and framing included) for the stream
    // - counted in every mode, also when KeepFrames is False
    function DataCount(const AStreamId: LongWord): Int64;
    /// pump until DataCount reaches AMin; False after the timeout
    function WaitDataCount(const AId: LongWord; const AMin: Int64;
      const ATimeoutMs: Integer): Boolean;
    property PeerAdvertisesConnect: Boolean read FPeerAdvertisesConnect;
    property CreditMode: THcCreditMode read FCreditMode write FCreditMode;
    property CreditDelayMs: Integer read FCreditDelayMs write FCreditDelayMs;
    /// when False, the DATA frames are counted and not kept
    property KeepFrames: Boolean read FKeepFrames write FKeepFrames;
  end;

implementation

function FrameBytes(const AFrame: TFrame): TBytes;
begin
  SetLength(Result, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(Result);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Result[FrameHeaderSize], Length(AFrame.Payload));
end;

function IsGoingAwayClose(const AFrame: TFrame): Boolean;
begin
  Result := (AFrame.Header.FrameType = ftData) and
    (Length(AFrame.Payload) >= 4) and (AFrame.Payload[0] = $88) and
    (AFrame.Payload[2] = $03) and (AFrame.Payload[3] = $E9);
end;

{ TH2WsClient }

constructor TH2WsClient.Create(const APort: Integer);
var
  Wire: TBytes;
begin
  inherited Create;
  FEnc := THpackCodec.Create;
  FDec := THpackCodec.Create;
  FFrames := TList<TFrame>.Create;
  FFields := TList<THeaderBlock>.Create;
  FStreamWindow := TDictionary<LongWord, Int64>.Create;
  FDataCounts := TDictionary<LongWord, Int64>.Create;
  FKeepFrames := True;
  FConnWindow := 65535;
  FSock := TCrtSocket.Open('127.0.0.1', IntToStr(APort), nlTcp, ResponseMs);
  // Nagle would hold a frame that is sent in two writes until the delayed ACK
  FSock.TcpNoDelay := True;
  SetLength(Wire, ClientPrefaceSize);
  Move(ClientPreface[0], Wire[0], ClientPrefaceSize);
  Wire := Cat(Wire, FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults)));
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

destructor TH2WsClient.Destroy;
begin
  FSock.Free;
  FStreamWindow.Free;
  FDataCounts.Free;
  FFields.Free;
  FFrames.Free;
  FDec.Free;
  FEnc.Free;
  inherited Destroy;
end;

procedure TH2WsClient.Write(const AFrame: TFrame);
var
  Wire: TBytes;
begin
  Wire := FrameBytes(AFrame);
  FSock.SockSend(@Wire[0], Length(Wire));
  FSock.SockSendFlush();
end;

function TH2WsClient.Credit(const AStreamId: LongWord): Int64;
begin
  if not FStreamWindow.TryGetValue(AStreamId, Result) then
    Result := 65535;
end;

procedure TH2WsClient.Pump(const AWaitMs: Integer);
var
  Pending: TCrtSocketPending;
  Chunk: RawByteString;
  HeaderBytes: TBytes;
  Header: TFrameHeader;
  N: Integer;
  Frame: TFrame;
  Settings: TConnectionSettings;
begin
  Pending := FSock.SockReceivePending(AWaitMs);
  // read only when octets are waiting: SockReceiveString on an idle socket blocks
  // up to the socket timeout
  if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
  begin
    Chunk := FSock.SockReceiveString;
    if Chunk <> '' then
      FBuf := FBuf + Chunk;
  end;
  while Length(FBuf) >= FrameHeaderSize do
  begin
    SetLength(HeaderBytes, FrameHeaderSize);
    Move(FBuf[1], HeaderBytes[0], FrameHeaderSize);
    Header := TFrameHeader.ReadFrom(HeaderBytes);
    N := FrameHeaderSize + Integer(Header.Length);
    if Length(FBuf) < N then
      Break;
    SetLength(Frame.Payload, Header.Length);
    if Header.Length > 0 then
      Move(FBuf[FrameHeaderSize + 1], Frame.Payload[0], Header.Length);
    Frame.Header := Header;
    FBuf := Copy(FBuf, N + 1, MaxInt);
    case Header.FrameType of
      ftSettings:
        if not Frame.IsAck then
        begin
          Settings := TConnectionSettings.Decode(Frame.Payload);
          FPeerAdvertisesConnect := Settings.EnableConnectProtocol;
          Write(BuildSettingsAck);
        end;
      ftWindowUpdate:
        if Header.StreamId = 0 then
          Inc(FConnWindow, ParseWindowUpdate(Frame))
        else
          FStreamWindow.AddOrSetValue(Header.StreamId,
            Credit(Header.StreamId) + ParseWindowUpdate(Frame));
      ftData:
        begin
          FDataCounts.AddOrSetValue(Header.StreamId,
            DataCount(Header.StreamId) + Header.Length);
          if (Header.Length > 0) and not Frame.IsEndStream and
             not IsGoingAwayClose(Frame) and (FCreditMode <> ccNone) then
          begin
            // Ended streams and the terminal going-away close need no more
            // flow-control credit from this validation peer.
            if (FCreditMode = ccDelayed) and (FCreditDelayMs > 0) then
              Sleep(FCreditDelayMs);
            Write(BuildWindowUpdateFrame(0, Header.Length));
            Write(BuildWindowUpdateFrame(Header.StreamId, Header.Length));
          end;
        end;
    end;
    if (Header.FrameType <> ftData) or FKeepFrames then
    begin
      FFrames.Add(Frame);
      if Header.FrameType = ftHeaders then
        FFields.Add(FDec.Decode(ExtractHeaderBlock(Frame)))
      else
        FFields.Add(nil);
    end;
  end;
end;

procedure TH2WsClient.OpenStream(const AId: LongWord; const AFields: THeaderBlock;
  const AEndStream: Boolean);
begin
  Write(BuildHeadersFrame(AId, FEnc.Encode(AFields), True, AEndStream));
end;

procedure TH2WsClient.OpenWebSocket(const AId: LongWord; const AExtra: THeaderBlock);
var
  F: THeaderBlock;
  I, N: Integer;

  procedure Add(const AName, AValue: string);
  begin
    SetLength(F, N + 1);
    F[N].Name := AName;
    F[N].Value := AValue;
    Inc(N);
  end;

begin
  F := nil;
  N := 0;
  Add(':method', 'CONNECT');
  Add(':scheme', 'http');
  Add(':path', '/ws');
  Add(':authority', 'localhost');
  Add(':protocol', 'websocket');
  Add('sec-websocket-version', '13');
  for I := 0 to High(AExtra) do
    Add(AExtra[I].Name, AExtra[I].Value);
  OpenStream(AId, F);
end;

procedure TH2WsClient.OpenGet(const AId: LongWord; const APath: string);
var
  F: THeaderBlock;
begin
  SetLength(F, 4);
  F[0].Name := ':method';
  F[0].Value := 'GET';
  F[1].Name := ':scheme';
  F[1].Value := 'http';
  F[2].Name := ':path';
  F[2].Value := APath;
  F[3].Name := ':authority';
  F[3].Value := 'localhost';
  OpenStream(AId, F, True);
end;

procedure TH2WsClient.SendData(const AId: LongWord; const AData: TBytes; const AEnd: Boolean);
var
  Pos, N: Integer;
  Chunk: TBytes;
  Deadline: QWord;
begin
  Pos := 0;
  Deadline := GetTickCount64 + 10000;
  if Length(AData) = 0 then
  begin
    Write(BuildDataFrame(AId, nil, AEnd));
    Exit;
  end;
  while Pos < Length(AData) do
  begin
    N := Length(AData) - Pos;
    if N > 16384 then
      N := 16384;
    while (FConnWindow < N) or (Credit(AId) < N) do
    begin
      Pump(20);
      if GetTickCount64 > Deadline then
        raise Exception.Create('the windows of the server stayed closed');
    end;
    SetLength(Chunk, N);
    Move(AData[Pos], Chunk[0], N);
    Dec(FConnWindow, N);
    FStreamWindow.AddOrSetValue(AId, Credit(AId) - N);
    Inc(Pos, N);
    Write(BuildDataFrame(AId, Chunk, AEnd and (Pos >= Length(AData))));
  end;
end;

procedure TH2WsClient.SendRst(const AId: LongWord; const ACode: THttp2ErrorCode);
begin
  Write(BuildRstStreamFrame(AId, ACode));
end;

function TH2WsClient.WaitHeaders(const AId: LongWord; const ATimeoutMs: Integer;
  out AFields: THeaderBlock): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  AFields := nil;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    for I := 0 to FFrames.Count - 1 do
      if (FFrames[I].Header.FrameType = ftHeaders) and (FFrames[I].Header.StreamId = AId) then
      begin
        AFields := FFields[I];
        Exit(True);
      end;
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := False;
end;

function TH2WsClient.DataOf(const AId: LongWord): TBytes;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FFrames.Count - 1 do
    if (FFrames[I].Header.FrameType = ftData) and (FFrames[I].Header.StreamId = AId) then
      Result := Cat(Result, ExtractDataPayload(FFrames[I]));
end;

function TH2WsClient.WaitFrames(const AId: LongWord; const AText: string;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  L: TStringList;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Pump(20);
    L := DecodeOutput(DataOf(AId));
    try
      if Pos(AText, L.Text) > 0 then
        Exit(True);
    finally
      L.Free;
    end;
  until GetTickCount64 > Deadline;
  Result := False;
end;

function TH2WsClient.WaitEnded(const AId: LongWord; const ATimeoutMs: Integer): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    for I := 0 to FFrames.Count - 1 do
      if (FFrames[I].Header.StreamId = AId) and
         (FFrames[I].Header.FrameType in [ftData, ftHeaders]) and FFrames[I].IsEndStream then
        Exit(True);
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := False;
end;

function TH2WsClient.Dump: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FFrames.Count - 1 do
    Result := Result + Format('[%s s%d len%d fl%d] ', [FrameTypeName(FFrames[I].Header.FrameType),
      FFrames[I].Header.StreamId, FFrames[I].Header.Length, FrameFlagsToByte(FFrames[I].Header.Flags)]);
end;

function TH2WsClient.WaitReset(const AId: LongWord; const ATimeoutMs: Integer;
  out ACode: THttp2ErrorCode): Boolean;
var
  I: Integer;
  Deadline: QWord;
begin
  ACode := ecNoError;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    for I := 0 to FFrames.Count - 1 do
      if (FFrames[I].Header.StreamId = AId) and (FFrames[I].Header.FrameType = ftRstStream) then
      begin
        ParseRstStream(FFrames[I], ACode);
        Exit(True);
      end;
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := False;
end;

procedure TH2WsClient.SendWsMessage(const AId: LongWord; const ATotal: Int64;
  const AFragBytes: Integer; const APattern: Byte);
var
  Left: Int64;
  N: Integer;
  Opcode: Byte;
  Chunk: TBytes;
begin
  if (AFragBytes < 1) or (AFragBytes > 32768) then
    raise Exception.Create('the fragment size must be from 1 to 32768 octets');
  if ATotal <= 0 then
  begin
    SendData(AId, ClientFrame(WsOpBinary, True, nil));
    Exit;
  end;
  Left := ATotal;
  Opcode := WsOpBinary;
  while Left > 0 do
  begin
    if Left > AFragBytes then
      N := AFragBytes
    else
      N := Integer(Left);
    SetLength(Chunk, N);
    FillChar(Chunk[0], N, APattern);
    Dec(Left, N);
    SendData(AId, ClientFrame(Opcode, Left = 0, Chunk));
    Opcode := WsOpContinuation;
  end;
end;

procedure TH2WsClient.SendWindowUpdate(const AStreamId: LongWord; const AIncrement: LongWord);
begin
  Write(BuildWindowUpdateFrame(AStreamId, AIncrement));
end;

function TH2WsClient.DataCount(const AStreamId: LongWord): Int64;
begin
  if not FDataCounts.TryGetValue(AStreamId, Result) then
    Result := 0;
end;

function TH2WsClient.WaitDataCount(const AId: LongWord; const AMin: Int64;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if DataCount(AId) >= AMin then
      Exit(True);
    Pump(20);
  until GetTickCount64 > Deadline;
  Result := DataCount(AId) >= AMin;
end;

end.
