{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, receive queue, flow control
notes:
  - This unit holds the receive queue of one stream. Its byte cap bounds the DATA that a stream holds.
  - Push never blocks. A push that passes the byte cap or the frame count cap raises EHttpStreamError with ecFlowControlError.
  - The queue is a single-producer single-consumer ring and an atomic byte counter. Push, TryPop and WaitForItem take no lock.
---
}
unit Http2.Client.Stream.Receive;

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Http2.Common.Frames, Http2.Common.Errors,
  Http2.Common.SpscRing;

const
  /// The largest number of frames that a receive queue holds. The value is
  // the capacity of the ring, so it is a power of two.
  // - Only DATA frames count against the byte cap. A stream that receives
  //   many frames with no payload (empty DATA, PING-like noise on the stream,
  //   small HEADERS) would otherwise fill the ring and not the byte cap.
  // - At the default byte cap (1 MiB) and the default frame size (16384 bytes)
  //   the byte cap holds 64 DATA frames, so 1024 frames never limit a peer
  //   that sends full frames. A peer that sends DATA frames of 1024 bytes or
  //   more is stopped by the byte cap first.
  // - A slot holds one TFrame record, so the ring of one stream costs this
  //   number times the size of that record, also when the queue is empty.
  //   The number is kept small for that reason.
  // - A push past the cap is a stream error of the same kind as a push past
  //   the byte cap (ecFlowControlError).
  cReceiveQueueFrameCap = 1024;

type
  /// a queue of received frames with a byte cap on the DATA it holds
  // - the byte count is the sum of DataLength of the DATA frames in the queue
  // - the other frame types never count against the byte cap, but every frame
  //   counts against cReceiveQueueFrameCap
  // - one producer thread (the reader) and one consumer thread at a time; the
  //   consumer can change from one thread to another after a hand-off that
  //   has a barrier (for example the start of a thread)
  // - Shutdown and IsShutdown are safe from any thread
  TByteBoundedFrameQueue = class
  private
    FItems: TSpscRing<TFrame>;
    FMaxBytes: Int64;
    // 64-bit and aligned: the first Int64 field of the class
    FQueuedBytes: Int64;
    {$IFDEF CPU32}
    // leaf lock: only the byte counter uses it, for a few instructions
    FCounterLock: TCriticalSection;
    {$ENDIF}
    function ReadBytes: Int64;
    function TryReserve(const ASize: Int64): Boolean;
    procedure ReleaseBytes(const ASize: Int64);
    class function FrameBytes(const AItem: TFrame): Int64; static;
  public
    constructor Create(const AMaxBytes: Int64);
    destructor Destroy; override;
    /// add a frame; raises EHttpStreamError when the DATA would pass MaxBytes
    // or when the queue holds cReceiveQueueFrameCap frames
    // - a frame pushed after Shutdown is dropped without a raise
    // - never blocks; the producer thread only
    procedure Push(const AItem: TFrame);
    /// return a frame only if one is already queued (never blocks)
    function TryPop(out AItem: TFrame): Boolean;
    /// block until a frame is queued, the queue shuts down or the time runs out
    function WaitForItem(const ATimeoutMs: Integer): Boolean;
    /// wake every blocked waiter; a later Push is dropped; any thread
    procedure Shutdown;
    function IsShutdown: Boolean;
    /// the sum of DataLength of the DATA frames in the queue
    property QueuedBytes: Int64 read ReadBytes;
    property MaxBytes: Int64 read FMaxBytes;
  end;

implementation

{ TByteBoundedFrameQueue }

constructor TByteBoundedFrameQueue.Create(const AMaxBytes: Int64);
begin
  inherited Create;
  FItems := TSpscRing<TFrame>.Create(cReceiveQueueFrameCap);
  FMaxBytes := AMaxBytes;
  FQueuedBytes := 0;
  {$IFDEF CPU32}
  FCounterLock := TCriticalSection.Create;
  {$ENDIF}
end;

destructor TByteBoundedFrameQueue.Destroy;
begin
  FItems.Free;
  {$IFDEF CPU32}
  FCounterLock.Free;
  {$ENDIF}
  inherited Destroy;
end;

class function TByteBoundedFrameQueue.FrameBytes(const AItem: TFrame): Int64;
begin
  if AItem.Header.FrameType = ftData then
    Result := Int64(AItem.DataLength)
  else
    Result := 0;
end;

function TByteBoundedFrameQueue.ReadBytes: Int64;
begin
  {$IFDEF CPU32}
  FCounterLock.Acquire;
  try
    Result := FQueuedBytes;
  finally
    FCounterLock.Release;
  end;
  {$ELSE}
  // an atomic read: an add of 0
  Result := InterlockedExchangeAdd64(FQueuedBytes, 0);
  {$ENDIF}
end;

function TByteBoundedFrameQueue.TryReserve(const ASize: Int64): Boolean;
{$IFNDEF CPU32}
var
  Old: Int64;
{$ENDIF}
begin
  {$IFDEF CPU32}
  FCounterLock.Acquire;
  try
    Result := FQueuedBytes + ASize <= FMaxBytes;
    if Result then
      Inc(FQueuedBytes, ASize);
  finally
    FCounterLock.Release;
  end;
  {$ELSE}
  // the check and the add are one compare-and-exchange, so two pushes cannot
  // both pass the cap
  repeat
    Old := InterlockedExchangeAdd64(FQueuedBytes, 0);
    if Old + ASize > FMaxBytes then
      Exit(False);
  until InterlockedCompareExchange64(FQueuedBytes, Old + ASize, Old) = Old;
  Result := True;
  {$ENDIF}
end;

procedure TByteBoundedFrameQueue.ReleaseBytes(const ASize: Int64);
begin
  {$IFDEF CPU32}
  FCounterLock.Acquire;
  try
    Dec(FQueuedBytes, ASize);
  finally
    FCounterLock.Release;
  end;
  {$ELSE}
  InterlockedExchangeAdd64(FQueuedBytes, -ASize);
  {$ENDIF}
end;

procedure TByteBoundedFrameQueue.Push(const AItem: TFrame);
var
  Size: Int64;
begin
  if FItems.IsShutdown then
    Exit;
  Size := FrameBytes(AItem);
  // the bytes are counted before the frame is in the ring, so the consumer
  // never subtracts bytes that are not counted: the counter is never negative
  if not TryReserve(Size) then
    raise EHttpStreamError.Create('receive queue of the stream is full',
      0, ecFlowControlError);
  if not FItems.TryPush(AItem) then
  begin
    ReleaseBytes(Size);
    // False means a shutdown (drop the frame) or a full ring (the frame cap)
    if FItems.IsShutdown then
      Exit;
    raise EHttpStreamError.Create('receive queue of the stream is full',
      0, ecFlowControlError);
  end;
end;

function TByteBoundedFrameQueue.TryPop(out AItem: TFrame): Boolean;
begin
  Result := FItems.TryPop(AItem);
  if Result then
    ReleaseBytes(FrameBytes(AItem));
end;

function TByteBoundedFrameQueue.WaitForItem(const ATimeoutMs: Integer): Boolean;
begin
  Result := FItems.WaitForItem(ATimeoutMs);
end;

procedure TByteBoundedFrameQueue.Shutdown;
begin
  FItems.Shutdown;
end;

function TByteBoundedFrameQueue.IsShutdown: Boolean;
begin
  Result := FItems.IsShutdown;
end;

end.
