{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, flow_control, send_credit, concurrency
notes:
  - This unit gives each sender waiting for flow-control credit its own event.
---
}
/// Per-sender wake events for HTTP/2 request flow control
unit Http2.Client.Connection.SendCredit;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  Classes, SyncObjs, Generics.Collections;

type
  ISendCreditWaiter = interface
    ['{73D62811-78A8-47DD-880C-74AE6DF6C508}']
    procedure Register;
    procedure Wait(const ATimeoutMs: Integer);
  end;

  ISendCreditWaiterRegistry = interface
    ['{F54B8EE0-8B98-4989-B567-E3334F9911A2}']
    function NewWaiter: ISendCreditWaiter;
    procedure WakeAll;
    /// number of registered senders waiting for a wake
    function Count: Integer;
  end;

function NewSendCreditWaiterRegistry: ISendCreditWaiterRegistry;

implementation

type
  TSendCreditWaiter = class;

  TSendCreditWaiterRegistry = class(TInterfacedObject,
    ISendCreditWaiterRegistry)
  private
    FLock: TCriticalSection;
    FWaiters: TList<TSendCreditWaiter>;
    procedure Add(const AWaiter: TSendCreditWaiter);
    procedure Remove(const AWaiter: TSendCreditWaiter);
  public
    constructor Create;
    destructor Destroy; override;
    function NewWaiter: ISendCreditWaiter;
    procedure WakeAll;
    function Count: Integer;
  end;

  TSendCreditWaiter = class(TInterfacedObject, ISendCreditWaiter)
  private
    FRegistry: TSendCreditWaiterRegistry;
    FRegistryKeepAlive: ISendCreditWaiterRegistry;
    FEvent: PRTLEvent;
  public
    constructor Create(const ARegistry: TSendCreditWaiterRegistry);
    destructor Destroy; override;
    procedure Register;
    procedure Wait(const ATimeoutMs: Integer);
    procedure Signal;
  end;

function NewSendCreditWaiterRegistry: ISendCreditWaiterRegistry;
begin
  Result := TSendCreditWaiterRegistry.Create;
end;

constructor TSendCreditWaiterRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWaiters := TList<TSendCreditWaiter>.Create;
end;

destructor TSendCreditWaiterRegistry.Destroy;
begin
  FWaiters.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSendCreditWaiterRegistry.NewWaiter: ISendCreditWaiter;
begin
  Result := TSendCreditWaiter.Create(Self);
end;

procedure TSendCreditWaiterRegistry.Add(const AWaiter: TSendCreditWaiter);
begin
  FLock.Acquire;
  try
    if FWaiters.IndexOf(AWaiter) < 0 then
      FWaiters.Add(AWaiter);
  finally
    FLock.Release;
  end;
end;

procedure TSendCreditWaiterRegistry.Remove(const AWaiter: TSendCreditWaiter);
var
  Index: Integer;
begin
  FLock.Acquire;
  try
    Index := FWaiters.IndexOf(AWaiter);
    if Index >= 0 then
      FWaiters.Delete(Index);
  finally
    FLock.Release;
  end;
end;

procedure TSendCreditWaiterRegistry.WakeAll;
var
  Waiter: TSendCreditWaiter;
begin
  FLock.Acquire;
  try
    for Waiter in FWaiters do
      Waiter.Signal;
    FWaiters.Clear;
  finally
    FLock.Release;
  end;
end;

function TSendCreditWaiterRegistry.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FWaiters.Count;
  finally
    FLock.Release;
  end;
end;

constructor TSendCreditWaiter.Create(
  const ARegistry: TSendCreditWaiterRegistry);
begin
  inherited Create;
  FRegistry := ARegistry;
  FRegistryKeepAlive := ARegistry as ISendCreditWaiterRegistry;
  FEvent := RTLEventCreate;
end;

destructor TSendCreditWaiter.Destroy;
begin
  FRegistry.Remove(Self);
  RTLEventDestroy(FEvent);
  FRegistry := nil;
  FRegistryKeepAlive := nil;
  inherited Destroy;
end;

procedure TSendCreditWaiter.Register;
begin
  FRegistry.Add(Self);
end;

procedure TSendCreditWaiter.Wait(const ATimeoutMs: Integer);
begin
  try
    RTLEventWaitFor(FEvent, ATimeoutMs);
  finally
    FRegistry.Remove(Self);
  end;
end;

procedure TSendCreditWaiter.Signal;
begin
  RTLEventSetEvent(FEvent);
end;

end.
