{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, budget, queued bytes, sessions
notes:
  - This unit holds the server-wide byte budget of the queued WebSocket
    messages and the cap on the open WebSocket sessions.
  - Each check and its change run under one lock, so two threads cannot pass
    the maximum together.
  - A message in memory charges its payload plus WsQueuedMessageOverhead, so a
    queue of one-octet messages is bounded by the budget as well.
---
}
/// The server-wide budget of the WebSocket queues and sessions
unit Http2.Server.WebSocket.Budget;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, SyncObjs;

const
  /// the octets that a message in memory charges to the budget besides its payload
  // - the queue entry, the reader and the heap blocks of a queued message cost about this
  //   much, so a message of one octet still charges the budget for its memory
  WsQueuedMessageOverhead = 256;

/// the budget charge of a message in memory with APayload octets
function WsMemoryCharge(const APayload: Int64): Int64;

type
  /// the bytes of the queued WebSocket messages and the open sessions of a server
  TWsByteBudget = class
  private
    FLock: TCriticalSection;
    FMaxBytes: Int64;
    FMaxSessions: Integer;
    FBytes: Int64;
    FSessions: Integer;
    function GetBytes: Int64;
    function GetSessions: Integer;
  public
    /// AMaxBytes is the greatest total of the queued octets; AMaxSessions is the
    /// greatest number of open sessions, and 0 turns the session cap off
    constructor Create(AMaxBytes: Int64; AMaxSessions: Integer);
    destructor Destroy; override;
    /// add ACount octets; False when the total would pass the maximum, and then
    /// the total does not change
    function TryAddBytes(ACount: Int64): Boolean;
    /// subtract ACount octets from the total
    procedure ReleaseBytes(ACount: Int64);
    /// count one more open session; False when the cap is reached
    function TryOpenSession: Boolean;
    /// count one open session less
    procedure CloseSession;
    /// the octets that are counted now
    property Bytes: Int64 read GetBytes;
    /// the sessions that are counted now
    property Sessions: Integer read GetSessions;
  end;

implementation

function WsMemoryCharge(const APayload: Int64): Int64;
begin
  Result := APayload + WsQueuedMessageOverhead;
end;

{ TWsByteBudget }

constructor TWsByteBudget.Create(AMaxBytes: Int64; AMaxSessions: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FMaxBytes := AMaxBytes;
  FMaxSessions := AMaxSessions;
end;

destructor TWsByteBudget.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TWsByteBudget.GetBytes: Int64;
begin
  FLock.Acquire;
  try
    Result := FBytes;
  finally
    FLock.Release;
  end;
end;

function TWsByteBudget.GetSessions: Integer;
begin
  FLock.Acquire;
  try
    Result := FSessions;
  finally
    FLock.Release;
  end;
end;

function TWsByteBudget.TryAddBytes(ACount: Int64): Boolean;
begin
  FLock.Acquire;
  try
    Result := FBytes + ACount <= FMaxBytes;
    if Result then
      Inc(FBytes, ACount);
  finally
    FLock.Release;
  end;
end;

procedure TWsByteBudget.ReleaseBytes(ACount: Int64);
begin
  FLock.Acquire;
  try
    Dec(FBytes, ACount);
  finally
    FLock.Release;
  end;
end;

function TWsByteBudget.TryOpenSession: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FMaxSessions = 0) or (FSessions < FMaxSessions);
    if Result then
      Inc(FSessions);
  finally
    FLock.Release;
  end;
end;

procedure TWsByteBudget.CloseSession;
begin
  FLock.Acquire;
  try
    if FSessions > 0 then
      Dec(FSessions);
  finally
    FLock.Release;
  end;
end;

end.
