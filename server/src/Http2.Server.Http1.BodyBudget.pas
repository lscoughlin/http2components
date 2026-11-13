{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body budget, in flight, memory, http1
notes:
  - This unit holds the server-wide budget of the body octets that the HTTP/1.1
    exchanges buffer before a handler reads them.
  - The budget is an interface, so the records that carry it share one object
    and the object ends with its last holder.
  - TryAdd checks the limit and adds the octets in one step, under one lock.
  - A limit of 0 turns the budget off; every add is accepted.
  - The lock order is the exchange lock first, then the budget lock.
---
}
/// The server-wide budget of buffered HTTP/1.1 body octets
unit Http2.Server.Http1.BodyBudget;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SyncObjs;

type
  /// the body octets that the server holds for all exchanges together
  IBodyBudget = interface
    ['{C3A1E5B2-6D47-4F9A-8E21-5B7D0A9C1E04}']
    /// add ACount octets when they fit under the limit; False leaves the
    /// count as it was
    function TryAdd(ACount: Int64): Boolean;
    /// give back ACount octets that the server no longer holds
    procedure Release(ACount: Int64);
    /// the octets that the server holds now
    function GetInFlight: Int64;
    property InFlight: Int64 read GetInFlight;
  end;

  /// the budget of one server; the lock makes the check and the add one step
  TBodyBudget = class(TInterfacedObject, IBodyBudget)
  private
    FLock: TCriticalSection;
    FMaxBytes: Int64;
    FInFlight: Int64;
  public
    /// AMaxBytes is the limit; 0 means no limit
    constructor Create(AMaxBytes: Int64);
    destructor Destroy; override;
    function TryAdd(ACount: Int64): Boolean;
    procedure Release(ACount: Int64);
    function GetInFlight: Int64;
  end;

/// charge ACount octets to the budget and to AHeld, the octets of one exchange
// - a nil budget accepts every charge
// - False when the budget refuses; AHeld does not change then
function TakeCharge(const ABudget: IBodyBudget; var AHeld: Int64;
  const ACount: Int64): Boolean;

/// give back the part of ACount that AHeld holds, and lower AHeld by it
procedure GiveCharge(const ABudget: IBodyBudget; var AHeld: Int64;
  const ACount: Int64);

/// give back all of AHeld; a second call does nothing
procedure DropCharge(const ABudget: IBodyBudget; var AHeld: Int64);

implementation

function TakeCharge(const ABudget: IBodyBudget; var AHeld: Int64;
  const ACount: Int64): Boolean;
begin
  if ABudget = nil then
    Exit(True);
  Result := ABudget.TryAdd(ACount);
  if Result then
    Inc(AHeld, ACount);
end;

procedure GiveCharge(const ABudget: IBodyBudget; var AHeld: Int64;
  const ACount: Int64);
var
  Part: Int64;
begin
  Part := ACount;
  if Part > AHeld then
    Part := AHeld;
  if Part <= 0 then
    Exit;
  Dec(AHeld, Part);
  if ABudget <> nil then
    ABudget.Release(Part);
end;

procedure DropCharge(const ABudget: IBodyBudget; var AHeld: Int64);
begin
  GiveCharge(ABudget, AHeld, AHeld);
end;

{ TBodyBudget }

constructor TBodyBudget.Create(AMaxBytes: Int64);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMaxBytes := AMaxBytes;
end;

destructor TBodyBudget.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TBodyBudget.TryAdd(ACount: Int64): Boolean;
begin
  FLock.Acquire;
  try
    Result := (FMaxBytes = 0) or (ACount <= FMaxBytes - FInFlight);
    if Result then
      Inc(FInFlight, ACount);
  finally
    FLock.Release;
  end;
end;

procedure TBodyBudget.Release(ACount: Int64);
begin
  FLock.Acquire;
  try
    Dec(FInFlight, ACount);
    if FInFlight < 0 then
      FInFlight := 0;
  finally
    FLock.Release;
  end;
end;

function TBodyBudget.GetInFlight: Int64;
begin
  FLock.Acquire;
  try
    Result := FInFlight;
  finally
    FLock.Release;
  end;
end;

end.
