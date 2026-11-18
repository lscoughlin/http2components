{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, body_reader, stream, pushback, text reader
notes:
  - This unit holds the body writer and body reader interfaces that the server and the client share.
  - The library owns the chunk buffer. A writer writes one chunk into it for each call.
  - TChunkBuffer keeps its memory between chunks. It is not thread safe.
  - A reader gives one chunk for each ReadChunk call. The helpers read a body to its end.
  - A reader gives a TStream (GetStream) and a TStreamReader (GetStreamReader) over its body.
  - This unit holds TReaderStream, a read-only stream over an IBodyReader with a pushback buffer.
  - A TReaderStream does not seek, does not write and has no size.
---
}
unit Http2.Common.Body;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, streamex;

const
  /// the largest number of octets that one Read call of a reader gives
  // - TBodyReaderBase.ReadChunk asks for at most this count
  cReadChunkBytes = 16384;

type
  /// a pulled body: the library calls NextChunk until it returns False
  // - the library passes the same stream for every call of one body
  // - on entry the stream is empty (Size = 0, Position = 0)
  // - the writer writes the chunk at the current position; [0, Size) is the chunk
  // - the writer does not keep a reference to the stream after the call
  // - the writer does not seek before the place where it began
  // - the library reads a chunk through Size, never through Position (D22)
  // - a chunk of Size = 0 is an empty chunk
  // - the octets of a call that returns False are the last chunk of the body;
  //   the library sends them and then ends the body (D4, D22)
  // - a call that returns False with Size = 0 only ends the body
  // - NextChunk can block; the library never calls it from an IO thread (D16, D17)
  IBodyWriter = interface
    ['{7E1F0C11-00F2-4A11-9C72-000000003101}']
    /// write the next chunk into ABuffer; return False when the body is over
    function NextChunk(const ABuffer: TStream): Boolean;
  end;

  /// a memory stream that a body writer fills one chunk at a time
  // - Reset empties the stream and keeps the allocated memory
  // - the memory is kept at any size, because a buffer lives for one body only
  // - not thread safe: one thread uses one buffer at a time (D24)
  TChunkBuffer = class(TMemoryStream)
  public
    /// Size and Position become 0; the allocated memory stays
    procedure Reset;
  end;

  /// a body that a caller reads one chunk at a time
  // - Read gives the next octets of the body; 0 means that the body has ended
  // - Read blocks until an octet arrives or the body ends
  // - after the end, every later Read and ReadChunk gives the end again
  // - a reader that has natural chunks can give more than one chunk for each call
  IBodyReader = interface
    ['{7E1F0C11-00F3-4A11-9C72-000000003201}']
    /// read at most ACount octets into ABuffer; answer the count that was read
    // - 0 means that the body has ended, now and on every later call
    function Read(var ABuffer; const ACount: Integer): Integer;
    /// append the next chunk to ABuffer at its position; False means that the body has ended
    // - a call that returns True writes at least one octet
    // - the octets of a call that returns False are the last chunk of the body
    // - the reader does not keep ABuffer after the call returns
    // - the reader does not seek before the position where the call began
    function ReadChunk(const ABuffer: TStream): Boolean;
    /// give a read-only, non-seekable TStream over the body
    // - the caller owns the stream and frees it
    // - the stream holds a reference to the reader until the stream is freed
    // - the stream is for one pass: a read after the end gives 0
    // - each Read of the stream calls Read of the reader once
    function GetStream: TStream;
    /// give a TStreamReader over the stream of GetStream
    // - the caller owns the TStreamReader and frees it
    // - the TStreamReader owns the stream: freeing it frees the stream and releases the reader
    // - the stream is for one pass: a read after the end gives the end again
    function GetStreamReader: TStreamReader;
  end;

  /// a read-only, non-seekable TStream view of an IBodyReader
  // - Read gives the octets of the body in order, after the octets of the pushback
  // - FillReads = False: a Read gives the octets of one reader call, so it does not wait
  //   for more octets than the reader gives in one call
  // - FillReads = True: a Read waits until ACount octets are read or the body ends;
  //   a parser that takes a short read as the end of the input needs this mode
  // - Seek, GetSize and Write raise EStreamError
  // - the stream does not own the reader, but it holds a reference to it
  TReaderStream = class(TStream)
  private
    FReader: IBodyReader;
    FFillReads: Boolean;
    FPush: TBytes;
    FPushPos: Integer;
    FWireBytes: Int64;
    FReaderFailed: Boolean;
    function ReaderRead(var ABuffer; const ACount: Integer): Integer;
  public
    /// create a view of AReader; AFillReads selects the read mode (see the class)
    constructor Create(const AReader: IBodyReader; const AFillReads: Boolean = False);
    /// the octets that the reader has given, without the pushback
    property WireBytes: Int64 read FWireBytes;
    /// True when the reader raised an exception during a Read of this stream
    // - the exception passes to the caller of Read; this flag tells that the reader failed
    property ReaderFailed: Boolean read FReaderFailed;
    /// prepend AData to the octets that Read still gives
    procedure PushBack(const AData: TBytes);
    /// read at most ACount octets; 0 means that the body has ended
    function Read(var ABuffer; ACount: LongInt): LongInt; override;
    /// raises EStreamError: the body is read only
    function Write(const ABuffer; ACount: LongInt): LongInt; override;
    /// raises EStreamError: the body is not seekable
    function Seek(const AOffset: Int64; AOrigin: TSeekOrigin): Int64; override;
    /// raises EStreamError: the body has no size
    function GetSize: Int64; override;
  end;

  /// the base class of a body reader; ReadChunk does one Read of at most cReadChunkBytes
  // - a descendant implements Read
  // - a reader with natural chunks overrides ReadChunk
  // - GetStream and GetStreamReader are inherited from this class
  TBodyReaderBase = class(TInterfacedObject, IBodyReader)
  public
    /// read at most ACount octets into ABuffer; 0 means that the body has ended
    function Read(var ABuffer; const ACount: Integer): Integer; virtual; abstract;
    /// append one Read of at most cReadChunkBytes to ABuffer; False when Read gave 0
    function ReadChunk(const ABuffer: TStream): Boolean; virtual;
    /// give a read-only, non-seekable TStream over the body (see IBodyReader)
    function GetStream: TStream;
    /// give a TStreamReader over the stream of GetStream (see IBodyReader)
    function GetStreamReader: TStreamReader;
  end;

  /// raised when a body is longer than the limit that the caller gave
  EBodyTooLarge = class(Exception);

  /// raised when a body does not have the format that its reader expects,
  /// or when a body reader answers a count that is out of range
  EBodyFormatError = class(Exception);

  /// the place that receives the chunks of a body that a producer writes
  // - Chunk gives one chunk of the body; it blocks until the place accepts the chunk (backpressure)
  // - a call with ALast False has ACount > 0
  // - the last call has ALast True; it can have ACount = 0, and then it only ends the body
  // - Chunk raises when the body can not go on, for example when the peer resets the stream
  IBodyChunkSink = interface
    ['{7E1F0C11-00F4-4A11-9C72-000000003301}']
    /// give one chunk of the body to the place
    procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
  end;

  /// a body that a producer writes; a place that supports it runs the producer
  // - Produce runs the producer to its end on the calling thread
  // - Produce gives each chunk to ASink; the last chunk comes with ALast True
  // - an exception of the producer or of the sink passes to the caller
  // - a producer body is used once: a second Produce or NextChunk raises EBodyFormatError
  IBodyProducer = interface
    ['{7E1F0C11-00F4-4A11-9C72-000000003302}']
    /// run the producer to its end and give each chunk to ASink
    procedure Produce(const ASink: IBodyChunkSink);
  end;

/// append AData to ABuffer at its position
// - an empty array writes nothing
procedure ChunkAppend(const ABuffer: TStream; const AData: TBytes);

/// append the octets of AText (UTF-8) to ABuffer at its position
// - an empty text writes nothing
procedure ChunkAppendText(const ABuffer: TStream; const AText: UTF8String);

/// the octets in [0, Size) of ABuffer as a new array (D25)
function ChunkBytes(const ABuffer: TChunkBuffer): TBytes;

/// read the body to its end and give all its octets as a new array
// - AMax > 0 limits the length of the body; a longer body raises EBodyTooLarge
// - the limit applies after each chunk, so a longer body stops at the first chunk over it
// - an exception of the reader passes to the caller
function ReadAllBody(AReader: IBodyReader; AMax: Int64 = 0): TBytes;

/// copy the body to ADest one chunk at a time
// - ADest receives the octets with WriteBuffer only; it is not sought or sized
// - the octets of the last call are copied too
procedure CopyBody(AReader: IBodyReader; ADest: TStream);

/// give a new TReaderStream over AReader in the one-call mode (FillReads = False)
// - the caller owns the stream and frees it
// - the stream holds a reference to AReader until it is freed
// - this is the stream that IBodyReader.GetStream gives
function BodyStream(const AReader: IBodyReader): TStream;

/// give a new TStreamReader over the stream of BodyStream(AReader)
// - the caller owns the TStreamReader; it owns the stream (OwnsStream = True)
// - this is the reader that IBodyReader.GetStreamReader gives
function BodyStreamReader(const AReader: IBodyReader): TStreamReader;

implementation

{ TChunkBuffer }

procedure TChunkBuffer.Reset;
begin
  // SetPointer keeps the allocation. SetSize(0) or Clear would free it.
  SetPointer(Memory, 0);
  Position := 0;
end;

{ TReaderStream }

constructor TReaderStream.Create(const AReader: IBodyReader; const AFillReads: Boolean);
begin
  inherited Create;
  FReader := AReader;
  FFillReads := AFillReads;
  FPushPos := 0;
  FWireBytes := 0;
  FReaderFailed := False;
end;

function TReaderStream.ReaderRead(var ABuffer; const ACount: Integer): Integer;
begin
  try
    Result := FReader.Read(ABuffer, ACount);
  except
    FReaderFailed := True;
    raise;
  end;
end;

procedure TReaderStream.PushBack(const AData: TBytes);
var
  LRest: TBytes;
  LCount: Integer;
begin
  // the octets not yet served come after AData
  LRest := nil;
  LCount := Length(FPush) - FPushPos;
  if LCount > 0 then
  begin
    SetLength(LRest, LCount);
    Move(FPush[FPushPos], LRest[0], LCount);
  end;
  SetLength(FPush, Length(AData) + LCount);
  if Length(AData) > 0 then
    Move(AData[0], FPush[0], Length(AData));
  if LCount > 0 then
    Move(LRest[0], FPush[Length(AData)], LCount);
  FPushPos := 0;
end;

function TReaderStream.Read(var ABuffer; ACount: LongInt): LongInt;
var
  P: PByte;
  Got: Integer;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  P := @ABuffer;
  // the pushback comes first; it never waits for the reader
  while (FPushPos < Length(FPush)) and (Result < ACount) do
  begin
    P[Result] := FPush[FPushPos];
    Inc(FPushPos);
    Inc(Result);
  end;
  if FFillReads then
  begin
    while Result < ACount do
    begin
      Got := ReaderRead(P[Result], ACount - Result);
      if Got <= 0 then
        Break;
      Inc(Result, Got);
      Inc(FWireBytes, Got);
    end;
  end
  else if Result = 0 then
  begin
    Got := ReaderRead(P[0], ACount);
    if Got > 0 then
    begin
      Result := Got;
      Inc(FWireBytes, Got);
    end;
  end;
end;

function TReaderStream.Write(const ABuffer; ACount: LongInt): LongInt;
begin
  Result := 0;
  raise EStreamError.Create('the body stream is read only');
end;

function TReaderStream.Seek(const AOffset: Int64; AOrigin: TSeekOrigin): Int64;
begin
  Result := 0;
  raise EStreamError.Create('the body stream is not seekable');
end;

function TReaderStream.GetSize: Int64;
begin
  Result := 0;
  raise EStreamError.Create('the body stream has no size');
end;

{ TBodyReaderBase }

function TBodyReaderBase.ReadChunk(const ABuffer: TStream): Boolean;
var
  LChunk: array[0..cReadChunkBytes - 1] of Byte;
  LCount: Integer;
begin
  LCount := Read(LChunk[0], cReadChunkBytes);
  if (LCount < 0) or (LCount > cReadChunkBytes) then
    raise EBodyFormatError.Create('a body reader gave a count out of range');
  Result := LCount > 0;
  if Result then
    ABuffer.WriteBuffer(LChunk[0], LCount);
end;

function TBodyReaderBase.GetStream: TStream;
begin
  Result := BodyStream(Self);
end;

function TBodyReaderBase.GetStreamReader: TStreamReader;
begin
  Result := BodyStreamReader(Self);
end;

procedure ChunkAppend(const ABuffer: TStream; const AData: TBytes);
begin
  if Length(AData) > 0 then
    ABuffer.WriteBuffer(AData[0], Length(AData));
end;

procedure ChunkAppendText(const ABuffer: TStream; const AText: UTF8String);
begin
  if Length(AText) > 0 then
    ABuffer.WriteBuffer(AText[1], Length(AText));
end;

function ChunkBytes(const ABuffer: TChunkBuffer): TBytes;
begin
  Result := nil;
  SetLength(Result, ABuffer.Size);
  if ABuffer.Size > 0 then
    Move(ABuffer.Memory^, Result[0], ABuffer.Size);
end;

function ReadAllBody(AReader: IBodyReader; AMax: Int64 = 0): TBytes;
var
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  LBuffer := TChunkBuffer.Create;
  try
    // the octets of the last call are part of the body, so they are checked and kept
    repeat
      LMore := AReader.ReadChunk(LBuffer);
      if (AMax > 0) and (LBuffer.Size > AMax) then
        raise EBodyTooLarge.CreateFmt('the body is longer than %d octets', [AMax]);
    until not LMore;
    Result := ChunkBytes(LBuffer);
  finally
    LBuffer.Free;
  end;
end;

procedure CopyBody(AReader: IBodyReader; ADest: TStream);
var
  LBuffer: TChunkBuffer;
  LMore: Boolean;
begin
  LBuffer := TChunkBuffer.Create;
  try
    repeat
      LBuffer.Reset;
      LMore := AReader.ReadChunk(LBuffer);
      if LBuffer.Size > 0 then
        ADest.WriteBuffer(LBuffer.Memory^, LBuffer.Size);
    until not LMore;
  finally
    LBuffer.Free;
  end;
end;

function BodyStream(const AReader: IBodyReader): TStream;
begin
  Result := TReaderStream.Create(AReader, False);
end;

function BodyStreamReader(const AReader: IBodyReader): TStreamReader;
var
  LStream: TStream;
begin
  LStream := BodyStream(AReader);
  try
    Result := TStreamReader.Create(LStream, cReadChunkBytes, True);
  except
    LStream.Free;
    raise;
  end;
end;

end.
