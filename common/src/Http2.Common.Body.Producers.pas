{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, body_producer, stream, text, chunk sink
notes:
  - This unit turns code that writes to a TStream or a TStreamWriter into the body of an IBodyWriter.
  - The producer stream keeps one chunk back, so the sink knows the last chunk (ALast).
  - A place that pulls the writer with NextChunk gets the body from a memory buffer (the fallback).
---
}
unit Http2.Common.Body.Producers;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, streamex, Http2.Common.Body;

type
  /// the method that writes a body to a stream
  // - the method writes its octets to AOut and does not keep AOut after it returns
  TStreamProducer = procedure(const AOut: TStream) of object;

  /// the method that writes a body to a text writer
  // - the octets of the text, in the encoding of the writer, are the octets of the body
  TTextProducer = procedure(const AOut: TStreamWriter) of object;

  /// a write-only stream that gives its octets to a body sink in chunks
  // - Write appends the octets to the current chunk
  // - a full chunk of AChunkBytes becomes the pending chunk
  // - when a chunk becomes pending, the previous pending chunk goes to the sink with ALast False
  //   (one chunk of look-ahead, so the last chunk is known when Finish runs)
  // - the sink call blocks, so Write blocks (backpressure)
  // - Read, SetSize and Seek raise EStreamError; Seek(0, soCurrent) gives the count written
  // - Finish sends the held octets; the last chunk comes with ALast True
  // - a Write after Finish raises EStreamError
  // - after a sink failure, Write drops its octets and Finish raises EStreamError
  // - Abort stops the stream: Write drops its octets and nothing more is sent
  // - Destroy never calls the sink
  // - not thread safe: one thread writes at a time
  TProducerStream = class(TStream)
  private
    FSink: IBodyChunkSink;
    FChunkBytes: Integer;
    FCurrent: TChunkBuffer;
    FPending: TChunkBuffer;
    FHasPending: Boolean;
    FWritten: Int64;
    FFinished: Boolean;
    FAborted: Boolean;
    procedure SendFullChunk;
    procedure SendChunk(const ABuffer: TChunkBuffer; const ALast: Boolean);
  public
    /// create a stream that gives its chunks to ASink; AChunkBytes is the largest chunk
    constructor Create(const ASink: IBodyChunkSink; const AChunkBytes: Integer = cReadChunkBytes);
    destructor Destroy; override;
    /// raises EStreamError: the stream is write only
    function Read(var Buffer; Count: Longint): Longint; override;
    /// append Count octets to the body; the call blocks while the sink takes a chunk
    function Write(const Buffer; Count: Longint): Longint; override;
    /// Seek(0, soCurrent) gives the count of the octets written; other seeks raise EStreamError
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    /// raises EStreamError: the size of a body is not set
    procedure SetSize(NewSize: Longint); override;
    /// raises EStreamError: the size of a body is not set
    procedure SetSize(const NewSize: Int64); override;
    /// send the held octets with the last chunk; a second call does nothing
    procedure Finish;
    /// stop the stream; no chunk is sent after this call
    procedure Abort;
  end;

  /// the state of a producer body; a body is run once
  TProducerRun = (prNew, prProduced, prPulled, prFailed);

  /// the body writer that the factories make; it is a producer and a pulled writer
  // - Produce runs the producer to its end on the calling thread
  // - NextChunk runs the producer into memory on the first call (the buffered fallback),
  //   and then gives the octets at most cReadChunkBytes at a time
  // - the last octets come with False; the memory is freed then
  // - a producer body is used once: a second run (Produce, or the first NextChunk after
  //   a Produce, or Produce after NextChunk) raises EBodyFormatError
  // - a producer that fails leaves the body in the failed state; the body does not end normally
  TProducerBodyWriter = class(TInterfacedObject, IBodyWriter, IBodyProducer)
  private
    FStreamProducer: TStreamProducer;
    FTextProducer: TTextProducer;
    FEncoding: TEncoding;
    FChunkBytes: Integer;
    FState: TProducerRun;
    FBuffer: TMemoryStream;
    procedure RunProducer(const ASink: IBodyChunkSink);
    procedure WriteWith(const AStream: TProducerStream);
    procedure StartPull;
  public
    /// create a body for a producer that writes to a stream
    constructor CreateStream(const AProducer: TStreamProducer; const AChunkBytes: Integer);
    /// create a body for a producer that writes text in AEncoding
    constructor CreateText(const AProducer: TTextProducer; const AEncoding: TEncoding;
      const AChunkBytes: Integer);
    destructor Destroy; override;
    /// write the next chunk into ABuffer; False when the body is over
    function NextChunk(const ABuffer: TStream): Boolean;
    /// run the producer to its end and give each chunk to ASink
    procedure Produce(const ASink: IBodyChunkSink);
  end;

/// a body writer for a producer that writes its octets to a stream
// - AProducer writes the body to the stream that it gets; the stream gives the chunks to the place
// - AChunkBytes is the largest chunk that the stream sends; it is at least 1
// - AProducer must not be nil; a nil producer raises EBodyFormatError
function BodyWriterFromStream(const AProducer: TStreamProducer;
  const AChunkBytes: Integer = cReadChunkBytes): IBodyWriter;

/// a body writer for a producer that writes text to a stream writer
// - AEncoding nil means UTF-8 without a byte order mark
// - the writer writes no preamble; AEncoding is not freed, and it must live as long as the body
// - AProducer must not be nil; a nil producer raises EBodyFormatError
function BodyWriterFromTextWriter(const AProducer: TTextProducer;
  const AEncoding: TEncoding = nil; const AChunkBytes: Integer = cReadChunkBytes): IBodyWriter;

implementation

type
  /// a text writer whose flush writes the buffered octets to the producer stream
  // - the Flush of FPC 3.2.4 passes its buffer array to WriteBuffer, so it writes the
  //   bytes of the array reference and not the text; this class writes the octets itself
  TBodyTextWriter = class(TStreamWriter)
  private
    FTarget: TStream;
  public
    constructor Create(const ATarget: TStream; const AEncoding: TEncoding);
    procedure Flush; override;
  end;

  /// a sink that writes the chunks of a body into a stream
  TCollectSink = class(TInterfacedObject, IBodyChunkSink)
  private
    FTarget: TStream;
  public
    constructor Create(const ATarget: TStream);
    procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
  end;

{ TBodyTextWriter }

constructor TBodyTextWriter.Create(const ATarget: TStream; const AEncoding: TEncoding);
begin
  inherited Create(ATarget, AEncoding, 1024);
  FTarget := ATarget;
end;

procedure TBodyTextWriter.Flush;
var
  LCount: Integer;
begin
  LCount := FBufferIndex;
  if LCount > 0 then
  begin
    FBufferIndex := 0;
    FTarget.WriteBuffer(FBuffer[0], LCount);
  end;
end;

{ TCollectSink }

constructor TCollectSink.Create(const ATarget: TStream);
begin
  inherited Create;
  FTarget := ATarget;
end;

procedure TCollectSink.Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
begin
  if ACount > 0 then
    FTarget.WriteBuffer(ABuffer, ACount);
end;

{ TProducerStream }

constructor TProducerStream.Create(const ASink: IBodyChunkSink; const AChunkBytes: Integer);
begin
  inherited Create;
  if (ASink = nil) or (AChunkBytes < 1) then
    raise EBodyFormatError.Create('a producer stream needs a sink and a chunk of at least 1 octet');
  FSink := ASink;
  FChunkBytes := AChunkBytes;
  FCurrent := TChunkBuffer.Create;
  FPending := TChunkBuffer.Create;
  FHasPending := False;
  FWritten := 0;
  FFinished := False;
  FAborted := False;
end;

destructor TProducerStream.Destroy;
begin
  FCurrent.Free;
  FPending.Free;
  inherited Destroy;
end;

function TProducerStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
  raise EStreamError.Create('a producer stream is write only');
end;

function TProducerStream.Write(const Buffer; Count: Longint): Longint;
var
  LFrom: PByte;
  LLeft: Integer;
  LPart: Integer;
begin
  if FFinished then
    raise EStreamError.Create('a producer stream is written after its end');
  if FAborted then
  begin
    // the sink has failed or the stream was aborted: the octets are dropped
    if Count > 0 then
      Result := Count
    else
      Result := 0;
    Exit;
  end;
  Result := 0;
  if Count <= 0 then
    Exit;
  LFrom := @Buffer;
  LLeft := Count;
  while LLeft > 0 do
  begin
    LPart := FChunkBytes - Integer(FCurrent.Size);
    if LPart > LLeft then
      LPart := LLeft;
    FCurrent.WriteBuffer(LFrom^, LPart);
    Inc(LFrom, LPart);
    Dec(LLeft, LPart);
    if FCurrent.Size >= FChunkBytes then
      SendFullChunk;
  end;
  Inc(FWritten, Count);
  Result := Count;
end;

function TProducerStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then
    Result := FWritten
  else
    raise EStreamError.Create('a producer stream can not seek');
end;

procedure TProducerStream.SetSize(NewSize: Longint);
begin
  raise EStreamError.Create('a producer stream has no size');
end;

procedure TProducerStream.SetSize(const NewSize: Int64);
begin
  raise EStreamError.Create('a producer stream has no size');
end;

procedure TProducerStream.SendFullChunk;
var
  LSwap: TChunkBuffer;
begin
  // the previous pending chunk goes out now that a newer chunk is full
  if FHasPending then
    SendChunk(FPending, False);
  LSwap := FPending;
  FPending := FCurrent;
  FCurrent := LSwap;
  FCurrent.Reset;
  FHasPending := True;
end;

procedure TProducerStream.SendChunk(const ABuffer: TChunkBuffer; const ALast: Boolean);
var
  LCount: Integer;
  LNone: Byte;
begin
  LCount := Integer(ABuffer.Size);
  LNone := 0;
  try
    if LCount > 0 then
      FSink.Chunk(PByte(ABuffer.Memory)^, LCount, ALast)
    else
      FSink.Chunk(LNone, 0, ALast);
  except
    // the body can not go on: later writes drop their octets and Finish raises
    FAborted := True;
    raise;
  end;
end;

procedure TProducerStream.Finish;
begin
  if FFinished then
    Exit;
  FFinished := True;
  if FAborted then
    raise EStreamError.Create('the body sink failed before the end of the body');
  if FHasPending and (FCurrent.Size = 0) then
    SendChunk(FPending, True)
  else
  begin
    if FHasPending then
      SendChunk(FPending, False);
    // when nothing was written at all, this sends one empty last chunk
    SendChunk(FCurrent, True);
  end;
end;

procedure TProducerStream.Abort;
begin
  FAborted := True;
end;

{ TProducerBodyWriter }

constructor TProducerBodyWriter.CreateStream(const AProducer: TStreamProducer;
  const AChunkBytes: Integer);
begin
  inherited Create;
  FStreamProducer := AProducer;
  FChunkBytes := AChunkBytes;
  FState := prNew;
end;

constructor TProducerBodyWriter.CreateText(const AProducer: TTextProducer;
  const AEncoding: TEncoding; const AChunkBytes: Integer);
begin
  inherited Create;
  FTextProducer := AProducer;
  FEncoding := AEncoding;
  FChunkBytes := AChunkBytes;
  FState := prNew;
end;

destructor TProducerBodyWriter.Destroy;
begin
  FreeAndNil(FBuffer);
  inherited Destroy;
end;

procedure TProducerBodyWriter.WriteWith(const AStream: TProducerStream);
var
  LWriter: TStreamWriter;
begin
  if not Assigned(FTextProducer) then
  begin
    FStreamProducer(AStream);
    Exit;
  end;
  LWriter := TBodyTextWriter.Create(AStream, FEncoding);
  try
    try
      FTextProducer(LWriter);
    except
      // the writer holds octets that must not be sent: Abort stops its flush in Free
      AStream.Abort;
      raise;
    end;
    LWriter.Flush;
  finally
    LWriter.Free;
  end;
end;

procedure TProducerBodyWriter.RunProducer(const ASink: IBodyChunkSink);
var
  LStream: TProducerStream;
begin
  LStream := TProducerStream.Create(ASink, FChunkBytes);
  try
    WriteWith(LStream);
    LStream.Finish;
  finally
    LStream.Free;
  end;
end;

procedure TProducerBodyWriter.Produce(const ASink: IBodyChunkSink);
begin
  if FState <> prNew then
    raise EBodyFormatError.Create('a producer body is used once');
  FState := prFailed;
  RunProducer(ASink);
  FState := prProduced;
end;

procedure TProducerBodyWriter.StartPull;
var
  LSink: IBodyChunkSink;
begin
  FState := prFailed;
  FBuffer := TMemoryStream.Create;
  try
    LSink := TCollectSink.Create(FBuffer);
    RunProducer(LSink);
  except
    FreeAndNil(FBuffer);
    raise;
  end;
  // the sink wrote to the end of the buffer; the pull reads it from the start
  FBuffer.Position := 0;
  FState := prPulled;
end;

function TProducerBodyWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  LCount: Int64;
begin
  if FState = prNew then
    StartPull;
  if FState <> prPulled then
    raise EBodyFormatError.Create('a producer body is used once');
  if FBuffer = nil then
  begin
    // the body has ended before: it gives the end again
    Result := False;
    Exit;
  end;
  LCount := FBuffer.Size - FBuffer.Position;
  if LCount > cReadChunkBytes then
    LCount := cReadChunkBytes;
  if LCount > 0 then
    ABuffer.CopyFrom(FBuffer, LCount);
  // the octets of this call are the last ones when no octet is left
  Result := FBuffer.Position < FBuffer.Size;
  if not Result then
    FreeAndNil(FBuffer);
end;

{ module routines }

function BodyWriterFromStream(const AProducer: TStreamProducer;
  const AChunkBytes: Integer): IBodyWriter;
begin
  if not Assigned(AProducer) then
    raise EBodyFormatError.Create('the producer of a body is nil');
  if AChunkBytes < 1 then
    raise EBodyFormatError.Create('a chunk holds at least one octet');
  Result := TProducerBodyWriter.CreateStream(AProducer, AChunkBytes);
end;

function BodyWriterFromTextWriter(const AProducer: TTextProducer;
  const AEncoding: TEncoding; const AChunkBytes: Integer): IBodyWriter;
var
  LEncoding: TEncoding;
begin
  if not Assigned(AProducer) then
    raise EBodyFormatError.Create('the producer of a body is nil');
  if AChunkBytes < 1 then
    raise EBodyFormatError.Create('a chunk holds at least one octet');
  LEncoding := AEncoding;
  if LEncoding = nil then
    LEncoding := TEncoding.UTF8;
  Result := TProducerBodyWriter.CreateText(AProducer, LEncoding, AChunkBytes);
end;

end.
