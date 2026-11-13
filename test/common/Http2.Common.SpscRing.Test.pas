{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: spsc, ring, test
notes:
  - This test checks the single-producer single-consumer ring.
  - The tests have no sleeps for synchronization. A wait is a bounded poll or a bounded event wait.
  - cStressItems is 200000 on the development machine. The Linux run raises it to 20000000.
---
}
unit Http2.Common.SpscRing.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Common.Frames, Http2.Common.Hpack,
  Http2.Common.SpscRing;

const
  /// number of items of the two-thread stress test; the Linux run uses 20000000
  cStressItems = 200000;

type
  /// a thread that runs one method and keeps the exception text
  TMethodThread = class(TThread)
  private
    FBody: TThreadMethod;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const ABody: TThreadMethod);
    property Error: string read FError;
  end;

  /// an object that counts its own destruction
  TCountedRef = class(TInterfacedObject)
  public
    destructor Destroy; override;
  end;

  TManagedItem = record
    Text: string;
    Data: TBytes;
    Ref: IInterface;
  end;

  TSpscRingTest = class(TTestCase)
  private
    FRing: TSpscRing<Integer>;
    FInHook: LongInt;
    FHookEntered: PRTLEvent;
    FHookRelease: PRTLEvent;
    FResult: Boolean;
    FValue: Integer;
    FSum: Int64;
    FOrderOk: Boolean;
    procedure HookBlock;
    procedure PopOnce;
    procedure PushOnce;
    procedure PopOnceBlocking;
    procedure PushBlocking;
    procedure ProduceStress;
    procedure WaitUntilTrue(const ACondition: PLongInt);
    procedure WaitForParked(const AConsumer: Boolean);
    procedure PrepareHook;
    procedure FinishHook;
    procedure AssertRaisesInvalid(const AWhat: string; const ACall: TThreadMethod);
    procedure CallTryPop;
    procedure CallPop;
    procedure CallWait;
    procedure CallTryPush;
    procedure CallPush;
  protected
    procedure TearDown; override;
  published
    procedure TestOrderIsKept;
    procedure TestWrapAround;
    procedure TestFullAndEmpty;
    procedure TestPushTimesOutWhenFull;
    procedure TestWaitForItemTimesOutWhenEmpty;
    procedure TestShutdownBehavior;
    procedure TestShutdownKeepsQueuedItems;
    procedure TestCapacityMustBePowerOfTwo;
    procedure TestManagedItemsAreKept;
    procedure TestFrameRoundTrip;
    procedure TestPoppedSlotReleasesItem;
    procedure TestDestroyReleasesQueuedItems;
    procedure TestShutdownWakesBlockedConsumer;
    procedure TestShutdownWakesBlockedProducer;
    procedure TestPopWakesOnPush;
    procedure TestPushWakesOnPop;
    procedure TestSecondConsumerIsRefused;
    procedure TestSecondProducerIsRefused;
    procedure TestTwoThreadStress;
  end;

implementation

var
  GDestroyed: LongInt;

{ TMethodThread }

constructor TMethodThread.Create(const ABody: TThreadMethod);
begin
  FBody := ABody;
  inherited Create(False);
end;

procedure TMethodThread.Execute;
begin
  try
    FBody();
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

{ TCountedRef }

destructor TCountedRef.Destroy;
begin
  InterlockedIncrement(GDestroyed);
  inherited Destroy;
end;

{ TSpscRingTest }

procedure TSpscRingTest.TearDown;
begin
  if FRing <> nil then
    FRing.Shutdown;
  FreeAndNil(FRing);
  if FHookEntered <> nil then
  begin
    RTLEventDestroy(FHookEntered);
    FHookEntered := nil;
  end;
  if FHookRelease <> nil then
  begin
    RTLEventDestroy(FHookRelease);
    FHookRelease := nil;
  end;
end;

procedure TSpscRingTest.WaitUntilTrue(const ACondition: PLongInt);
var
  LTries: Integer;
begin
  // bounded poll: at most about 10 seconds
  LTries := 0;
  while (ACondition^ = 0) and (LTries < 10000) do
  begin
    Sleep(1);
    Inc(LTries);
  end;
  AssertTrue('the condition became true', ACondition^ <> 0);
end;

procedure TSpscRingTest.WaitForParked(const AConsumer: Boolean);
var
  LTries: Integer;
begin
  LTries := 0;
  if AConsumer then
    while (not FRing.ConsumerParked) and (LTries < 10000) do
    begin
      Sleep(1);
      Inc(LTries);
    end
  else
    while (not FRing.ProducerParked) and (LTries < 10000) do
    begin
      Sleep(1);
      Inc(LTries);
    end;
  AssertTrue('the thread is parked', (AConsumer and FRing.ConsumerParked) or
    ((not AConsumer) and FRing.ProducerParked));
end;

procedure TSpscRingTest.PrepareHook;
begin
  FHookEntered := RTLEventCreate;
  FHookRelease := RTLEventCreate;
  FInHook := 0;
end;

procedure TSpscRingTest.HookBlock;
begin
  // runs on the first thread while the ring guard is set
  InterlockedExchange(FInHook, 1);
  RTLEventSetEvent(FHookEntered);
  RTLEventWaitFor(FHookRelease, 10000);
end;

procedure TSpscRingTest.FinishHook;
begin
  RTLEventSetEvent(FHookRelease);
end;

procedure TSpscRingTest.PopOnce;
begin
  FResult := FRing.TryPop(FValue);
end;

procedure TSpscRingTest.PushOnce;
begin
  FResult := FRing.TryPush(7);
end;

procedure TSpscRingTest.PopOnceBlocking;
begin
  FResult := FRing.Pop(FValue);
end;

procedure TSpscRingTest.PushBlocking;
begin
  FResult := FRing.Push(7);
end;

procedure TSpscRingTest.CallTryPop;
var
  LItem: Integer;
begin
  FRing.TryPop(LItem);
end;

procedure TSpscRingTest.CallPop;
var
  LItem: Integer;
begin
  FRing.Pop(LItem);
end;

procedure TSpscRingTest.CallWait;
begin
  FRing.WaitForItem(0);
end;

procedure TSpscRingTest.CallTryPush;
begin
  FRing.TryPush(1);
end;

procedure TSpscRingTest.CallPush;
begin
  FRing.Push(1, 0);
end;

procedure TSpscRingTest.AssertRaisesInvalid(const AWhat: string; const ACall: TThreadMethod);
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ACall();
  except
    on EInvalidOperation do
      LRaised := True;
  end;
  AssertTrue(AWhat + ' raises EInvalidOperation', LRaised);
end;

procedure TSpscRingTest.TestOrderIsKept;
var
  I, LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(8);
  for I := 1 to 5 do
    AssertTrue('push', FRing.TryPush(I));
  AssertEquals(5, FRing.Count);
  for I := 1 to 5 do
  begin
    AssertTrue('pop', FRing.TryPop(LItem));
    AssertEquals(I, LItem);
  end;
  AssertEquals(0, FRing.Count);
end;

procedure TSpscRingTest.TestWrapAround;
var
  I, LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(4);
  for I := 1 to 50 do
  begin
    AssertTrue('push', FRing.TryPush(I));
    AssertTrue('push', FRing.TryPush(I + 1000));
    AssertTrue('pop', FRing.TryPop(LItem));
    AssertEquals(I, LItem);
    AssertTrue('pop', FRing.TryPop(LItem));
    AssertEquals(I + 1000, LItem);
  end;
end;

procedure TSpscRingTest.TestFullAndEmpty;
var
  I, LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(4);
  AssertEquals(4, FRing.Capacity);
  AssertFalse('empty ring', FRing.TryPop(LItem));
  for I := 1 to 4 do
    AssertTrue('push', FRing.TryPush(I));
  AssertFalse('full ring', FRing.TryPush(5));
  AssertEquals(4, FRing.Count);
  AssertTrue('pop', FRing.TryPop(LItem));
  AssertEquals(1, LItem);
  AssertTrue('room again', FRing.TryPush(5));
end;

procedure TSpscRingTest.TestPushTimesOutWhenFull;
begin
  FRing := TSpscRing<Integer>.Create(1);
  AssertTrue('first push', FRing.Push(1, 0));
  AssertFalse('second push times out', FRing.Push(2, 20));
  AssertEquals(1, FRing.Count);
end;

procedure TSpscRingTest.TestWaitForItemTimesOutWhenEmpty;
begin
  FRing := TSpscRing<Integer>.Create(2);
  AssertFalse('empty ring', FRing.WaitForItem(20));
  AssertTrue('push', FRing.TryPush(3));
  AssertTrue('item present', FRing.WaitForItem(0));
  AssertEquals(1, FRing.Count);
end;

procedure TSpscRingTest.TestShutdownBehavior;
var
  LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(4);
  AssertFalse(FRing.IsShutdown);
  FRing.Shutdown;
  AssertTrue(FRing.IsShutdown);
  AssertFalse('push after shutdown is dropped', FRing.Push(1));
  AssertFalse('try push after shutdown is dropped', FRing.TryPush(1));
  AssertEquals(0, FRing.Count);
  AssertFalse('pop of an empty ring after shutdown', FRing.Pop(LItem));
  AssertFalse('try pop of an empty ring', FRing.TryPop(LItem));
  AssertFalse('wait of an empty ring', FRing.WaitForItem(cSpscNoTimeout));
end;

procedure TSpscRingTest.TestShutdownKeepsQueuedItems;
var
  LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(4);
  AssertTrue(FRing.TryPush(11));
  AssertTrue(FRing.TryPush(12));
  FRing.Shutdown;
  AssertTrue('wait sees the queued item', FRing.WaitForItem(0));
  AssertTrue(FRing.Pop(LItem));
  AssertEquals(11, LItem);
  AssertTrue(FRing.TryPop(LItem));
  AssertEquals(12, LItem);
  AssertFalse(FRing.Pop(LItem));
end;

procedure TSpscRingTest.TestCapacityMustBePowerOfTwo;
var
  LRing: TSpscRing<Integer>;
  LRaised: Boolean;
  LCapacity: Integer;
  LBad: array[0..4] of Integer;
  I: Integer;
begin
  LBad[0] := 0;
  LBad[1] := -4;
  LBad[2] := 3;
  LBad[3] := 6;
  LBad[4] := 100;
  for I := 0 to 4 do
  begin
    LCapacity := LBad[I];
    LRaised := False;
    LRing := nil;
    try
      try
        LRing := TSpscRing<Integer>.Create(LCapacity);
      except
        on EArgumentException do
          LRaised := True;
      end;
    finally
      LRing.Free;
    end;
    AssertTrue('capacity ' + IntToStr(LCapacity) + ' is refused', LRaised);
  end;
end;

procedure TSpscRingTest.TestManagedItemsAreKept;
var
  LRing: TSpscRing<TManagedItem>;
  LIn, LOut: TManagedItem;
  I: Integer;
begin
  LRing := TSpscRing<TManagedItem>.Create(4);
  try
    for I := 1 to 20 do
    begin
      LIn.Text := 'item ' + IntToStr(I);
      SetLength(LIn.Data, I);
      LIn.Data[I - 1] := Byte(I);
      LIn.Ref := nil;
      AssertTrue('push', LRing.TryPush(LIn));
      AssertTrue('pop', LRing.TryPop(LOut));
      AssertEquals('item ' + IntToStr(I), LOut.Text);
      AssertEquals(I, Length(LOut.Data));
      AssertEquals(I, Integer(LOut.Data[I - 1]));
    end;
  finally
    LRing.Free;
  end;
end;

procedure TSpscRingTest.TestFrameRoundTrip;
var
  LRing: TSpscRing<TFrame>;
  LIn, LOut: TFrame;
begin
  LRing := TSpscRing<TFrame>.Create(2);
  try
    LIn := Default(TFrame);
    SetLength(LIn.Payload, 3);
    LIn.Payload[2] := 9;
    LIn.Header.StreamId := 5;
    SetLength(LIn.DecodedHeaders, 1);
    LIn.DecodedHeaders[0].Name := 'a';
    LIn.DecodedHeaders[0].Value := 'b';
    LIn.HeadersDecoded := True;
    AssertTrue(LRing.TryPush(LIn));
    LIn := Default(TFrame);
    AssertTrue(LRing.TryPop(LOut));
    AssertEquals(5, Integer(LOut.Header.StreamId));
    AssertEquals(3, Length(LOut.Payload));
    AssertEquals(9, Integer(LOut.Payload[2]));
    AssertTrue(LOut.HeadersDecoded);
    AssertEquals(1, Length(LOut.DecodedHeaders));
    AssertEquals('b', LOut.DecodedHeaders[0].Value);
  finally
    LRing.Free;
  end;
end;

procedure TSpscRingTest.TestPoppedSlotReleasesItem;
var
  LRing: TSpscRing<TManagedItem>;
  LIn, LOut: TManagedItem;
  LBefore: LongInt;
begin
  LBefore := GDestroyed;
  LRing := TSpscRing<TManagedItem>.Create(4);
  try
    LIn.Ref := TCountedRef.Create;
    AssertTrue(LRing.TryPush(LIn));
    LIn.Ref := nil;
    AssertEquals('the slot holds the object', LBefore, GDestroyed);
    AssertTrue(LRing.TryPop(LOut));
    AssertEquals('the caller holds the object', LBefore, GDestroyed);
    LOut.Ref := nil;
    // the ring is still alive: only a cleared slot lets the object go now
    AssertEquals('the slot released the object', LBefore + 1, GDestroyed);
  finally
    LRing.Free;
  end;
end;

procedure TSpscRingTest.TestDestroyReleasesQueuedItems;
var
  LRing: TSpscRing<TManagedItem>;
  LIn: TManagedItem;
  LBefore: LongInt;
begin
  LBefore := GDestroyed;
  LRing := TSpscRing<TManagedItem>.Create(4);
  LIn.Ref := TCountedRef.Create;
  AssertTrue(LRing.TryPush(LIn));
  LIn.Ref := nil;
  AssertEquals(LBefore, GDestroyed);
  LRing.Free;
  AssertEquals('Destroy released the queued item', LBefore + 1, GDestroyed);
end;

procedure TSpscRingTest.TestShutdownWakesBlockedConsumer;
var
  LThread: TMethodThread;
begin
  FRing := TSpscRing<Integer>.Create(2);
  FResult := True;
  LThread := TMethodThread.Create(PopOnceBlocking);
  try
    WaitForParked(True);
    FRing.Shutdown;
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertFalse('Pop returns False after Shutdown', FResult);
  finally
    LThread.Free;
  end;
end;

procedure TSpscRingTest.TestShutdownWakesBlockedProducer;
var
  LThread: TMethodThread;
begin
  FRing := TSpscRing<Integer>.Create(1);
  AssertTrue(FRing.TryPush(1));
  FResult := True;
  LThread := TMethodThread.Create(PushBlocking);
  try
    WaitForParked(False);
    FRing.Shutdown;
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertFalse('Push returns False after Shutdown', FResult);
  finally
    LThread.Free;
  end;
end;

procedure TSpscRingTest.TestPopWakesOnPush;
var
  LThread: TMethodThread;
begin
  FRing := TSpscRing<Integer>.Create(2);
  FResult := False;
  FValue := 0;
  LThread := TMethodThread.Create(PopOnceBlocking);
  try
    WaitForParked(True);
    AssertTrue(FRing.TryPush(42));
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertTrue(FResult);
    AssertEquals(42, FValue);
  finally
    LThread.Free;
  end;
end;

procedure TSpscRingTest.TestPushWakesOnPop;
var
  LThread: TMethodThread;
  LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(1);
  AssertTrue(FRing.TryPush(1));
  FResult := False;
  LThread := TMethodThread.Create(PushBlocking);
  try
    WaitForParked(False);
    AssertTrue(FRing.TryPop(LItem));
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertTrue('the blocked Push finished', FResult);
    AssertTrue(FRing.TryPop(LItem));
    AssertEquals(7, LItem);
  finally
    LThread.Free;
  end;
end;

procedure TSpscRingTest.TestSecondConsumerIsRefused;
var
  LThread: TMethodThread;
  LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(4);
  PrepareHook;
  AssertTrue(FRing.TryPush(5));
  FRing.OnConsumerEntered := HookBlock;
  LThread := TMethodThread.Create(PopOnce);
  try
    RTLEventWaitFor(FHookEntered, 10000);
    AssertTrue('the first consumer is inside', FInHook <> 0);
    // the first consumer holds the guard; every entry of a second consumer is refused
    FRing.OnConsumerEntered := nil;
    AssertRaisesInvalid('TryPop', CallTryPop);
    AssertRaisesInvalid('Pop', CallPop);
    AssertRaisesInvalid('WaitForItem', CallWait);
    // a refused entry leaves the guard set for the first consumer
    AssertRaisesInvalid('TryPop again', CallTryPop);
    FinishHook;
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertTrue('the first consumer got its item', FResult);
    AssertEquals(5, FValue);
    // the guard is free again
    AssertFalse(FRing.TryPop(LItem));
  finally
    FinishHook;
    LThread.Free;
  end;
end;

procedure TSpscRingTest.TestSecondProducerIsRefused;
var
  LThread: TMethodThread;
  LItem: Integer;
begin
  FRing := TSpscRing<Integer>.Create(4);
  PrepareHook;
  FRing.OnProducerEntered := HookBlock;
  LThread := TMethodThread.Create(PushOnce);
  try
    RTLEventWaitFor(FHookEntered, 10000);
    AssertTrue('the first producer is inside', FInHook <> 0);
    FRing.OnProducerEntered := nil;
    AssertRaisesInvalid('TryPush', CallTryPush);
    AssertRaisesInvalid('Push', CallPush);
    AssertRaisesInvalid('TryPush again', CallTryPush);
    FinishHook;
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertTrue('the first producer pushed its item', FResult);
    AssertEquals(1, FRing.Count);
    AssertTrue(FRing.TryPop(LItem));
    AssertEquals(7, LItem);
    AssertTrue('the guard is free again', FRing.TryPush(8));
  finally
    FinishHook;
    LThread.Free;
  end;
end;

procedure TSpscRingTest.ProduceStress;
var
  I: Integer;
begin
  for I := 0 to cStressItems - 1 do
    if not FRing.Push(I, 30000) then
      Exit;
end;

procedure TSpscRingTest.TestTwoThreadStress;
var
  LThread: TMethodThread;
  LItem, I: Integer;
begin
  FRing := TSpscRing<Integer>.Create(256);
  FSum := 0;
  FOrderOk := True;
  LThread := TMethodThread.Create(ProduceStress);
  try
    for I := 0 to cStressItems - 1 do
    begin
      if not FRing.WaitForItem(30000) then
      begin
        FOrderOk := False;
        Break;
      end;
      if not FRing.TryPop(LItem) then
      begin
        FOrderOk := False;
        Break;
      end;
      if LItem <> I then
        FOrderOk := False;
      Inc(FSum, LItem);
    end;
    FRing.Shutdown;
    LThread.WaitFor;
    AssertEquals('', LThread.Error);
    AssertTrue('items arrive in order', FOrderOk);
    AssertEquals(Int64(cStressItems) * (cStressItems - 1) div 2, FSum);
  finally
    LThread.Free;
  end;
end;

initialization
  RegisterTest(TSpscRingTest);

end.
