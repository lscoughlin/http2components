{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, stream, pushback, serialized body
notes:
  - This unit keeps the name TReaderStream for code that uses this unit. The class is in Http2.Common.Body.
  - The unit holds TSerializedBodyWriter, the base of the writers that serialize a whole document.
  - A TReaderStream does not seek, does not write and has no size.
  - A serialized writer keeps the document in one memory stream only until the body ends.
---
}
unit Http2.Common.Body.Streams;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Http2.Common.Body;

type
  /// the read-only body stream; the class is TReaderStream of Http2.Common.Body
  // - kept under this name, so that a unit that uses Http2.Common.Body.Streams compiles
  TReaderStream = Http2.Common.Body.TReaderStream;

  /// the base class of a writer that serializes a whole document
  // - Serialize writes the whole body into the stream, and NextChunk calls it once
  // - NextChunk gives the serialized octets cReadChunkBytes at a time
  // - the last chunk comes with False; the memory is freed then
  // - a writer is not thread safe: one thread calls NextChunk at a time
  TSerializedBodyWriter = class(TInterfacedObject, IBodyWriter)
  private
    FData: TMemoryStream;
    FDone: Boolean;
  protected
    /// write the whole body to ATarget; the stream is empty on entry
    procedure Serialize(const ATarget: TStream); virtual; abstract;
  public
    destructor Destroy; override;
    /// write the next chunk into ABuffer; False when the body is over
    function NextChunk(const ABuffer: TStream): Boolean;
  end;

implementation

{ TSerializedBodyWriter }

destructor TSerializedBodyWriter.Destroy;
begin
  FData.Free;
  inherited Destroy;
end;

function TSerializedBodyWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  LCount: Int64;
  LChunk: Integer;
begin
  if FDone then
    Exit(False);
  if FData = nil then
  begin
    FData := TMemoryStream.Create;
    try
      Serialize(FData);
    except
      FreeAndNil(FData);
      FDone := True;
      raise;
    end;
    FData.Position := 0;
  end;
  LCount := FData.Size - FData.Position;
  if LCount > cReadChunkBytes then
    LCount := cReadChunkBytes;
  LChunk := Integer(LCount);
  if LChunk > 0 then
    ABuffer.WriteBuffer(PByte(FData.Memory)[FData.Position], LChunk);
  FData.Position := FData.Position + LChunk;
  Result := FData.Position < FData.Size;
  if not Result then
  begin
    // the body is over: the serialized octets are no longer needed
    FreeAndNil(FData);
    FDone := True;
  end;
end;

end.
