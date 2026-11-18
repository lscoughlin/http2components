{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, http1, server, producer, body writer, streaming, compression, test, fpcunit
notes:
  - This unit proves that a producer body reaches the peer complete on both protocols.
  - The HTTP/2 tests run the producer on a handler thread and take the octets on the
    test thread. The HTTP/1.1 tests run the producer on the test thread and read the
    octets that the exchange queued, and decode the chunked framing.
  - The compressing producer is checked with the gzip decoder of the server.
  - A raising producer and a cancelled stream are checked at the response. The reset
    of a handler exception is made by the handler pool and is not run here.
---
}
/// Tests of the producer bodies on the HTTP/2 and HTTP/1.1 response paths
unit Http2.Server.BodyProducer.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Common.Body, Http2.Common.Body.Producers, Http2.Common.Hpack,
  Http2.Server.Errors, Http2.Server.Seam, Http2.Server.Stream,
  Http2.Server.StreamAdapters, Http2.Server.Http1.Guard, Http2.Server.Http1.Host,
  Http2.Server.Http1.Exchange, Http2.Server.Encoding,
  Http2.Server.BodyWriterStreaming.Test;

type
  /// a host for the HTTP/1.1 exchange that keeps the octets that it queues
  TRecordHost = class(TCapHost)
  private
    FRecorded: TBytes;
  public
    procedure EnqueueOutput(const AData: TBytes); override;
    /// the octets that the exchange queued, in order
    property Recorded: TBytes read FRecorded;
  end;

  /// the producers of the tests
  // - each method writes its body to the stream that the producer stream gives
  TProducerSource = class
  private
    FCancelSeen: Boolean;
  public
    /// write the test body of cBodyBytes octets in pieces of odd sizes
    procedure WriteOdd(const AOut: TStream);
    /// write the first part of the body, then raise an exception
    procedure WriteThenRaise(const AOut: TStream);
    /// write nothing
    procedure WriteNothing(const AOut: TStream);
    /// write chunks until a write raises EStreamCancelled, then pass the exception on
    procedure WriteUntilCancelled(const AOut: TStream);
    /// true when a write raised EStreamCancelled
    property CancelSeen: Boolean read FCancelSeen;
  end;

  /// tests of the producer bodies and of a request body read through GetStream
  TBodyProducerTest = class(TTestCase)
  private
    FSource: TProducerSource;
    procedure CheckBodyIsPattern(const AData: TBytes; const ACount: Integer);
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    /// an HTTP/2 response from a producer of 100 000 octets in odd sizes arrives complete
    procedure TestH2ProducerBodyArrivesComplete;
    /// a producer that raises: the exception passes to the handler thread, and the response does not end
    procedure TestH2ProducerExceptionPassesAndResponseDoesNotEnd;
    /// a cancelled stream raises EStreamCancelled inside the producer's Write
    procedure TestH2CancelledStreamRaisesInProducer;
    /// an empty producer on HTTP/2 ends the response with no octet
    procedure TestH2EmptyProducerEndsTheResponse;
    /// an HTTP/1.1 response from a producer is chunked, and the last chunk comes once
    procedure TestH1ProducerBodyIsChunkedOnce;
    /// an empty producer on HTTP/1.1 gives only the last chunk
    procedure TestH1EmptyProducerGivesOnlyTheLastChunk;
    /// a producer in TCompressingBodyWriter gives a body that the gzip decoder restores
    procedure TestCompressingProducerRestoresTheBody;
    /// an empty producer in TCompressingBodyWriter gives a valid empty gzip body
    procedure TestEmptyCompressingProducerIsValidGzip;
    /// a request body read through GetStream of TH1Exchange equals ReadAllBody
    procedure TestH1RequestGetStreamEqualsReadAllBody;
  end;

const
  /// the octets of the test body
  cBodyBytes = 100000;
  /// the octets that a raising producer writes before it raises
  cRaiseAfter = 40000;

implementation

const
  /// the outbound limit of the HTTP/2 streams of these tests, in octets
  cOutboundLimit = 16384;
  /// the chunk size of the producer streams of these tests, in octets
  cProducerChunk = 4096;
  /// the longest wait for a handler thread, in milliseconds
  cWaitMs = 10000;
  /// the outbound limit of the HTTP/1.1 exchange when no consumer takes octets
  cRoomyLimit = 4 * 1024 * 1024;

/// the octet of the test body at position AIndex
function PatternByte(const AIndex: Integer): Byte;
begin
  Result := Byte((AIndex * 31) + (AIndex shr 8) + 7);
end;

/// the test body as a new array of AData octets, for the first ACount octets
function PatternBytes(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := PatternByte(I);
end;

/// append the octets of AData to ATarget
procedure AppendOctets(var ATarget: TBytes; const AData: TBytes);
var
  At: Integer;
begin
  At := Length(ATarget);
  SetLength(ATarget, At + Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], ATarget[At], Length(AData));
end;

/// append ACount octets at ABuffer to ATarget
procedure AppendRaw(var ATarget: TBytes; const ABuffer; const ACount: Integer);
var
  At: Integer;
begin
  At := Length(ATarget);
  SetLength(ATarget, At + ACount);
  if ACount > 0 then
    Move(ABuffer, ATarget[At], ACount);
end;

/// take every octet that the stream queues until the handler thread ends
// - the thread is stopped when the wait limit passes, so the test does not hang
function ReceiveAll(const AStream: TServerStream; const ARunner: TWriterThread): TBytes;
var
  Data: TBytes;
  Deadline: QWord;
begin
  Result := nil;
  Deadline := GetTickCount64 + cWaitMs;
  while (not ARunner.Finished) and (GetTickCount64 < Deadline) do
  begin
    while AStream.TakeOutbound(Data, 0) do
      AppendOctets(Result, Data);
    Sleep(1);
  end;
  if not ARunner.Finished then
  begin
    AStream.Cancel(ecCancel);
    ARunner.WaitFor;
  end;
  while AStream.TakeOutbound(Data, 0) do
    AppendOctets(Result, Data);
end;

/// the index of the first octet after the CRLF CRLF that ends the head, or -1
function BodyStartOf(const AData: TBytes): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to Length(AData) - 4 do
    if (AData[I] = 13) and (AData[I + 1] = 10) and (AData[I + 2] = 13) and (AData[I + 3] = 10) then
      Exit(I + 4);
end;

/// decode the chunked body that starts at APos; True when the last chunk ends the data
// - the last chunk must be the final octets, so a second last chunk fails the decode
function DecodeChunked(const AData: TBytes; var APos: Integer; out ABody: TBytes): Boolean;
var
  Size, Next, I, J: Integer;
  Count: Integer;
  Digit: Integer;
begin
  Result := False;
  ABody := nil;
  while True do
  begin
    // the size line ends with CRLF; its octets are hexadecimal digits
    I := APos;
    while (I + 1 < Length(AData)) and not ((AData[I] = 13) and (AData[I + 1] = 10)) do
      Inc(I);
    // a size line has at least one digit
    if (I + 1 >= Length(AData)) or (I = APos) then
      Exit;
    Size := 0;
    for J := APos to I - 1 do
    begin
      case Chr(AData[J]) of
        '0'..'9': Digit := AData[J] - Ord('0');
        'a'..'f': Digit := AData[J] - Ord('a') + 10;
        'A'..'F': Digit := AData[J] - Ord('A') + 10;
      else
        Exit;
      end;
      Size := Size * 16 + Digit;
    end;
    APos := I + 2;
    if Size = 0 then
    begin
      // the last chunk ends with an empty line, and nothing follows it
      if (APos + 1 < Length(AData)) and (AData[APos] = 13) and (AData[APos + 1] = 10) then
      begin
        Inc(APos, 2);
        Result := APos = Length(AData);
      end;
      Exit;
    end;
    Next := APos + Size;
    if Next + 2 > Length(AData) then
      Exit;
    Count := Length(ABody);
    SetLength(ABody, Count + Size);
    Move(AData[APos], ABody[Count], Size);
    if (AData[Next] <> 13) or (AData[Next + 1] <> 10) then
      Exit;
    APos := Next + 2;
  end;
end;

{ TRecordHost }

procedure TRecordHost.EnqueueOutput(const AData: TBytes);
begin
  inherited EnqueueOutput(AData);
  AppendOctets(FRecorded, AData);
end;

{ TProducerSource }

procedure TProducerSource.WriteOdd(const AOut: TStream);
const
  cSizes: array[0..8] of Integer = (1, 7, 4093, 16381, 33, 16384, 5, 20000, 977);
var
  Pos, Step, K, J: Integer;
  Piece: TBytes;
begin
  Pos := 0;
  K := 0;
  while Pos < cBodyBytes do
  begin
    Step := cSizes[K mod 9];
    Inc(K);
    if Pos + Step > cBodyBytes then
      Step := cBodyBytes - Pos;
    SetLength(Piece, Step);
    for J := 0 to Step - 1 do
      Piece[J] := PatternByte(Pos + J);
    AOut.WriteBuffer(Piece[0], Step);
    Inc(Pos, Step);
  end;
end;

procedure TProducerSource.WriteThenRaise(const AOut: TStream);
var
  Piece: TBytes;
begin
  Piece := PatternBytes(cRaiseAfter);
  AOut.WriteBuffer(Piece[0], cRaiseAfter);
  raise EHttpError.Create('the producer failed');
end;

procedure TProducerSource.WriteNothing(const AOut: TStream);
begin
  // the body has no octets
end;

procedure TProducerSource.WriteUntilCancelled(const AOut: TStream);
var
  Piece: TBytes;
  I: Integer;
begin
  Piece := PatternBytes(cProducerChunk);
  try
    for I := 1 to 100000 do
      AOut.WriteBuffer(Piece[0], cProducerChunk);
  except
    on E: EStreamCancelled do
    begin
      FCancelSeen := True;
      raise;
    end;
  end;
end;

{ TBodyProducerTest }

procedure TBodyProducerTest.SetUp;
begin
  inherited SetUp;
  FSource := TProducerSource.Create;
end;

procedure TBodyProducerTest.TearDown;
begin
  FSource.Free;
  inherited TearDown;
end;

procedure TBodyProducerTest.CheckBodyIsPattern(const AData: TBytes; const ACount: Integer);
var
  I, Bad: Integer;
begin
  AssertEquals('the body has every octet', ACount, Length(AData));
  Bad := 0;
  for I := 0 to ACount - 1 do
    if AData[I] <> PatternByte(I) then
      Inc(Bad);
  AssertEquals('every octet has its position in the body', 0, Bad);
end;

procedure TBodyProducerTest.TestH2ProducerBodyArrivesComplete;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Runner: TWriterThread;
  Got: TBytes;
begin
  Stream := TServerStream.Create(1, nil, nil, 65536, cOutboundLimit);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := BodyWriterFromStream(FSource.WriteOdd, cProducerChunk);
  Runner := TWriterThread.Create(Response, Writer);
  try
    Got := ReceiveAll(Stream, Runner);
    AssertTrue('the handler thread finished', Runner.Finished);
    AssertFalse('the producer raised nothing', Runner.Failed);
    CheckBodyIsPattern(Got, cBodyBytes);
  finally
    Runner.Free;
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyProducerTest.TestH2ProducerExceptionPassesAndResponseDoesNotEnd;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Runner: TWriterThread;
  Got: TBytes;
begin
  Stream := TServerStream.Create(1, nil, nil, 65536, cOutboundLimit);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := BodyWriterFromStream(FSource.WriteThenRaise, cProducerChunk);
  Runner := TWriterThread.Create(Response, Writer);
  try
    Got := ReceiveAll(Stream, Runner);
    AssertTrue('the handler thread finished', Runner.Finished);
    AssertTrue('the exception of the producer passed to the handler thread', Runner.Failed);
    AssertFalse('the response did not end normally', (Response as TServerStreamResponse).Ended);
    // the octets that the producer sent before the raise are a prefix of the body
    AssertTrue('a prefix of the body arrived', Length(Got) < cRaiseAfter);
    CheckBodyIsPattern(Got, Length(Got));
  finally
    Runner.Free;
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyProducerTest.TestH2CancelledStreamRaisesInProducer;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Runner: TWriterThread;
begin
  // a small outbound limit and no consumer: the producer waits in Write
  Stream := TServerStream.Create(1, nil, nil, 65536, cProducerChunk);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := BodyWriterFromStream(FSource.WriteUntilCancelled, cProducerChunk);
  Runner := TWriterThread.Create(Response, Writer);
  try
    Sleep(200);
    AssertFalse('the producer waits in Write', Runner.Finished);
    Stream.Cancel(ecCancel);
    Runner.WaitFor;
    AssertTrue('the write of the producer raised EStreamCancelled', FSource.CancelSeen);
    AssertTrue('the exception passed to the handler thread', Runner.Failed);
  finally
    Runner.Free;
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyProducerTest.TestH2EmptyProducerEndsTheResponse;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
begin
  Stream := TServerStream.Create(1, nil, nil, 65536, cOutboundLimit);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := BodyWriterFromStream(FSource.WriteNothing, cProducerChunk);
  try
    Response.SetBodyWriter(Writer);
    Response.Finish;
    AssertTrue('the response ended', (Response as TServerStreamResponse).Ended);
    AssertEquals('the empty body queues no octet', 0, Stream.OutboundCount);
  finally
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyProducerTest.TestH1ProducerBodyIsChunkedOnce;
var
  Host: TRecordHost;
  Link: THostLink;
  LinkRef: IInterface;
  Options: TH1ExchangeOptions;
  Head: TH1Head;
  Response: IServerResponse;
  Writer: IBodyWriter;
  BodyAt: Integer;
  Body: TBytes;
begin
  Host := TRecordHost.Create;
  Link := THostLink.Create(Host);
  LinkRef := Link;
  Options.Scheme := 'http';
  Options.OutboundLimit := cRoomyLimit;
  Options.BodyDeadlineMs := 0;
  Options.BodyTotalMs := 0;
  Options.WriteStallMs := 0;
  Options.BodyBudget := nil;
  FillChar(Head, SizeOf(Head), 0);
  Head.Line.Method := 'GET';
  Head.Line.Minor := 1;
  Head.KeepAlive := True;
  Head.Expect100 := False;
  Response := TH1Exchange.Create(Link, Head, Options, 1);
  Writer := BodyWriterFromStream(FSource.WriteOdd, cProducerChunk);
  try
    // no content length: the body is chunked
    Response.SendHeaders(200, nil, False);
    Response.SetBodyWriter(Writer);
    BodyAt := BodyStartOf(Host.Recorded);
    AssertTrue('the head ends', BodyAt > 0);
    // the decode ends only when the last chunk is the final octet of the output
    AssertTrue('the body is chunked, and the last chunk comes once',
      DecodeChunked(Host.Recorded, BodyAt, Body));
    CheckBodyIsPattern(Body, cBodyBytes);
  finally
    Response := nil;
    LinkRef := nil;
    Host.Free;
  end;
end;

procedure TBodyProducerTest.TestH1EmptyProducerGivesOnlyTheLastChunk;
var
  Host: TRecordHost;
  Link: THostLink;
  LinkRef: IInterface;
  Options: TH1ExchangeOptions;
  Head: TH1Head;
  Response: IServerResponse;
  Writer: IBodyWriter;
  BodyAt: Integer;
  Body: TBytes;
begin
  Host := TRecordHost.Create;
  Link := THostLink.Create(Host);
  LinkRef := Link;
  Options.Scheme := 'http';
  Options.OutboundLimit := cRoomyLimit;
  Options.BodyDeadlineMs := 0;
  Options.BodyTotalMs := 0;
  Options.WriteStallMs := 0;
  Options.BodyBudget := nil;
  FillChar(Head, SizeOf(Head), 0);
  Head.Line.Method := 'GET';
  Head.Line.Minor := 1;
  Head.KeepAlive := True;
  Head.Expect100 := False;
  Response := TH1Exchange.Create(Link, Head, Options, 1);
  Writer := BodyWriterFromStream(FSource.WriteNothing, cProducerChunk);
  try
    Response.SendHeaders(200, nil, False);
    Response.SetBodyWriter(Writer);
    BodyAt := BodyStartOf(Host.Recorded);
    AssertTrue('the head ends', BodyAt > 0);
    // the body is the last chunk alone: 0 CRLF CRLF, and nothing after it
    AssertTrue('the body is one last chunk', DecodeChunked(Host.Recorded, BodyAt, Body));
    AssertEquals('the body has no octet', 0, Length(Body));
  finally
    Response := nil;
    LinkRef := nil;
    Host.Free;
  end;
end;

procedure TBodyProducerTest.TestCompressingProducerRestoresTheBody;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Runner: TWriterThread;
  Got: TBytes;
  Plain: TBytes;
begin
  Stream := TServerStream.Create(1, nil, nil, 65536, cOutboundLimit);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := TCompressingBodyWriter.Create(
    BodyWriterFromStream(FSource.WriteOdd, cProducerChunk), ceGzip);
  Runner := TWriterThread.Create(Response, Writer);
  try
    Got := ReceiveAll(Stream, Runner);
    AssertTrue('the handler thread finished', Runner.Finished);
    AssertFalse('the producer raised nothing', Runner.Failed);
    Plain := GzipDecompress(Got);
    CheckBodyIsPattern(Plain, cBodyBytes);
  finally
    Runner.Free;
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyProducerTest.TestEmptyCompressingProducerIsValidGzip;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Data: TBytes;
  Got: TBytes;
begin
  Stream := TServerStream.Create(1, nil, nil, 65536, cRoomyLimit);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := TCompressingBodyWriter.Create(
    BodyWriterFromStream(FSource.WriteNothing, cProducerChunk), ceGzip);
  try
    Response.SetBodyWriter(Writer);
    Response.Finish;
    Got := nil;
    while Stream.TakeOutbound(Data, 0) do
      AppendOctets(Got, Data);
    AssertTrue('the gzip container is not empty', Length(Got) > 0);
    AssertEquals('the gzip container has no octet of body', 0, Length(GzipDecompress(Got)));
  finally
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyProducerTest.TestH1RequestGetStreamEqualsReadAllBody;
var
  Host: TCapHost;
  Link: THostLink;
  LinkRef: IInterface;
  Options: TH1ExchangeOptions;
  Head: TH1Head;
  ExFirst, ExSecond: TH1Exchange;
  First, Second: IServerRequest;
  Data: TBytes;
  Expected: TBytes;
  Stream: TStream;
  Got: TBytes;
  Chunk: array[0..999] of Byte;
  N: Integer;
  Written: Integer;
begin
  Host := TCapHost.Create;
  Link := THostLink.Create(Host);
  LinkRef := Link;
  Options.Scheme := 'http';
  Options.OutboundLimit := cRoomyLimit;
  Options.BodyDeadlineMs := 0;
  Options.BodyTotalMs := 0;
  Options.WriteStallMs := 0;
  Options.BodyBudget := nil;
  FillChar(Head, SizeOf(Head), 0);
  Head.Line.Method := 'POST';
  Head.Line.Minor := 1;
  Head.KeepAlive := True;
  Head.Expect100 := False;
  Data := PatternBytes(50000);
  ExFirst := TH1Exchange.Create(Link, Head, Options, 1);
  ExSecond := TH1Exchange.Create(Link, Head, Options, 2);
  // the interface references keep the two exchanges alive
  First := ExFirst;
  Second := ExSecond;
  try
    // two exchanges hold the same body; each one is read once
    Written := 0;
    while Written < Length(Data) do
    begin
      N := Length(Data) - Written;
      if N > 16384 then
        N := 16384;
      ExFirst.AppendBody(Data[Written], N);
      ExSecond.AppendBody(Data[Written], N);
      Inc(Written, N);
    end;
    ExFirst.EndBody;
    ExSecond.EndBody;
    Expected := ReadAllBody(First);
    AssertEquals('ReadAllBody reads the whole body', Length(Data), Length(Expected));
    Stream := Second.GetStream;
    try
      Got := nil;
      repeat
        N := Stream.Read(Chunk[0], SizeOf(Chunk));
        if N > 0 then
          AppendRaw(Got, Chunk[0], N);
      until N <= 0;
    finally
      Stream.Free;
    end;
    AssertEquals('GetStream gives the same count', Length(Expected), Length(Got));
    AssertTrue('GetStream gives the same octets',
      CompareMem(@Expected[0], @Got[0], Length(Got)));
  finally
    First := nil;
    Second := nil;
    LinkRef := nil;
    Host.Free;
  end;
end;

initialization
  RegisterTest(TBodyProducerTest);

end.
