{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, inbound message, body reader, pipe, back pressure
notes:
  - This unit holds the two readers that give a WebSocket message to a handler as an
    IBodyReader. A TWsMemoryReader serves a message that ended inside the inline limit.
    A TWsMessagePipe serves a message that is larger and still arrives.
  - The IO thread writes into the pipe with Push, Finish and Abort. One handler
    thread reads. Push never waits. The lock of the pipe is a leaf lock: no
    code that holds it takes another lock, and no callback runs while it is held.
  - Read waits on an event with no lock held. A read that gets no octet for the
    stall time aborts the pipe and raises EStreamCancelled.
  - The pipe reports the octets that leave it, read by the handler or dropped, to a
    callback of the owner. The owner returns receive credit for them. The callback runs
    on the thread of the caller, after the lock is released.
  - A push that takes the buffered octets over the cap refuses the octets and
    aborts the pipe. The owner closes the session.
---
}
/// The readers that give a WebSocket message to a handler
unit Http2.Server.WebSocket.Inbound;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2.Common.Body, Http2.Server.Errors;

type
  /// the pipe tells its owner how many octets left it: the handler read them or the
  /// pipe dropped them; the call comes with no lock held
  TWsPipeTaken = procedure(const ACount: Integer) of object;

  /// the pipe tells its owner about an event; the call comes with no lock held
  TWsPipeNotice = procedure of object;

  /// a message that ended inside the inline limit
  TWsMemoryReader = class(TBodyReaderBase)
  private
    FData: TBytes;
    FPos: Integer;
  public
    constructor Create(const AData: TBytes);
    function Read(var ABuffer; const ACount: Integer): Integer; override;
    /// the octets that remain are one chunk
    function ReadChunk(const ABuffer: TStream): Boolean; override;
  end;

  /// the octets of a message that is still arriving
  // - one IO thread calls Push, Finish and Abort; one handler thread reads
  TWsMessagePipe = class(TBodyReaderBase)
  private
    FLock: TCriticalSection;
    FEvent: PRTLEvent;
    FChunks: TQueue<TBytes>;
    FHeadOffset: Integer;
    FBuffered: Integer;
    FCap: Integer;
    FStallMs: Integer;
    FFinished: Boolean;
    FAborted: Boolean;
    FOverflowed: Boolean;
    FStalled: Boolean;
    FOnTaken: TWsPipeTaken;
    FOnStalled: TWsPipeNotice;
    function GetBuffered: Integer;
    function GetOverflowed: Boolean;
    function GetStalled: Boolean;
    function GetAborted: Boolean;
    /// wait until octets are there; copy up to ACount octets to ABuffer, or, when
    /// ABuffer is nil, move the next chunk to AChunk; 0 means the end
    function Fetch(const ABuffer: Pointer; const ACount: Integer;
      out AChunk: TBytes): Integer;
    procedure Stall;
  public
    /// ACap is the greatest count of buffered octets; AStallMs is the time that a read
    /// waits for an octet before it gives up (0 waits for ever)
    constructor Create(const ACap, AStallMs: Integer; const AOnTaken: TWsPipeTaken;
      const AOnStalled: TWsPipeNotice);
    destructor Destroy; override;
    /// append the octets; never waits; False when the octets did not fit under the cap:
    /// the pipe is then aborted and the octets are dropped
    function Push(const AData; const ACount: Integer): Boolean;
    /// the message is complete: a read gives the octets that remain and then the end
    procedure Finish;
    /// the message will not complete: a read raises EStreamCancelled; the buffered
    // octets are dropped; a finished pipe ignores the call
    procedure Abort;
    /// the owner no longer takes calls; the pipe stays valid for a reader that holds it
    procedure Detach;
    function Read(var ABuffer; const ACount: Integer): Integer; override;
    /// the next buffered chunk, as it was pushed, or the rest of a chunk that a Read began
    function ReadChunk(const ABuffer: TStream): Boolean; override;
    /// the pipe was aborted: by Abort, by an overflow or by a stall
    property Aborted: Boolean read GetAborted;
    property Overflowed: Boolean read GetOverflowed;
    property Stalled: Boolean read GetStalled;
    /// the octets that wait for the handler
    property Buffered: Integer read GetBuffered;
  end;

implementation

{ TWsMemoryReader }

constructor TWsMemoryReader.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
end;

function TWsMemoryReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := Length(FData) - FPos;
  if Result > ACount then
    Result := ACount;
  if Result <= 0 then
    Exit(0);
  Move(FData[FPos], ABuffer, Result);
  Inc(FPos, Result);
end;

function TWsMemoryReader.ReadChunk(const ABuffer: TStream): Boolean;
var
  Left: Integer;
begin
  Left := Length(FData) - FPos;
  Result := Left > 0;
  if Result then
  begin
    ABuffer.WriteBuffer(FData[FPos], Left);
    FPos := Length(FData);
  end;
end;

{ TWsMessagePipe }

constructor TWsMessagePipe.Create(const ACap, AStallMs: Integer;
  const AOnTaken: TWsPipeTaken; const AOnStalled: TWsPipeNotice);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEvent := RTLEventCreate;
  FChunks := TQueue<TBytes>.Create;
  FCap := ACap;
  FStallMs := AStallMs;
  FOnTaken := AOnTaken;
  FOnStalled := AOnStalled;
end;

destructor TWsMessagePipe.Destroy;
begin
  FChunks.Free;
  RTLEventDestroy(FEvent);
  FLock.Free;
  inherited Destroy;
end;

function TWsMessagePipe.GetBuffered: Integer;
begin
  FLock.Acquire;
  try
    Result := FBuffered;
  finally
    FLock.Release;
  end;
end;

function TWsMessagePipe.GetOverflowed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FOverflowed;
  finally
    FLock.Release;
  end;
end;

function TWsMessagePipe.GetStalled: Boolean;
begin
  FLock.Acquire;
  try
    Result := FStalled;
  finally
    FLock.Release;
  end;
end;

function TWsMessagePipe.GetAborted: Boolean;
begin
  FLock.Acquire;
  try
    Result := FAborted;
  finally
    FLock.Release;
  end;
end;

function TWsMessagePipe.Push(const AData; const ACount: Integer): Boolean;
var
  Chunk: TBytes;
  Taken: TWsPipeTaken;
  Drop: Integer;
begin
  Result := True;
  if ACount <= 0 then
    Exit;
  Drop := 0;
  FLock.Acquire;
  try
    Taken := FOnTaken;
    if FAborted or FFinished then
      Drop := ACount
    else if Int64(FBuffered) + ACount > FCap then
    begin
      // the handler reads too slowly for a channel that cannot slow its peer
      FOverflowed := True;
      FAborted := True;
      Drop := FBuffered + ACount;
      FBuffered := 0;
      FHeadOffset := 0;
      FChunks.Clear;
      Result := False;
    end
    else
    begin
      SetLength(Chunk, ACount);
      Move(AData, Chunk[0], ACount);
      FChunks.Enqueue(Chunk);
      Inc(FBuffered, ACount);
    end;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FEvent);
  // a dropped octet is credited at once, so the peer is not slowed for it
  if (Drop > 0) and Assigned(Taken) then
    Taken(Drop);
end;

procedure TWsMessagePipe.Finish;
begin
  FLock.Acquire;
  try
    FFinished := True;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FEvent);
end;

procedure TWsMessagePipe.Abort;
var
  Dropped: Integer;
  Taken: TWsPipeTaken;
begin
  Dropped := 0;
  FLock.Acquire;
  try
    Taken := FOnTaken;
    // a finished pipe stays readable, and an aborted pipe has nothing left to drop
    if FFinished or FAborted then
      Exit;
    FAborted := True;
    Dropped := FBuffered;
    FBuffered := 0;
    FHeadOffset := 0;
    FChunks.Clear;
  finally
    FLock.Release;
  end;
  RTLEventSetEvent(FEvent);
  if (Dropped > 0) and Assigned(Taken) then
    Taken(Dropped);
end;

procedure TWsMessagePipe.Detach;
begin
  FLock.Acquire;
  try
    FOnTaken := nil;
    FOnStalled := nil;
  finally
    FLock.Release;
  end;
end;

procedure TWsMessagePipe.Stall;
var
  Notice: TWsPipeNotice;
begin
  FLock.Acquire;
  try
    Notice := FOnStalled;
    FStalled := True;
  finally
    FLock.Release;
  end;
  Abort;
  if Assigned(Notice) then
    Notice;
  raise EStreamCancelled.Create('the message stalled');
end;

function TWsMessagePipe.Fetch(const ABuffer: Pointer; const ACount: Integer;
  out AChunk: TBytes): Integer;
var
  Taken: TWsPipeTaken;
  Start, Waited: QWord;
  Chunk: TBytes;
  Avail: Integer;
begin
  AChunk := nil;
  Start := GetTickCount64;
  while True do
  begin
    Result := 0;
    Taken := nil;
    FLock.Acquire;
    try
      if FAborted then
        raise EStreamCancelled.Create('the message was cancelled');
      if FChunks.Count > 0 then
      begin
        Chunk := FChunks.Peek;
        Avail := Length(Chunk) - FHeadOffset;
        if ABuffer <> nil then
        begin
          if Avail > ACount then
            Avail := ACount;
          Move(Chunk[FHeadOffset], ABuffer^, Avail);
          Inc(FHeadOffset, Avail);
          if FHeadOffset >= Length(Chunk) then
          begin
            FChunks.Dequeue;
            FHeadOffset := 0;
          end;
        end
        else
        begin
          // a whole chunk moves with no copy; the rest of a chunk is copied
          if FHeadOffset = 0 then
            AChunk := Chunk
          else
            AChunk := Copy(Chunk, FHeadOffset, Avail);
          FChunks.Dequeue;
          FHeadOffset := 0;
        end;
        Dec(FBuffered, Avail);
        Taken := FOnTaken;
        Result := Avail;
      end
      else if FFinished then
        Exit(0);
    finally
      FLock.Release;
    end;
    if Result > 0 then
    begin
      // the credit goes out with no lock held: the IO thread holds the channel lock
      // and takes the lock of the pipe, so this thread must not do the reverse
      if Assigned(Taken) then
        Taken(Result);
      Exit;
    end;
    if FStallMs > 0 then
    begin
      Waited := GetTickCount64 - Start;
      if Waited >= QWord(FStallMs) then
        Stall;
      RTLEventWaitFor(FEvent, Integer(QWord(FStallMs) - Waited));
    end
    else
      RTLEventWaitFor(FEvent);
  end;
end;

function TWsMessagePipe.Read(var ABuffer; const ACount: Integer): Integer;
var
  None: TBytes;
begin
  if ACount <= 0 then
    Exit(0);
  Result := Fetch(@ABuffer, ACount, None);
end;

function TWsMessagePipe.ReadChunk(const ABuffer: TStream): Boolean;
var
  Chunk: TBytes;
begin
  Result := Fetch(nil, 0, Chunk) > 0;
  if Result then
    ABuffer.WriteBuffer(Chunk[0], Length(Chunk));
end;

end.
