{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Stream-lease state machine tests (plan story S08)
// - covers stream-id allocation under concurrency, HEADERS encode/decode
//   round-trip, request streaming, bodyless responses, RST_STREAM mapped from
//   the body Read, illegal transitions, exactly-once cleanup, a full mocked
//   exchange, and a live TConnection + mock socket integration.
// - non-vacuous by construction: every "did X happen" assertion observes a
//   positive counter (ids collected, unregister count, fail count) rather
//   than the absence of an error.
// - ownership: a lease is registered with the connection as an interface, so
//   the test keeps an IConnectionStream reference (as production's response
//   object would) and releases it via ReleaseLease + the interface going nil,
//   never a raw Free.
unit Http2.Client.Stream.Support;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.ConnectionThread.Test;

type
  /// pulls a fixed list of chunks then returns False (single-use writer)
  TChunkWriter = class(TInterfacedObject, IBodyWriter)
  private
    FChunks: array of TBytes;
    FIndex: Integer;
  public
    constructor Create(const AChunks: array of TBytes);
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

  /// one thread that repeatedly calls Next on a shared allocator
  TAllocWorker = class(TThread)
  private
    FAlloc: TStreamIdAllocator;
    FCount: Integer;
    FIds: TArray<LongWord>;
    FDone: PRTLEvent;
    FDoneFlag: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AAlloc: TStreamIdAllocator; const ACount: Integer);
    destructor Destroy; override;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Ids: TArray<LongWord> read FIds;
  end;

  /// after a delay, hands one frame to a lease the way the connection's reader
  /// thread does: the peer answering while an upload is parked on credit
  TLateFrame = class(TThread)
  private
    FLease: TStreamLease;
    FFrame: TFrame;
    FDelayMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ALease: TStreamLease; const AFrame: TFrame;
      const ADelayMs: Integer);
  end;

type
  /// fails the connection from another thread while ReadBody is blocked in
  /// PopInbound, so the failure arrives via the queue shutdown path.
  TFailingDriver = class(TThread)
  private
    FConn: TConnection;
    FDelayMs: Integer;
  public
    constructor Create(const AConn: TConnection; const ADelayMs: Integer);
    procedure Execute; override;
  end;


  TStreamLeaseTestBase = class(TTestCase)
  protected
    function MakeLease(const AConn: TConnection;
      const ARequest: TStreamRequest; out AAlloc: TStreamIdAllocator;
      out ALease: TStreamLease; out AIL: IConnectionStream): Boolean;
  end;

function BytesOf(const A: string): TBytes;
function StrOf(const A: TBytes): string;
function JoinBytes(const A, B: TBytes): TBytes;
function ResponseHeadersFrame(const ACodec: THpackCodec;
  const AStatus: string; const AExtra: array of THttpHeaderField;
  const AStreamId: LongWord; const AEndStream: Boolean): TFrame;
function ReadAllBody(const ABody: IHttpBodyStream): string;

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

function StrOf(const A: TBytes): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
    Result := Result + Chr(A[I]);
end;

function JoinBytes(const A, B: TBytes): TBytes;
var
  N, I: Integer;
begin
  Result := nil;
  N := Length(A);
  SetLength(Result, N + Length(B));
  for I := 0 to N - 1 do
    Result[I] := A[I];
  for I := 0 to High(B) do
    Result[N + I] := B[I];
end;

/// encode a response header list with a fresh codec and wrap it in a HEADERS
/// frame (used to drive the lease's decoder from the peer side)
function ResponseHeadersFrame(const ACodec: THpackCodec;
  const AStatus: string; const AExtra: array of THttpHeaderField;
  const AStreamId: LongWord; const AEndStream: Boolean): TFrame;
var
  Block: THeaderBlock;
  I, N: Integer;
begin
  N := 1 + Length(AExtra);
  SetLength(Block, N);
  Block[0].Name := ':status';
  Block[0].Value := AStatus;
  Block[0].Sensitive := False;
  for I := 0 to High(AExtra) do
    Block[I + 1] := AExtra[I];
  Result := BuildHeadersFrame(AStreamId, ACodec.Encode(Block), True,
    AEndStream);
end;

function ReadAllBody(const ABody: IHttpBodyStream): string;
var
  Buf: array[0..63] of Byte;
  Chunk: TBytes;
  N, I: LongInt;
begin
  Result := '';
  while True do
  begin
    N := ABody.Read(Buf, SizeOf(Buf));
    if N = 0 then
      Break;
    SetLength(Chunk, N);
    for I := 0 to N - 1 do
      Chunk[I] := Buf[I];
    Result := Result + StrOf(Chunk);
  end;
end;

{ TChunkWriter }

constructor TChunkWriter.Create(const AChunks: array of TBytes);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FChunks, Length(AChunks));
  for I := 0 to High(AChunks) do
    FChunks[I] := AChunks[I];
  FIndex := 0;
end;

function TChunkWriter.NextChunk(out ABuffer: TBytes): Boolean;
begin
  Result := FIndex <= High(FChunks);
  if Result then
  begin
    ABuffer := FChunks[FIndex];
    Inc(FIndex);
  end
  else
    ABuffer := nil;
end;

{ TAllocWorker }

constructor TAllocWorker.Create(const AAlloc: TStreamIdAllocator;
  const ACount: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FAlloc := AAlloc;
  FCount := ACount;
  FDone := RTLEventCreate;
end;

destructor TAllocWorker.Destroy;
begin
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TAllocWorker.Execute;
var
  I: Integer;
begin
  SetLength(FIds, FCount);
  for I := 0 to FCount - 1 do
    FIds[I] := FAlloc.Next;
  FDoneFlag := True;
  RTLEventSetEvent(FDone);
end;

function TAllocWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
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

{ TStreamLeaseTest }

function TStreamLeaseTestBase.MakeLease(const AConn: TConnection;
  const ARequest: TStreamRequest; out AAlloc: TStreamIdAllocator;
  out ALease: TStreamLease; out AIL: IConnectionStream): Boolean;
begin
  AAlloc := TStreamIdAllocator.Create;
  ALease := TStreamLease.Create(AConn, AAlloc, ARequest);
  AIL := ALease;                       // caller-held reference keeps it alive
  // in production a lease sends no DATA before the peer has sent its SETTINGS,
  // so DATA knows the peer's INITIAL_WINDOW_SIZE (RFC 9113 section 6.5.3).
  // The credit gate in AcquireSendCredit withholds DATA until then. Re-apply
  // the connection's current peer settings (a zero delta) so a test that set
  // them beforehand, e.g. a tiny MaxFrameSize, is not clobbered.
  AConn.ApplyPeerSettingsValue(AConn.PeerSettings);
  Result := True;
end;


{ TLateFrame }

constructor TLateFrame.Create(const ALease: TStreamLease; const AFrame: TFrame;
  const ADelayMs: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLease := ALease;
  FFrame := AFrame;
  FDelayMs := ADelayMs;
end;

procedure TLateFrame.Execute;
begin
  Sleep(FDelayMs);
  FLease.OnStreamFrame(FFrame);
end;

constructor TFailingDriver.Create(const AConn: TConnection;
  const ADelayMs: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConn := AConn;
  FDelayMs := ADelayMs;
end;

procedure TFailingDriver.Execute;
begin
  Sleep(FDelayMs);
  FConn.FailWith('socket reset', ecConnectError);
end;


end.
