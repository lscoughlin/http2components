{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: handler deadline, max handler time, stuck handler, 503, cancel
notes:
  - This unit holds the handler time limit. The tracker lists the running
    handlers with their start times. The watch is a tracker with a thread that
    sweeps the list and answers each handler that passes the limit.
  - A handler thread is never killed. At the limit, the watch claims the
    response and sends a 503 when no head went out, and then cancels the
    handler side of the stream. A handler that never checks for cancel keeps its
    thread until it returns, and the stuck count holds it until then.
  - The claim of the response is one atomic cell for each handler. The handler
    side of the cell is in a response wrapper, so the 503 and a late response
    head of the handler can never both reach the wire.
  - The locks. The tracker lock is a leaf lock: no call into a stream, a
    connection or an observer runs while the tracker holds it.
---
}
/// The handler time limit of the handler pool
unit Http2.Server.HandlerDeadline;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2.Common.Hpack, Http2.Common.Status, Http2.Server.Errors, Http2.Server.Seam,
  Http2.Server.Duplex, Http2.Server.AccessLog, Http2.Server.Stream,
  Http2.Server.StreamAdapters, Http2.Server.HandlerJob;

type
  /// the report of an HTTP/2 handler that passed the limit
  THandlerExpiredEvent = procedure(const AStream: TServerStream) of object;

  /// the report of an HTTP/1.1 handler that passed the limit
  THandlerJobExpiredEvent = procedure(const AJob: IHandlerJob) of object;

  /// a job that can answer for a handler that passed the limit
  // - ExpireHandler answers 503 when no head went out, cancels the handler
  //   side, and closes the connection when a head went out
  IHandlerExpirable = interface
    ['{7E1F0C11-0091-4A11-9C72-000000000C02}']
    procedure ExpireHandler;
  end;

  /// the atomic claim of the response head, shared by a handler and the watch
  // - a detach takes the claim too, so a detached response is not expired
  IDeadlineCell = interface
    ['{7E1F0C11-0091-4A11-9C72-000000000C03}']
    /// the handler takes the head; False when the watch took it first
    function HandlerClaim: Boolean;
    /// the handler detaches; False when the watch took the response first.
    // - APrior receives the state before the claim, for DetachRestore
    function DetachClaim(out APrior: LongInt): Boolean;
    /// a refused detach gives the claim back
    procedure DetachRestore(const APrior: LongInt);
    /// the watch takes the response: 0 when no head went out, 1 when a head
    // went out, and -1 when the response is detached or the watch owns it
    function ExpiryClaim: Integer;
  end;

  TDeadlineCell = class(TInterfacedObject, IDeadlineCell)
  private
    /// the states: see the constants of the implementation
    FState: LongInt;
  public
    function HandlerClaim: Boolean;
    function DetachClaim(out APrior: LongInt): Boolean;
    procedure DetachRestore(const APrior: LongInt);
    function ExpiryClaim: Integer;
  end;

  /// the running handlers and their start times
  // - a method takes the tracker lock for one list operation only
  THandlerDeadlines = class
  private
    type
      TEntry = record
        Stream: TServerStream;
        Job: IHandlerJob;
        Cell: IDeadlineCell;
        StartMs: QWord;
        Fired: Boolean;
      end;
  private
    FLock: TCriticalSection;
    FEntries: TDictionary<Pointer, TEntry>;
    FStuck: Integer;
    procedure Add(const AKey: Pointer; const AEntry: TEntry);
    procedure Remove(const AKey: Pointer);
    function GetStuckCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    /// start the time of the handler of AStream
    procedure Register(const AStream: TServerStream; AStartMs: QWord);
    /// the handler of AStream returned; a handler past its limit leaves the
    /// stuck count here
    procedure Unregister(const AStream: TServerStream);
    /// the same two calls for an HTTP/1.1 job
    procedure RegisterJob(const AJob: IHandlerJob; AStartMs: QWord);
    procedure UnregisterJob(const AJob: IHandlerJob);
    /// report each handler that is AMaxMs old or older, once
    // - the reports run with no lock held. A stream is held by a reference
    //   until its report ends. AMaxMs of 0 reports nothing
    procedure Sweep(ANowMs: QWord; AMaxMs: Integer;
      const AOnExpired: THandlerExpiredEvent;
      const AOnJobExpired: THandlerJobExpiredEvent = nil);
    /// the claim cell of the handler of AStream; nil when it is not listed
    function CellOf(const AStream: TServerStream): IDeadlineCell;
    /// the handlers past the limit that have not returned
    property StuckCount: Integer read GetStuckCount;
  end;

  TDeadlineThread = class;

  /// the tracker with its thread, and the answer to an expired handler
  THandlerDeadlineWatch = class(THandlerDeadlines)
  private
    FMaxMs: Integer;
    /// the address of the observer field of the pool; nil reports to nobody
    FObserver: Pointer;
    FThread: TDeadlineThread;
    procedure Report(const AStreamId: LongWord);
    procedure WaitHeadTaken(const AStream: TServerStream);
  public
    constructor Create(const AMaxMs: Integer; const AObserver: Pointer);
    destructor Destroy; override;
    /// end the thread; the tracker stays usable for Unregister
    procedure Halt;
    procedure ExpireStream(const AStream: TServerStream);
    procedure ExpireJob(const AJob: IHandlerJob);
    property MaxMs: Integer read FMaxMs;
  end;

  /// the thread that sweeps the tracker
  TDeadlineThread = class(TThread)
  private
    FWatch: THandlerDeadlineWatch;
    FWake: PRTLEvent;
    FTickMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AWatch: THandlerDeadlineWatch);
    destructor Destroy; override;
    procedure Stop;
  end;

/// the watch for a limit of AMaxMs; nil when AMaxMs is 0
// - AObserver is the address of an IHttp2ServerObserver field, read at each
//   event, so an observer that is set later is heard
function StartHandlerDeadlines(const AMaxMs: Integer;
  const AObserver: Pointer): THandlerDeadlineWatch;

/// the response that a handler sees: the head and the detach go through the claim
// - ADeadlines nil, an unlisted stream or a response without the probe
//   interfaces answer AResponse unchanged
function WrapDeadlineResponse(const ADeadlines: THandlerDeadlines;
  const AStream: TServerStream; const AResponse: IServerResponse): IServerResponse;

implementation

uses
  Http2.Server.Observer, Http2.Server.ResponseWriter;

const
  /// no head went out and the response is not detached
  cCellOpen = 0;
  /// the handler sent the head
  cCellHeadSent = 1;
  /// the watch owns the response
  cCellWatch = 2;
  /// the handler detached before a head went out
  cCellDetachedOpen = 3;
  /// the handler detached after the head went out
  cCellDetachedHead = 4;

const
  /// the longest wait for the IO side to take a queued 503, in milliseconds
  cHeadTakenWaitMs = 250;

type
  PHttp2ServerObserver = ^IHttp2ServerObserver;

  /// the response of a handler, with the claim of the head in front of it
  TDeadlineResponse = class(TInterfacedObject, IServerResponse, IAccessLogProbe,
    IH2Upgradable)
  private
    FInner: IServerResponse;
    FProbe: IAccessLogProbe;
    FUpgrade: IH2Upgradable;
    FCell: IDeadlineCell;
    procedure Claim;
  public
    constructor Create(const AInner: IServerResponse;
      const AProbe: IAccessLogProbe; const AUpgrade: IH2Upgradable;
      const ACell: IDeadlineCell);
    procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
      const AEndStream: Boolean = False);
    procedure Write(const AData: TBytes); overload;
    procedure Write(const ABuffer; const ACount: Integer); overload;
    procedure SetBodyWriter(const AWriter: IBodyWriter);
    procedure Finish;
    procedure RegisterCancelHook(const AHook: TCancelHook);
    function IsCancelled: Boolean;
    function StreamId: LongWord;
    function Detach: IDuplexChannel;
    function LoggedStatus: Integer;
    function LoggedBodyOctets: Int64;
    function LoggedRemoteAddress: string;
    function LoggedProtocol: string;
    function WsEnvironment: IInterface;
  end;

{ TDeadlineCell }

function TDeadlineCell.HandlerClaim: Boolean;
begin
  // state 0 becomes 1; state 1 stays; state 2 means the watch owns the response
  Result := InterlockedCompareExchange(FState, 1, 0) <> 2;
end;

function TDeadlineCell.DetachClaim(out APrior: LongInt): Boolean;
var
  Old, Next: LongInt;
begin
  // an open response becomes detached; a head that went out keeps its mark
  repeat
    Old := FState;
    APrior := Old;
    if Old = cCellWatch then
      Exit(False);
    if Old = cCellOpen then
      Next := cCellDetachedOpen
    else if Old = cCellHeadSent then
      Next := cCellDetachedHead
    else
      Next := Old;
  until InterlockedCompareExchange(FState, Next, Old) = Old;
  Result := True;
end;

procedure TDeadlineCell.DetachRestore(const APrior: LongInt);
begin
  InterlockedExchange(FState, APrior);
end;

function TDeadlineCell.ExpiryClaim: Integer;
var
  Old: LongInt;
begin
  // a detached response and a response that the watch owns are not expired
  repeat
    Old := FState;
    if (Old = cCellWatch) or (Old = cCellDetachedOpen) or (Old = cCellDetachedHead) then
      Exit(-1);
  until InterlockedCompareExchange(FState, cCellWatch, Old) = Old;
  if Old = cCellOpen then
    Result := 0
  else
    Result := 1;
end;

{ TDeadlineResponse }

constructor TDeadlineResponse.Create(const AInner: IServerResponse;
  const AProbe: IAccessLogProbe; const AUpgrade: IH2Upgradable;
  const ACell: IDeadlineCell);
begin
  inherited Create;
  FInner := AInner;
  FProbe := AProbe;
  FUpgrade := AUpgrade;
  FCell := ACell;
end;

procedure TDeadlineResponse.Claim;
begin
  if not FCell.HandlerClaim then
    raise EStreamCancelled.Create('the handler time limit passed');
end;

procedure TDeadlineResponse.SendHeaders(const AStatus: Integer;
  const AHeaders: THeaderBlock; const AEndStream: Boolean);
begin
  // an interim head (1xx) is not the response
  if AStatus >= 200 then
    Claim;
  FInner.SendHeaders(AStatus, AHeaders, AEndStream);
end;

procedure TDeadlineResponse.Write(const AData: TBytes);
begin
  FInner.Write(AData);
end;

procedure TDeadlineResponse.Write(const ABuffer; const ACount: Integer);
begin
  FInner.Write(ABuffer, ACount);
end;

procedure TDeadlineResponse.SetBodyWriter(const AWriter: IBodyWriter);
begin
  FInner.SetBodyWriter(AWriter);
end;

procedure TDeadlineResponse.Finish;
begin
  FInner.Finish;
end;

procedure TDeadlineResponse.RegisterCancelHook(const AHook: TCancelHook);
begin
  FInner.RegisterCancelHook(AHook);
end;

function TDeadlineResponse.IsCancelled: Boolean;
begin
  Result := FInner.IsCancelled;
end;

function TDeadlineResponse.StreamId: LongWord;
begin
  Result := FInner.StreamId;
end;

function TDeadlineResponse.Detach: IDuplexChannel;
var
  Prior: LongInt;
begin
  // a detached stream may send its head through the channel, so the detach
  // takes the claim: the watch then leaves the stream to its owner
  if not FCell.DetachClaim(Prior) then
    raise EStreamCancelled.Create('the handler time limit passed');
  try
    Result := FInner.Detach;
  except
    // a refused or failed detach leaves the stream as it was
    FCell.DetachRestore(Prior);
    raise;
  end;
end;

function TDeadlineResponse.LoggedStatus: Integer;
begin
  Result := FProbe.LoggedStatus;
end;

function TDeadlineResponse.LoggedBodyOctets: Int64;
begin
  Result := FProbe.LoggedBodyOctets;
end;

function TDeadlineResponse.LoggedRemoteAddress: string;
begin
  Result := FProbe.LoggedRemoteAddress;
end;

function TDeadlineResponse.LoggedProtocol: string;
begin
  Result := FProbe.LoggedProtocol;
end;

function TDeadlineResponse.WsEnvironment: IInterface;
begin
  Result := FUpgrade.WsEnvironment;
end;

{ THandlerDeadlines }

constructor THandlerDeadlines.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<Pointer, TEntry>.Create;
end;

destructor THandlerDeadlines.Destroy;
begin
  FEntries.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure THandlerDeadlines.Add(const AKey: Pointer; const AEntry: TEntry);
begin
  FLock.Acquire;
  try
    FEntries.AddOrSetValue(AKey, AEntry);
  finally
    FLock.Release;
  end;
end;

procedure THandlerDeadlines.Remove(const AKey: Pointer);
var
  Entry: TEntry;
begin
  FLock.Acquire;
  try
    if FEntries.TryGetValue(AKey, Entry) then
    begin
      FEntries.Remove(AKey);
      // the handler returned: it leaves the stuck count
      if Entry.Fired then
        Dec(FStuck);
    end;
  finally
    FLock.Release;
  end;
end;

function THandlerDeadlines.GetStuckCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FStuck;
  finally
    FLock.Release;
  end;
end;

procedure THandlerDeadlines.Register(const AStream: TServerStream;
  AStartMs: QWord);
var
  Entry: TEntry;
begin
  Entry := Default(TEntry);
  Entry.Stream := AStream;
  Entry.Cell := TDeadlineCell.Create;
  Entry.StartMs := AStartMs;
  Add(AStream, Entry);
end;

procedure THandlerDeadlines.Unregister(const AStream: TServerStream);
begin
  Remove(AStream);
end;

procedure THandlerDeadlines.RegisterJob(const AJob: IHandlerJob;
  AStartMs: QWord);
var
  Entry: TEntry;
begin
  Entry := Default(TEntry);
  Entry.Job := AJob;
  Entry.StartMs := AStartMs;
  Add(Pointer(AJob), Entry);
end;

procedure THandlerDeadlines.UnregisterJob(const AJob: IHandlerJob);
begin
  Remove(Pointer(AJob));
end;

function THandlerDeadlines.CellOf(const AStream: TServerStream): IDeadlineCell;
var
  Entry: TEntry;
begin
  Result := nil;
  FLock.Acquire;
  try
    if FEntries.TryGetValue(AStream, Entry) then
      Result := Entry.Cell;
  finally
    FLock.Release;
  end;
end;

procedure THandlerDeadlines.Sweep(ANowMs: QWord; AMaxMs: Integer;
  const AOnExpired: THandlerExpiredEvent;
  const AOnJobExpired: THandlerJobExpiredEvent);
var
  Pair: TPair<Pointer, TEntry>;
  Due: TList<TEntry>;
  Entry: TEntry;
  Keys: TList<Pointer>;
  I: Integer;
begin
  if AMaxMs <= 0 then
    Exit;
  Due := TList<TEntry>.Create;
  Keys := TList<Pointer>.Create;
  try
    FLock.Acquire;
    try
      for Pair in FEntries do
        if (not Pair.Value.Fired) and (ANowMs >= Pair.Value.StartMs) and
           (ANowMs - Pair.Value.StartMs >= QWord(AMaxMs)) then
          Keys.Add(Pair.Key);
      for I := 0 to Keys.Count - 1 do
      begin
        Entry := FEntries[Keys[I]];
        Entry.Fired := True;
        FEntries[Keys[I]] := Entry;
        Inc(FStuck);
        // the reference keeps the stream alive after the handler returns
        if Entry.Stream <> nil then
          Entry.Stream.AddRef;
        Due.Add(Entry);
      end;
    finally
      FLock.Release;
    end;
    for I := 0 to Due.Count - 1 do
    begin
      Entry := Due[I];
      try
        try
          if Entry.Stream <> nil then
          begin
            if Assigned(AOnExpired) then
              AOnExpired(Entry.Stream);
          end
          else if Assigned(AOnJobExpired) then
            AOnJobExpired(Entry.Job);
        except
          // one failed report must not stop the others
        end;
      finally
        if Entry.Stream <> nil then
          Entry.Stream.ReleaseRef;
      end;
    end;
  finally
    Keys.Free;
    Due.Free;
  end;
end;

{ TDeadlineThread }

constructor TDeadlineThread.Create(const AWatch: THandlerDeadlineWatch);
begin
  FWatch := AWatch;
  FWake := RTLEventCreate;
  // a few checks within the limit; never below 5 ms and never above 100 ms
  FTickMs := AWatch.MaxMs div 4;
  if FTickMs < 5 then
    FTickMs := 5;
  if FTickMs > 100 then
    FTickMs := 100;
  inherited Create(False);
end;

destructor TDeadlineThread.Destroy;
begin
  RTLEventDestroy(FWake);
  inherited Destroy;
end;

procedure TDeadlineThread.Stop;
begin
  Terminate;
  RTLEventSetEvent(FWake);
  WaitFor;
end;

procedure TDeadlineThread.Execute;
begin
  while not Terminated do
  begin
    RTLEventWaitFor(FWake, FTickMs);
    if Terminated then
      Break;
    try
      FWatch.Sweep(GetTickCount64, FWatch.MaxMs, FWatch.ExpireStream,
        FWatch.ExpireJob);
    except
      // the thread must outlive a failed sweep
    end;
  end;
end;

{ THandlerDeadlineWatch }

constructor THandlerDeadlineWatch.Create(const AMaxMs: Integer;
  const AObserver: Pointer);
begin
  inherited Create;
  FMaxMs := AMaxMs;
  FObserver := AObserver;
  FThread := TDeadlineThread.Create(Self);
end;

destructor THandlerDeadlineWatch.Destroy;
begin
  Halt;
  inherited Destroy;
end;

procedure THandlerDeadlineWatch.Halt;
var
  Thread: TDeadlineThread;
begin
  Thread := FThread;
  FThread := nil;
  if Thread <> nil then
  begin
    Thread.Stop;
    Thread.Free;
  end;
end;

procedure THandlerDeadlineWatch.Report(const AStreamId: LongWord);
var
  Observer: IHttp2ServerObserver;
  Timeout: IHttp2HandlerTimeoutObserver;
begin
  if FObserver = nil then
    Exit;
  Observer := PHttp2ServerObserver(FObserver)^;
  if (Observer <> nil) and Supports(Observer, IHttp2HandlerTimeoutObserver,
    Timeout) then
    try
      Timeout.OnHandlerTimeout(AStreamId, StuckCount);
    except
      // an observer must not end the deadline thread
    end;
end;

procedure THandlerDeadlineWatch.WaitHeadTaken(const AStream: TServerStream);
var
  Until_: QWord;
begin
  // the RST_STREAM must follow the 503 on the wire. The IO side encodes the
  // queued head when it next flushes; the wait is short and bounded
  Until_ := GetTickCount64 + cHeadTakenWaitMs;
  while AStream.HasPendingHeaders and (not AStream.IsCancelled) and
        (GetTickCount64 < Until_) do
    Sleep(1);
end;

procedure THandlerDeadlineWatch.ExpireStream(const AStream: TServerStream);
var
  Cell: IDeadlineCell;
  Taken: Integer;
begin
  Cell := CellOf(AStream);
  // no cell: the handler returned after the sweep chose it
  if Cell = nil then
    Exit;
  // a detached stream is not subject to the limit: its owner keeps it
  Taken := Cell.ExpiryClaim;
  if Taken < 0 then
    Exit;
  if not AStream.IsCancelled then
  begin
    // 1: answer 503 when no head went out
    if Taken = 0 then
    begin
      AStream.QueueResponseHeaders(HttpStatusServiceUnavailable,
        WithDate(nil, HttpStatusServiceUnavailable), True);
      WaitHeadTaken(AStream);
    end;
    // 2, 3 and 4: cancel the handler side, reset the stream and free the slot
    AStream.Refuse(ecCancel);
  end;
  Report(AStream.StreamId);
end;

procedure THandlerDeadlineWatch.ExpireJob(const AJob: IHandlerJob);
var
  Expirable: IHandlerExpirable;
  Request: IServerRequest;
  Id: LongWord;
begin
  Id := 0;
  if Supports(AJob, IServerRequest, Request) then
    Id := Request.StreamId;
  Request := nil;
  if Supports(AJob, IHandlerExpirable, Expirable) then
    Expirable.ExpireHandler;
  Report(Id);
end;

{ unit routines }

function StartHandlerDeadlines(const AMaxMs: Integer;
  const AObserver: Pointer): THandlerDeadlineWatch;
begin
  Result := nil;
  if AMaxMs > 0 then
    Result := THandlerDeadlineWatch.Create(AMaxMs, AObserver);
end;

function WrapDeadlineResponse(const ADeadlines: THandlerDeadlines;
  const AStream: TServerStream; const AResponse: IServerResponse): IServerResponse;
var
  Cell: IDeadlineCell;
  Probe: IAccessLogProbe;
  Upgrade: IH2Upgradable;
begin
  Result := AResponse;
  if ADeadlines = nil then
    Exit;
  Cell := ADeadlines.CellOf(AStream);
  if (Cell <> nil) and Supports(AResponse, IAccessLogProbe, Probe) and
     Supports(AResponse, IH2Upgradable, Upgrade) then
    Result := TDeadlineResponse.Create(AResponse, Probe, Upgrade, Cell);
end;

end.
