{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, flow control, window update
notes:
  - This unit counts received DATA bytes for WINDOW_UPDATE batching (RFC 9113 section 6.9).
  - The class does no I/O and takes no lock. The caller holds its lock.
---
}
unit Http2.Client.Connection.Credit;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Generics.Collections;

type
  /// counts received DATA bytes and reports when a WINDOW_UPDATE is due
  TReceiveCreditTracker = class
  private
    FPendingConn: LongWord;
    FPendingStream: TDictionary<LongWord, LongWord>;
  public
    constructor Create;
    destructor Destroy; override;
    /// account for ALength received bytes on AStreamId. AStreamTracked is True
    // when the stream still has an open lease. Returns True when an increment
    // is due, and sets the increments to return to the peer.
    function OnData(AStreamId: LongWord; ALength: Integer;
      AStreamTracked: Boolean; ABatchSize: LongWord;
      out AConnIncrement, AStreamIncrement: LongWord): Boolean;
    /// return the pending stream credit and clear it (0 when none)
    function TakeStream(AStreamId: LongWord): LongWord;
    /// drop the pending credit of a closed stream
    procedure Forget(AStreamId: LongWord);
  end;

implementation

constructor TReceiveCreditTracker.Create;
begin
  inherited Create;
  FPendingConn := 0;
  FPendingStream := TDictionary<LongWord, LongWord>.Create;
end;

destructor TReceiveCreditTracker.Destroy;
begin
  FreeAndNil(FPendingStream);
  inherited Destroy;
end;

function TReceiveCreditTracker.OnData(AStreamId: LongWord; ALength: Integer;
  AStreamTracked: Boolean; ABatchSize: LongWord;
  out AConnIncrement, AStreamIncrement: LongWord): Boolean;
var
  Pending: LongWord;
begin
  AConnIncrement := 0;
  AStreamIncrement := 0;
  // connection window: DATA counts against it regardless of the stream
  FPendingConn := FPendingConn + LongWord(ALength);
  if FPendingConn >= ABatchSize then
  begin
    FPendingConn := 0;
    AConnIncrement := ABatchSize;
  end;
  // stream window: only for a stream that is still tracked
  if AStreamTracked then
  begin
    if not FPendingStream.TryGetValue(AStreamId, Pending) then
      Pending := 0;
    Pending := Pending + LongWord(ALength);
    if Pending >= ABatchSize then
    begin
      FPendingStream.AddOrSetValue(AStreamId, 0);
      AStreamIncrement := Pending;
    end
    else
      FPendingStream.AddOrSetValue(AStreamId, Pending);
  end;
  Result := (AConnIncrement > 0) or (AStreamIncrement > 0);
end;

function TReceiveCreditTracker.TakeStream(AStreamId: LongWord): LongWord;
begin
  if not FPendingStream.TryGetValue(AStreamId, Result) then
    Exit(0);
  if Result = 0 then
    Exit;
  FPendingStream.AddOrSetValue(AStreamId, 0);
end;

procedure TReceiveCreditTracker.Forget(AStreamId: LongWord);
begin
  FPendingStream.Remove(AStreamId);
end;

end.
