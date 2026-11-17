{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket_pump
notes:
  - This unit holds the pump that sends one streamed WebSocket message. The pump reads
    one chunk of an IBodyWriter at a time and sends each chunk as one fragment.
  - At most one Step runs at one time. A Step starts only after a schedule, and the
    Step that owns the pump gives up the ownership before any act that can cause
    the next schedule.
  - The pump lock guards the shared fields only. It is never held across a call into
    the host or into the writer.
  - RFC 6455 section 5.4 defines the fragments. The last fragment carries FIN, and the
    octets of the call of NextChunk that returns False are that last fragment.
---
}
/// The pump of a streamed WebSocket message
unit Http2.Server.WebSocket.Pump;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs,
  Http2.Common.Body, Http2.Common.Errors, Http2.Server.Duplex,
  Http2.Server.WebSocket.Frames;

const
  cWsPumpStepChunks = 16;
  cWsPumpParkPollMs = 250;

var
  /// the number of chunks of one step that the session passes to a new pump; a test seam
  // - the tests set it to a smaller number and restore it; production code never writes it
  WsPumpStepChunks: Integer = cWsPumpStepChunks;

type
  /// what the pump needs from its session
  IWsPumpHost = interface
    ['{7E1F0C11-00F1-4A11-9C72-000000003001}']
    /// write wire octets as one unit under the send lock
    // - srClosed when no data frame may go out any more
    // - on srQueued with AFin the host counts the message as sent
    function PumpWrite(const AWire: TBytes; const AFin: Boolean): TSendResult;
    /// the channel took a fragment with APayload octets of payload
    procedure PumpCount(const APayload: Integer);
    /// run Step on the streaming pool; False when the pool has stopped
    function PumpSchedule: Boolean;
    /// run TimerFired (never Step) on the streaming pool after ADelayMs; False when the
    /// pool has stopped
    function PumpScheduleAfter(const ADelayMs: Integer): Boolean;
    /// the pump ended: AFailure is nil for a normal end or for a stop
    // - AFailure is valid for the length of the call only
    procedure PumpEnded(const AFailure: Exception);
    /// the pump found a defect of its own (two steps at one time); the host reports it
    procedure PumpDefect(const AText: string);
  end;

  TWsPumpState = (psRunning, psParked, psDone);

  /// the pump, as the session and the pool entries hold it
  // - an interface, so that a pool entry that read the reference keeps the pump alive
  //   while another thread replaces or drops it
  IWsPump = interface
    ['{7E1F0C11-00F1-4A11-9C72-000000003002}']
    /// the streaming pool calls this; at most one call runs at a time
    procedure Step;
    /// the channel drained; safe from any thread
    // - never calls the writer, never writes; at most it calls AHost.PumpSchedule
    procedure Wake;
    /// the park timer fired; safe from any thread; clears the timer flag, then acts as Wake
    procedure TimerFired;
    /// the session ended or closed; safe from any thread; idempotent
    procedure Stop;
    function State: TWsPumpState;
  end;

  /// the next named step of Step
  TWsPumpAct = (paPull, paWrite, paQueued, paLimit, paPark, paExit);

  TWsStreamPump = class(TInterfacedObject, IWsPump)
  private
    FLock: TCriticalSection;
    // the fields that never change after Create
    FText: Boolean;
    FFrameSize: Integer;
    FMaxChunk: Int64;
    FStepChunks: Integer;
    // the shared fields, guarded by FLock
    FState: TWsPumpState;
    /// a Step owns the pump
    FInStep: Boolean;
    /// a drain or a timer signal came while the pump ran
    FDrained: Boolean;
    /// a park timer is pending
    FTimerArmed: Boolean;
    FHost: IWsPumpHost;
    FReader: IBodyWriter;
    // the owner fields: only the Step that owns the pump touches them
    FPending: TBytes;
    FPendingFin: Boolean;
    FPendingPayload: Integer;
    FStarted: Boolean;
    FBuf: TChunkBuffer;
    /// DONE: the end of the pump; returns the host that PumpEnded needs (nil after Stop)
    function Done: IWsPumpHost;
    /// GIVE-UP-OWNERSHIP of STEP-LIMIT; False when a Stop came (the caller does Done)
    function GiveUp: Boolean;
    /// ENTER
    function Enter(out AHost: IWsPumpHost): Boolean;
    function Pull: TWsPumpAct;
    function WriteOut(const AHost: IWsPumpHost): TWsPumpAct;
    function Queued(const AHost: IWsPumpHost): TWsPumpAct;
    function Limit(const AHost: IWsPumpHost; var AChunks: Integer;
      var AOwned: Boolean): TWsPumpAct;
    function Park(const AHost: IWsPumpHost; var AOwned: Boolean): TWsPumpAct;
    /// a host call that schedules; an exception counts as False
    function Schedule(const AHost: IWsPumpHost): Boolean;
    function ScheduleAfter(const AHost: IWsPumpHost; const ADelayMs: Integer): Boolean;
    /// the drain rule of Wake and TimerFired
    procedure Signal(const AClearTimer: Boolean);
  public
    /// AStepChunks is the number of chunks of one step; the session passes
    /// cWsPumpStepChunks, and a test passes a smaller number
    constructor Create(const AReader: IBodyWriter; const AText: Boolean;
      const AFrameSize: Integer; const AMaxChunk: Int64; const AStepChunks: Integer;
      const AHost: IWsPumpHost);
    destructor Destroy; override;
    procedure Step;
    procedure Wake;
    procedure TimerFired;
    procedure Stop;
    function State: TWsPumpState;
  end;

implementation

constructor TWsStreamPump.Create(const AReader: IBodyWriter; const AText: Boolean;
  const AFrameSize: Integer; const AMaxChunk: Int64; const AStepChunks: Integer;
  const AHost: IWsPumpHost);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FReader := AReader;
  FText := AText;
  FFrameSize := AFrameSize;
  FMaxChunk := AMaxChunk;
  FStepChunks := AStepChunks;
  if FStepChunks < 1 then
    FStepChunks := 1;
  FHost := AHost;
  FBuf := TChunkBuffer.Create;
  FState := psRunning;
end;

destructor TWsStreamPump.Destroy;
begin
  FBuf.Free;
  FLock.Free;
  inherited Destroy;
end;

function TWsStreamPump.State: TWsPumpState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TWsStreamPump.Done: IWsPumpHost;
var
  Reader: IBodyWriter;
begin
  // the owner fields go first: nothing touches them after FInStep is False
  FPending := nil;
  FreeAndNil(FBuf);
  FLock.Acquire;
  try
    FState := psDone;
    FInStep := False;
    Result := FHost;
    FHost := nil;
    Reader := FReader;
    FReader := nil;
  finally
    FLock.Release;
  end;
  // the reader is released outside the lock
  Reader := nil;
end;

function TWsStreamPump.GiveUp: Boolean;
begin
  FLock.Acquire;
  try
    // after a Stop the Step ends the pump instead, so it releases the reader
    Result := FState <> psDone;
    if Result then
      FInStep := False;
  finally
    FLock.Release;
  end;
end;

function TWsStreamPump.Enter(out AHost: IWsPumpHost): Boolean;
var
  Defect: Boolean;
begin
  Result := False;
  Defect := False;
  AHost := nil;
  FLock.Acquire;
  try
    // a Step that a late schedule starts after DONE or Stop ends here
    if FState <> psRunning then
      Exit;
    AHost := FHost;
    if FInStep then
      Defect := True
    else
    begin
      FInStep := True;
      Result := True;
    end;
  finally
    FLock.Release;
  end;
  if Defect then
  begin
    // the pump never raises here: an exception would leave a pool thread
    if AHost <> nil then
      AHost.PumpDefect('two pump steps');
    AHost := nil;
  end;
end;

function TWsStreamPump.Pull: TWsPumpAct;
var
  Reader: IBodyWriter;
  Host: IWsPumpHost;
  Stopped, More: Boolean;
  Op: Byte;
  Over: EHttpError;
begin
  FLock.Acquire;
  try
    Stopped := FState = psDone;
    Reader := FReader;
  finally
    FLock.Release;
  end;
  if Stopped then
  begin
    // a Stop came: the host reference is nil already
    Done;
    Reader := nil;
    Exit(paExit);
  end;
  // a wire that the channel refused earlier goes out first
  if Length(FPending) > 0 then
    Exit(paWrite);
  FBuf.Reset;
  try
    More := Reader.NextChunk(FBuf);
  except
    on E: Exception do
    begin
      // E lives until the handler ends: PumpEnded uses it inside the handler
      Host := Done;
      Reader := nil;
      if Host <> nil then
        Host.PumpEnded(E);
      Exit(paExit);
    end;
  end;
  // the reader is never released while NextChunk runs; the local copy goes now
  Reader := nil;
  if FBuf.Size > FMaxChunk then
  begin
    Host := Done;
    if Host <> nil then
    begin
      Over := EHttpError.Create('a chunk of a streamed message is over the size limit');
      try
        Host.PumpEnded(Over);
      finally
        Over.Free;
      end;
    end;
    Exit(paExit);
  end;
  if More and (FBuf.Size = 0) then
    // an empty chunk is skipped
    Exit(paLimit);
  if FStarted then
    Op := WsOpContinuation
  else if FText then
    Op := WsOpText
  else
    Op := WsOpBinary;
  // the wire array holds a copy of the chunk, so FBuf is free for the next call
  // - Integer(FBuf.Size) is safe: TWsOptions caps MaxMessageSize, and so a chunk, at MaxInt
  FPending := WsEncodeFragment(Op, not More, FBuf.Memory^, Integer(FBuf.Size),
    FFrameSize);
  FPendingFin := not More;
  FPendingPayload := Integer(FBuf.Size);
  Result := paWrite;
end;

function TWsStreamPump.WriteOut(const AHost: IWsPumpHost): TWsPumpAct;
begin
  // an exception of the host goes to the handler of Step
  case AHost.PumpWrite(FPending, FPendingFin) of
    srQueued:
      Result := paQueued;
    srClosed:
      begin
        // no data frame may go out any more: the session knows, so this is quiet
        Done;
        Result := paExit;
      end;
  else
    Result := paPark;
  end;
end;

function TWsStreamPump.Schedule(const AHost: IWsPumpHost): Boolean;
begin
  try
    Result := AHost.PumpSchedule;
  except
    Result := False;
  end;
end;

function TWsStreamPump.ScheduleAfter(const AHost: IWsPumpHost;
  const ADelayMs: Integer): Boolean;
begin
  try
    Result := AHost.PumpScheduleAfter(ADelayMs);
  except
    Result := False;
  end;
end;

function TWsStreamPump.Queued(const AHost: IWsPumpHost): TWsPumpAct;
var
  Fin: Boolean;
begin
  AHost.PumpCount(FPendingPayload);
  FStarted := True;
  Fin := FPendingFin;
  FPending := nil;
  if Fin then
  begin
    // the session learned the end from PumpWrite: no PumpEnded call
    Done;
    Exit(paExit);
  end;
  Result := paLimit;
end;

function TWsStreamPump.Limit(const AHost: IWsPumpHost; var AChunks: Integer;
  var AOwned: Boolean): TWsPumpAct;
begin
  Inc(AChunks);
  if AChunks < FStepChunks then
    Exit(paPull);
  if not GiveUp then
  begin
    // a Stop came: this Step ends the pump and releases the reader
    Done;
    Exit(paExit);
  end;
  // from here the Step touches no owner field and ends no pump: the next Step can
  // start at once
  AOwned := False;
  if not Schedule(AHost) then
    Stop;
  Result := paExit;
end;

function TWsStreamPump.Park(const AHost: IWsPumpHost; var AOwned: Boolean): TWsPumpAct;
var
  Gone, Again, ArmTimer: Boolean;
begin
  Gone := False;
  Again := False;
  ArmTimer := False;
  FLock.Acquire;
  try
    if FState = psDone then
      Gone := True
    else if FDrained then
    begin
      // a drain came between the refusal and now: the channel may have room
      FDrained := False;
      Again := True;
    end
    else
    begin
      // GIVE-UP-OWNERSHIP together with the state change
      FInStep := False;
      FState := psParked;
      if not FTimerArmed then
      begin
        FTimerArmed := True;
        ArmTimer := True;
      end;
    end;
  finally
    FLock.Release;
  end;
  if Gone then
  begin
    Done;
    Exit(paExit);
  end;
  if Again then
    Exit(paWrite);
  // no owner field is touched from here, and this Step ends no pump: a Wake can
  // start the next Step now
  AOwned := False;
  if ArmTimer and not ScheduleAfter(AHost, cWsPumpParkPollMs) then
    Stop;
  Result := paExit;
end;

procedure TWsStreamPump.Step;
var
  Host: IWsPumpHost;
  Act: TWsPumpAct;
  Chunks: Integer;
  Owned: Boolean;
  Ended: IWsPumpHost;
begin
  if not Enter(Host) then
    Exit;
  Owned := True;
  Chunks := 0;
  Act := paPull;
  try
    while Act <> paExit do
      case Act of
        paPull: Act := Pull;
        paWrite: Act := WriteOut(Host);
        paQueued: Act := Queued(Host);
        paLimit: Act := Limit(Host, Chunks, Owned);
        paPark: Act := Park(Host, Owned);
      else
        Act := paExit;
      end;
  except
    on E: Exception do
      // an exception of the host or of the encoder: the pump ends like a writer
      // that raised. After Limit or Park gave up ownership this Step ends no pump
      if Owned then
      begin
        Ended := Done;
        if Ended <> nil then
          Ended.PumpEnded(E);
      end;
  end;
end;

procedure TWsStreamPump.Signal(const AClearTimer: Boolean);
var
  Resume: Boolean;
  Host: IWsPumpHost;
begin
  Resume := False;
  Host := nil;
  FLock.Acquire;
  try
    if AClearTimer then
      FTimerArmed := False;
    case FState of
      psParked:
        begin
          // only one caller makes this move, so only one schedule follows
          FState := psRunning;
          Resume := True;
          Host := FHost;
        end;
      psRunning:
        FDrained := True;
    end;
  finally
    FLock.Release;
  end;
  if Resume and (Host <> nil) and not Schedule(Host) then
    Stop;
end;

procedure TWsStreamPump.Wake;
begin
  Signal(False);
end;

procedure TWsStreamPump.TimerFired;
begin
  Signal(True);
end;

procedure TWsStreamPump.Stop;
var
  Host: IWsPumpHost;
  Reader: IBodyWriter;
begin
  FLock.Acquire;
  try
    FState := psDone;
    Host := FHost;
    FHost := nil;
    // a running Step releases the reader at its next PULL check or at DONE
    if not FInStep then
    begin
      Reader := FReader;
      FReader := nil;
    end;
  finally
    FLock.Release;
  end;
  Reader := nil;
  Host := nil;
end;

end.
