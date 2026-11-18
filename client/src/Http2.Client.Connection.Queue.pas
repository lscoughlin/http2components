{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, queue
notes:
  - This unit owns the generic bounded blocking queue implementation.
---
}
unit Http2.Client.Connection.Queue;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Generics.Collections, Http2.Client.Tls.Types;

const
  cDefaultQueueCapacity = 128;

type
  TBlockingQueueState<T> = class
  private
    FLock: TCriticalSection;
    FNotEmpty: PRTLEvent;
    FNotFull: PRTLEvent;
    FItems: TQueue<T>;
    FCapacity: Integer;
    FShutdown: Boolean;
    FWaitersParked: Integer;
    FWake: IReadInterrupt;
  public
    constructor Create(const ACapacity: Integer = cDefaultQueueCapacity);
    destructor Destroy; override;
    /// the wake channel of a consumer that blocks in a socket read, not in Pop;
    // set once, before the consumer starts. Push calls it after the item is queued
    property Wake: IReadInterrupt read FWake write FWake;
    procedure Push(const AItem: T);
    function Pop(out AItem: T): Boolean;
    function TryPop(out AItem: T): Boolean;
    procedure Shutdown;
    /// items currently buffered (introspection for tests)
    function Count: Integer;
    /// number of consumers currently blocked inside Pop (test seam)
    function WaitersParked: Integer;
    /// bounded, event-driven wait until at least one item is available;
    /// returns False on shutdown or when the deadline expires
    function WaitForItem(const ATimeoutMs: Integer): Boolean;
    function IsShutdown: Boolean;
  end;


implementation

{ TBlockingQueue<T> }

constructor TBlockingQueueState<T>.Create(const ACapacity: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FNotEmpty := RTLEventCreate;
  FNotFull := RTLEventCreate;
  FItems := TQueue<T>.Create;
  FCapacity := ACapacity;
  FShutdown := False;
end;

destructor TBlockingQueueState<T>.Destroy;
begin
  FItems.Free;
  RTLEventDestroy(FNotEmpty);
  RTLEventDestroy(FNotFull);
  FLock.Free;
  inherited Destroy;
end;

procedure TBlockingQueueState<T>.Push(const AItem: T);
var
  WokenByShutdown: Boolean;
begin
  WokenByShutdown := False;
  FLock.Acquire;
  try
    while (not FShutdown) and (FCapacity > 0) and (FItems.Count >= FCapacity) do
    begin
      FLock.Release;
      try
        RTLEventWaitFor(FNotFull);
      finally
        FLock.Acquire;
      end;
    end;
    if not FShutdown then
      FItems.Enqueue(AItem)
    else
      WokenByShutdown := True;
  finally
    FLock.Release;
  end;
  // chain-wake the next blocked producer on the SAME event, then a consumer
  if WokenByShutdown then
    RTLEventSetEvent(FNotFull);
  RTLEventSetEvent(FNotEmpty);
  if (not WokenByShutdown) and (FWake <> nil) then
    FWake.InterruptRead;
end;

function TBlockingQueueState<T>.Pop(out AItem: T): Boolean;
var
  WokenByShutdown: Boolean;
begin
  Result := False;
  WokenByShutdown := False;
  FLock.Acquire;
  try
    while (not FShutdown) and (FItems.Count = 0) do
    begin
      Inc(FWaitersParked);
      FLock.Release;
      try
        RTLEventWaitFor(FNotEmpty);
      finally
        FLock.Acquire;
        Dec(FWaitersParked);
      end;
    end;
    if FItems.Count > 0 then
    begin
      AItem := FItems.Dequeue;
      Result := True;
    end
    else if FShutdown then
      WokenByShutdown := True;
  finally
    FLock.Release;
  end;
  // chain-wake the next blocked consumer on the SAME event, then release a
  // producer slot. Signalling FNotFull here would leave sibling consumers
  // waiting on FNotEmpty blocked forever after Shutdown.
  if WokenByShutdown then
    RTLEventSetEvent(FNotEmpty);
  RTLEventSetEvent(FNotFull);
end;

function TBlockingQueueState<T>.TryPop(out AItem: T): Boolean;
begin
  FLock.Acquire;
  try
    Result := FItems.Count > 0;
    if Result then
      AItem := FItems.Dequeue;
  finally
    FLock.Release;
  end;
  if Result then
    RTLEventSetEvent(FNotFull);
end;

procedure TBlockingQueueState<T>.Shutdown;
begin
  FLock.Acquire;
  try
    FShutdown := True;
  finally
    FLock.Release;
  end;
  // RTLEvent wakes one waiter at a time; each released waiter re-signals
  // the SAME event in its Pop/Push epilogue, so the full set unblocks.
  RTLEventSetEvent(FNotEmpty);
  RTLEventSetEvent(FNotFull);
end;

function TBlockingQueueState<T>.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FItems.Count;
  finally
    FLock.Release;
  end;
end;

function TBlockingQueueState<T>.WaitersParked: Integer;
begin
  FLock.Acquire;
  try
    Result := FWaitersParked;
  finally
    FLock.Release;
  end;
end;

function TBlockingQueueState<T>.WaitForItem(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    FLock.Acquire;
    try
      if FItems.Count > 0 then
        Exit(True);
      if FShutdown then
        Exit(False);
    finally
      FLock.Release;
    end;
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FNotEmpty, Remaining);
  end;
end;

function TBlockingQueueState<T>.IsShutdown: Boolean;
begin
  FLock.Acquire;
  try
    Result := FShutdown;
  finally
    FLock.Release;
  end;
end;

{ TConnectionThread }

end.
