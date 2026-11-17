{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer
notes:
  - This unit holds the body writer interface that the server and the client share.
  - The library owns the chunk buffer. A writer writes one chunk into it for each call.
  - TChunkBuffer keeps its memory between chunks. It is not thread safe.
---
}
unit Http2.Common.Body;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

type
  /// a pulled body: the library calls NextChunk until it returns False
  // - the library passes the same stream for every call of one body
  // - on entry the stream is empty (Size = 0, Position = 0)
  // - the writer writes the chunk at the current position; [0, Size) is the chunk
  // - the writer does not keep a reference to the stream after the call
  // - the writer does not seek before the place where it began
  // - the library reads a chunk through Size, never through Position (D22)
  // - a chunk of Size = 0 is an empty chunk
  // - octets that a call writes before it returns False are ignored
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

/// append AData to ABuffer at its position
// - an empty array writes nothing
procedure ChunkAppend(const ABuffer: TStream; const AData: TBytes);

/// append the octets of AText (UTF-8) to ABuffer at its position
// - an empty text writes nothing
procedure ChunkAppendText(const ABuffer: TStream; const AText: UTF8String);

/// the octets in [0, Size) of ABuffer as a new array (D25)
function ChunkBytes(const ABuffer: TChunkBuffer): TBytes;

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
  SetLength(Result, ABuffer.Size);
  if ABuffer.Size > 0 then
    Move(ABuffer.Memory^, Result[0], ABuffer.Size);
end;

end.
