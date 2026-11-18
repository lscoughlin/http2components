{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Public-API client tests (plan story S09: factory, pool, Send, Close,
/// response types, generic reader).
// - the pool tests use an injected IHttp2SocketFactory that returns an
//   in-memory scripted server socket, so NO real sockets are opened.
// - non-vacuous by construction: the cap test asserts the observed dial count
//   and connection count equal MaxConnections (mutating the pool to ignore the
//   cap fails it); pseudo-header/port-omission is asserted from the DECODED
//   wire block in Http2.Client.Request.Test.pas.
unit Http2.Client.Test.Support;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}
interface
uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client,
  Http2.Client.Observer, Http2.Client.Encoding, Http2.Common.Body;
type
  TFakeResponseGate = (frgNone, frgFirstHeaders, frgFirstBody);
  /// a scripted in-memory HTTP/2 server: parses every frame the client writes
  /// and answers each request HEADERS with a configured response.
  TFakeServerSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FLock: TCriticalSection;
    FAcc: TBytes;                 // all bytes the client has written
    FParsePos: Integer;
    FPrefaceDone: Boolean;
    FIn: TBytes;                  // bytes the client may read
    FReadPos: Integer;
    FStatus: string;
    FBody: TBytes;
    FEndStream: Boolean;
    FRespHeaders: THeaderBlock;
    FCodec: THpackCodec;
    FGate: TFakeResponseGate;
    FRequestCount: Integer;
    FHeldStreamId: LongWord;
    FRequestEvent: TEvent;
    FConnected: Boolean;
    FConnectTimeoutMs, FReadTimeoutMs, FWriteTimeoutMs: Integer;
    procedure AppendWritten(const ABuffer; const ACount: Integer);
    procedure ParseAvailable;
    procedure EmitResponse(const AStreamId: LongWord);
    function FrameBytes(const AF: TFrame): TBytes;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetResponse(const AStatus: string; const ABody: TBytes;
      const AEndStream: Boolean);
    /// add a response header field to every response this socket answers
    procedure AddResponseHeader(const AName, AValue: string);
    procedure SetGate(const AGate: TFakeResponseGate);
    function WaitForRequests(const ACount, ATimeoutMs: Integer): Boolean;
    procedure ReleaseGate;
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

  /// counts dials and hands out fresh fake server sockets. ResponseEndStream=
  /// False makes the fake answer with HEADERS only (no END_STREAM, no DATA),
  /// so a lease stays registered and the pool cap binds.
  TFakeSocketFactory = class(TInterfacedObject, IHttp2SocketFactory)
  private
    FLock: TCriticalSection;
    FDials: Integer;
    FResponseBody: TBytes;
    FResponseEndStream: Boolean;
    FResponseStatus: string;
    FResponseHeaders: THeaderBlock;
    FResponseGate: TFakeResponseGate;
    FLastSocket: TFakeServerSocket;
  public
    constructor Create;
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function Dials: Integer;
    procedure SetResponse(const AStatus: string; const ABody: TBytes;
      const AEndStream: Boolean);
    /// add a response header field that every dialled socket will answer
    procedure AddResponseHeader(const AName, AValue: string);
    procedure SetResponseGate(const AGate: TFakeResponseGate);
    function WaitForRequests(const ACount, ATimeoutMs: Integer): Boolean;
    procedure ReleaseGate;
  end;

  /// a fake IConnectionStream used only to raise a connection's stream count
  TFakeConnStream = class(TInterfacedObject, IConnectionStream)
  public
    procedure OnConnectionFailed(const AMessage: string;
      const ACode: THttp2ErrorCode);
    procedure OnConnectionGoAway(const ALastStreamId: LongWord);
    procedure OnStreamFrame(const AFrame: TFrame);
  end;

  /// a fake pooled connection for least-loaded pool tests (no sockets)
  TFakePooledConnection = class(TInterfacedObject, IPooledConnection)
  private
    FLoad: Integer;
    FEligible: Boolean;
    FOrigin: string;
    FConn: TConnection;
    FLock: TCriticalSection;
  public
    constructor Create(const AOrigin: string; const ALoad: Integer;
      const AEligible: Boolean);
    destructor Destroy; override;
    function ActiveStreams: Integer;
    function Eligible: Boolean;
    function Acquire(const ARequest: TStreamRequest; const ATimeoutMs: Integer;
      out AAcquired: Boolean): IHttpResponse;
    function AcquireUpgraded(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer): IHttpResponse;
    function Closed: Boolean;
    procedure Drain;
    procedure ReleaseIfIdle;
    function GetConn: TConnection;
    function GetOrigin: string;
    function GetLock: TCriticalSection;
    function GetKey: Pointer;
  end;

  /// a fake response + body stream for TResponseReader<T> tests
  TFakeBody = class(TBodyReaderBase, IHttpBodyStream)
  private
    FData: TBytes;
    FPos: Integer;
  public
    constructor Create(const AData: TBytes);
    function Read(var ABuffer; const ACount: LongInt): LongInt; override;
    function Eof: Boolean;
  end;

  TFakeResponse = class(TInterfacedObject, IHttpResponse)
  private
    FStatus: LongInt;
    FHeaders: IHttpHeaders;
    FBody: IHttpBodyStream;
  public
    constructor Create(const AStatus: LongInt; const ABody: IHttpBodyStream);
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
  end;

  /// one thread performing a single Send against a shared client
  TSendWorker = class(TThread)
  private
    FClient: IHttpClient;
    FUrl: string;
    FDone: PRTLEvent;
    FDoneFlag: Boolean;
    FStatus: LongInt;
    FError: string;
    FRaised: Boolean;
    FResponse: IHttpResponse;   // retained so the stream stays registered
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const AUrl: string);
    destructor Destroy; override;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Status: LongInt read FStatus;
    property Raised: Boolean read FRaised;
    property Error: string read FError;
    property Response: IHttpResponse read FResponse;
  end;

  TBodyReadWorker = class(TThread)
  private
    FResponse: IHttpResponse;
    FDone: PRTLEvent;
    FStarted: PRTLEvent;
    FError: string;
    FByteCount: Integer;
    FStartedFlag: Boolean;
    FDoneFlag: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AResponse: IHttpResponse);
    destructor Destroy; override;
    function WaitStarted(const ATimeoutMs: Integer): Boolean;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Error: string read FError;
    property ByteCount: Integer read FByteCount;
  end;

  TCancellableSendWorker = class(TThread)
  private
    FClient: IHttpClient;
    FToken: ICancellationToken;
    FDone: PRTLEvent;
    FRaised: Boolean;
    FDoneFlag: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient;
      const AToken: ICancellationToken);
    destructor Destroy; override;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Raised: Boolean read FRaised;
  end;

function StrOf(const A: TBytes): string;
function ReadWholeBody(const ABody: IHttpBodyStream): string;

implementation

{ TFakeServerSocket }

constructor TFakeServerSocket.Create;
var
  F: TFrame;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FCodec := THpackCodec.Create;
  FStatus := '200';
  FBody := nil;
  FEndStream := True;
  FRespHeaders := nil;
  FGate := frgNone;
  FRequestCount := 0;
  FHeldStreamId := 0;
  FRequestEvent := TEvent.Create(nil, True, False, '');
  FConnected := True;
  FConnectTimeoutMs := 1000;
  FReadTimeoutMs := 1000;
  FWriteTimeoutMs := 1000;
  // a real server sends its own SETTINGS as its first frame; the client must
  // apply it before it may send DATA, so seed it for the very first read
  F := BuildSettingsFrame(TConnectionSettings.Defaults);
  FIn := FrameBytes(F);
end;

destructor TFakeServerSocket.Destroy;
begin
  FCodec.Free;
  FRequestEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeServerSocket.SetResponse(const AStatus: string;
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

procedure TFakeServerSocket.AddResponseHeader(const AName, AValue: string);
var
  N: Integer;
  FirstBodyCount: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FRespHeaders);
    SetLength(FRespHeaders, N + 1);
    FRespHeaders[N].Name := AName;
    FRespHeaders[N].Value := AValue;
    FRespHeaders[N].Sensitive := False;
  finally
    FLock.Release;
  end;
end;

procedure TFakeServerSocket.SetGate(const AGate: TFakeResponseGate);
begin
  FLock.Acquire;
  try
    FGate := AGate;
  finally
    FLock.Release;
  end;
end;

function TFakeServerSocket.WaitForRequests(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    FLock.Acquire;
    try
      if FRequestCount >= ACount then
        Exit(True);
    finally
      FLock.Release;
    end;
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(1);
  until False;
end;

procedure TFakeServerSocket.ReleaseGate;
var
  F: TFrame;
begin
  FLock.Acquire;
  try
    if FHeldStreamId = 0 then
      Exit;
    if FGate = frgFirstBody then
    begin
      F := BuildDataFrame(FHeldStreamId, FBody, True);
      FIn := FIn + FrameBytes(F);
    end
    else
      EmitResponse(FHeldStreamId);
    FHeldStreamId := 0;
    FGate := frgNone;
  finally
    FLock.Release;
  end;
end;

function TFakeServerSocket.FrameBytes(const AF: TFrame): TBytes;
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

procedure TFakeServerSocket.EmitResponse(const AStreamId: LongWord);
var
  Block: THeaderBlock;
  Enc: TBytes;
  F: TFrame;
  I, N: Integer;
begin
  // ':status' is first, then every header this socket was told to add
  N := Length(FRespHeaders);
  SetLength(Block, N + 1);
  Block[0].Name := ':status';
  Block[0].Value := FStatus;
  Block[0].Sensitive := False;
  for I := 0 to N - 1 do
    Block[I + 1] := FRespHeaders[I];
  Enc := FCodec.Encode(Block);
  if Length(FBody) = 0 then
  begin
    F := BuildHeadersFrame(AStreamId, Enc, True, FEndStream);
    FIn := FIn + FrameBytes(F);
  end
  else
  begin
    F := BuildHeadersFrame(AStreamId, Enc, True, False);
    FIn := FIn + FrameBytes(F);
    F := BuildDataFrame(AStreamId, FBody, FEndStream);
    FIn := FIn + FrameBytes(F);
  end;
end;

procedure TFakeServerSocket.AppendWritten(const ABuffer;
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

procedure TFakeServerSocket.ParseAvailable;
var
  Len, Typ: Integer;
  StreamId: LongWord;
  Total: Integer;
  Block: THeaderBlock;
  Enc: TBytes;
  F: TFrame;
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
    StreamId := (LongWord(FAcc[FParsePos + 5]) shl 24) or
      (LongWord(FAcc[FParsePos + 6]) shl 16) or
      (LongWord(FAcc[FParsePos + 7]) shl 8) or LongWord(FAcc[FParsePos + 8]);
    if Length(FAcc) - FParsePos < FrameHeaderSize + Len then
      Exit;
    Total := FrameHeaderSize + Len;
    Inc(FParsePos, Total);
    if (Typ = Ord(ftHeaders)) and (StreamId <> 0) then
    begin
      Inc(FRequestCount);
      FRequestEvent.SetEvent;
      if (FRequestCount = 1) and (FGate = frgFirstHeaders) then
        FHeldStreamId := StreamId
      else if (FRequestCount = 1) and (FGate = frgFirstBody) then
      begin
        FHeldStreamId := StreamId;
        SetLength(Block, Length(FRespHeaders) + 1);
        Block[0].Name := ':status';
        Block[0].Value := FStatus;
        Block[0].Sensitive := False;
        for I := 0 to High(FRespHeaders) do
          Block[I + 1] := FRespHeaders[I];
        Enc := FCodec.Encode(Block);
        F := BuildHeadersFrame(StreamId, Enc, True, False);
        FIn := FIn + FrameBytes(F);
      end
      else
        EmitResponse(StreamId);
    end;
  end;
end;

function TFakeServerSocket.Write(const ABuffer; ACount: Integer): Integer;
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
  Result := ACount;
end;

function TFakeServerSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  Avail, N: Integer;
  P: PByte;
begin
  FLock.Acquire;
  try
    if not FConnected then
      Exit(0);
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

procedure TFakeServerSocket.Close;
begin
  FConnected := False;
end;

function TFakeServerSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TFakeServerSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TFakeServerSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TFakeServerSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TFakeServerSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TFakeServerSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TFakeServerSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

{ TFakeSocketFactory }

constructor TFakeSocketFactory.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FResponseStatus := '200';
  FResponseBody := nil;
  FResponseEndStream := True;
  FResponseHeaders := nil;
  FResponseGate := frgNone;
  FLastSocket := nil;
end;

destructor TFakeSocketFactory.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeSocketFactory.SetResponse(const AStatus: string;
  const ABody: TBytes; const AEndStream: Boolean);
begin
  FLock.Acquire;
  try
    FResponseStatus := AStatus;
    FResponseBody := ABody;
    FResponseEndStream := AEndStream;
  finally
    FLock.Release;
  end;
end;

function TFakeSocketFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  S: TFakeServerSocket;
  I: Integer;
begin
  S := TFakeServerSocket.Create;
  FLock.Acquire;
  try
    Inc(FDials);
    FLastSocket := S;
    S.SetResponse(FResponseStatus, FResponseBody, FResponseEndStream);
    S.SetGate(FResponseGate);
    for I := 0 to High(FResponseHeaders) do
      S.AddResponseHeader(FResponseHeaders[I].Name,
        FResponseHeaders[I].Value);
  finally
    FLock.Release;
  end;
  Result := S;
end;

procedure TFakeSocketFactory.SetResponseGate(const AGate: TFakeResponseGate);
begin
  FLock.Acquire;
  try
    FResponseGate := AGate;
  finally
    FLock.Release;
  end;
end;

function TFakeSocketFactory.WaitForRequests(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  S: TFakeServerSocket;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    FLock.Acquire;
    try
      S := FLastSocket;
    finally
      FLock.Release;
    end;
    if S <> nil then
      Exit(S.WaitForRequests(ACount,
        Integer(Deadline - GetTickCount64)));
    if GetTickCount64 >= Deadline then
      Exit(False);
    Sleep(1);
  until False;
end;

procedure TFakeSocketFactory.ReleaseGate;
var
  S: TFakeServerSocket;
begin
  FLock.Acquire;
  try
    S := FLastSocket;
  finally
    FLock.Release;
  end;
  if S <> nil then
    S.ReleaseGate;
end;

procedure TFakeSocketFactory.AddResponseHeader(const AName, AValue: string);
var
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FResponseHeaders);
    SetLength(FResponseHeaders, N + 1);
    FResponseHeaders[N].Name := AName;
    FResponseHeaders[N].Value := AValue;
    FResponseHeaders[N].Sensitive := False;
  finally
    FLock.Release;
  end;
end;

function TFakeSocketFactory.Dials: Integer;
begin
  FLock.Acquire;
  try
    Result := FDials;
  finally
    FLock.Release;
  end;
end;

{ TFakeConnStream }

procedure TFakeConnStream.OnConnectionFailed(const AMessage: string;
  const ACode: THttp2ErrorCode);
begin
end;

procedure TFakeConnStream.OnConnectionGoAway(const ALastStreamId: LongWord);
begin
end;

procedure TFakeConnStream.OnStreamFrame(const AFrame: TFrame);
begin
end;

{ TFakePooledConnection }

constructor TFakePooledConnection.Create(const AOrigin: string;
  const ALoad: Integer; const AEligible: Boolean);
begin
  inherited Create;
  FOrigin := AOrigin;
  FLoad := ALoad;
  FEligible := AEligible;
  FLock := TCriticalSection.Create;
  FConn := TConnection.Create(TFakeServerSocket.Create);
end;

destructor TFakePooledConnection.Destroy;
begin
  FConn.Free;
  FLock.Free;
  inherited Destroy;
end;

function TFakePooledConnection.ActiveStreams: Integer;
begin
  Result := FLoad;
end;

function TFakePooledConnection.Eligible: Boolean;
begin
  Result := FEligible;
end;

function TFakePooledConnection.AcquireUpgraded(
  const ARequest: TStreamRequest;
  const ATimeoutMs: Integer): IHttpResponse;
begin
  raise EHttpProtocolError.Create('fake pooled connection: no h2c upgrade',
    ecInternalError);
end;

function TFakePooledConnection.Closed: Boolean;
begin
  Result := FConn.State = csClosed;
end;

function TFakePooledConnection.GetKey: Pointer;
begin
  Result := Pointer(FConn);
end;

function TFakePooledConnection.Acquire(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
begin
  AAcquired := False;
  Result := nil;
end;

procedure TFakePooledConnection.Drain;
begin
  FEligible := False;
end;

procedure TFakePooledConnection.ReleaseIfIdle;
begin
end;

function TFakePooledConnection.GetConn: TConnection;
begin
  Result := FConn;
end;

function TFakePooledConnection.GetOrigin: string;
begin
  Result := FOrigin;
end;

function TFakePooledConnection.GetLock: TCriticalSection;
begin
  Result := FLock;
end;

{ TFakeBody }

constructor TFakeBody.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
  FPos := 0;
end;

function TFakeBody.Read(var ABuffer; const ACount: LongInt): LongInt;
var
  Avail, N: Integer;
  P: PByte;
begin
  Avail := Length(FData) - FPos;
  if Avail <= 0 then
    Exit(0);
  N := ACount;
  if N > Avail then
    N := Avail;
  P := @ABuffer;
  Move(FData[FPos], P^, N);
  Inc(FPos, N);
  Result := N;
end;

function TFakeBody.Eof: Boolean;
begin
  Result := FPos >= Length(FData);
end;

{ TFakeResponse }

constructor TFakeResponse.Create(const AStatus: LongInt;
  const ABody: IHttpBodyStream);
begin
  inherited Create;
  FStatus := AStatus;
  FBody := ABody;
  FHeaders := NewHttpHeaders;
end;

function TFakeResponse.GetStatusCode: LongInt;
begin
  Result := FStatus;
end;

function TFakeResponse.GetHeaders: IHttpHeaders;
begin
  Result := FHeaders;
end;

function TFakeResponse.GetBody: IHttpBodyStream;
begin
  Result := FBody;
end;

{ TSendWorker }

constructor TSendWorker.Create(const AClient: IHttpClient; const AUrl: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FUrl := AUrl;
  FDone := RTLEventCreate;
end;

destructor TSendWorker.Destroy;
begin
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TSendWorker.Execute;
var
  R: IHttpResponse;
begin
  try
    R := FClient.Send(THttpRequest.Create(hmGet, FUrl));
    FResponse := R;
    FStatus := R.StatusCode;
  except
    on E: Exception do
    begin
      FRaised := True;
      FError := E.ClassName + ': ' + E.Message;
      if E is EHttpError then
        FStatus := -1;
    end;
  end;
  FDoneFlag := True;
  RTLEventSetEvent(FDone);
end;

function TSendWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while not FDoneFlag do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FDone, Remaining);
  end;
  Result := True;
end;

constructor TBodyReadWorker.Create(const AResponse: IHttpResponse);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FResponse := AResponse;
  FDone := RTLEventCreate;
  FStarted := RTLEventCreate;
end;

destructor TBodyReadWorker.Destroy;
begin
  RTLEventDestroy(FStarted);
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TBodyReadWorker.Execute;
var
  B: array[0..31] of Byte;
begin
  FStartedFlag := True;
  RTLEventSetEvent(FStarted);
  try
    FByteCount := FResponse.Body.Read(B[0], SizeOf(B));
  except
    on E: Exception do FError := E.ClassName + ': ' + E.Message;
  end;
  FDoneFlag := True;
  RTLEventSetEvent(FDone);
end;

function TBodyReadWorker.WaitStarted(const ATimeoutMs: Integer): Boolean;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while not FStartedFlag and (GetTickCount64 < Deadline) do Sleep(1);
  Result := FStartedFlag;
end;

function TBodyReadWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while not FDoneFlag and (GetTickCount64 < Deadline) do Sleep(1);
  Result := FDoneFlag;
end;

constructor TCancellableSendWorker.Create(const AClient: IHttpClient;
  const AToken: ICancellationToken);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FToken := AToken;
  FDone := RTLEventCreate;
end;

destructor TCancellableSendWorker.Destroy;
begin
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TCancellableSendWorker.Execute;
var
  R: IHttpResponse;
begin
  try
    R := FClient.Send(THttpRequest.Create(hmGet,
      'https://api.example/first').WithCancelToken(FToken));
  except
    on E: Exception do FRaised := True;
  end;
  FDoneFlag := True;
  RTLEventSetEvent(FDone);
end;

function TCancellableSendWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
var Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while not FDoneFlag and (GetTickCount64 < Deadline) do Sleep(1);
  Result := FDoneFlag;
end;

{ helpers }

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

function ReadWholeBody(const ABody: IHttpBodyStream): string;
var
  Buf: array[0..255] of Byte;
  N: LongInt;
  B: TBytes;
begin
  Result := '';
  while True do
  begin
    N := ABody.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    SetLength(B, N);
    Move(Buf[0], B[0], N);
    Result := Result + StrOf(B);
  end;
end;

{ TClientTest }

end.
