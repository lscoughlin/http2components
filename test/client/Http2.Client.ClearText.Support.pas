{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this provides scripted sockets for client tests
---
}
unit Http2.Client.ClearText.Support;



{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, StrUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client,
  Http2.Client.Http1;

type
  /// a factory that must never be dialled: the strict default rejects the
  /// request before the transport is reached
  TNeverDialFactory = class(TInterfacedObject, IHttp2SocketFactory)
  public
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
  end;

  /// a scripted IHttp2Socket for one byte-exchange.  FScript is handed out to
  /// the reader; FWritten accumulates every byte the client wrote so a test
  /// can assert the exact request the codec/upgrade put on the wire.
  TScriptSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FLock: TCriticalSection;
    FScript: TBytes;
    FReadPos: Integer;
    FWritten: TBytes;
    FConnected: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Feed(const AText: string);
    procedure FeedBytes(const ABytes: TBytes);
    function WrittenText: string;
    function WrittenBytes: TBytes;
    /// bounded wait until the written bytes contain ANeedle (the connection
    /// thread flushes asynchronously, so a byte assertion must wait)
    function WaitForText(const ANeedle: string;
      const ATimeoutMs: Integer): Boolean;
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

  /// a factory implementing BOTH transport contracts.  Each DialProtocol call
  /// records the policy arguments and returns the socket handed to Create, so a
  /// path that needs a second connection (the h2c upgrade rerouted to HTTP/1.1)
  /// can hand out a fresh socket by constructing a second factory.
  /// a factory implementing BOTH transport contracts.  Every dial returns a
  /// FRESH TScriptSocket fed with the same script text, so a path that needs a
  /// second connection (the h2c upgrade rerouted to a fallen-back HTTP/1.1) is
  /// testable.  It records every DialProtocol call so policy plumbing is
  /// asserted.
  TScriptProtocolFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FProtocol: TNegotiatedProtocol;
    FScript: TBytes;
    /// holds a strong interface reference so each handed-out socket stays
    /// alive for SocketAt after the pool releases it
    FSockets: TList<IHttp2Socket>;
    FLock: TCriticalSection;
    FDials: Integer;
    FLastScheme: string;
    FLastFallback: Boolean;
    FLastPolicy: TClearTextPolicy;
    FLastHost: string;
    FLastPort: Word;
    function NewSocket: IHttp2Socket;
  public
    constructor Create(const AProtocol: TNegotiatedProtocol;
      const AScriptText: string);
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function Dials: Integer;
    /// the socket handed out on dial AIndex (0-based), or nil when out of range
    function SocketAt(const AIndex: Integer): TScriptSocket;
    function LastScheme: string;
    function LastFallback: Boolean;
    function LastPolicy: TClearTextPolicy;
    function LastHost: string;
    function LastPort: Word;
  end;

  /// an in-memory frame-level HTTP/2 peer (HTTP/2 side of a prior-knowledge or
  /// adopted upgrade connection).  It decodes the client's request HEADERS and
  /// answers one scripted response so a full Send can run end to end.
  TFramePeer = class(TInterfacedObject, IHttp2Socket)
  private
    FLock: TCriticalSection;
    FDataEvent: PRTLEvent;
    FAcc: TBytes;
    FParsePos: Integer;
    FPrefaceDone: Boolean;
    FIn: TBytes;
    FReadPos: Integer;
    FConnected: Boolean;
    FStatus: string;
    FBody: TBytes;
    FEndStream: Boolean;
    FCodec: THpackCodec;
    FRespCodec: THpackCodec;
    FReqMethod: string;
    FReqPath: string;
    FReqScheme: string;
    FReqAuthority: string;
    FReqCount: Integer;
    procedure AppendInLocked(const ABytes: TBytes);
    procedure AppendWritten(const ABuffer; const ACount: Integer);
    procedure ParseAvailable;
    procedure EmitResponse(const AStreamId: LongWord);
    function FrameBytes(const AF: TFrame): TBytes;
  public
    constructor Create(const AStatus: string; const ABody: TBytes);
    destructor Destroy; override;
    property ReqMethod: string read FReqMethod;
    property ReqPath: string read FReqPath;
    property ReqScheme: string read FReqScheme;
    property ReqAuthority: string read FReqAuthority;
    property ReqCount: Integer read FReqCount;
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

  /// hands out a fresh frame peer per dial (prior knowledge over cleartext).
  /// It implements the extended contract so the pool's DialProtocol path is
  /// exercised for BOTH schemes; the returned codec is always the HTTP/2
  /// cleartext one, which is enough to prove the pool keys by origin.
  TFramePeerPlainFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FStatus: string;
    FBody: TBytes;
    FPeers: TList<TFramePeer>;
  public
    constructor Create(const AStatus: string; const ABody: TBytes);
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function SocketAt(const AIndex: Integer): TFramePeer;
  end;

function CountOccurrences(const AText, ANeedle: string): Integer;
function CountWritten(const AFactory: TScriptProtocolFactory;
  const ANeedle: string): Integer;
function DrainBody(const R: IHttpResponse): Integer;
function TextBytes(const S: string): TBytes;
function BytesText(const B: TBytes): string;
function ConcatBytes(const A, B: TBytes): TBytes;

implementation

function CountOccurrences(const AText, ANeedle: string): Integer;
var
  P: Integer;
begin
  Result := 0;
  P := Pos(ANeedle, AText);
  while P > 0 do
  begin
    Inc(Result);
    P := PosEx(ANeedle, AText, P + Length(ANeedle));
  end;
end;

/// how many times ANeedle was written across EVERY socket the factory handed
/// out: the number of copies of a request the peer received
function CountWritten(const AFactory: TScriptProtocolFactory;
  const ANeedle: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  I := 0;
  while AFactory.SocketAt(I) <> nil do
  begin
    Inc(Result, CountOccurrences(AFactory.SocketAt(I).WrittenText, ANeedle));
    Inc(I);
  end;
end;

/// drain the body and return its length
function DrainBody(const R: IHttpResponse): Integer;
var
  Buf: array[0..63] of Byte;
  N: LongInt;
begin
  Result := 0;
  repeat
    N := R.Body.Read(Buf, SizeOf(Buf));
    if N > 0 then
      Inc(Result, N);
  until N <= 0;
end;

function TextBytes(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function BytesText(const B: TBytes): string;
begin
  Result := '';
  if Length(B) > 0 then
  begin
    SetLength(Result, Length(B));
    Move(B[0], Result[1], Length(B));
  end;
end;

function ConcatBytes(const A, B: TBytes): TBytes;
var
  N: Integer;
begin
  Result := nil;
  N := Length(A);
  SetLength(Result, N + Length(B));
  if N > 0 then
    Move(A[0], Result[0], N);
  if Length(B) > 0 then
    Move(B[0], Result[N], Length(B));
end;

{ TNeverDialFactory }

function TNeverDialFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  raise Exception.Create('the transport must not be dialled');
end;

{ TScriptSocket }

constructor TScriptSocket.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FConnected := True;
end;

destructor TScriptSocket.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TScriptSocket.Feed(const AText: string);
begin
  FeedBytes(TextBytes(AText));
end;

procedure TScriptSocket.FeedBytes(const ABytes: TBytes);
begin
  FLock.Acquire;
  try
    FScript := ConcatBytes(FScript, ABytes);
  finally
    FLock.Release;
  end;
end;

function TScriptSocket.WrittenText: string;
begin
  Result := BytesText(WrittenBytes);
end;

function TScriptSocket.WrittenBytes: TBytes;
begin
  FLock.Acquire;
  try
    Result := FWritten;
  finally
    FLock.Release;
  end;
end;

function TScriptSocket.WaitForText(const ANeedle: string;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if Pos(ANeedle, WrittenText) > 0 then
      Exit(True);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(2);
  until False;
end;

function TScriptSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  Avail, N: Integer;
begin
  FLock.Acquire;
  try
    if not FConnected then
      Exit(0);
    Avail := Length(FScript) - FReadPos;
    if Avail <= 0 then
      Exit(0);   // script exhausted: EOF
    N := ACount;
    if N > Avail then
      N := Avail;
    Move(FScript[FReadPos], PByte(@ABuffer)^, N);
    Inc(FReadPos, N);
    Result := N;
  finally
    FLock.Release;
  end;
end;

function TScriptSocket.Write(const ABuffer; ACount: Integer): Integer;
var
  B: TBytes;
begin
  FLock.Acquire;
  try
    if not FConnected then
      raise EHttpConnectionClosed.Create('scripted socket closed');
    SetLength(B, ACount);
    if ACount > 0 then
      Move(PByte(@ABuffer)^, B[0], ACount);
    FWritten := ConcatBytes(FWritten, B);
    Result := ACount;
  finally
    FLock.Release;
  end;
end;

procedure TScriptSocket.Close;
begin
  FLock.Acquire;
  try
    FConnected := False;
  finally
    FLock.Release;
  end;
end;

function TScriptSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TScriptSocket.GetConnectTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TScriptSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
end;

function TScriptSocket.GetReadTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TScriptSocket.SetReadTimeoutMs(const AValue: Integer);
begin
end;

function TScriptSocket.GetWriteTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TScriptSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
end;

{ TScriptProtocolFactory }

constructor TScriptProtocolFactory.Create(const AProtocol: TNegotiatedProtocol;
  const AScriptText: string);
begin
  inherited Create;
  FProtocol := AProtocol;
  FScript := TextBytes(AScriptText);
  FSockets := TList<IHttp2Socket>.Create;
  FLock := TCriticalSection.Create;
end;

destructor TScriptProtocolFactory.Destroy;
begin
  FSockets.Free;
  FLock.Free;
  inherited Destroy;
end;

function TScriptProtocolFactory.NewSocket: IHttp2Socket;
var
  S: TScriptSocket;
begin
  S := TScriptSocket.Create;
  S.FeedBytes(FScript);
  Result := S;
  FSockets.Add(Result);
end;

function TScriptProtocolFactory.SocketAt(const AIndex: Integer): TScriptSocket;
var
  O: TObject;
begin
  Result := nil;
  if (AIndex < 0) or (AIndex >= FSockets.Count) then
    Exit;
  // downcast via Supports, never a hard class cast on an interface
  if Supports(FSockets[AIndex], TScriptSocket, O) then
    Result := TScriptSocket(O);
end;

function TScriptProtocolFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  Result := NewSocket;
end;

function TScriptProtocolFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  FLock.Acquire;
  try
    Inc(FDials);
    FLastScheme := AScheme;
    FLastFallback := AHttp1Fallback;
    FLastPolicy := APolicy;
    FLastHost := AHost;
    FLastPort := APort;
  finally
    FLock.Release;
  end;
  AProtocol := FProtocol;
  Result := NewSocket;
end;

function TScriptProtocolFactory.Dials: Integer;
begin
  FLock.Acquire;
  try
    Result := FDials;
  finally
    FLock.Release;
  end;
end;

function TScriptProtocolFactory.LastScheme: string;
begin
  FLock.Acquire;
  try
    Result := FLastScheme;
  finally
    FLock.Release;
  end;
end;

function TScriptProtocolFactory.LastFallback: Boolean;
begin
  FLock.Acquire;
  try
    Result := FLastFallback;
  finally
    FLock.Release;
  end;
end;

function TScriptProtocolFactory.LastPolicy: TClearTextPolicy;
begin
  FLock.Acquire;
  try
    Result := FLastPolicy;
  finally
    FLock.Release;
  end;
end;

function TScriptProtocolFactory.LastHost: string;
begin
  FLock.Acquire;
  try
    Result := FLastHost;
  finally
    FLock.Release;
  end;
end;

function TScriptProtocolFactory.LastPort: Word;
begin
  FLock.Acquire;
  try
    Result := FLastPort;
  finally
    FLock.Release;
  end;
end;

{ TFramePeer }

constructor TFramePeer.Create(const AStatus: string; const ABody: TBytes);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDataEvent := RTLEventCreate;
  FCodec := THpackCodec.Create;
  FRespCodec := THpackCodec.Create;
  FConnected := True;
  FStatus := AStatus;
  FBody := ABody;
  FEndStream := True;
  // a real server sends its own SETTINGS first; the client must apply it
  // before it may send DATA, so seed it for the first read
  AppendInLocked(FrameBytes(BuildSettingsFrame(TConnectionSettings.Defaults)));
end;

destructor TFramePeer.Destroy;
begin
  FCodec.Free;
  FRespCodec.Free;
  RTLEventDestroy(FDataEvent);
  FLock.Free;
  inherited Destroy;
end;

function TFramePeer.FrameBytes(const AF: TFrame): TBytes;
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

procedure TFramePeer.AppendInLocked(const ABytes: TBytes);
begin
  FIn := ConcatBytes(FIn, ABytes);
end;

procedure TFramePeer.AppendWritten(const ABuffer; const ACount: Integer);
var
  N: Integer;
begin
  if ACount <= 0 then
    Exit;
  N := Length(FAcc);
  SetLength(FAcc, N + ACount);
  Move(PByte(@ABuffer)^, FAcc[N], ACount);
end;

procedure TFramePeer.EmitResponse(const AStreamId: LongWord);
var
  Block: THeaderBlock;
  Enc: TBytes;
begin
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := FStatus;
  Block[0].Sensitive := False;
  Enc := FRespCodec.Encode(Block);
  if Length(FBody) = 0 then
    AppendInLocked(FrameBytes(BuildHeadersFrame(AStreamId, Enc, True,
      FEndStream)))
  else
  begin
    AppendInLocked(FrameBytes(BuildHeadersFrame(AStreamId, Enc, True, False)));
    AppendInLocked(FrameBytes(BuildDataFrame(AStreamId, FBody, True)));
  end;
end;

procedure TFramePeer.ParseAvailable;
var
  Len, Typ, Total, Flags: Integer;
  StreamId: LongWord;
  Payload: TBytes;
  Fields: THeaderBlock;
  F: THttpHeaderField;
  I: Integer;
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
    if (Typ = Ord(ftHeaders)) and (StreamId <> 0) and
       ((Flags and $04) <> 0) then
    begin
      Inc(FReqCount);
      Fields := FCodec.Decode(Payload);
      for I := 0 to High(Fields) do
      begin
        F := Fields[I];
        if F.Name = ':method' then FReqMethod := F.Value
        else if F.Name = ':path' then FReqPath := F.Value
        else if F.Name = ':scheme' then FReqScheme := F.Value
        else if F.Name = ':authority' then FReqAuthority := F.Value;
      end;
      EmitResponse(StreamId);
    end
    else if (Typ = Ord(ftPing)) and ((Flags and $01) = 0) then
      AppendInLocked(FrameBytes(BuildPingFrame(Payload, True)))
    else if (Typ = Ord(ftSettings)) and ((Flags and $01) <> 0) then
      ; // SETTINGS ACK: ignore
  end;
end;

function TFramePeer.Read(var ABuffer; ACount: Integer): Integer;
var
  Avail, N: Integer;
begin
  FLock.Acquire;
  try
    if not FConnected then
      raise EHttpConnectionClosed.Create('frame peer closed');
    Avail := Length(FIn) - FReadPos;
    if Avail <= 0 then
      raise EHttpTimeout.Create('frame peer read idle');
    N := ACount;
    if N > Avail then
      N := Avail;
    Move(FIn[FReadPos], PByte(@ABuffer)^, N);
    Inc(FReadPos, N);
    Result := N;
  finally
    FLock.Release;
  end;
end;

function TFramePeer.Write(const ABuffer; ACount: Integer): Integer;
begin
  FLock.Acquire;
  try
    if not FConnected then
      raise EHttpConnectionClosed.Create('frame peer closed');
    AppendWritten(ABuffer, ACount);
    ParseAvailable;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
  Result := ACount;
end;

procedure TFramePeer.Close;
begin
  FLock.Acquire;
  try
    FConnected := False;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FDataEvent);
end;

function TFramePeer.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TFramePeer.GetConnectTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TFramePeer.SetConnectTimeoutMs(const AValue: Integer);
begin
end;

function TFramePeer.GetReadTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TFramePeer.SetReadTimeoutMs(const AValue: Integer);
begin
end;

function TFramePeer.GetWriteTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TFramePeer.SetWriteTimeoutMs(const AValue: Integer);
begin
end;

{ TFramePeerPlainFactory }

constructor TFramePeerPlainFactory.Create(const AStatus: string;
  const ABody: TBytes);
begin
  inherited Create;
  FStatus := AStatus;
  FBody := ABody;
  FPeers := TList<TFramePeer>.Create;
end;

destructor TFramePeerPlainFactory.Destroy;
begin
  FPeers.Free;
  inherited Destroy;
end;

function TFramePeerPlainFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  P: TFramePeer;
begin
  P := TFramePeer.Create(FStatus, FBody);
  FPeers.Add(P);
  Result := P;
end;

function TFramePeerPlainFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  AProtocol := npHttp2Cleartext;
  Result := Dial(AHost, APort, ATimeoutMs);
end;

function TFramePeerPlainFactory.SocketAt(const AIndex: Integer): TFramePeer;
begin
  Result := FPeers[AIndex];
end;

{ TClearTextTest }

end.
