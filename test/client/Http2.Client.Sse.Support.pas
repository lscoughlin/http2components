{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this provides scripted event-stream test inputs
---
}
unit Http2.Client.Sse.Support;



{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.WebSocket,
  Http2.Client.Sse, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames, Http2.Client.RequestObserver, Http2.Common.Body;

type
  TDripBodyStream = class(TBodyReaderBase, IHttpBodyStream)
  private
    FData: TBytes;
    FPos: Integer;
    FChunk: Integer;
  public
    constructor Create(const AData: TBytes; const AChunk: Integer = 1);
    function Read(var ABuffer; const ACount: LongInt): LongInt; override;
    function Eof: Boolean;
  end;

  /// the least IHttpResponse that can carry headers and a body

  TStubResponse = class(TInterfacedObject, IHttpResponse)
  private
    FStatus: LongInt;
    FHeaders: IHttpHeaders;
    FBody: IHttpBodyStream;
  public
    constructor Create(const AStatus: LongInt; const AHeaders: IHttpHeaders;
      const ABody: IHttpBodyStream);
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
  end;

  /// an IHttpClient that answers from a script of canned event streams, so the
  /// reconnect loop can be tested without a transport
  // - deliberately NOT reference counted (_AddRef/_Release return -1): the
  /// test owns the instance and frees it with Free, while other interfaces
  /// just hold a non-owning reference. Without this the final Free plus the
  /// interface's release double-free the object (EBusError).

  TScriptedClient = class(TInterfacedObject, IHttpClient)
  private
    FBodies: TList<string>;
    FRequests: TList<THttpRequest>;
    FIndex: Integer;
    FRefuseConnection: Boolean;
    FRejectResponse: Boolean;
    FFailNext: Integer;
  public
    function QueryInterface(constref AID: TGUID; out AObj): LongInt; cdecl;
    function _AddRef: LongInt; cdecl;
    function _Release: LongInt; cdecl;
    constructor Create;
    destructor Destroy; override;
    procedure AddBody(const AText: string);
    /// every Send raises EHttpConnectionClosed (a persistent transport fault)
    procedure RefuseConnection;
    /// the next ACount Sends raise EHttpConnectionClosed, then it recovers
    procedure FailNextRequests(const ACount: Integer);
    /// every Send raises EHttpProtocolError (the response is not an event
    /// stream; reconnecting cannot fix it)
    procedure RejectResponse;
    function Send(const ARequest: THttpRequest): IHttpResponse; overload;
    function Send(const ARequest: IWebSocketRequest): IWebSocket; overload;
    procedure Close;
    function RequestCount: Integer;
    function RequestAt(const AIndex: Integer): THttpRequest;
  end;

  /// one thread blocked in TStreamLease.ReadBody, so a test can assert that
  /// the read is still parked and then unblock it

  TSseReadDriver = class(TThread)
  private
    FLease: TStreamLease;
    FBytes: Integer;
    FRaised: Boolean;
    FError: string;
    FFinished: Boolean;
    FDone: PRTLEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ALease: TStreamLease);
    destructor Destroy; override;
    /// True when the read finished within ATimeoutMs
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Bytes: Integer read FBytes;
    property Raised: Boolean read FRaised;
    property Error: string read FError;
  end;

  /// drives a cancel from another thread while ReadBody is blocked

  TSseCancelDriver = class(TThread)
  private
    FToken: TCancellationToken;
    FDelayMs: Integer;
  public
    constructor Create(const AToken: TCancellationToken;
      const ADelayMs: Integer);
    procedure Execute; override;
  end;

  TOutcomeObserver = class(TBaseRequestObserver)
  private
    FEnded: PRTLEvent;
  public
    Kind: TAttemptKind;
    StreamId: Int64;
    Outcome: THttpOutcome;
    constructor Create;
    destructor Destroy; override;
    function OnAttemptStart(const A: THttpAttempt): IInterface; override;
    procedure OnAttemptEnd(const AToken: IInterface;
      const O: THttpOutcome); override;
    /// bounded wait for the end
    function WaitForEnd(const ATimeoutMs: Integer): Boolean;
  end;

  /// the opt-in live case: skipped unless SSE_TEST_URL points at a
  /// tools/validate/sse_server.py instance (the same gate idiom the other
  /// live tests use). It proves the whole stack end to end: incremental
  /// delivery, reconnect, last-event-id resume, and retry: adoption; and that
  /// the per-event timing measured at the wire matches a server that emits at
  /// a known interval.

function FastBody(const AText: string): string;
function BytesOf(const A: string): TBytes;
function RawBytes(const A: array of Byte): TBytes;
function U32BE(const AData: TBytes; const AOffset: Integer): LongWord;
function NewHeaders(const APairs: array of string): IHttpHeaders;
function ResponseHeadersFor(const ACodec: THpackCodec;
  const AStatus: string; const AStreamId: LongWord;
  const AEndStream: Boolean): TFrame;
function DataFrameOf(const AStreamId: LongWord; const AText: string;
  const AEndStream: Boolean): TFrame;

implementation

function BytesOf(const A: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 1 to Length(A) do
    Result[I - 1] := Ord(A[I]);
end;

function RawBytes(const A: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

function U32BE(const AData: TBytes; const AOffset: Integer): LongWord;
begin
  // ReadUInt32BE lives in the Http2.Common.Frames implementation section, so decode
  // the 4-byte big-endian payload here
  Result := (LongWord(AData[AOffset]) shl 24) or
            (LongWord(AData[AOffset + 1]) shl 16) or
            (LongWord(AData[AOffset + 2]) shl 8) or
            LongWord(AData[AOffset + 3]);
end;

function NewHeaders(const APairs: array of string): IHttpHeaders;
var
  I: Integer;
begin
  Result := NewHttpHeaders;
  I := 0;
  while I + 1 <= High(APairs) do
  begin
    Result.Add(APairs[I], APairs[I + 1]);
    Inc(I, 2);
  end;
end;

function ResponseHeadersFor(const ACodec: THpackCodec;
  const AStatus: string; const AStreamId: LongWord;
  const AEndStream: Boolean): TFrame;
var
  Block: THeaderBlock;
begin
  SetLength(Block, 1);
  Block[0].Name := ':status';
  Block[0].Value := AStatus;
  Block[0].Sensitive := False;
  Result := BuildHeadersFrame(AStreamId, ACodec.Encode(Block), True,
    AEndStream);
end;

function DataFrameOf(const AStreamId: LongWord; const AText: string;
  const AEndStream: Boolean): TFrame;
begin
  Result := BuildDataFrame(AStreamId, BytesOf(AText), AEndStream);
end;

{ TDripBodyStream }

constructor TDripBodyStream.Create(const AData: TBytes;
  const AChunk: Integer);
begin
  inherited Create;
  FData := Copy(AData, 0, Length(AData));
  FPos := 0;
  FChunk := AChunk;
end;

function TDripBodyStream.Read(var ABuffer; const ACount: LongInt): LongInt;
var
  P: PByte;
  Left, Take: Integer;
begin
  P := @ABuffer;
  Left := Length(FData) - FPos;
  if Left <= 0 then
    Exit(0);
  Take := FChunk;
  if Take > ACount then
    Take := ACount;
  if Take > Left then
    Take := Left;
  Move(FData[FPos], P[0], Take);
  Inc(FPos, Take);
  Result := Take;
end;

function TDripBodyStream.Eof: Boolean;
begin
  Result := FPos >= Length(FData);
end;

{ TStubResponse }

constructor TStubResponse.Create(const AStatus: LongInt;
  const AHeaders: IHttpHeaders; const ABody: IHttpBodyStream);
begin
  inherited Create;
  FStatus := AStatus;
  if AHeaders <> nil then
    FHeaders := AHeaders
  else
    FHeaders := NewHttpHeaders;
  FBody := ABody;
end;

function TStubResponse.GetStatusCode: LongInt;
begin
  Result := FStatus;
end;

function TStubResponse.GetHeaders: IHttpHeaders;
begin
  Result := FHeaders;
end;

function TStubResponse.GetBody: IHttpBodyStream;
begin
  Result := FBody;
end;

{ TScriptedClient }

constructor TScriptedClient.Create;
begin
  inherited Create;
  FBodies := TList<string>.Create;
  FRequests := TList<THttpRequest>.Create;
  FIndex := 0;
end;

function TScriptedClient.QueryInterface(constref AID: TGUID;
  out AObj): LongInt;
begin
  if GetInterface(AID, AObj) then
    Result := 0
  else
    Result := LongInt($80004002);        // E_NOINTERFACE
end;

function TScriptedClient._AddRef: LongInt;
begin
  Result := -1;                          // the test owns the instance
end;

function TScriptedClient._Release: LongInt;
begin
  Result := -1;                          // the test owns the instance
end;

destructor TScriptedClient.Destroy;
begin
  FBodies.Free;
  FRequests.Free;
  inherited Destroy;
end;

procedure TScriptedClient.AddBody(const AText: string);
begin
  FBodies.Add(AText);
end;

procedure TScriptedClient.RefuseConnection;
begin
  FRefuseConnection := True;
end;

procedure TScriptedClient.FailNextRequests(const ACount: Integer);
begin
  FFailNext := ACount;
end;

procedure TScriptedClient.RejectResponse;
begin
  FRejectResponse := True;
end;

function TScriptedClient.Send(const ARequest: IWebSocketRequest): IWebSocket;
begin
  raise EHttpWebSocketError.Create('a scripted client opens no WebSocket');
end;

function TScriptedClient.Send(const ARequest: THttpRequest): IHttpResponse;
var
  Body: string;
begin
  FRequests.Add(ARequest);
  if FFailNext > 0 then
  begin
    Dec(FFailNext);
    raise EHttpConnectionClosed.Create('scripted transient transport failure');
  end;
  if FRefuseConnection then
    raise EHttpConnectionClosed.Create('scripted transport failure');
  if FRejectResponse then
    raise EHttpProtocolError.Create('scripted: not an event stream',
      ecProtocolError);
  if (FIndex < 0) or (FIndex >= FBodies.Count) then
    Body := ''
  else
    Body := FBodies[FIndex];
  Inc(FIndex);
  Result := TStubResponse.Create(200,
    NewHeaders([HeaderContentType, cSseContentType]),
    TDripBodyStream.Create(BytesOf(Body), 4096));
end;

procedure TScriptedClient.Close;
begin
  // nothing to release
end;

function TScriptedClient.RequestCount: Integer;
begin
  Result := FRequests.Count;
end;

function TScriptedClient.RequestAt(const AIndex: Integer): THttpRequest;
begin
  Result := FRequests[AIndex];
end;

{ TSseReadDriver }

constructor TSseReadDriver.Create(const ALease: TStreamLease);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLease := ALease;
  FDone := RTLEventCreate;
end;

destructor TSseReadDriver.Destroy;
begin
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TSseReadDriver.Execute;
var
  Buf: array[0..15] of Byte;
begin
  FBytes := 0;
  FRaised := False;
  try
    try
      FBytes := FLease.ReadBody(Buf, SizeOf(Buf));
    except
      on E: Exception do
      begin
        FRaised := True;
        FError := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    FFinished := True;
    RTLEventSetEvent(FDone);
  end;
end;

function TSseReadDriver.WaitDone(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while not FFinished do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FDone, Remaining);
  end;
  Result := True;
end;

{ TSseCancelDriver }

constructor TSseCancelDriver.Create(const AToken: TCancellationToken;
  const ADelayMs: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FToken := AToken;
  FDelayMs := ADelayMs;
end;

procedure TSseCancelDriver.Execute;
begin
  Sleep(FDelayMs);
  FToken.Cancel;
end;

{ TSseParserTest }

function FastBody(const AText: string): string;
begin
  Result := 'retry: 1' + #10 + AText;
end;

constructor TOutcomeObserver.Create;
begin
  inherited Create;
  FEnded := RTLEventCreate;
end;

destructor TOutcomeObserver.Destroy;
begin
  RTLEventDestroy(FEnded);
  inherited Destroy;
end;

function TOutcomeObserver.OnAttemptStart(const A: THttpAttempt): IInterface;
begin
  Kind := A.Kind;
  StreamId := A.StreamId;
  Result := nil;
end;

procedure TOutcomeObserver.OnAttemptEnd(const AToken: IInterface;
  const O: THttpOutcome);
begin
  Outcome := O;
  Outcome.Error := nil;
  RTLEventSetEvent(FEnded);
end;

function TOutcomeObserver.WaitForEnd(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FEnded, ATimeoutMs);
  Result := Outcome.EndUs > 0;
end;

{ TSseLiveTest }
end.
