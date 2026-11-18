{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - HTTP/1.1 streaming upload tests (plan S08); the scripted socket is in Http2.Client.Http1.Test
---
}
/// HTTP/1.1 streaming upload tests (plan S08)
// - a BodyWriter request is written chunk by chunk (THttp1Connection.WriteChunkedBody)
// - NOTHING here opens a real socket: TSocketScript and TDiscardSocket are in-memory
unit Http2.Client.Http1.Upload.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Common.Body, Http2.Common.Body.Producers,
  Http2.Client.Tls, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1, Http2.Client.Http1.Test;

type
  /// a writer with one scripted chunk and one More flag for each call
  // - when Probe is set, Seen[i] holds what the socket had received before call i
  // - when FailAt >= 0, the call of that index (0-based) raises
  TSequenceBodyWriter = class(TInterfacedObject, IBodyWriter)
  private
    FChunks: TArray<TBytes>;
    FMores: TArray<Boolean>;
    FIndex: Integer;
  public
    Probe: TSocketScript;
    FailAt: Integer;
    Seen: TArray<string>;
    constructor Create(const AChunks: array of string;
      const AMores: array of Boolean);
    function NextChunk(const ABuffer: TStream): Boolean;
  end;

  /// a socket that takes every octet and keeps only the count (no reads)
  TDiscardSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FCount: Int64;
  public
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
    property Count: Int64 read FCount;
  end;

  /// a writer of cLargeChunkCount chunks of cLargeChunkSize octets; it samples
  /// the heap at every 50th call and keeps the peak
  TLargeBodyWriter = class(TInterfacedObject, IBodyWriter)
  private
    FBlock: Pointer;
    FCalls: Integer;
  public
    StartUsed: Int64;
    PeakUsed: Int64;
    constructor Create;
    destructor Destroy; override;
    function NextChunk(const ABuffer: TStream): Boolean;
  end;

  /// an exchange observer that keeps the RequestWritten count
  TBytesOutExchange = class(TInterfacedObject, IExchangeObserver)
  public
    Written: Int64;
    procedure RouteChosen(const AProtocol: TNegotiatedProtocol;
      const AReused: Boolean);
    procedure RequestWritten(const ABytesOut: Int64);
    procedure ExchangeEnded(const AEnd: TExchangeEnd);
  end;

  /// the exception that a producer raises in the upload tests
  EUploadProducerFailure = class(Exception);

  /// a producer that writes its parts in order, with an optional failure and cancel
  // - FailAfter: the index of the part after which Write raises (-1: never)
  // - CancelAfter: the index of the part after which Token is cancelled (-1: never)
  // - the object must live until the call that uses its method pointer returns
  TPartsProducer = class
  private
    FParts: TArray<string>;
    FFailAfter: Integer;
    FCancelAfter: Integer;
    FToken: TCancellationToken;
  public
    constructor Create(const AParts: array of string);
    procedure Write(const AOut: TStream);
    property FailAfter: Integer read FFailAfter write FFailAfter;
    property CancelAfter: Integer read FCancelAfter write FCancelAfter;
    property Token: TCancellationToken read FToken write FToken;
  end;

  THttp1UploadTest = class(TTestCase)
  published
    procedure TestWriterBodyGoesOutChunkByChunk;
    procedure TestWriterBodyWireIsChunkedCoding;
    procedure TestLastChunkWithFalseIsSent;
    procedure TestZeroLengthChunkIsSkipped;
    procedure TestEmptyWriterSendsOnlyTheLastChunk;
    procedure TestWriterRaisingClosesTheConnection;
    procedure TestLargeWriterBodyKeepsMemoryBounded;
    procedure TestWriterBodyCountsFramingInBytesOut;
    /// a producer's odd writes go out as chunks of AChunkBytes, the last chunk once
    procedure TestProducerOddPartsGoOutAsChunks;
    /// a body that ends on a chunk boundary sends the last chunk once, no empty chunk
    procedure TestProducerBoundaryEndsOnce;
    /// a producer that writes nothing sends only the last-chunk marker
    procedure TestProducerEmptyBodySendsOnlyTheMarker;
    /// a producer that raises closes the connection for reuse, and the call raises its exception
    procedure TestProducerRaisingClosesTheConnection;
    /// a cancelled call raises EHttpStreamError in the producer's Write and closes the connection
    procedure TestProducerCancelledCallRaisesInWrite;
    /// the bytes out of a producer body equal the bytes out of the same body pulled
    procedure TestProducerCountsFramingLikeThePullPath;
  end;

implementation

const
  cLargeChunkCount = 300;
  cLargeChunkSize = 1024 * 1024;
  cHeapBudget = 16 * 1024 * 1024;

function UploadTextBytes(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

/// the octets that follow the blank line of the head in AWritten
function AfterHead(const AWritten: string): string;
var
  P: Integer;
begin
  P := Pos(#13#10#13#10, AWritten);
  if P = 0 then
    Exit('');
  Result := Copy(AWritten, P + 4, Length(AWritten));
end;

function NewGetRequest(const APath: string): TStreamRequest;
begin
  Result := TStreamRequest.Create('GET', 'example.com').WithPath(APath);
end;

{ TSequenceBodyWriter }

constructor TSequenceBodyWriter.Create(const AChunks: array of string;
  const AMores: array of Boolean);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FChunks, Length(AChunks));
  for I := 0 to High(AChunks) do
    FChunks[I] := UploadTextBytes(AChunks[I]);
  SetLength(FMores, Length(AMores));
  for I := 0 to High(AMores) do
    FMores[I] := AMores[I];
  FIndex := 0;
  FailAt := -1;
  Probe := nil;
end;

function TSequenceBodyWriter.NextChunk(const ABuffer: TStream): Boolean;
begin
  if Probe <> nil then
  begin
    SetLength(Seen, FIndex + 1);
    Seen[FIndex] := Probe.WrittenText;
  end;
  if FIndex = FailAt then
    raise EHttpProtocolError.Create('scripted writer failure', ecProtocolError);
  if FIndex > High(FChunks) then
    Exit(False);
  ChunkAppend(ABuffer, FChunks[FIndex]);
  Result := FMores[FIndex];
  Inc(FIndex);
end;

{ TDiscardSocket }

function TDiscardSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := 0;   // the script is empty: EOF
end;

function TDiscardSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Inc(FCount, ACount);
  Result := ACount;
end;

procedure TDiscardSocket.Close;
begin
end;

function TDiscardSocket.GetConnected: Boolean;
begin
  Result := True;
end;

function TDiscardSocket.GetConnectTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TDiscardSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
end;

function TDiscardSocket.GetReadTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TDiscardSocket.SetReadTimeoutMs(const AValue: Integer);
begin
end;

function TDiscardSocket.GetWriteTimeoutMs: Integer;
begin
  Result := 30000;
end;

procedure TDiscardSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
end;

{ TLargeBodyWriter }

constructor TLargeBodyWriter.Create;
begin
  inherited Create;
  GetMem(FBlock, cLargeChunkSize);
  FillChar(FBlock^, cLargeChunkSize, Ord('x'));
  FCalls := 0;
end;

destructor TLargeBodyWriter.Destroy;
begin
  FreeMem(FBlock);
  inherited Destroy;
end;

function TLargeBodyWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  Used: Int64;
begin
  if FCalls mod 50 = 0 then
  begin
    Used := Int64(GetFPCHeapStatus.CurrHeapUsed);
    if Used > PeakUsed then
      PeakUsed := Used;
  end;
  Inc(FCalls);
  ABuffer.WriteBuffer(FBlock^, cLargeChunkSize);
  Result := FCalls < cLargeChunkCount;
end;

{ TBytesOutExchange }

procedure TBytesOutExchange.RouteChosen(const AProtocol: TNegotiatedProtocol;
  const AReused: Boolean);
begin
end;

procedure TBytesOutExchange.RequestWritten(const ABytesOut: Int64);
begin
  Written := ABytesOut;
end;

procedure TBytesOutExchange.ExchangeEnded(const AEnd: TExchangeEnd);
begin
end;

{ THttp1UploadTest }

procedure THttp1UploadTest.TestWriterBodyGoesOutChunkByChunk;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Writer: TSequenceBodyWriter;
  Keep: IBodyWriter;
  Req: TStreamRequest;
  Resp: IHttpResponse;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Writer := TSequenceBodyWriter.Create(['aa', 'bbb', 'c'], [True, True, False]);
  Writer.Probe := Sock;
  Keep := Writer;
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    Resp := Conn.Send(Req);
    AssertEquals('response status', 200, Resp.StatusCode);
    AssertEquals('three calls', 3, Length(Writer.Seen));
    AssertTrue('the head was out before the first call',
      Pos('Transfer-Encoding: chunked', Writer.Seen[0]) > 0);
    AssertTrue('chunk aa was out before the second call',
      Pos('2'#13#10'aa'#13#10, Writer.Seen[1]) > 0);
    AssertTrue('chunk bbb was out before the third call',
      Pos('3'#13#10'bbb'#13#10, Writer.Seen[2]) > 0);
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestWriterBodyWireIsChunkedCoding;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Keep := TScriptedBodyWriter.Create(['aa', 'bbb', 'c']);
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    Conn.Send(Req);
    AssertEquals('chunked coding after the head',
      '2'#13#10'aa'#13#10'3'#13#10'bbb'#13#10'1'#13#10'c'#13#10'0'#13#10#13#10,
      AfterHead(Sock.WrittenText));
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestLastChunkWithFalseIsSent;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Keep := TSequenceBodyWriter.Create(['aa', 'bbb'], [True, False]);
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    Conn.Send(Req);
    AssertEquals('the octets of the False call are the last chunk',
      '2'#13#10'aa'#13#10'3'#13#10'bbb'#13#10'0'#13#10#13#10,
      AfterHead(Sock.WrittenText));
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestZeroLengthChunkIsSkipped;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Keep := TSequenceBodyWriter.Create(['aa', '', 'bbb'], [True, True, False]);
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    Conn.Send(Req);
    AssertEquals('the empty chunk leaves no 0 size line in the middle',
      '2'#13#10'aa'#13#10'3'#13#10'bbb'#13#10'0'#13#10#13#10,
      AfterHead(Sock.WrittenText));
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestEmptyWriterSendsOnlyTheLastChunk;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Keep := TSequenceBodyWriter.Create([''], [False]);
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    Conn.Send(Req);
    AssertEquals('only the last chunk follows the head',
      '0'#13#10#13#10, AfterHead(Sock.WrittenText));
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestWriterRaisingClosesTheConnection;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Writer: TSequenceBodyWriter;
  Keep: IBodyWriter;
  Req: TStreamRequest;
  Raised: Boolean;
  Msg: string;
begin
  // the socket close is proven at pool level (THttp1PooledConnection.Acquire);
  // here the connection must refuse reuse
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Writer := TSequenceBodyWriter.Create(['aa', 'bbb', 'c'], [True, True, False]);
  Writer.FailAt := 1;   // the second call raises
  Keep := Writer;
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    Raised := False;
    Msg := '';
    try
      Conn.Send(Req);
    except
      on E: EHttpProtocolError do
      begin
        Raised := True;
        Msg := E.Message;
      end;
    end;
    AssertTrue('the writer exception reaches Send', Raised);
    AssertEquals('the writer exception keeps its message',
      'scripted writer failure', Msg);
    AssertTrue('chunk aa went out before the failure',
      Pos('2'#13#10'aa'#13#10, Sock.WrittenText) > 0);
    AssertFalse('the connection is not reusable after the failure',
      Conn.Reusable);
    Raised := False;
    try
      Conn.Send(NewGetRequest('/again'));
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('a second request on the same connection is refused', Raised);
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestLargeWriterBodyKeepsMemoryBounded;
var
  Sock: TDiscardSocket;
  Conn: THttp1Connection;
  Large: TLargeBodyWriter;
  Keep: IBodyWriter;
  Req: TStreamRequest;
  Growth: Int64;
begin
  Sock := TDiscardSocket.Create;
  Large := TLargeBodyWriter.Create;
  Keep := Large;
  Large.StartUsed := Int64(GetFPCHeapStatus.CurrHeapUsed);
  Large.PeakUsed := Large.StartUsed;
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/big')
    .WithBodyWriter(Keep);
  Conn := THttp1Connection.Create(Sock);
  try
    // the socket never answers: BeginResponse returns False after the body
    Conn.BeginResponse(Req);
    AssertTrue('every chunk went out',
      Sock.Count >= Int64(cLargeChunkCount) * (cLargeChunkSize + 2));
    Growth := Large.PeakUsed - Large.StartUsed;
    AssertTrue('the heap grows by less than 16 MiB, grew by ' + IntToStr(Growth),
      Growth < cHeapBudget);
  finally
    Conn.Free;
  end;
end;

procedure THttp1UploadTest.TestWriterBodyCountsFramingInBytesOut;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Keep: IBodyWriter;
  Obs: TBytesOutExchange;
  ObsRef: IExchangeObserver;
  Req: TStreamRequest;
begin
  // FSentBodyBytes: the size lines, the data, the CRLFs and the last chunk
  // ('2'CRLF'aa'CRLF = 7, '3'CRLF'bbb'CRLF = 8, '0'CRLF CRLF = 5)
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Keep := TSequenceBodyWriter.Create(['aa', 'bbb'], [True, False]);
  Obs := TBytesOutExchange.Create;
  ObsRef := Obs;
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep).WithExchange(ObsRef);
  Conn := THttp1Connection.Create(Sock);
  try
    Conn.Send(Req);
    AssertEquals('the framing counts, the head does not', 20, Obs.Written);
  finally
    Conn.Free;
  end;
end;

{ TPartsProducer }

constructor TPartsProducer.Create(const AParts: array of string);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FParts, Length(AParts));
  for I := 0 to High(AParts) do
    FParts[I] := AParts[I];
  FFailAfter := -1;
  FCancelAfter := -1;
  FToken := nil;
end;

procedure TPartsProducer.Write(const AOut: TStream);
var
  I: Integer;
  Bytes: TBytes;
begin
  for I := 0 to High(FParts) do
  begin
    Bytes := UploadTextBytes(FParts[I]);
    if Length(Bytes) > 0 then
      AOut.WriteBuffer(Bytes[0], Length(Bytes));
    if I = FFailAfter then
      raise EUploadProducerFailure.Create('scripted producer failure');
    if (I = FCancelAfter) and (FToken <> nil) then
      FToken.Cancel;
  end;
end;

procedure THttp1UploadTest.TestProducerOddPartsGoOutAsChunks;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Prod: TPartsProducer;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Prod := TPartsProducer.Create(['ab', 'cdefg', 'h']);
  try
    Keep := BodyWriterFromStream(Prod.Write, 3);
    Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
      .WithBodyWriter(Keep);
    Conn := THttp1Connection.Create(Sock);
    try
      Conn.Send(Req);
      AssertEquals('chunks of 3 octets, the last chunk once, then the marker',
        '3'#13#10'abc'#13#10'3'#13#10'def'#13#10'2'#13#10'gh'#13#10'0'#13#10#13#10,
        AfterHead(Sock.WrittenText));
    finally
      Conn.Free;
    end;
  finally
    Prod.Free;
  end;
end;

procedure THttp1UploadTest.TestProducerBoundaryEndsOnce;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Prod: TPartsProducer;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  // the body ends on a chunk boundary: the last chunk is sent once, with no empty chunk
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Prod := TPartsProducer.Create(['aaa', 'bbb']);
  try
    Keep := BodyWriterFromStream(Prod.Write, 3);
    Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
      .WithBodyWriter(Keep);
    Conn := THttp1Connection.Create(Sock);
    try
      Conn.Send(Req);
      AssertEquals('two chunks and the marker',
        '3'#13#10'aaa'#13#10'3'#13#10'bbb'#13#10'0'#13#10#13#10,
        AfterHead(Sock.WrittenText));
    finally
      Conn.Free;
    end;
  finally
    Prod.Free;
  end;
end;

procedure THttp1UploadTest.TestProducerEmptyBodySendsOnlyTheMarker;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Prod: TPartsProducer;
  Keep: IBodyWriter;
  Req: TStreamRequest;
begin
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Prod := TPartsProducer.Create(['']);
  try
    Keep := BodyWriterFromStream(Prod.Write, 3);
    Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
      .WithBodyWriter(Keep);
    Conn := THttp1Connection.Create(Sock);
    try
      Conn.Send(Req);
      AssertEquals('only the last-chunk marker follows the head',
        '0'#13#10#13#10, AfterHead(Sock.WrittenText));
    finally
      Conn.Free;
    end;
  finally
    Prod.Free;
  end;
end;

procedure THttp1UploadTest.TestProducerRaisingClosesTheConnection;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Prod: TPartsProducer;
  Keep: IBodyWriter;
  Req: TStreamRequest;
  Raised: Boolean;
  Msg: string;
begin
  // the producer fails after 'bbb' is written: 'aaa' is out, no last chunk follows
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Prod := TPartsProducer.Create(['aaa', 'bbb']);
  Prod.FailAfter := 1;
  try
    Keep := BodyWriterFromStream(Prod.Write, 3);
    Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
      .WithBodyWriter(Keep);
    Conn := THttp1Connection.Create(Sock);
    try
      Raised := False;
      Msg := '';
      try
        Conn.Send(Req);
      except
        on E: EUploadProducerFailure do
        begin
          Raised := True;
          Msg := E.Message;
        end;
      end;
      AssertTrue('the producer exception reaches Send', Raised);
      AssertEquals('the exception keeps its message', 'scripted producer failure', Msg);
      AssertEquals('only the sent chunk is on the wire',
        '3'#13#10'aaa'#13#10, AfterHead(Sock.WrittenText));
      AssertFalse('the connection is not reusable after the failure', Conn.Reusable);
      Raised := False;
      try
        Conn.Send(NewGetRequest('/again'));
      except
        on E: EHttpProtocolError do
          Raised := True;
      end;
      AssertTrue('a second request on the same connection is refused', Raised);
    finally
      Conn.Free;
    end;
  finally
    Prod.Free;
  end;
end;

procedure THttp1UploadTest.TestProducerCancelledCallRaisesInWrite;
var
  Sock: TSocketScript;
  Conn: THttp1Connection;
  Prod: TPartsProducer;
  Keep: IBodyWriter;
  Req: TStreamRequest;
  TokenIntf: ICancellationToken;
  Raised: Boolean;
  Code: THttp2ErrorCode;
begin
  // the token is cancelled after 'aaa' is written: the write of 'bbb' sends 'aaa' and raises
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  TokenIntf := TCancellationToken.Create;
  Prod := TPartsProducer.Create(['aaa', 'bbb', 'ccc']);
  Prod.Token := TokenIntf as TCancellationToken;
  Prod.CancelAfter := 0;
  try
    Keep := BodyWriterFromStream(Prod.Write, 3);
    Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
      .WithBodyWriter(Keep).WithCancelToken(TokenIntf);
    Conn := THttp1Connection.Create(Sock);
    try
      Raised := False;
      Code := ecInternalError;
      try
        Conn.Send(Req);
      except
        on E: EHttpStreamError do
        begin
          Raised := True;
          Code := E.ErrorCode;
        end;
      end;
      AssertTrue('the cancelled call raises EHttpStreamError', Raised);
      AssertTrue('the error is the cancel error', Code = ecCancel);
      AssertEquals('the pending chunk did not go out', '', AfterHead(Sock.WrittenText));
      AssertFalse('the connection is not reusable after the cancel', Conn.Reusable);
    finally
      Conn.Free;
    end;
  finally
    Prod.Free;
  end;
end;

procedure THttp1UploadTest.TestProducerCountsFramingLikeThePullPath;
var
  Sock, Sock2: TSocketScript;
  Conn, Conn2: THttp1Connection;
  Prod: TPartsProducer;
  Keep, Keep2: IBodyWriter;
  Obs, Obs2: TBytesOutExchange;
  ObsRef, ObsRef2: IExchangeObserver;
  Req, Req2: TStreamRequest;
begin
  // the chunks of the producer: '3'CRLF'abc'CRLF = 8, '3'CRLF'def'CRLF = 8,
  // '2'CRLF'gh'CRLF = 7 and '0'CRLF CRLF = 5, which makes 28 octets after the head
  Sock := TSocketScript.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Prod := TPartsProducer.Create(['ab', 'cdefg', 'h']);
  Keep := BodyWriterFromStream(Prod.Write, 3);
  Obs := TBytesOutExchange.Create;
  ObsRef := Obs;
  Req := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep).WithExchange(ObsRef);
  Conn := THttp1Connection.Create(Sock);
  try
    Conn.Send(Req);
    AssertEquals('the framing counts, the head does not', 28, Obs.Written);
  finally
    Conn.Free;
  end;
  // the pull path gives the same count for the same chunks
  Sock2 := TSocketScript.Create;
  Sock2.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10);
  Keep2 := TSequenceBodyWriter.Create(['abc', 'def', 'gh'], [True, True, False]);
  Obs2 := TBytesOutExchange.Create;
  ObsRef2 := Obs2;
  Req2 := TStreamRequest.Create('POST', 'example.com').WithPath('/up')
    .WithBodyWriter(Keep2).WithExchange(ObsRef2);
  Conn2 := THttp1Connection.Create(Sock2);
  try
    Conn2.Send(Req2);
    AssertEquals('the pull path counts the same octets', Obs2.Written, Obs.Written);
  finally
    Conn2.Free;
    Prod.Free;
  end;
end;

initialization
  RegisterTest(THttp1UploadTest);
end.
