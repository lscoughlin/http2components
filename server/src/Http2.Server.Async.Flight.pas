{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, write in flight, close decision, test seam
notes:
  - This unit holds the test seam of the write path of the async server.
  - A write gate is called by a send loop after it took output from the
    core and before it hands the output to the socket. A test parks the
    thread in the gate, so a second thread can take the close decision while
    the output is in flight.
  - The counter of deferred closes counts each close that a thread left to
    the send loop, because that loop still holds output.
  - When no gate is set, each call costs one test of a Boolean.
---
}
/// The test seam of the write in flight of the async server
unit Http2.Server.Async.Flight;

{$mode delphi}{$H+}

interface

type
  /// the gate that a send loop calls before it writes output
  // - AConnection is the connection object of the loop
  TWriteGate = procedure(const AConnection: TObject) of object;

/// set the write gate; a nil gate removes it
procedure SetWriteGate(const AGate: TWriteGate);
/// called by a send loop before it writes output to the socket
procedure FlightBeforeWrite(const AConnection: TObject);
/// called when a thread leaves a close to the send loop that holds output
procedure FlightCloseDeferred;
/// the number of deferred closes since the process started
function FlightDeferredCount: Integer;

implementation

uses
  SyncObjs;

var
  GArmed: Boolean;
  GGate: TWriteGate;
  GLock: TCriticalSection;
  GDeferred: Integer;

procedure SetWriteGate(const AGate: TWriteGate);
begin
  GLock.Enter;
  try
    GGate := AGate;
    GArmed := Assigned(AGate);
  finally
    GLock.Leave;
  end;
end;

procedure FlightBeforeWrite(const AConnection: TObject);
var
  Gate: TWriteGate;
begin
  if not GArmed then
    Exit;
  GLock.Enter;
  try
    Gate := GGate;
  finally
    GLock.Leave;
  end;
  // the gate runs outside the lock, because it can park the thread
  if Assigned(Gate) then
    Gate(AConnection);
end;

procedure FlightCloseDeferred;
begin
  InterlockedIncrement(GDeferred);
end;

function FlightDeferredCount: Integer;
begin
  Result := InterlockedExchangeAdd(GDeferred, 0);
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
