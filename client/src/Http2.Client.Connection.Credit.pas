{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, flow control, window update
notes:
  - This unit counts received DATA bytes for WINDOW_UPDATE batching (RFC 9113 section 6.9).
  - The stream credit can move from arrival (OnData) to read time (OnConsumed).
  - The class does no I/O and takes no lock. The caller holds its lock.
---
}
unit Http2.Client.Connection.Credit;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Generics.Collections;

/// the batch for read-time stream credit: ABatch, but at most half of
// AWindow, so a peer that has spent the window always sees an update come
function ReadBatchSize(AWindow: Int64; ABatch: LongWord): LongWord;

type
  /// counts received DATA bytes and reports when a WINDOW_UPDATE is due
  TReceiveCreditTracker = class
  private
    FPendingConn: LongWord;
    FPendingStream: TDictionary<LongWord, LongWord>;
    FStreamCreditOnRead: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    /// account for ALength received bytes on AStreamId. AStreamTracked is True
    // when the stream still has an open lease. Returns True when an increment
    // is due, and sets the increments to return to the peer.
    function OnData(AStreamId: LongWord; ALength: Integer;
      AStreamTracked: Boolean; ABatchSize: LongWord;
      out AConnIncrement, AStreamIncrement: LongWord): Boolean;
    /// account for ALength bytes that the application consumed from AStreamId.
    // Returns the stream increment to post: 0 when the batch is not full
    function OnConsumed(AStreamId: LongWord; ALength: Integer;
      ABatchSize: LongWord): LongWord;
    /// True: the stream credit is returned by OnConsumed, not by OnData
    property StreamCreditOnRead: Boolean read FStreamCreditOnRead
      write FStreamCreditOnRead;
    /// return the pending stream credit and clear it (0 when none)
    function TakeStream(AStreamId: LongWord): LongWord;
    /// drop the pending credit of a closed stream
    procedure Forget(AStreamId: LongWord);
  end;

implementation

function ReadBatchSize(AWindow: Int64; ABatch: LongWord): LongWord;
begin
  if AWindow div 2 < Int64(ABatch) then
    Result := LongWord(AWindow div 2)
  else
    Result := ABatch;
end;

constructor TReceiveCreditTracker.Create;
begin
  inherited Create;
  FPendingConn := 0;
  FStreamCreditOnRead := False;
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
  if AStreamTracked and not FStreamCreditOnRead then
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

function TReceiveCreditTracker.OnConsumed(AStreamId: LongWord;
  ALength: Integer; ABatchSize: LongWord): LongWord;
var
  Pending: LongWord;
begin
  Result := 0;
  if ALength <= 0 then
    Exit;
  if not FPendingStream.TryGetValue(AStreamId, Pending) then
    Pending := 0;
  Pending := Pending + LongWord(ALength);
  if Pending >= ABatchSize then
  begin
    Result := Pending;
    Pending := 0;
  end;
  FPendingStream.AddOrSetValue(AStreamId, Pending);
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
