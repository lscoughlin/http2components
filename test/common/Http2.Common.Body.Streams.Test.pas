{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, stream, test
notes:
  - This test checks the read-only stream over a body reader and the base class of the serialized writers.
  - The tests check that Seek, GetSize and Write raise, that the pushback comes first, and the read modes.
  - The tests check the chunk boundaries of a serialized writer and that its end repeats.
---
}
unit Http2.Common.Body.Streams.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Common.Body,
  Http2.Common.Body.Streams, Http2.Common.Body.Fixtures;

type
  TBodyStreamsTest = class(TTestCase)
  private
    function ReadOf(const AStream: TStream; const ACount: Integer): string;
  published
    procedure TestFillReadWaitsForTheCount;
    procedure TestSingleReadReturnsWhatTheReaderGives;
    procedure TestEndGivesZeroAndRepeats;
    procedure TestPushBackComesFirst;
    procedure TestPushBackPrepends;
    procedure TestWireBytesCountOnlyTheReader;
    procedure TestSeekRaises;
    procedure TestWriteRaises;
    procedure TestSizeRaises;
    procedure TestReaderErrorIsKept;
    procedure TestSerializedWriterWithoutOctets;
    procedure TestSerializedWriterChunkBoundaries;
    procedure TestSerializedWriterEndRepeats;
  end;

implementation

function TBodyStreamsTest.ReadOf(const AStream: TStream; const ACount: Integer): string;
var
  LBuffer: array of Byte;
  LCount: Integer;
begin
  SetLength(LBuffer, ACount);
  LCount := AStream.Read(LBuffer[0], ACount);
  SetLength(Result, LCount);
  if LCount > 0 then
    Move(LBuffer[0], Result[1], LCount);
end;

procedure TBodyStreamsTest.TestFillReadWaitsForTheCount;
var
  LStream: TReaderStream;
  LBuffer: array[0..15] of Byte;
  LCount: Integer;
  LText: string;
begin
  // the reader gives one octet per call; a fill read still gives all ten octets
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abcdefghij'), 1), True);
  try
    LCount := LStream.Read(LBuffer, 10);
    AssertEquals('a fill read gives the count', 10, LCount);
    SetString(LText, PAnsiChar(@LBuffer[0]), LCount);
    AssertEquals('the octets are in order', 'abcdefghij', LText);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestSingleReadReturnsWhatTheReaderGives;
var
  LStream: TReaderStream;
begin
  // a single read gives one reader call and does not wait for the count
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abc'), 1));
  try
    AssertEquals('one octet from one reader call', 'a', ReadOf(LStream, 10));
    AssertEquals('the next single read gives the next octet', 'b', ReadOf(LStream, 10));
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestEndGivesZeroAndRepeats;
var
  LStream: TReaderStream;
  LBuffer: array[0..3] of Byte;
begin
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('a'), 4), True);
  try
    AssertEquals('the octet', 1, LStream.Read(LBuffer, 4));
    AssertEquals('the end gives 0', 0, LStream.Read(LBuffer, 4));
    AssertEquals('the end repeats', 0, LStream.Read(LBuffer, 4));
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestPushBackComesFirst;
var
  LStream: TReaderStream;
  LBuffer: array[0..7] of Byte;
  LCount: Integer;
begin
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abc'), 1));
  try
    LStream.PushBack(OctetsOf('XY'));
    // the pushback gives its two octets and does not wait for the reader
    LCount := LStream.Read(LBuffer, 4);
    AssertEquals('the pushback gives its octets without a wait', 2, LCount);
    AssertEquals('the pushback comes first', 'XY', Chr(LBuffer[0]) + Chr(LBuffer[1]));
    AssertEquals('the reader follows', 'a', ReadOf(LStream, 4));
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestPushBackPrepends;
var
  LStream: TReaderStream;
  LBuffer: array[0..7] of Byte;
  LCount: Integer;
  LText: string;
begin
  LStream := TReaderStream.Create(TStepReader.Create(nil, 1), True);
  try
    LStream.PushBack(OctetsOf('CD'));
    LStream.PushBack(OctetsOf('AB'));
    LCount := LStream.Read(LBuffer, 8);
    SetLength(LText, LCount);
    Move(LBuffer[0], LText[1], LCount);
    AssertEquals('a second pushback goes in front of the first', 'ABCD', LText);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestWireBytesCountOnlyTheReader;
var
  LStream: TReaderStream;
  LBuffer: array[0..7] of Byte;
  LCount: Integer;
begin
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abc'), 8), True);
  try
    LStream.PushBack(OctetsOf('xy'));
    LCount := LStream.Read(LBuffer, 5);
    AssertEquals('five octets in all', 5, LCount);
    AssertEquals('the wire count leaves out the pushback', 3, LStream.WireBytes);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestSeekRaises;
var
  LStream: TReaderStream;
  LRaised: Boolean;
begin
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abc'), 8));
  try
    LRaised := False;
    try
      LStream.Seek(0, soBeginning);
    except
      on E: EStreamError do
        LRaised := True;
    end;
    AssertTrue('Seek raises EStreamError', LRaised);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestWriteRaises;
var
  LStream: TReaderStream;
  LRaised: Boolean;
  LData: Byte;
begin
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abc'), 8));
  try
    LRaised := False;
    LData := 1;
    try
      LStream.Write(LData, 1);
    except
      on E: EStreamError do
        LRaised := True;
    end;
    AssertTrue('Write raises EStreamError', LRaised);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestSizeRaises;
var
  LStream: TReaderStream;
  LRaised: Boolean;
  LSize: Int64;
begin
  LStream := TReaderStream.Create(TStepReader.Create(OctetsOf('abc'), 8));
  try
    LRaised := False;
    try
      LSize := LStream.Size;
    except
      on E: EStreamError do
        LRaised := True;
    end;
    AssertTrue('Size raises EStreamError', LRaised);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestReaderErrorIsKept;
var
  LStream: TReaderStream;
  LBuffer: array[0..15] of Byte;
  LRaised: Boolean;
begin
  LStream := TReaderStream.Create(TFailingReader.Create(OctetsOf('abcdef'), 3), True);
  try
    LRaised := False;
    try
      LStream.Read(LBuffer, 10);
    except
      on E: TProbeError do
        LRaised := True;
    end;
    AssertTrue('the reader exception passes to the caller', LRaised);
    AssertTrue('the stream marks the reader as failed', LStream.ReaderFailed);
  finally
    LStream.Free;
  end;
end;

procedure TBodyStreamsTest.TestSerializedWriterWithoutOctets;
var
  LWriter: IBodyWriter;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  LWriter := TPatternWriter.Create(0);
  LBuffer := TChunkBuffer.Create;
  try
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('an empty body ends at once', LMore);
    AssertEquals('the last call carries no octets', 0, Integer(LBuffer.Size));
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyStreamsTest.TestSerializedWriterChunkBoundaries;
var
  LWriter: IBodyWriter;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  // two full chunks and five octets: True, True, then False with five octets
  LWriter := TPatternWriter.Create(2 * cReadChunkBytes + 5);
  LBuffer := TChunkBuffer.Create;
  try
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertTrue('the first call is not the end', LMore);
    AssertEquals('the first chunk is cReadChunkBytes', cReadChunkBytes, Integer(LBuffer.Size));
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertTrue('the second call is not the end', LMore);
    AssertEquals('the second chunk is cReadChunkBytes', cReadChunkBytes, Integer(LBuffer.Size));
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('the third call is the end', LMore);
    AssertEquals('the last chunk holds the rest', 5, Integer(LBuffer.Size));
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('the end repeats', LMore);
    AssertEquals('the repeated end has no octets', 0, Integer(LBuffer.Size));
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyStreamsTest.TestSerializedWriterEndRepeats;
var
  LWriter: IBodyWriter;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  // exactly one full chunk: the full chunk comes with False, so the body has one call
  LWriter := TPatternWriter.Create(cReadChunkBytes);
  LBuffer := TChunkBuffer.Create;
  try
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('one full chunk is the last chunk', LMore);
    AssertEquals('the chunk is cReadChunkBytes', cReadChunkBytes, Integer(LBuffer.Size));
    LBuffer.Reset;
    LMore := LWriter.NextChunk(LBuffer);
    AssertFalse('the end repeats', LMore);
    AssertEquals('the repeated end has no octets', 0, Integer(LBuffer.Size));
  finally
    LBuffer.Free;
  end;
end;

initialization
  RegisterTest(TBodyStreamsTest);

end.
