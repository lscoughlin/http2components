{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, body_reader
notes:
  - This unit holds the body writer and body reader interfaces that the server and the client share.
  - The library owns the chunk buffer. A writer writes one chunk into it for each call.
  - TChunkBuffer keeps its memory between chunks. It is not thread safe.
  - A reader gives one chunk for each ReadChunk call. The helpers read a body to its end.
---
}
unit Http2.Common.Body;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

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
  end;

  /// the base class of a body reader; ReadChunk does one Read of at most cReadChunkBytes
  // - a descendant implements Read
  // - a reader with natural chunks overrides ReadChunk
  TBodyReaderBase = class(TInterfacedObject, IBodyReader)
  public
    /// read at most ACount octets into ABuffer; 0 means that the body has ended
    function Read(var ABuffer; const ACount: Integer): Integer; virtual; abstract;
    /// append one Read of at most cReadChunkBytes to ABuffer; False when Read gave 0
    function ReadChunk(const ABuffer: TStream): Boolean; virtual;
  end;

  /// raised when a body is longer than the limit that the caller gave
  EBodyTooLarge = class(Exception);

  /// raised when a body does not have the format that its reader expects,
  /// or when a body reader answers a count that is out of range
  EBodyFormatError = class(Exception);

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

implementation

procedure TChunkBuffer.Reset;
begin
  // SetPointer keeps the allocation. SetSize(0) or Clear would free it.
  SetPointer(Memory, 0);
  Position := 0;
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

end.
