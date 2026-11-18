{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, test
notes:
  - This test checks the body reader base class and the helpers that read a body to its end.
  - The tests check the chunk size, the end that repeats, the last-chunk rule and the limit.
  - The tests check that CopyBody never seeks the destination.
---
}
unit Http2.Common.BodyReader.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Common.Body;

type
  /// a reader over a byte array; each Read gives at most AStep octets
  TScriptedReader = class(TBodyReaderBase)
  private
    FData: TBytes;
    FPosition: Integer;
    FStep: Integer;
    FCalls: Integer;
    FLargestAsked: Integer;
  public
    constructor Create(const AData: TBytes; const AStep: Integer);
    function Read(var ABuffer; const ACount: Integer): Integer; override;
    /// the number of Read calls so far
    property Calls: Integer read FCalls;
    /// the largest count that a Read call asked for
    property LargestAsked: Integer read FLargestAsked;
  end;

  /// a reader that gives "abc" in one call and "de" with False in the next call
  TLastChunkReader = class(TBodyReaderBase)
  private
    FCalls: Integer;
  public
    function Read(var ABuffer; const ACount: Integer): Integer; override;
    function ReadChunk(const ABuffer: TStream): Boolean; override;
  end;

  /// a reader whose Read raises EBodyFormatError
  TFailingReader = class(TBodyReaderBase)
  public
    function Read(var ABuffer; const ACount: Integer): Integer; override;
  end;

  /// a reader whose Read answers one octet more than the count that it was asked
  TOverAnsweringReader = class(TBodyReaderBase)
  public
    function Read(var ABuffer; const ACount: Integer): Integer; override;
  end;

  /// a stream that accepts writes and raises on every seek
  // - the content is kept in an inner memory stream, so the test reads the octets
  TNoSeekStream = class(TStream)
  private
    FContent: TMemoryStream;
  public
    constructor Create;
    destructor Destroy; override;
    function Write(const ABuffer; ACount: Longint): Longint; override;
    function Seek(const AOffset: Int64; AOrigin: TSeekOrigin): Int64; override;
    function Seek(AOffset: Longint; AOrigin: Word): Longint; override;
    /// the octets that were written
    function Content: TBytes;
  end;

  TBodyReaderTest = class(TTestCase)
  private
    function Pattern(const ACount: Integer): TBytes;
    function TextBytes(const AText: string): TBytes;
    function SameBytes(const A, B: TBytes): Boolean;
    function Pull(const AReader: IBodyReader; const ABuffer: TChunkBuffer;
      out AMore: Boolean): Integer;
    function ReadsTooLarge(const AReader: IBodyReader; const AMax: Int64): Boolean;
  published
    procedure TestBaseGivesOneChunkPerRead;
    procedure TestShortReadsGiveSmallerChunks;
    procedure TestEndRepeats;
    procedure TestChunkAppendsAtPosition;
    procedure TestLastChunkOfFalseCallIsKept;
    procedure TestReadAllBodyWithoutLimit;
    procedure TestReadAllBodyStopsAtTheFirstChunkOver;
    procedure TestReadAllBodyLimitCountsTheLastChunk;
    procedure TestCopyBodyDoesNotSeek;
    procedure TestReaderExceptionPasses;
    procedure TestOutOfRangeCountIsRefused;
  end;

implementation

constructor TScriptedReader.Create(const AData: TBytes; const AStep: Integer);
begin
  inherited Create;
  FData := AData;
  FStep := AStep;
end;

function TScriptedReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Inc(FCalls);
  if ACount > FLargestAsked then
    FLargestAsked := ACount;
  Result := Length(FData) - FPosition;
  if Result > ACount then
    Result := ACount;
  if Result > FStep then
    Result := FStep;
  if Result > 0 then
  begin
    Move(FData[FPosition], ABuffer, Result);
    Inc(FPosition, Result);
  end;
end;

function TLastChunkReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
end;

function TLastChunkReader.ReadChunk(const ABuffer: TStream): Boolean;
begin
  Inc(FCalls);
  if FCalls = 1 then
  begin
    ChunkAppendText(ABuffer, 'abc');
    Result := True;
  end
  else if FCalls = 2 then
  begin
    ChunkAppendText(ABuffer, 'de');
    Result := False;
  end
  else
    Result := False;
end;

function TFailingReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
  raise EBodyFormatError.Create('the reader fails');
end;

function TOverAnsweringReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := ACount + 1;
end;

constructor TNoSeekStream.Create;
begin
  inherited Create;
  FContent := TMemoryStream.Create;
end;

destructor TNoSeekStream.Destroy;
begin
  FContent.Free;
  inherited Destroy;
end;

function TNoSeekStream.Write(const ABuffer; ACount: Longint): Longint;
begin
  Result := FContent.Write(ABuffer, ACount);
end;

function TNoSeekStream.Seek(const AOffset: Int64; AOrigin: TSeekOrigin): Int64;
begin
  Result := 0;
  raise EAssertionFailedError.Create('the destination was sought');
end;

function TNoSeekStream.Seek(AOffset: Longint; AOrigin: Word): Longint;
begin
  Result := 0;
  raise EAssertionFailedError.Create('the destination was sought');
end;

function TNoSeekStream.Content: TBytes;
begin
  Result := nil;
  SetLength(Result, FContent.Size);
  if FContent.Size > 0 then
    Move(FContent.Memory^, Result[0], FContent.Size);
end;

function TBodyReaderTest.Pattern(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte(I mod 251);
end;

function TBodyReaderTest.TextBytes(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TBodyReaderTest.SameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
    begin
      Result := False;
      Exit;
    end;
end;

function TBodyReaderTest.Pull(const AReader: IBodyReader; const ABuffer: TChunkBuffer;
  out AMore: Boolean): Integer;
begin
  ABuffer.Reset;
  AMore := AReader.ReadChunk(ABuffer);
  Result := Integer(ABuffer.Size);
end;

function TBodyReaderTest.ReadsTooLarge(const AReader: IBodyReader; const AMax: Int64): Boolean;
var
  LBytes: TBytes;
begin
  Result := False;
  try
    LBytes := ReadAllBody(AReader, AMax);
  except
    on E: EBodyTooLarge do
      Result := True;
  end;
end;

procedure TBodyReaderTest.TestBaseGivesOneChunkPerRead;
var
  LReader: IBodyReader;
  LScripted: TScriptedReader;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  LScripted := TScriptedReader.Create(Pattern(40000), MaxInt);
  LReader := LScripted;
  LBuffer := TChunkBuffer.Create;
  try
    AssertEquals('the first chunk is cReadChunkBytes', cReadChunkBytes, Pull(LReader, LBuffer, LMore));
    AssertTrue('the first call is not the end', LMore);
    AssertEquals('the second chunk is cReadChunkBytes', cReadChunkBytes, Pull(LReader, LBuffer, LMore));
    AssertTrue('the second call is not the end', LMore);
    AssertEquals('the third chunk holds the rest', 40000 - 2 * cReadChunkBytes, Pull(LReader, LBuffer, LMore));
    AssertTrue('the third call is not the end', LMore);
    AssertEquals('the end gives no octets', 0, Pull(LReader, LBuffer, LMore));
    AssertFalse('the end gives False', LMore);
    AssertEquals('the end repeats with no octets', 0, Pull(LReader, LBuffer, LMore));
    AssertFalse('the end repeats with False', LMore);
    AssertEquals('five Read calls in all', 5, LScripted.Calls);
    AssertEquals('no Read asks for more than cReadChunkBytes', cReadChunkBytes, LScripted.LargestAsked);
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyReaderTest.TestShortReadsGiveSmallerChunks;
var
  LReader: IBodyReader;
  LScripted: TScriptedReader;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  LScripted := TScriptedReader.Create(Pattern(1000), 300);
  LReader := LScripted;
  LBuffer := TChunkBuffer.Create;
  try
    AssertEquals('a short read gives a short chunk', 300, Pull(LReader, LBuffer, LMore));
    AssertTrue(LMore);
    AssertEquals('the second short chunk', 300, Pull(LReader, LBuffer, LMore));
    AssertTrue(LMore);
    AssertEquals('the third short chunk', 300, Pull(LReader, LBuffer, LMore));
    AssertTrue(LMore);
    AssertEquals('the rest of the body', 100, Pull(LReader, LBuffer, LMore));
    AssertTrue(LMore);
    AssertEquals('the end gives no octets', 0, Pull(LReader, LBuffer, LMore));
    AssertFalse(LMore);
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyReaderTest.TestEndRepeats;
var
  LReader: IBodyReader;
  LScripted: TScriptedReader;
  LBuffer: TChunkBuffer;
  LMore: Boolean;
  I: Integer;
begin
  LScripted := TScriptedReader.Create(nil, 10);
  LReader := LScripted;
  LBuffer := TChunkBuffer.Create;
  try
    for I := 1 to 3 do
    begin
      AssertEquals('an empty body gives no octets', 0, Pull(LReader, LBuffer, LMore));
      AssertFalse('an empty body ends at once', LMore);
    end;
    AssertEquals('each call asks Read', 3, LScripted.Calls);
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyReaderTest.TestChunkAppendsAtPosition;
var
  LReader: IBodyReader;
  LBuffer: TChunkBuffer;
  LExpected: TBytes;
  LMore: Boolean;
begin
  LReader := TScriptedReader.Create(Pattern(3), 10);
  LBuffer := TChunkBuffer.Create;
  try
    ChunkAppendText(LBuffer, 'xy');
    AssertTrue(LReader.ReadChunk(LBuffer));
    LMore := LReader.ReadChunk(LBuffer);
    AssertFalse(LMore);
    LExpected := TextBytes('xy');
    SetLength(LExpected, 5);
    LExpected[2] := 0;
    LExpected[3] := 1;
    LExpected[4] := 2;
    AssertTrue('ReadChunk appends after the octets in the buffer', SameBytes(LExpected, ChunkBytes(LBuffer)));
  finally
    LBuffer.Free;
  end;
end;

procedure TBodyReaderTest.TestLastChunkOfFalseCallIsKept;
var
  LReader: IBodyReader;
  LStream: TNoSeekStream;
begin
  LReader := TLastChunkReader.Create;
  AssertTrue('ReadAllBody keeps the octets of the False call',
    SameBytes(TextBytes('abcde'), ReadAllBody(LReader)));

  LReader := TLastChunkReader.Create;
  LStream := TNoSeekStream.Create;
  try
    CopyBody(LReader, LStream);
    AssertTrue('CopyBody keeps the octets of the False call', SameBytes(TextBytes('abcde'), LStream.Content));
  finally
    LStream.Free;
  end;
end;

procedure TBodyReaderTest.TestReadAllBodyWithoutLimit;
var
  LReader: IBodyReader;
begin
  LReader := TScriptedReader.Create(Pattern(100000), 1000);
  AssertTrue('ReadAllBody without a limit gives the whole body', SameBytes(Pattern(100000), ReadAllBody(LReader)));

  LReader := TScriptedReader.Create(Pattern(100000), 1000);
  AssertTrue('a limit of 0 means no limit', SameBytes(Pattern(100000), ReadAllBody(LReader, 0)));

  LReader := TScriptedReader.Create(nil, 1000);
  AssertEquals('an empty body gives an empty array', 0, Length(ReadAllBody(LReader)));
end;

procedure TBodyReaderTest.TestReadAllBodyStopsAtTheFirstChunkOver;
var
  LReader: IBodyReader;
  LScripted: TScriptedReader;
begin
  LScripted := TScriptedReader.Create(Pattern(40000), MaxInt);
  LReader := LScripted;
  AssertTrue('a body over the limit raises EBodyTooLarge', ReadsTooLarge(LReader, 20000));
  AssertEquals('the reader stops after the chunk over the limit', 2, LScripted.Calls);

  LReader := TScriptedReader.Create(Pattern(40000), MaxInt);
  AssertTrue('a body of exactly the limit passes', SameBytes(Pattern(40000), ReadAllBody(LReader, 40000)));

  LReader := TScriptedReader.Create(Pattern(40000), MaxInt);
  AssertTrue('a body one octet over the limit raises', ReadsTooLarge(LReader, 39999));
end;

procedure TBodyReaderTest.TestReadAllBodyLimitCountsTheLastChunk;
var
  LReader: IBodyReader;
begin
  // the body is "abcde": the limit of 4 is passed by the octets of the False call
  LReader := TLastChunkReader.Create;
  AssertTrue('the octets of the False call count toward the limit', ReadsTooLarge(LReader, 4));

  LReader := TLastChunkReader.Create;
  AssertTrue('the body of exactly the limit passes', SameBytes(TextBytes('abcde'), ReadAllBody(LReader, 5)));
end;

procedure TBodyReaderTest.TestCopyBodyDoesNotSeek;
var
  LReader: IBodyReader;
  LStream: TNoSeekStream;
begin
  LReader := TScriptedReader.Create(Pattern(50000), 4000);
  LStream := TNoSeekStream.Create;
  try
    CopyBody(LReader, LStream);
    AssertTrue('CopyBody writes the body in order', SameBytes(Pattern(50000), LStream.Content));
  finally
    LStream.Free;
  end;

  LReader := TScriptedReader.Create(nil, 4000);
  LStream := TNoSeekStream.Create;
  try
    CopyBody(LReader, LStream);
    AssertEquals('CopyBody of an empty body writes nothing', 0, Length(LStream.Content));
  finally
    LStream.Free;
  end;
end;

procedure TBodyReaderTest.TestReaderExceptionPasses;
var
  LReader: IBodyReader;
  LStream: TNoSeekStream;
  LBytes: TBytes;
  LRaised: Boolean;
begin
  LReader := TFailingReader.Create;
  LRaised := False;
  try
    LBytes := ReadAllBody(LReader);
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('ReadAllBody passes the exception of the reader', LRaised);

  LStream := TNoSeekStream.Create;
  try
    LRaised := False;
    try
      CopyBody(LReader, LStream);
    except
      on E: EBodyFormatError do
        LRaised := True;
    end;
    AssertTrue('CopyBody passes the exception of the reader', LRaised);
  finally
    LStream.Free;
  end;
end;

procedure TBodyReaderTest.TestOutOfRangeCountIsRefused;
var
  LReader: IBodyReader;
  LBuffer: TChunkBuffer;
  LRaised: Boolean;
begin
  LReader := TOverAnsweringReader.Create;
  LBuffer := TChunkBuffer.Create;
  try
    LRaised := False;
    try
      LReader.ReadChunk(LBuffer);
    except
      on E: EBodyFormatError do
        LRaised := True;
    end;
    AssertTrue('a count over cReadChunkBytes raises EBodyFormatError', LRaised);
    AssertEquals('no octet is written for the refused count', 0, LBuffer.Size);
  finally
    LBuffer.Free;
  end;
end;

initialization
  RegisterTest(TBodyReaderTest);
end.
