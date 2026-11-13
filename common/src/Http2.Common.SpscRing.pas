{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, queue, spsc, ring, lock-free
notes:
  - This unit holds a fixed-capacity single-producer single-consumer ring.
  - The fast path takes no lock. Exactly one thread pushes and exactly one thread pops at a time.
  - A second producer or a second consumer at the same time raises EInvalidOperation.
  - The ring is correct on a weak memory model (arm64) and on a strong one (x86-64).
---
}
unit Http2.Common.SpscRing;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes;

const
  /// the value of a timeout parameter that means "wait without a deadline"
  cSpscNoTimeout = -1;
  /// the largest capacity of a ring
  cSpscMaxCapacity = 1 shl 30;
  /// The longest single wait. A wake that is missed delays a thread by at
  /// most this time, and a thread then checks the ring again.
  cSpscMaxWaitSliceMs = 100;

type
  TSpscRingHook = procedure of object;

  /// Single-producer single-consumer ring. The names follow
  /// TBlockingQueueState<T>. The producer owns Tail, the consumer owns Head.
  /// Each index is written by one thread only.
  TSpscRing<T> = class
  private
    FSlots: array of T;
    FMask: LongWord;
    FCapacity: LongWord;
    /// written by the consumer thread only
    FHead: LongWord;
    /// written by the producer thread only
    FTail: LongWord;
    FShutdown: LongInt;
    FConsumerParked: LongInt;
    FProducerParked: LongInt;
    FConsumerBusy: LongInt;
    FProducerBusy: LongInt;
    FNotEmpty: PRTLEvent;
    FNotFull: PRTLEvent;
    FOnConsumerEntered: TSpscRingHook;
    FOnProducerEntered: TSpscRingHook;
    procedure EnterConsumer;
    procedure LeaveConsumer;
    procedure EnterProducer;
    procedure LeaveProducer;
    function ShutdownSeen: Boolean;
    function HasItem: Boolean;
    function HasRoom: Boolean;
    procedure Take(out AItem: T);
    procedure Put(const AItem: T);
    function TakeIfAny(out AItem: T): Boolean;
    function AwaitItem(const ATimeoutMs: Integer): Boolean;
    function PushCore(const AItem: T; const ATimeoutMs: Integer): Boolean;
  public
    /// ACapacityPow2 must be a power of two from 1 to cSpscMaxCapacity
    constructor Create(const ACapacityPow2: Integer);
    destructor Destroy; override;
    /// Waits while the ring is full, until room, shutdown or the timeout.
    /// Returns True when the item is in the ring. After Shutdown the item is
    /// dropped and the result is False.
    function Push(const AItem: T; const ATimeoutMs: Integer = cSpscNoTimeout): Boolean;
    /// never waits; False when the ring is full or shut down
    function TryPush(const AItem: T): Boolean;
    /// Waits for an item. Returns False when the ring is empty after Shutdown.
    function Pop(out AItem: T): Boolean;
    /// never waits; False when the ring is empty
    function TryPop(out AItem: T): Boolean;
    /// Waits, without taking the item, until the ring holds an item. Returns
    /// False on shutdown with an empty ring or when the timeout ends.
    function WaitForItem(const ATimeoutMs: Integer): Boolean;
    procedure Shutdown;
    function IsShutdown: Boolean;
    /// items in the ring now (exact only when no other thread works on the ring)
    function Count: Integer;
    function Capacity: Integer;
    /// test seam: a consumer waits for an item now
    function ConsumerParked: Boolean;
    /// test seam: a producer waits for room now
    function ProducerParked: Boolean;
    /// test seam: runs on the consumer thread after the consumer guard is set
    property OnConsumerEntered: TSpscRingHook read FOnConsumerEntered write FOnConsumerEntered;
    /// test seam: runs on the producer thread after the producer guard is set
    property OnProducerEntered: TSpscRingHook read FOnProducerEntered write FOnProducerEntered;
  end;

implementation

constructor TSpscRing<T>.Create(const ACapacityPow2: Integer);
begin
  inherited Create;
  if (ACapacityPow2 < 1) or (ACapacityPow2 > cSpscMaxCapacity) or
    ((ACapacityPow2 and (ACapacityPow2 - 1)) <> 0) then
    raise EArgumentException.Create('the ring capacity must be a power of two');
  FCapacity := LongWord(ACapacityPow2);
  FMask := FCapacity - 1;
  SetLength(FSlots, ACapacityPow2);
  FNotEmpty := RTLEventCreate;
  FNotFull := RTLEventCreate;
end;

destructor TSpscRing<T>.Destroy;
begin
  // SetLength finalizes every managed item that is still in a slot
  SetLength(FSlots, 0);
  // a constructor that refuses its argument runs Destroy with no events
  if FNotEmpty <> nil then
    RTLEventDestroy(FNotEmpty);
  if FNotFull <> nil then
    RTLEventDestroy(FNotFull);
  inherited Destroy;
end;

procedure TSpscRing<T>.EnterConsumer;
begin
  // the exchange returns the old value: 1 means that another consumer is inside
  if InterlockedExchange(FConsumerBusy, 1) <> 0 then
    raise EInvalidOperation.Create('the SPSC ring has a second consumer at the same time');
  if Assigned(FOnConsumerEntered) then
    FOnConsumerEntered();
end;

procedure TSpscRing<T>.LeaveConsumer;
begin
  InterlockedExchange(FConsumerBusy, 0);
end;

procedure TSpscRing<T>.EnterProducer;
begin
  if InterlockedExchange(FProducerBusy, 1) <> 0 then
    raise EInvalidOperation.Create('the SPSC ring has a second producer at the same time');
  if Assigned(FOnProducerEntered) then
    FOnProducerEntered();
end;

procedure TSpscRing<T>.LeaveProducer;
begin
  InterlockedExchange(FProducerBusy, 0);
end;

function TSpscRing<T>.ShutdownSeen: Boolean;
begin
  Result := FShutdown <> 0;
  // read barrier: orders this read of FShutdown before the later read of the
  // index (FTail or FHead) that the caller makes
  ReadBarrier;
end;

function TSpscRing<T>.HasItem: Boolean;
var
  LTail: LongWord;
begin
  LTail := FTail;
  // read barrier: FTail is read before the slot. This pairs with the write
  // barrier of Put, which publishes FTail after the slot is written.
  ReadBarrier;
  Result := LTail <> FHead;
end;

function TSpscRing<T>.HasRoom: Boolean;
var
  LHead: LongWord;
begin
  LHead := FHead;
  // read barrier: FHead is read before the slot is written. This pairs with
  // the write barrier of Take, which publishes FHead after the slot is cleared.
  ReadBarrier;
  Result := (FTail - LHead) < FCapacity;
end;

procedure TSpscRing<T>.Take(out AItem: T);
var
  LHead: LongWord;
begin
  LHead := FHead;
  AItem := FSlots[LHead and FMask];
  // clear the slot so that a managed item (string, TBytes, interface) is released now
  FSlots[LHead and FMask] := Default(T);
  // write barrier: the slot is cleared before the new FHead is published
  WriteBarrier;
  FHead := LHead + 1;
  // full barrier: FHead is published before FProducerParked is read. It pairs
  // with the parked flag that the producer sets before its last check of FHead.
  ReadWriteBarrier;
  if FProducerParked <> 0 then
    RTLEventSetEvent(FNotFull);
end;

procedure TSpscRing<T>.Put(const AItem: T);
var
  LTail: LongWord;
begin
  LTail := FTail;
  FSlots[LTail and FMask] := AItem;
  // write barrier: the slot is written before the new FTail is published
  WriteBarrier;
  FTail := LTail + 1;
  // full barrier: FTail is published before FConsumerParked is read. It pairs
  // with the parked flag that the consumer sets before its last check of FTail.
  ReadWriteBarrier;
  if FConsumerParked <> 0 then
    RTLEventSetEvent(FNotEmpty);
end;

function TSpscRing<T>.TakeIfAny(out AItem: T): Boolean;
begin
  // an item that is in the ring is returned, also after Shutdown
  Result := HasItem;
  if Result then
    Take(AItem);
end;

function TSpscRing<T>.AwaitItem(const ATimeoutMs: Integer): Boolean;
var
  LDeadline, LNow: QWord;
  LSlice: Integer;
  LDown: Boolean;
begin
  LDeadline := 0;
  if ATimeoutMs >= 0 then
    LDeadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    // FShutdown is read before FTail: an item pushed before Shutdown is never lost
    LDown := ShutdownSeen;
    if HasItem then
      Exit(True);
    if LDown then
      Exit(False);
    // Park: the exchange is a full barrier. The flag is visible to the
    // producer before this thread reads FTail again. If the producer published
    // FTail first, the check below sees it. If not, the producer sees the flag.
    InterlockedExchange(FConsumerParked, 1);
    if HasItem or ShutdownSeen then
    begin
      InterlockedExchange(FConsumerParked, 0);
      Continue;
    end;
    LSlice := cSpscMaxWaitSliceMs;
    if ATimeoutMs >= 0 then
    begin
      LNow := GetTickCount64;
      if LNow >= LDeadline then
      begin
        InterlockedExchange(FConsumerParked, 0);
        Exit(False);
      end;
      if LDeadline - LNow < QWord(LSlice) then
        LSlice := Integer(LDeadline - LNow);
    end;
    RTLEventWaitFor(FNotEmpty, LSlice);
    InterlockedExchange(FConsumerParked, 0);
  end;
end;

function TSpscRing<T>.PushCore(const AItem: T; const ATimeoutMs: Integer): Boolean;
var
  LDeadline, LNow: QWord;
  LSlice: Integer;
begin
  LDeadline := 0;
  if ATimeoutMs >= 0 then
    LDeadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if ShutdownSeen then
      Exit(False);
    if HasRoom then
    begin
      Put(AItem);
      Exit(True);
    end;
    // Park: the exchange is a full barrier (the same protocol as AwaitItem)
    InterlockedExchange(FProducerParked, 1);
    if HasRoom or ShutdownSeen then
    begin
      InterlockedExchange(FProducerParked, 0);
      Continue;
    end;
    LSlice := cSpscMaxWaitSliceMs;
    if ATimeoutMs >= 0 then
    begin
      LNow := GetTickCount64;
      if LNow >= LDeadline then
      begin
        InterlockedExchange(FProducerParked, 0);
        Exit(False);
      end;
      if LDeadline - LNow < QWord(LSlice) then
        LSlice := Integer(LDeadline - LNow);
    end;
    RTLEventWaitFor(FNotFull, LSlice);
    InterlockedExchange(FProducerParked, 0);
  end;
end;

function TSpscRing<T>.Push(const AItem: T; const ATimeoutMs: Integer): Boolean;
begin
  EnterProducer;
  try
    Result := PushCore(AItem, ATimeoutMs);
  finally
    LeaveProducer;
  end;
end;

function TSpscRing<T>.TryPush(const AItem: T): Boolean;
begin
  Result := Push(AItem, 0);
end;

function TSpscRing<T>.Pop(out AItem: T): Boolean;
begin
  EnterConsumer;
  try
    Result := AwaitItem(cSpscNoTimeout);
    if Result then
      Take(AItem)
    else
      AItem := Default(T);
  finally
    LeaveConsumer;
  end;
end;

function TSpscRing<T>.TryPop(out AItem: T): Boolean;
begin
  EnterConsumer;
  try
    Result := TakeIfAny(AItem);
    if not Result then
      AItem := Default(T);
  finally
    LeaveConsumer;
  end;
end;

function TSpscRing<T>.WaitForItem(const ATimeoutMs: Integer): Boolean;
begin
  EnterConsumer;
  try
    Result := AwaitItem(ATimeoutMs);
  finally
    LeaveConsumer;
  end;
end;

procedure TSpscRing<T>.Shutdown;
begin
  // the exchange is a full barrier: FShutdown is visible before the events are set
  InterlockedExchange(FShutdown, 1);
  // each side has one waiter at most, so one set wakes it
  RTLEventSetEvent(FNotEmpty);
  RTLEventSetEvent(FNotFull);
end;

function TSpscRing<T>.IsShutdown: Boolean;
begin
  Result := ShutdownSeen;
end;

function TSpscRing<T>.Count: Integer;
var
  LHead, LTail: LongWord;
begin
  LHead := FHead;
  ReadBarrier;
  LTail := FTail;
  ReadBarrier;
  // the two reads are not one snapshot; the result stays inside 0..Capacity
  if LTail - LHead > FCapacity then
    Result := Integer(FCapacity)
  else
    Result := Integer(LTail - LHead);
end;

function TSpscRing<T>.Capacity: Integer;
begin
  Result := Integer(FCapacity);
end;

function TSpscRing<T>.ConsumerParked: Boolean;
begin
  Result := FConsumerParked <> 0;
end;

function TSpscRing<T>.ProducerParked: Boolean;
begin
  Result := FProducerParked <> 0;
end;

end.
