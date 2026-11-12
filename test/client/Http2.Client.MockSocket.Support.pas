{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// In-memory mock IHttp2Socket, frame-level assertions, and reusable scripted
/// HTTP/2 server scenarios (plan S11 tasks 11.2, 11.3, 11.4).
// - this unit is part of the http2client project (see doc/design/
//   testing-observability.md): "IHttp2Socket has a mock implementation (an
//   in-memory duplex of TFrames) so the whole connection loop runs without a
//   socket."
// - NOTHING here opens a real socket or touches the network. The mock feeds
//   canned inbound bytes to the connection thread and captures every outbound
//   byte; helpers parse the capture back into TFrames so a test can assert the
//   EXACT frame sequence (type, flags, stream id, payload), not merely that
//   "something was written".
//
// Oracle hook (plan task 11.8) — comparing against `nghttp -nv`:
//   1. run the scenario against a TMockSocket and call
//      `FrameSequenceSummary(Mock.OutboundFrames)`; it prints one line per
//      frame as `#n TYPE flags=0xXX stream=N len=L payload=<hex>`.
//   2. run the equivalent request against `nghttp -nv https://host/...` and
//      read its `recv (stream_id=N) SETTINGS/HEADERS/DATA ...` / `send ...`
//      lines (nghttp's direction labels are from the client's point of view).
//   3. compare frame TYPE, stream id, flags and payload length frame by frame;
//      HPACK payload bytes differ because Huffman/table state differs, so
//      compare decoded header lists, not raw HEADERS octets.
//   `TScriptedServer.SendResponse` uses the same static-table-only encoding as
//   nghttp for a bare `:status`, so status frames are byte-comparable.
unit Http2.Client.MockSocket.Support;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}
interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Hpack, Http2.Client.MockSocket.Frames, Http2.Client.Tls, Http2.Client.Observer,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client;

type
  /// how the mock answers a Read when no canned bytes are available:
  ///   mrmTimeout — raise EHttpTimeout (an idle poll; the default)
  ///   mrmEof     — return 0 (the peer closed the transport)
  ///   mrmStall   — block without returning, so no deadline can fire
  TMockReadMode = (mrmTimeout, mrmEof, mrmStall);

  /// an in-memory duplex IHttp2Socket that feeds canned inbound bytes and
  /// captures outbound bytes. Thread-safe: the connection thread reads/writes
  /// while the test thread scripts and asserts.
  TMockSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FLock: TCriticalSection;
    FWroteEvent: PRTLEvent;
    FDataEvent: PRTLEvent;
    FWritten: TBytes;
    FWrites: Integer;
    FReadData: TBytes;
    FReadPos: Integer;
    FReadMode: TMockReadMode;
    FConnected: Boolean;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    FAutoRespond: Boolean;
    FEchoData: Boolean;
    FResponseStatus: string;
    FResponseBody: TBytes;
    FResponseEndStream: Boolean;
    FParsePos: Integer;
    FPrefaceDone: Boolean;
    FCodec: THpackCodec;
    FResponseCount: Integer;
    procedure AppendWritten(const ABuffer; const ACount: Integer);
    procedure AppendReadLocked(const ABytes: TBytes);
    procedure ParseAvailable;
    procedure EmitResponse(const AStreamId: LongWord);
    procedure EchoDataFrame(const AStreamId: LongWord; const AOffset,
      ALength: Integer; const AEndStream: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    // ---- scripting the inbound direction ----
    /// append raw canned bytes the connection thread may read
    procedure Feed(const ABytes: TBytes); overload;
    procedure FeedFrame(const AFrame: TFrame); overload;
    procedure FeedFrames(const AFrames: array of TFrame);
    procedure EnqueueSettings(const ASettings: TConnectionSettings); overload;
    procedure EnqueueSettingsAck;
    procedure EnqueueHeaders(const AStreamId: LongWord; const ABlock: TBytes;
      const AEndHeaders, AEndStream: Boolean);
    /// encode `:status` with the mock's own HPACK codec and feed HEADERS
    procedure EnqueueResponseHeaders(const AStreamId: LongWord;
      const AStatus: string; const AEndStream: Boolean);
    procedure EnqueueData(const AStreamId: LongWord; const AData: TBytes;
      const AEndStream: Boolean);
    procedure EnqueueRstStream(const AStreamId: LongWord;
      const ACode: THttp2ErrorCode);
    procedure EnqueueGoAway(const ALastStreamId: LongWord;
      const ACode: THttp2ErrorCode; const ADebug: TBytes);
    procedure EnqueuePing(const AData: TBytes; const AAck: Boolean);
    procedure EnqueueWindowUpdate(const AStreamId, AIncrement: LongWord);
    /// a frame header whose declared length exceeds any legal
    /// SETTINGS_MAX_FRAME_SIZE, so ReadFrame raises EHttpProtocolError
    procedure EnqueueOversizedFrameHeader;
    /// a PUSH_PROMISE frame addressed to AStreamId promising APromisedId;
    /// since we advertise ENABLE_PUSH = 0 the peer must not send this
    procedure EnqueuePushPromise(const AStreamId, APromisedId: LongWord;
      const ABlock: TBytes);

    /// behave like a scripted server: answer each request HEADERS with a
    /// `:status` (+ body) response. Pass AEndStream=False to answer with
    /// HEADERS only, leaving the lease registered.
    procedure AutoRespondToRequestHeaders(const AStatus: string;
      const ABody: TBytes; const AEndStream: Boolean);

    /// echo every client DATA frame back as DATA on the same stream and
    /// return window credit for it, like a server that streams its response
    /// while it still reads the request body
    procedure EchoRequestData;

    // ---- capturing the outbound direction ----
    /// every byte written, a copy
    function WrittenBytes: TBytes;
    /// how many Write calls have happened (frames + pieces)
    function WriteCount: Integer;
    /// the captured bytes with (or without) the 24-byte client preface
    function OutboundBytes(const ASkipPreface: Boolean): TBytes;
    /// the captured bytes parsed into frames
    function OutboundFrames(const ASkipPreface: Boolean = True): TArray<TFrame>;
    procedure ClearWritten;
    /// wait until at least ACount frame-writing calls have happened
    function WaitForWrites(const ACount, ATimeoutMs: Integer): Boolean;
    /// wait until at least ACount outbound frames (after the preface) exist
    function WaitForFrames(const ACount, ATimeoutMs: Integer): Boolean;

    // ---- stall mode ----
    /// reads park without returning until UnstallReads/Close
    procedure StallReads;
    procedure UnstallReads;
    property ReadMode: TMockReadMode read FReadMode write FReadMode;
    /// how many auto-responded requests the mock has answered
    property AutoResponseCount: Integer read FResponseCount;

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
  end;


type
  /// a reusable scripted peer: builds and feeds canned server frame sequences
  /// over a TMockSocket, encoding response headers with its own HPACK codec
TScriptedServer = class
private
  FMock: TMockSocket;
  FCodec: THpackCodec;
  FStatus: string;
public
  constructor Create(const AMock: TMockSocket); overload;
  constructor Create(const AMock: TMockSocket;
    const AStatus: string); overload;
  destructor Destroy; override;

  procedure SendSettings(const ASettings: TConnectionSettings);
  procedure SendSettingsAck;
  procedure SendHeaders(const AStreamId: LongWord; const AStatus: string;
    const AEndStream: Boolean);
  procedure SendResponse(const AStreamId: LongWord; const AStatus: string;
    const ABody: TBytes; const AEndStream: Boolean = True);
  procedure SendGoAway(const ALastStreamId: LongWord;
    const ACode: THttp2ErrorCode = ecNoError);
  procedure SendRstStream(const AStreamId: LongWord;
    const ACode: THttp2ErrorCode);
  procedure SendPing(const AData: TBytes; const AAck: Boolean = False);
  procedure SendWindowUpdate(const AStreamId, AIncrement: LongWord);

  // ---- named reusable scenarios (11.4) ----
  procedure ScenarioNormalGet(const AStreamId: LongWord; const ABody: TBytes);
  procedure ScenarioMultiplex(const AStreamIds: array of LongWord);
  procedure ScenarioGoAway(const ALastStreamId: LongWord);
  procedure ScenarioRstStream(const AStreamId: LongWord;
    const ACode: THttp2ErrorCode);
  // peer advertises a zero initial window and withholds WINDOW_UPDATE, then
  // stalls so the client's read cannot make progress (flow-control stall)
  procedure ScenarioZeroWindow(const AStreamId: LongWord);
  // an oversized frame header, so the connection must fail the read
  procedure ScenarioMalformedFrame;
  /// send PUSH_PROMISE even though the client disabled push (case 8.2/1)
  procedure ScenarioPushPromise(const AStreamId,
    APromisedId: LongWord);
end;

type
  /// hands out a fresh TMockSocket on every Dial, so the PUBLIC client
  /// (THttpClientFactory.WithSocketFactory) can drive the whole Send path
  /// with no real socket (plan S11 "Done when: the mock socket can drive the
  /// full Send path to completion").
  TMockSocketFactory = class(TInterfacedObject, IHttp2SocketFactory)
  private
    FLock: TCriticalSection;
    /// non-owning raw pointers, only for assertions from the test thread
    FSockets: TList<TMockSocket>;
    /// owning interface references, so a handed-out socket stays alive even
    /// after every connection released it (TMockSocket is refcounted)
    FKeepAlive: TList<IHttp2Socket>;
    FDials: Integer;
    FStatus: string;
    FBody: TBytes;
    FEndStream: Boolean;
    FEcho: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    /// every handed-out socket echoes request DATA back (see
    /// TMockSocket.EchoRequestData)
    procedure SetEcho(const AEcho: Boolean);
    /// configure the canned response every handed-out socket will produce
    procedure SetResponse(const AStatus: string; const ABody: TBytes;
      const AEndStream: Boolean);
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function Dials: Integer;
    /// the socket handed out on the 0-based AIndex-th dial
    function Socket(const AIndex: Integer): TMockSocket;
  end;


implementation

constructor TMockSocket.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWroteEvent := RTLEventCreate;
  FDataEvent := RTLEventCreate;
  FCodec := THpackCodec.Create;
  FConnected := True;
  FConnectTimeoutMs := 1000;
  FReadTimeoutMs := 1000;
  FWriteTimeoutMs := 1000;
  FReadMode := mrmTimeout;
  FReadPos := 0;
  FResponseEndStream := True;
end;

destructor TMockSocket.Destroy;
begin
  FCodec.Free;
  RTLEventDestroy(FWroteEvent);
  RTLEventDestroy(FDataEvent);
  FLock.Free;
  inherited Destroy;
end;

procedure TMockSocket.AppendWritten(const ABuffer;
  const ACount: Integer);
var
  P: PByte;
  N: Integer;
begin
  if ACount <= 0 then
    Exit;
  P := @ABuffer;
  N := Length(FWritten);
  SetLength(FWritten, N + ACount);
  Move(P^, FWritten[N], ACount);
end;

procedure TMockSocket.Feed(const ABytes: TBytes);
var
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FReadData);
    SetLength(FReadData, N + Length(ABytes));
    if Length(ABytes) > 0 then
      Move(ABytes[0], FReadData[N], Length(ABytes));
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
end;

procedure TMockSocket.FeedFrame(const AFrame: TFrame);
begin
  Feed(FrameToBytes(AFrame));
end;

procedure TMockSocket.FeedFrames(const AFrames: array of TFrame);
var
  I: Integer;
  Acc: TBytes;
begin
  Acc := nil;
  for I := 0 to High(AFrames) do
    Acc := AppendFrame(Acc, AFrames[I]);
  Feed(Acc);
end;

procedure TMockSocket.EnqueueSettings(const ASettings: TConnectionSettings);
begin
  FeedFrame(BuildSettingsFrame(ASettings));
end;

procedure TMockSocket.EnqueueSettingsAck;
begin
  FeedFrame(BuildSettingsAck);
end;

procedure TMockSocket.EnqueueHeaders(const AStreamId: LongWord;
  const ABlock: TBytes; const AEndHeaders, AEndStream: Boolean);
begin
  FeedFrame(BuildHeadersFrame(AStreamId, ABlock, AEndHeaders, AEndStream));
end;

procedure TMockSocket.EnqueueResponseHeaders(const AStreamId: LongWord;
  const AStatus: string; const AEndStream: Boolean);
var
  Block: THeaderBlock;
  Enc: TBytes;
begin
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := AStatus;
  Block[0].Sensitive := False;
  Enc := FCodec.Encode(Block);
  FeedFrame(BuildHeadersFrame(AStreamId, Enc, True, AEndStream));
end;

procedure TMockSocket.EnqueueData(const AStreamId: LongWord;
  const AData: TBytes; const AEndStream: Boolean);
begin
  FeedFrame(BuildDataFrame(AStreamId, AData, AEndStream));
end;

procedure TMockSocket.EnqueueRstStream(const AStreamId: LongWord;
  const ACode: THttp2ErrorCode);
begin
  FeedFrame(BuildRstStreamFrame(AStreamId, ACode));
end;

procedure TMockSocket.EnqueueGoAway(const ALastStreamId: LongWord;
  const ACode: THttp2ErrorCode; const ADebug: TBytes);
begin
  FeedFrame(BuildGoAwayFrame(ALastStreamId, ACode, ADebug));
end;

procedure TMockSocket.EnqueuePing(const AData: TBytes; const AAck: Boolean);
begin
  FeedFrame(BuildPingFrame(AData, AAck));
end;

procedure TMockSocket.EnqueueWindowUpdate(const AStreamId,
  AIncrement: LongWord);
begin
  FeedFrame(BuildWindowUpdateFrame(AStreamId, AIncrement));
end;

procedure TMockSocket.EnqueueOversizedFrameHeader;
var
  Hdr: TBytes;
begin
  // declared length 0xFFFFFF (16777215) exceeds every legal max frame size,
  // so the connection's ReadFrame must raise EHttpProtocolError
  SetLength(Hdr, FrameHeaderSize);
  Hdr[0] := $FF;
  Hdr[1] := $FF;
  Hdr[2] := $FF;
  Hdr[3] := Ord(ftData);
  Hdr[4] := 0;
  Hdr[5] := 0;
  Hdr[6] := 0;
  Hdr[7] := 0;
  Hdr[8] := 0;
  Feed(Hdr);
end;

procedure TMockSocket.EnqueuePushPromise(const AStreamId,
  APromisedId: LongWord; const ABlock: TBytes);
var
  Payload: TBytes;
begin
  // PUSH_PROMISE payload: R + promised-stream-id (4 bytes), then the header
  // block fragment. We advertise ENABLE_PUSH = 0, so any such frame must be
  // rejected as a connection PROTOCOL_ERROR (RFC 9113 section 6.6).
  SetLength(Payload, 4 + Length(ABlock));
  Payload[0] := (APromisedId shr 24) and $FF;
  Payload[1] := (APromisedId shr 16) and $FF;
  Payload[2] := (APromisedId shr 8) and $FF;
  Payload[3] := APromisedId and $FF;
  if Length(ABlock) > 0 then
    Move(ABlock[0], Payload[4], Length(ABlock));
  FeedFrame(TFrame.Create(ftPushPromise, [ffEndHeaders], AStreamId, Payload));
end;

procedure TMockSocket.AutoRespondToRequestHeaders(const AStatus: string;
  const ABody: TBytes; const AEndStream: Boolean);
begin
  FLock.Acquire;
  try
    FAutoRespond := True;
    FResponseStatus := AStatus;
    FResponseBody := ABody;
    FResponseEndStream := AEndStream;
  finally
    FLock.Release;
  end;
end;

procedure TMockSocket.EchoRequestData;
begin
  FLock.Acquire;
  try
    FEchoData := True;
  finally
    FLock.Release;
  end;
end;

procedure TMockSocket.EchoDataFrame(const AStreamId: LongWord; const AOffset,
  ALength: Integer; const AEndStream: Boolean);
begin
  // reached from ParseAvailable while FLock is held: append directly
  AppendReadLocked(FrameToBytes(BuildDataFrame(AStreamId,
    Copy(FWritten, AOffset, ALength), AEndStream)));
  if ALength > 0 then
  begin
    AppendReadLocked(FrameToBytes(BuildWindowUpdateFrame(0, ALength)));
    AppendReadLocked(FrameToBytes(BuildWindowUpdateFrame(AStreamId, ALength)));
  end;
end;

procedure TMockSocket.EmitResponse(const AStreamId: LongWord);
var
  Block: THeaderBlock;
  Enc: TBytes;
  F: TFrame;
begin
  // reached from ParseAvailable while FLock is held: append directly
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := FResponseStatus;
  Block[0].Sensitive := False;
  Enc := FCodec.Encode(Block);
  if Length(FResponseBody) = 0 then
  begin
    F := BuildHeadersFrame(AStreamId, Enc, True, FResponseEndStream);
    AppendReadLocked(FrameToBytes(F));
  end
  else
  begin
    F := BuildHeadersFrame(AStreamId, Enc, True, False);
    AppendReadLocked(FrameToBytes(F));
    F := BuildDataFrame(AStreamId, FResponseBody, FResponseEndStream);
    AppendReadLocked(FrameToBytes(F));
  end;
  Inc(FResponseCount);
end;

procedure TMockSocket.AppendReadLocked(const ABytes: TBytes);
var
  N: Integer;
begin
  // caller already holds FLock (used by ParseAvailable's auto-respond path)
  N := Length(FReadData);
  SetLength(FReadData, N + Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], FReadData[N], Length(ABytes));
end;

procedure TMockSocket.ParseAvailable;
var
  Len, Typ, Total: Integer;
  StreamId: LongWord;
begin
  if not FPrefaceDone then
  begin
    if Length(FWritten) < 24 then
      Exit;
    FParsePos := 24;
    FPrefaceDone := True;
  end;
  while Length(FWritten) - FParsePos >= FrameHeaderSize do
  begin
    Len := (FWritten[FParsePos] shl 16) or (FWritten[FParsePos + 1] shl 8) or
      FWritten[FParsePos + 2];
    Typ := FWritten[FParsePos + 3];
    StreamId := (LongWord(FWritten[FParsePos + 5]) shl 24) or
      (LongWord(FWritten[FParsePos + 6]) shl 16) or
      (LongWord(FWritten[FParsePos + 7]) shl 8) or
      LongWord(FWritten[FParsePos + 8]);
    if Length(FWritten) - FParsePos < FrameHeaderSize + Len then
      Exit;
    Total := FrameHeaderSize + Len;
    if FEchoData and (Typ = Ord(ftData)) and (StreamId <> 0) then
      EchoDataFrame(StreamId, FParsePos + FrameHeaderSize, Len,
        (FWritten[FParsePos + 4] and 1) <> 0);
    Inc(FParsePos, Total);
    if FAutoRespond and (Typ = Ord(ftHeaders)) and (StreamId <> 0) then
      EmitResponse(StreamId);
  end;
end;

function TMockSocket.WrittenBytes: TBytes;
begin
  FLock.Acquire;
  try
    Result := Copy(FWritten, 0, Length(FWritten));
  finally
    FLock.Release;
  end;
end;

function TMockSocket.WriteCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FWrites;
  finally
    FLock.Release;
  end;
end;

function TMockSocket.OutboundBytes(const ASkipPreface: Boolean): TBytes;
var
  All: TBytes;
  Start: Integer;
begin
  All := WrittenBytes;
  if ASkipPreface then
    Start := 24
  else
    Start := 0;
  if Start >= Length(All) then
    Result := nil
  else
    Result := Copy(All, Start, Length(All) - Start);
end;

function TMockSocket.OutboundFrames(
  const ASkipPreface: Boolean): TArray<TFrame>;
begin
  Result := ParseFrameSequence(WrittenBytes, ASkipPreface);
end;

procedure TMockSocket.ClearWritten;
begin
  FLock.Acquire;
  try
    FWritten := nil;
    FWrites := 0;
    FParsePos := 0;
    FPrefaceDone := False;
  finally
    FLock.Release;
  end;
end;

function TMockSocket.WaitForWrites(const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while WriteCount < ACount do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FWroteEvent, Remaining);
  end;
  Result := True;
end;

function TMockSocket.WaitForFrames(const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Result := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if Length(OutboundFrames(True)) >= ACount then
      Exit(True);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FWroteEvent, Remaining);
  end;
end;

procedure TMockSocket.StallReads;
begin
  FLock.Acquire;
  try
    FReadMode := mrmStall;
  finally
    FLock.Release;
  end;
end;

procedure TMockSocket.UnstallReads;
begin
  FLock.Acquire;
  try
    if FReadMode = mrmStall then
      FReadMode := mrmTimeout;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
end;

function TMockSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  Avail, N: Integer;
  P: PByte;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('mock socket closed');
  FLock.Acquire;
  try
    while True do
    begin
      Avail := Length(FReadData) - FReadPos;
      if Avail > 0 then
      begin
        N := ACount;
        if N > Avail then
          N := Avail;
        P := @ABuffer;
        Move(FReadData[FReadPos], P^, N);
        Inc(FReadPos, N);
        Exit(N);
      end;
      if FReadMode = mrmEof then
        Exit(0);
      if FReadMode = mrmStall then
      begin
        // park without returning; the connection thread stays blocked in
        // Read, so no deadline can fire. Close/Unstall releases us.
        FLock.Release;
        try
          RTLEventWaitFor(FDataEvent, 100);
        finally
          FLock.Acquire;
        end;
        if (not FConnected) or (FReadMode <> mrmStall) then
          raise EHttpTimeout.Create('mock read unstalled');
        Continue;
      end;
      raise EHttpTimeout.Create('mock read idle');
    end;
    Result := 0;
  finally
    FLock.Release;
  end;
end;

function TMockSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('mock socket closed');
  FLock.Acquire;
  try
    AppendWritten(ABuffer, ACount);
    Inc(FWrites);
    ParseAvailable;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FWroteEvent);
  Result := ACount;
end;

procedure TMockSocket.Close;
begin
  FLock.Acquire;
  try
    FConnected := False;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
  RTLEventSetEvent(FWroteEvent);
end;

function TMockSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TMockSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TMockSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TMockSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TMockSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TMockSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TMockSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

{ TScriptedServer }

constructor TScriptedServer.Create(const AMock: TMockSocket);
begin
  Create(AMock, '200');
end;

constructor TScriptedServer.Create(const AMock: TMockSocket;
  const AStatus: string);
begin
  inherited Create;
  FMock := AMock;
  FCodec := THpackCodec.Create;
  FStatus := AStatus;
end;

destructor TScriptedServer.Destroy;
begin
  FCodec.Free;
  inherited Destroy;
end;

procedure TScriptedServer.SendSettings(const ASettings: TConnectionSettings);
begin
  FMock.EnqueueSettings(ASettings);
end;

procedure TScriptedServer.SendSettingsAck;
begin
  FMock.EnqueueSettingsAck;
end;

procedure TScriptedServer.SendHeaders(const AStreamId: LongWord;
  const AStatus: string; const AEndStream: Boolean);
var
  Block: THeaderBlock;
  Enc: TBytes;
begin
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := AStatus;
  Block[0].Sensitive := False;
  Enc := FCodec.Encode(Block);
  FMock.EnqueueHeaders(AStreamId, Enc, True, AEndStream);
end;

procedure TScriptedServer.SendResponse(const AStreamId: LongWord;
  const AStatus: string; const ABody: TBytes; const AEndStream: Boolean);
begin
  SendHeaders(AStreamId, AStatus, AEndStream and (Length(ABody) = 0));
  if Length(ABody) > 0 then
    FMock.EnqueueData(AStreamId, ABody, AEndStream);
end;

procedure TScriptedServer.SendGoAway(const ALastStreamId: LongWord;
  const ACode: THttp2ErrorCode);
begin
  FMock.EnqueueGoAway(ALastStreamId, ACode, nil);
end;

procedure TScriptedServer.SendRstStream(const AStreamId: LongWord;
  const ACode: THttp2ErrorCode);
begin
  FMock.EnqueueRstStream(AStreamId, ACode);
end;

procedure TScriptedServer.SendPing(const AData: TBytes; const AAck: Boolean);
begin
  FMock.EnqueuePing(AData, AAck);
end;

procedure TScriptedServer.SendWindowUpdate(const AStreamId,
  AIncrement: LongWord);
begin
  FMock.EnqueueWindowUpdate(AStreamId, AIncrement);
end;

procedure TScriptedServer.ScenarioNormalGet(const AStreamId: LongWord;
  const ABody: TBytes);
begin
  SendSettings(TConnectionSettings.Defaults);
  SendResponse(AStreamId, FStatus, ABody, True);
end;

procedure TScriptedServer.ScenarioMultiplex(
  const AStreamIds: array of LongWord);
var
  I: Integer;
begin
  SendSettings(TConnectionSettings.Defaults);
  for I := 0 to High(AStreamIds) do
    SendResponse(AStreamIds[I], FStatus, nil, True);
end;

procedure TScriptedServer.ScenarioGoAway(const ALastStreamId: LongWord);
begin
  SendGoAway(ALastStreamId, ecNoError);
end;

procedure TScriptedServer.ScenarioRstStream(const AStreamId: LongWord;
  const ACode: THttp2ErrorCode);
begin
  SendRstStream(AStreamId, ACode);
end;

procedure TScriptedServer.ScenarioZeroWindow(const AStreamId: LongWord);
var
  S: TConnectionSettings;
begin
  S := TConnectionSettings.Defaults;
  S.InitialWindowSize := 0;      // peer grants no stream window
  SendSettings(S);
  // answer the request headers but never replenish the window
  SendHeaders(AStreamId, FStatus, False);
  FMock.StallReads;
end;

procedure TScriptedServer.ScenarioMalformedFrame;
begin
  FMock.EnqueueOversizedFrameHeader;
end;

procedure TScriptedServer.ScenarioPushPromise(const AStreamId,
  APromisedId: LongWord);
begin
  FMock.EnqueuePushPromise(AStreamId, APromisedId, nil);
end;

{ TMockSocketFactory }

constructor TMockSocketFactory.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSockets := TList<TMockSocket>.Create;
  FKeepAlive := TList<IHttp2Socket>.Create;
  FDials := 0;
  FStatus := '200';
  FBody := nil;
  FEndStream := True;
end;

destructor TMockSocketFactory.Destroy;
begin
  // release our owning interface references; the sockets are refcounted and
  // must never be Free'd directly
  FKeepAlive.Clear;
  FKeepAlive.Free;
  FSockets.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMockSocketFactory.SetEcho(const AEcho: Boolean);
begin
  FLock.Acquire;
  try
    FEcho := AEcho;
  finally
    FLock.Release;
  end;
end;

procedure TMockSocketFactory.SetResponse(const AStatus: string;
  const ABody: TBytes; const AEndStream: Boolean);
begin
  FLock.Acquire;
  try
    FStatus := AStatus;
    FBody := ABody;
    FEndStream := AEndStream;
  finally
    FLock.Release;
  end;
end;

function TMockSocketFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  S: TMockSocket;
  St: string;
  Bd: TBytes;
  ES, Echo: Boolean;
begin
  S := TMockSocket.Create;
  FLock.Acquire;
  try
    Inc(FDials);
    FSockets.Add(S);
    St := FStatus;
    Bd := FBody;
    ES := FEndStream;
    Echo := FEcho;
  finally
    FLock.Release;
  end;
  if Echo then
    S.EchoRequestData;
  // the mock answers the client preface + SETTINGS and every request HEADERS
  S.AutoRespondToRequestHeaders(St, Bd, ES);
  // a real server's first frame is its own SETTINGS; the client must apply it
  // before it may send DATA, so answer the client preface + SETTINGS exchange
  // here
  S.EnqueueSettings(TConnectionSettings.Defaults);
  Result := S;
  FLock.Acquire;
  try
    FKeepAlive.Add(Result);
  finally
    FLock.Release;
  end;
end;

function TMockSocketFactory.Dials: Integer;
begin
  FLock.Acquire;
  try
    Result := FDials;
  finally
    FLock.Release;
  end;
end;

function TMockSocketFactory.Socket(const AIndex: Integer): TMockSocket;
begin
  FLock.Acquire;
  try
    if (AIndex >= 0) and (AIndex < FSockets.Count) then
      Result := FSockets[AIndex]
    else
      Result := nil;
  finally
    FLock.Release;
  end;
end;


end.
