{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body budget, in flight, memory, http1
notes:
  - This unit holds the server-wide budget of the body octets that the HTTP/1.1
    exchanges buffer before a handler reads them.
  - TryAdd checks the limit and adds the octets in one step, under one lock.
  - A limit of 0 turns the budget off; every add is accepted.
---
}
/// The server-wide budget of buffered HTTP/1.1 body octets
unit Http2.Server.Http1.BodyBudget;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SyncObjs;

type
  /// the body octets that the server holds for all exchanges together
  TBodyBudget = class
  private
    FLock: TCriticalSection;
    FMaxBytes: Int64;
    FInFlight: Int64;
  public
    /// AMaxBytes is the limit; 0 means no limit
    constructor Create(AMaxBytes: Int64);
    destructor Destroy; override;
    /// add ACount octets when they fit under the limit; False leaves the
    /// count as it was
    function TryAdd(ACount: Int64): Boolean;
    /// give back ACount octets that the server no longer holds
    procedure Release(ACount: Int64);
    /// the octets that the server holds now
    property InFlight: Int64 read FInFlight;
  end;

implementation

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

end.
