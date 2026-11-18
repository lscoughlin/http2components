{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, stream, pushback, serialized body
notes:
  - This unit holds TReaderStream, a read-only stream over an IBodyReader with a pushback buffer.
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
