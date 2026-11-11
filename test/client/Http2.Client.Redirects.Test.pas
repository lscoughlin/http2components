{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Redirect tests (plan story S10, tasks 10.1-10.4) plus the reusable
/// scripted frame-level fake used by the timeout suite too.
// - NOTHING here opens a real socket or touches the network: an injected
//   IHttp2SocketFactory hands out in-memory frame-level peers that decode the
//   client's request HEADERS (with a persistent HPACK decoder, so dynamic
///   table state stays in sync) and answer with a scripted response per
///   request.
// - non-vacuous by construction: the method/body matrix is asserted from the
///   DECODED request HEADERS and DATA payloads the fake captured, so removing
//   the 303->GET rewrite, the 307 body preservation or the non-replayable
//   guard fails a test; cross-origin asserts the factory dialled twice.
unit Http2.Client.Redirects.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client;

type
  /// one scripted server response
  TRespKind = (rkHeaders, rkRst, rkHeadersThenRst);
  TRespSpec = record
    Kind: TRespKind;
    Status: string;
    Location: string;
    Body: TBytes;
    EndStream: Boolean;
    RstCode: THttp2ErrorCode;
    /// optional response headers ('' = none)
    ContentType: string;
    ContentEncoding: string;
    /// the body DATA frame does not carry END_STREAM, so the stream stays open
    BodyOpen: Boolean;
  end;

/// convert response bytes to a string for test checks
function StrOf(const A: TBytes): string;
/// a response with :status (+ optional location header and body)
function HdrSpec(const AStatus: string; const ALocation: string = '';
  const ABody: TBytes = nil; const AEndStream: Boolean = True): TRespSpec;
/// ASpec with a content-type (and an optional content-encoding) header
function WithContentType(const ASpec: TRespSpec; const AType: string;
  const AEncoding: string = ''): TRespSpec;
/// ASpec whose body frame leaves the stream open
function WithOpenBody(const ASpec: TRespSpec): TRespSpec;
/// a RST_STREAM response
function RstSpec(const ACode: THttp2ErrorCode): TRespSpec;
/// a 200 response head that stays open, then RST_STREAM
function HdrRstSpec(const ACode: THttp2ErrorCode): TRespSpec;
/// copy an inline open-array literal into a dynamic array
function SpecArray(const A: array of TRespSpec): TArray<TRespSpec>;

type
  /// one captured request: method/path/authority, regular header names and the
  /// full DATA payload the client sent on that stream
  TReqRecord = record
    Method: string;
    Path: string;
    Authority: string;
    HeaderNames: string;
    /// every regular header as 'name: value' lines, in wire order
    HeaderLines: string;
    Body: TBytes;
    HasBody: Boolean;
  end;

  /// an in-memory frame-level HTTP/2 peer: parses every frame the client
  /// writes, records each request, and answers with the next scripted spec.
  TFakeFrameSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FLock: TCriticalSection;
    FDataEvent: PRTLEvent;
    FAcc: TBytes;                 // all bytes the client wrote
    FParsePos: Integer;
    FPrefaceDone: Boolean;
    FIn: TBytes;                  // bytes the client may read
    FReadPos: Integer;
    FConnected: Boolean;
    FAutoRespond: Boolean;
    FCodec: THpackCodec;          // decodes the client's request HEADERS
    FRespCodec: THpackCodec;      // encodes our response HEADERS
    FSpecs: TArray<TRespSpec>;
    FSpecIdx: Integer;
    FReqs: TArray<TReqRecord>;
    FReqByStream: TDictionary<LongWord, Integer>;
    function FrameBytes(const AF: TFrame): TBytes;
    procedure AppendWritten(const ABuffer; const ACount: Integer);
    procedure AppendInLocked(const ABytes: TBytes);
    procedure ParseAvailable;
    procedure HandleRequestHeaders(const AStreamId: LongWord;
      const ABlock: TBytes);
    procedure EmitResponse(const AStreamId: LongWord);
    function CurrentSpec: TRespSpec;
  public
    constructor Create(const ASpecs: TArray<TRespSpec>);
    destructor Destroy; override;
    procedure SetAutoRespond(const AValue: Boolean);
    /// queue a frame for the client to read, as if it had just arrived from
    /// the peer
    procedure InjectFrame(const AFrame: TFrame);
    function RequestCount: Integer;
    function RequestAt(const AIndex: Integer): TReqRecord;
    function WrittenFrames: TArray<TFrame>;
    function WaitForRequests(const ACount, ATimeoutMs: Integer): Boolean;
    /// bounded wait until request AIndex has received at least ALength body
    /// bytes. A request is recorded at its HEADERS frame and its body arrives
    /// in later DATA frames, so WaitForRequests alone does not cover the body.
    function WaitForRequestBody(const AIndex, ALength,
      ATimeoutMs: Integer): Boolean;
    /// bounded wait until a written frame of AType appears.  A posted frame is
    /// flushed by the connection thread asynchronously, so a caller that
    /// observes a request failing (e.g. a cancel) may still race the wire.
    function WaitForWrittenFrame(const AType: TFrameType;
      const ATimeoutMs: Integer): Boolean;
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

  /// hands out TFakeFrameSocket peers, one scripted sequence per dial. Records
  /// every dial's host/port/timeout so origin and timeout plumbing is testable.
  TFakeFrameFactory = class(TInterfacedObject, IHttp2SocketFactory)
  private
    FLock: TCriticalSection;
    FDials: Integer;
    FScripts: array of TArray<TRespSpec>;
    FAutoRespond: Boolean;
    FFailDial: Boolean;
    FHosts: TArray<string>;
    FPorts: TArray<Word>;
    FTimeouts: TArray<Integer>;
    FSockets: TArray<IHttp2Socket>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetDialScript(const AIndex: Integer;
      const ASpecs: array of TRespSpec);
    procedure SetAutoRespond(const AValue: Boolean);
    /// when set, Dial raises EHttpTimeout (a stalled connect deadline)
    procedure SetFailDial(const AValue: Boolean);
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function Dials: Integer;
    /// bounded wait until at least ACount dials have happened
    function WaitForDials(const ACount, ATimeoutMs: Integer): Boolean;
    function HostAt(const AIndex: Integer): string;
    function PortAt(const AIndex: Integer): Word;
    function TimeoutAt(const AIndex: Integer): Integer;
    function SocketAt(const AIndex: Integer): TFakeFrameSocket;
  end;


implementation

function HdrSpec(const AStatus: string; const ALocation: string;
  const ABody: TBytes; const AEndStream: Boolean): TRespSpec;
begin
  Result.Kind := rkHeaders;
  Result.Status := AStatus;
  Result.Location := ALocation;
  Result.Body := ABody;
  Result.EndStream := AEndStream;
  Result.RstCode := ecNoError;
  Result.ContentType := '';
  Result.ContentEncoding := '';
  Result.BodyOpen := False;
end;

function WithOpenBody(const ASpec: TRespSpec): TRespSpec;
begin
  Result := ASpec;
  Result.BodyOpen := True;
end;

function WithContentType(const ASpec: TRespSpec; const AType: string;
  const AEncoding: string): TRespSpec;
begin
  Result := ASpec;
  Result.ContentType := AType;
  Result.ContentEncoding := AEncoding;
end;

function RstSpec(const ACode: THttp2ErrorCode): TRespSpec;
begin
  Result.Kind := rkRst;
  Result.Status := '';
  Result.Location := '';
  Result.Body := nil;
  Result.EndStream := True;
  Result.RstCode := ACode;
  Result.ContentType := '';
  Result.ContentEncoding := '';
  Result.BodyOpen := False;
end;

function HdrRstSpec(const ACode: THttp2ErrorCode): TRespSpec;
begin
  Result := HdrSpec('200', '', nil, False);
  Result.Kind := rkHeadersThenRst;
  Result.RstCode := ACode;
end;

function SpecArray(const A: array of TRespSpec): TArray<TRespSpec>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function BytesOf(const A: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 1 to Length(A) do
    Result[I - 1] := Ord(A[I]);
end;

function StrOf(const A: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
    Result := Result + Chr(A[I]);
end;

{ TFakeFrameSocket }

constructor TFakeFrameSocket.Create(const ASpecs: TArray<TRespSpec>);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDataEvent := RTLEventCreate;
  FCodec := THpackCodec.Create;
  FRespCodec := THpackCodec.Create;
  FConnected := True;
  FAutoRespond := True;
  FSpecs := ASpecs;
  FSpecIdx := 0;
  FReqByStream := TDictionary<LongWord, Integer>.Create;
  // a real server sends its own SETTINGS first; the client must apply it
  // before it may send DATA, so seed it for the first read
  FIn := FIn + FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults));
end;

destructor TFakeFrameSocket.Destroy;
begin
  FReqByStream.Free;
  FCodec.Free;
  FRespCodec.Free;
  RTLEventDestroy(FDataEvent);
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeFrameSocket.SetAutoRespond(const AValue: Boolean);
begin
  FLock.Acquire;
  try
    FAutoRespond := AValue;
  finally
    FLock.Release;
  end;
end;

procedure TFakeFrameSocket.InjectFrame(const AFrame: TFrame);
begin
  FLock.Acquire;
  try
    AppendInLocked(FrameBytes(AFrame));
  finally
    FLock.Release;
  end;
end;

function TFakeFrameSocket.FrameBytes(const AF: TFrame): TBytes;
var
  MS: TMemoryStream;
begin
  Result := nil;
  MS := TMemoryStream.Create;
  try
    WriteFrame(MS, AF);
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
      Move(MS.Memory^, Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

procedure TFakeFrameSocket.AppendWritten(const ABuffer;
  const ACount: Integer);
var
  P: PByte;
  N: Integer;
begin
  if ACount <= 0 then
    Exit;
  P := @ABuffer;
  N := Length(FAcc);
  SetLength(FAcc, N + ACount);
  Move(P^, FAcc[N], ACount);
end;

procedure TFakeFrameSocket.AppendInLocked(const ABytes: TBytes);
var
  N: Integer;
begin
  N := Length(FIn);
  SetLength(FIn, N + Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], FIn[N], Length(ABytes));
end;

function TFakeFrameSocket.CurrentSpec: TRespSpec;
begin
  if FSpecIdx < Length(FSpecs) then
    Result := FSpecs[FSpecIdx]
  else if Length(FSpecs) > 0 then
    Result := FSpecs[High(FSpecs)]   // sticky: keep serving the last script
  else
    Result := HdrSpec('200');
end;

procedure TFakeFrameSocket.HandleRequestHeaders(const AStreamId: LongWord;
  const ABlock: TBytes);
var
  Fields: THeaderBlock;
  F: THttpHeaderField;
  I, Idx: Integer;
  Rec: TReqRecord;
begin
  Rec.Method := '';
  Rec.Path := '';
  Rec.Authority := '';
  Rec.HeaderNames := '';
  Rec.HeaderLines := '';
  Rec.Body := nil;
  Rec.HasBody := False;
  Fields := FCodec.Decode(ABlock);
  for I := 0 to High(Fields) do
  begin
    F := Fields[I];
    if F.Name = ':method' then
      Rec.Method := F.Value
    else if F.Name = ':path' then
      Rec.Path := F.Value
    else if F.Name = ':authority' then
      Rec.Authority := F.Value
    else if (F.Name <> '') and (F.Name[1] <> ':') then
    begin
      if Rec.HeaderNames <> '' then
        Rec.HeaderNames := Rec.HeaderNames + ',';
      Rec.HeaderNames := Rec.HeaderNames + F.Name;
      Rec.HeaderLines := Rec.HeaderLines + F.Name + ': ' + F.Value + #10;
    end;
  end;
  SetLength(FReqs, Length(FReqs) + 1);
  Idx := High(FReqs);
  FReqs[Idx] := Rec;
  FReqByStream.AddOrSetValue(AStreamId, Idx);
end;

procedure TFakeFrameSocket.EmitResponse(const AStreamId: LongWord);
var
  Spec: TRespSpec;
  Block: THeaderBlock;
  Enc: TBytes;
begin
  Spec := CurrentSpec;
  Inc(FSpecIdx);
  if Spec.Kind = rkRst then
  begin
    AppendInLocked(FrameBytes(BuildRstStreamFrame(AStreamId, Spec.RstCode)));
    Exit;
  end;
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := Spec.Status;
  Block[0].Sensitive := False;
  if Spec.Location <> '' then
  begin
    SetLength(Block, 2);
    Block[1].Name := 'location';
    Block[1].Value := Spec.Location;
    Block[1].Sensitive := False;
  end;
  if Spec.ContentType <> '' then
  begin
    SetLength(Block, Length(Block) + 1);
    Block[High(Block)].Name := 'content-type';
    Block[High(Block)].Value := Spec.ContentType;
    Block[High(Block)].Sensitive := False;
  end;
  if Spec.ContentEncoding <> '' then
  begin
    SetLength(Block, Length(Block) + 1);
    Block[High(Block)].Name := 'content-encoding';
    Block[High(Block)].Value := Spec.ContentEncoding;
    Block[High(Block)].Sensitive := False;
  end;
  Enc := FRespCodec.Encode(Block);
  if Spec.Kind = rkHeadersThenRst then
  begin
    AppendInLocked(FrameBytes(BuildHeadersFrame(AStreamId, Enc, True, False)));
    AppendInLocked(FrameBytes(BuildRstStreamFrame(AStreamId, Spec.RstCode)));
    Exit;
  end;
  if Length(Spec.Body) = 0 then
    AppendInLocked(FrameBytes(BuildHeadersFrame(AStreamId, Enc, True,
      Spec.EndStream)))
  else
  begin
    AppendInLocked(FrameBytes(BuildHeadersFrame(AStreamId, Enc, True, False)));
    AppendInLocked(FrameBytes(BuildDataFrame(AStreamId, Spec.Body,
      not Spec.BodyOpen)));
  end;
end;

procedure TFakeFrameSocket.ParseAvailable;
var
  Len, Typ, Total, Flags: Integer;
  StreamId: LongWord;
  Payload: TBytes;
  Idx: Integer;
  Rec: TReqRecord;
begin
  if not FPrefaceDone then
  begin
    if Length(FAcc) < 24 then
      Exit;
    FParsePos := 24;
    FPrefaceDone := True;
  end;
  while Length(FAcc) - FParsePos >= FrameHeaderSize do
  begin
    Len := (FAcc[FParsePos] shl 16) or (FAcc[FParsePos + 1] shl 8) or
      FAcc[FParsePos + 2];
    Typ := FAcc[FParsePos + 3];
    Flags := FAcc[FParsePos + 4];
    StreamId := (LongWord(FAcc[FParsePos + 5]) shl 24) or
      (LongWord(FAcc[FParsePos + 6]) shl 16) or
      (LongWord(FAcc[FParsePos + 7]) shl 8) or LongWord(FAcc[FParsePos + 8]);
    if Length(FAcc) - FParsePos < FrameHeaderSize + Len then
      Exit;
    Total := FrameHeaderSize + Len;
    Payload := Copy(FAcc, FParsePos + FrameHeaderSize, Len);
    Inc(FParsePos, Total);
    if (Typ = Ord(ftHeaders)) and (StreamId <> 0) then
    begin
      if (Flags and $04) <> 0 then   // END_HEADERS: the block is complete
      begin
        // the client never pads or prioritizes request HEADERS, so the raw
        // payload is exactly the HPACK block
        HandleRequestHeaders(StreamId, Payload);
        if FAutoRespond then
          EmitResponse(StreamId);
      end;
    end
    else if (Typ = Ord(ftData)) and (StreamId <> 0) then
    begin
      if FReqByStream.TryGetValue(StreamId, Idx) then
      begin
        Rec := FReqs[Idx];
        Rec.Body := Rec.Body + Payload;
        Rec.HasBody := True;
        FReqs[Idx] := Rec;
      end;
    end
    else if (Typ = Ord(ftPing)) and ((Flags and $01) = 0) then
      AppendInLocked(FrameBytes(BuildPingFrame(Payload, True)))
    else if (Typ = Ord(ftSettings)) and ((Flags and $01) <> 0) then
      ; // SETTINGS ACK: ignore
  end;
end;

function TFakeFrameSocket.RequestCount: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FReqs);
  finally
    FLock.Release;
  end;
end;

function TFakeFrameSocket.RequestAt(const AIndex: Integer): TReqRecord;
begin
  FLock.Acquire;
  try
    Result := FReqs[AIndex];
  finally
    FLock.Release;
  end;
end;

function TFakeFrameSocket.WrittenFrames: TArray<TFrame>;
var
  Ofs: Integer;
  F: TFrame;
  Hdr: TBytes;
  Total: Integer;
  Bytes: TBytes;
begin
  Result := nil;
  FLock.Acquire;
  try
    Bytes := Copy(FAcc, 0, Length(FAcc));
  finally
    FLock.Release;
  end;
  Ofs := 24;
  while Ofs + FrameHeaderSize <= Length(Bytes) do
  begin
    Hdr := Copy(Bytes, Ofs, FrameHeaderSize);
    F.Header := TFrameHeader.ReadFrom(Hdr);
    Total := FrameHeaderSize + Integer(F.Header.Length);
    if Ofs + Total > Length(Bytes) then
      Break;
    F.Payload := Copy(Bytes, Ofs + FrameHeaderSize, F.Header.Length);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := F;
    Inc(Ofs, Total);
  end;
end;

function TFakeFrameSocket.WaitForRequests(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while RequestCount < ACount do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(2);
  end;
  Result := True;
end;

function TFakeFrameSocket.WaitForRequestBody(const AIndex, ALength,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (RequestCount <= AIndex) or (Length(RequestAt(AIndex).Body) < ALength) do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(2);
  end;
  Result := True;
end;

function TFakeFrameSocket.WaitForWrittenFrame(const AType: TFrameType;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Frames := WrittenFrames;
    for I := 0 to High(Frames) do
      if Frames[I].Header.FrameType = AType then
        Exit(True);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(2);
  until False;
end;

function TFakeFrameSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  Avail, N: Integer;
  P: PByte;
begin
  FLock.Acquire;
  try
    if not FConnected then
      raise EHttpConnectionClosed.Create('fake socket closed');
    Avail := Length(FIn) - FReadPos;
    if Avail <= 0 then
      raise EHttpTimeout.Create('fake read idle');
    N := ACount;
    if N > Avail then
      N := Avail;
    P := @ABuffer;
    Move(FIn[FReadPos], P^, N);
    Inc(FReadPos, N);
    Result := N;
  finally
    FLock.Release;
  end;
end;

function TFakeFrameSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  FLock.Acquire;
  try
    if not FConnected then
      raise EHttpConnectionClosed.Create('fake socket closed');
    AppendWritten(ABuffer, ACount);
    ParseAvailable;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
  Result := ACount;
end;

procedure TFakeFrameSocket.Close;
begin
  FLock.Acquire;
  try
    FConnected := False;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
end;

function TFakeFrameSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TFakeFrameSocket.GetConnectTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TFakeFrameSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
end;

function TFakeFrameSocket.GetReadTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TFakeFrameSocket.SetReadTimeoutMs(const AValue: Integer);
begin
end;

function TFakeFrameSocket.GetWriteTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TFakeFrameSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
end;

{ TFakeFrameFactory }

constructor TFakeFrameFactory.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAutoRespond := True;
  FFailDial := False;
end;

destructor TFakeFrameFactory.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeFrameFactory.SetDialScript(const AIndex: Integer;
  const ASpecs: array of TRespSpec);
var
  I: Integer;
begin
  // scripts are indexed by dial number (0-based), so setting index 3 grows
  if AIndex >= Length(FScripts) then
    SetLength(FScripts, AIndex + 1);
  SetLength(FScripts[AIndex], Length(ASpecs));
  for I := 0 to High(ASpecs) do
    FScripts[AIndex][I] := ASpecs[I];
end;

procedure TFakeFrameFactory.SetAutoRespond(const AValue: Boolean);
begin
  FAutoRespond := AValue;
end;

procedure TFakeFrameFactory.SetFailDial(const AValue: Boolean);
begin
  FFailDial := AValue;
end;

function TFakeFrameFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  S: TFakeFrameSocket;
  Specs: TArray<TRespSpec>;
  I: Integer;
begin
  if FFailDial then
    raise EHttpTimeout.Create('fake connect deadline');
  Specs := nil;
  FLock.Acquire;
  try
    I := FDials;
    if I < Length(FScripts) then
      Specs := FScripts[I];
    Inc(FDials);
    SetLength(FHosts, FDials);
    SetLength(FPorts, FDials);
    SetLength(FTimeouts, FDials);
    FHosts[I] := AHost;
    FPorts[I] := APort;
    FTimeouts[I] := ATimeoutMs;
  finally
    FLock.Release;
  end;
  S := TFakeFrameSocket.Create(Specs);
  S.SetAutoRespond(FAutoRespond);
  Result := S;
  FLock.Acquire;
  try
    SetLength(FSockets, FDials);
    FSockets[I] := Result;
  finally
    FLock.Release;
  end;
end;

function TFakeFrameFactory.Dials: Integer;
begin
  FLock.Acquire;
  try
    Result := FDials;
  finally
    FLock.Release;
  end;
end;

function TFakeFrameFactory.WaitForDials(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while Dials < ACount do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(2);
  end;
  Result := True;
end;

function TFakeFrameFactory.HostAt(const AIndex: Integer): string;
begin
  FLock.Acquire;
  try
    Result := FHosts[AIndex];
  finally
    FLock.Release;
  end;
end;

function TFakeFrameFactory.PortAt(const AIndex: Integer): Word;
begin
  FLock.Acquire;
  try
    Result := FPorts[AIndex];
  finally
    FLock.Release;
  end;
end;

function TFakeFrameFactory.TimeoutAt(const AIndex: Integer): Integer;
begin
  FLock.Acquire;
  try
    Result := FTimeouts[AIndex];
  finally
    FLock.Release;
  end;
end;

function TFakeFrameFactory.SocketAt(const AIndex: Integer): TFakeFrameSocket;
begin
  FLock.Acquire;
  try
    Result := FSockets[AIndex] as TFakeFrameSocket;
  finally
    FLock.Release;
  end;
end;

{ TRedirectTest }


end.
