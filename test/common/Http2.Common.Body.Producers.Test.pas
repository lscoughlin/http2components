{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, body_producer, stream, text, test
notes:
  - This test checks the producer stream, the producer body and the buffered fallback.
  - The tests use a recording sink that keeps each chunk and its ALast flag.
  - The tests check the chunk sizes, the last chunk, the failures and the single use of a producer body.
---
}
unit Http2.Common.Body.Producers.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Common.Body,
  Http2.Common.Body.Producers, Http2.Common.Body.Fixtures, streamex;

type
  /// the exception that a failing sink raises
  TSinkFailure = class(Exception);

  /// a sink that keeps each chunk and its ALast flag
  TRecordingSink = class(TInterfacedObject, IBodyChunkSink)
  private
    FData: array of string;
    FLast: array of Boolean;
  public
    procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
    /// the number of calls
    function Calls: Integer;
    /// the octets of call AIndex; '' when the call does not exist
    function OctetsAt(const AIndex: Integer): string;
    /// True when call AIndex had ALast True
    function LastAt(const AIndex: Integer): Boolean;
    /// the number of calls with ALast True
    function LastCalls: Integer;
    /// the octets of all calls, in order
    function AllOctets: string;
  end;

  /// a sink that raises TSinkFailure on the call with the number AFailAt
  TFailingSink = class(TInterfacedObject, IBodyChunkSink)
  private
    FCalls: Integer;
    FFailAt: Integer;
  public
    constructor Create(const AFailAt: Integer);
    procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
  end;

  TBodyProducersTest = class(TTestCase)
  private
    FSawFailure: Boolean;
    procedure WriteTen(const AOut: TStream);
    procedure WriteTwelve(const AOut: TStream);
    procedure WriteTwelveSeeFailure(const AOut: TStream);
    procedure WriteNothing(const AOut: TStream);
    procedure WriteEightThenRaise(const AOut: TStream);
    procedure WriteHundredThousand(const AOut: TStream);
    procedure WriteUtf8Lines(const AOut: TStreamWriter);
  published
    procedure TestChunkSizesWithLookAhead;
    procedure TestSingleWriteUsesDefaultChunk;
    procedure TestEmptyProducerGivesOneLastCall;
    procedure TestExactBoundaryLastCallHoldsOctets;
    procedure TestProducerFailurePassesWithoutLast;
    procedure TestSinkFailureComesOutOfWrite;
    procedure TestWriteAfterFinishRaises;
    procedure TestReadAndSeekRaise;
    procedure TestSeekCurrentGivesCount;
    procedure TestTextVariantKeepsMultiByteOctets;
    procedure TestBufferedFallbackGivesOctets;
    procedure TestBufferedFallbackEmptyBody;
    procedure TestSecondUseRaises;
    procedure TestNilProducerRaises;
  end;

implementation

const
  cTen = 'abcdefghij';
  cTwelve = 'abcdefghijkl';
  cEight = 'abcdefgh';
  // 'h', e acute, 'llo ', U+65E5, U+672C, as UTF-8 octets
  cUtf8Text = 'h'#$C3#$A9'llo '#$E6#$97#$A5#$E6#$9C#$AC;

procedure WriteOctets(const AOut: TStream; const AText: string);
begin
  if Length(AText) > 0 then
    AOut.WriteBuffer(AText[1], Length(AText));
end;

function BufferText(const ABuffer: TChunkBuffer): string;
begin
  SetLength(Result, ABuffer.Size);
  if ABuffer.Size > 0 then
    Move(ABuffer.Memory^, Result[1], ABuffer.Size);
end;

{ TRecordingSink }

procedure TRecordingSink.Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
var
  LIndex: Integer;
  LText: string;
begin
  SetLength(LText, ACount);
  if ACount > 0 then
    Move(ABuffer, LText[1], ACount);
  LIndex := Length(FData);
  SetLength(FData, LIndex + 1);
  SetLength(FLast, LIndex + 1);
  FData[LIndex] := LText;
  FLast[LIndex] := ALast;
end;

function TRecordingSink.Calls: Integer;
begin
  Result := Length(FData);
end;

function TRecordingSink.OctetsAt(const AIndex: Integer): string;
begin
  Result := '';
  if (AIndex >= 0) and (AIndex < Length(FData)) then
    Result := FData[AIndex];
end;

function TRecordingSink.LastAt(const AIndex: Integer): Boolean;
begin
  Result := False;
  if (AIndex >= 0) and (AIndex < Length(FLast)) then
    Result := FLast[AIndex];
end;

function TRecordingSink.LastCalls: Integer;
var
  LIndex: Integer;
begin
  Result := 0;
  for LIndex := 0 to Length(FLast) - 1 do
    if FLast[LIndex] then
      Inc(Result);
end;

function TRecordingSink.AllOctets: string;
var
  LIndex: Integer;
begin
  Result := '';
  for LIndex := 0 to Length(FData) - 1 do
    Result := Result + FData[LIndex];
end;

{ TFailingSink }

constructor TFailingSink.Create(const AFailAt: Integer);
begin
  inherited Create;
  FFailAt := AFailAt;
  FCalls := 0;
end;

procedure TFailingSink.Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
begin
  Inc(FCalls);
  if FCalls = FFailAt then
    raise TSinkFailure.Create('the sink failed');
end;

{ TBodyProducersTest }

procedure TBodyProducersTest.WriteTen(const AOut: TStream);
begin
  WriteOctets(AOut, cTen);
end;

procedure TBodyProducersTest.WriteTwelve(const AOut: TStream);
begin
  WriteOctets(AOut, cTwelve);
end;

procedure TBodyProducersTest.WriteTwelveSeeFailure(const AOut: TStream);
begin
  try
    WriteOctets(AOut, cTwelve);
  except
    on E: TSinkFailure do
    begin
      FSawFailure := True;
      raise;
    end;
  end;
end;

procedure TBodyProducersTest.WriteNothing(const AOut: TStream);
begin
end;

procedure TBodyProducersTest.WriteEightThenRaise(const AOut: TStream);
begin
  WriteOctets(AOut, cEight);
  raise TProbeError.Create('the producer failed');
end;

procedure TBodyProducersTest.WriteHundredThousand(const AOut: TStream);
var
  LData: TBytes;
begin
  LData := PatternOctets(100000);
  AOut.WriteBuffer(LData[0], Length(LData));
end;

procedure TBodyProducersTest.WriteUtf8Lines(const AOut: TStreamWriter);
begin
  AOut.WriteLine(cUtf8Text);
  AOut.Write(cUtf8Text);
end;

procedure TBodyProducersTest.TestChunkSizesWithLookAhead;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LStream: TProducerStream;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LStream := TProducerStream.Create(LSink, 4);
  try
    WriteOctets(LStream, cTen);
    LStream.Finish;
  finally
    LStream.Free;
  end;
  AssertEquals('three calls', 3, LRec.Calls);
  AssertEquals('the first chunk has four octets', 'abcd', LRec.OctetsAt(0));
  AssertEquals('the second chunk has four octets', 'efgh', LRec.OctetsAt(1));
  AssertEquals('the last chunk has the rest', 'ij', LRec.OctetsAt(2));
  AssertFalse('the first call is not last', LRec.LastAt(0));
  AssertFalse('the second call is not last', LRec.LastAt(1));
  AssertTrue('the third call is last', LRec.LastAt(2));
  AssertEquals('one call is last', 1, LRec.LastCalls);
end;

procedure TBodyProducersTest.TestSingleWriteUsesDefaultChunk;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LProducer: IBodyProducer;
  LWriter: IBodyWriter;
  LIndex: Integer;
  LLimit: Boolean;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LWriter := BodyWriterFromStream(WriteHundredThousand);
  LProducer := LWriter as IBodyProducer;
  LProducer.Produce(LSink);
  AssertEquals('seven calls: six full chunks and the rest', 7, LRec.Calls);
  LLimit := True;
  for LIndex := 0 to LRec.Calls - 1 do
    if Length(LRec.OctetsAt(LIndex)) > cReadChunkBytes then
      LLimit := False;
  AssertTrue('no chunk is over the default size', LLimit);
  AssertEquals('one call is last', 1, LRec.LastCalls);
  AssertTrue('the last call is the last one', LRec.LastAt(LRec.Calls - 1));
  AssertTrue('the octets arrive complete and in order',
    TextOf(PatternOctets(100000)) = LRec.AllOctets);
end;

procedure TBodyProducersTest.TestEmptyProducerGivesOneLastCall;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LWriter: IBodyWriter;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LWriter := BodyWriterFromStream(WriteNothing);
  (LWriter as IBodyProducer).Produce(LSink);
  AssertEquals('one call', 1, LRec.Calls);
  AssertEquals('the call has no octets', 0, Length(LRec.OctetsAt(0)));
  AssertTrue('the call is last', LRec.LastAt(0));
end;

procedure TBodyProducersTest.TestExactBoundaryLastCallHoldsOctets;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LStream: TProducerStream;
begin
  // eight octets with four per chunk end on a chunk boundary: the last call holds the octets
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LStream := TProducerStream.Create(LSink, 4);
  try
    WriteOctets(LStream, cEight);
    LStream.Finish;
  finally
    LStream.Free;
  end;
  AssertEquals('two calls', 2, LRec.Calls);
  AssertEquals('the first call has four octets', 'abcd', LRec.OctetsAt(0));
  AssertFalse('the first call is not last', LRec.LastAt(0));
  AssertEquals('the last call holds the last four octets', 'efgh', LRec.OctetsAt(1));
  AssertTrue('the call with the last octets is last', LRec.LastAt(1));
end;

procedure TBodyProducersTest.TestProducerFailurePassesWithoutLast;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LWriter: IBodyWriter;
  LRaised: Boolean;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LWriter := BodyWriterFromStream(WriteEightThenRaise);
  LRaised := False;
  try
    (LWriter as IBodyProducer).Produce(LSink);
  except
    on E: TProbeError do
      LRaised := True;
  end;
  AssertTrue('the producer exception passes to the caller', LRaised);
  AssertEquals('no call is last', 0, LRec.LastCalls);
end;

procedure TBodyProducersTest.TestSinkFailureComesOutOfWrite;
var
  LSink: IBodyChunkSink;
  LWriter: IBodyWriter;
  LRaised: Boolean;
begin
  // the sink fails on its second call; the producer writes twelve octets with four per chunk
  LSink := TFailingSink.Create(2);
  LWriter := BodyWriterFromStream(WriteTwelveSeeFailure, 4);
  FSawFailure := False;
  LRaised := False;
  try
    (LWriter as IBodyProducer).Produce(LSink);
  except
    on E: TSinkFailure do
      LRaised := True;
  end;
  AssertTrue('the sink exception passes to the caller', LRaised);
  AssertTrue('the exception came out of the producer Write', FSawFailure);
end;

procedure TBodyProducersTest.TestWriteAfterFinishRaises;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LStream: TProducerStream;
  LRaised: Boolean;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LStream := TProducerStream.Create(LSink, 4);
  try
    WriteOctets(LStream, 'ab');
    LStream.Finish;
    LStream.Finish;
    LRaised := False;
    try
      WriteOctets(LStream, 'x');
    except
      on E: EStreamError do
        LRaised := True;
    end;
    AssertTrue('a Write after Finish raises', LRaised);
  finally
    LStream.Free;
  end;
  AssertEquals('Finish twice sends the chunk once', 1, LRec.Calls);
  AssertEquals('the chunk is the last one', 'ab', LRec.OctetsAt(0));
  AssertTrue('the chunk has ALast True', LRec.LastAt(0));
end;

procedure TBodyProducersTest.TestReadAndSeekRaise;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LStream: TProducerStream;
  LByte: Byte;
  LRaisedRead: Boolean;
  LRaisedSeek: Boolean;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LStream := TProducerStream.Create(LSink, 4);
  try
    LRaisedRead := False;
    try
      LStream.Read(LByte, 1);
    except
      on E: EStreamError do
        LRaisedRead := True;
    end;
    AssertTrue('Read raises EStreamError', LRaisedRead);
    LRaisedSeek := False;
    try
      LStream.Seek(5, soBeginning);
    except
      on E: EStreamError do
        LRaisedSeek := True;
    end;
    AssertTrue('Seek(5, soBeginning) raises EStreamError', LRaisedSeek);
  finally
    LStream.Free;
  end;
  AssertEquals('the failed calls send nothing', 0, LRec.Calls);
end;

procedure TBodyProducersTest.TestSeekCurrentGivesCount;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LStream: TProducerStream;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LStream := TProducerStream.Create(LSink, 4);
  try
    WriteOctets(LStream, 'abc');
    AssertEquals('Seek(0, soCurrent) gives the count written', 3,
      LStream.Seek(0, soCurrent));
    LStream.Finish;
  finally
    LStream.Free;
  end;
end;

procedure TBodyProducersTest.TestTextVariantKeepsMultiByteOctets;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LWriter: IBodyWriter;
  LIndex: Integer;
  LExpected: string;
  LFull: Boolean;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  // a chunk of five octets splits the multi-byte characters
  LWriter := BodyWriterFromTextWriter(WriteUtf8Lines, nil, 5);
  (LWriter as IBodyProducer).Produce(LSink);
  LExpected := cUtf8Text + sLineBreak + cUtf8Text;
  AssertTrue('the octets arrive complete, in order, as UTF-8',
    LExpected = LRec.AllOctets);
  LFull := True;
  for LIndex := 0 to LRec.Calls - 2 do
    if Length(LRec.OctetsAt(LIndex)) <> 5 then
      LFull := False;
  AssertTrue('every chunk but the last has five octets', LFull);
  AssertEquals('one call is last', 1, LRec.LastCalls);
  AssertTrue('the last call is the last one', LRec.LastAt(LRec.Calls - 1));
end;

procedure TBodyProducersTest.TestBufferedFallbackGivesOctets;
var
  LWriter: IBodyWriter;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
  LOctets: string;
  LFalseCount: Integer;
  LCalls: Integer;
  LLimit: Boolean;
begin
  LWriter := BodyWriterFromStream(WriteHundredThousand);
  LBuffer := TChunkBuffer.Create;
  try
    LOctets := '';
    LFalseCount := 0;
    LCalls := 0;
    LLimit := True;
    repeat
      LBuffer.Reset;
      LMore := LWriter.NextChunk(LBuffer);
      Inc(LCalls);
      if LBuffer.Size > cReadChunkBytes then
        LLimit := False;
      LOctets := LOctets + BufferText(LBuffer);
      if not LMore then
        Inc(LFalseCount);
    until not LMore;
    AssertTrue('no call gives more than the read size', LLimit);
    AssertEquals('seven calls', 7, LCalls);
    AssertEquals('one call returns False', 1, LFalseCount);
    AssertTrue('the octets arrive complete and in order',
      TextOf(PatternOctets(100000)) = LOctets);
  finally
    LBuffer.Free;
  end;
  // a body of ten octets: the first call gives all of them with False
  LWriter := BodyWriterFromStream(WriteTen);
  LBuffer := TChunkBuffer.Create;
  try
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('the first call of a short body returns False', LMore);
    AssertEquals('the last octets come with the False answer', cTen, BufferText(LBuffer));
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyProducersTest.TestBufferedFallbackEmptyBody;
var
  LWriter: IBodyWriter;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  LWriter := BodyWriterFromStream(WriteNothing);
  LBuffer := TChunkBuffer.Create;
  try
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('an empty body gives False at once', LMore);
    AssertEquals('an empty body gives no octets', 0, LBuffer.Size);
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('the end repeats', LMore);
    AssertEquals('the end gives no octets', 0, LBuffer.Size);
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyProducersTest.TestSecondUseRaises;
var
  LRec: TRecordingSink;
  LSink: IBodyChunkSink;
  LWriter: IBodyWriter;
  LBuffer: TChunkBuffer;
  LRaised: Boolean;
begin
  LRec := TRecordingSink.Create;
  LSink := LRec;
  LBuffer := TChunkBuffer.Create;
  try
    // a pulled body can not be produced after the pull
    LWriter := BodyWriterFromStream(WriteTen);
    DrainWriter(LWriter);
    LRaised := False;
    try
      (LWriter as IBodyProducer).Produce(LSink);
    except
      on E: EBodyFormatError do
        LRaised := True;
    end;
    AssertTrue('Produce after a pull raises EBodyFormatError', LRaised);
    // a produced body can not be pulled
    LWriter := BodyWriterFromStream(WriteTen);
    (LWriter as IBodyProducer).Produce(LSink);
    LRaised := False;
    try
      LWriter.NextChunk(LBuffer);
    except
      on E: EBodyFormatError do
        LRaised := True;
    end;
    AssertTrue('NextChunk after Produce raises EBodyFormatError', LRaised);
    // a second Produce raises
    LWriter := BodyWriterFromTextWriter(WriteUtf8Lines);
    (LWriter as IBodyProducer).Produce(LSink);
    LRaised := False;
    try
      (LWriter as IBodyProducer).Produce(LSink);
    except
      on E: EBodyFormatError do
        LRaised := True;
    end;
    AssertTrue('a second Produce raises EBodyFormatError', LRaised);
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyProducersTest.TestNilProducerRaises;
var
  LWriter: IBodyWriter;
  LRaised: Boolean;
begin
  LRaised := False;
  try
    LWriter := BodyWriterFromStream(nil);
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a nil stream producer raises EBodyFormatError', LRaised);
  LRaised := False;
  try
    LWriter := BodyWriterFromTextWriter(nil);
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a nil text producer raises EBodyFormatError', LRaised);
end;

initialization
  RegisterTest(TBodyProducersTest);

end.
