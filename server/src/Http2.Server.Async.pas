{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, io pool, tls, wake-up
notes:
  - This unit implements the async server listener and connection methods.
---
}
unit Http2.Server.Async;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}
interface
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, {$IFDEF UNIX}Sockets,{$ENDIF}
  mormot.core.base,
  mormot.core.os,
  mormot.core.threads,
  mormot.net.sock,
  mormot.net.async,
  mormot.net.server,
  Http2.Server.Errors,
  Http2.Server.Config,
  Http2.Server.Connection,
  Http2.Server.Limits,
  Http2.Server.Observer,
  Http2.Server.Output,
  Http2.Server.Seam,
  Http2.Server.Duplex,
  Http2.Server.StreamPool,
  Http2.Server.Stream,
  Http2.Server.Admission,
  Http2.Server.HandlerJob,
  Http2.Server.Http1.Limits,
  Http2.Server.Http1.Select,
  Http2.Server.Http1.Core,
  Http2.Server.Http1.Driver,
  Http2.Server.ClientCert,
  Http2.Server.Mtls.Types,
  Http2.Server.Async.Events,
  Http2.Server.Async.Options,
  Http2.Server.Async.Counters,
  Http2.Server.Async.Waker,
  Http2.Server.Async.Sweep,
  Http2.Server.Async.Socket,
  Http2.Server.Tls.Binding, Http2.Server.Tls.Adapter,
  Http2.Common.Tls.Context, Http2.Common.Tls.Session,
  Http2.Common.Tls.Types;

const
  /// the time a staged close waits for the peer to close first, in seconds
  cDrainSeconds = 2;
  /// the how argument of shutdown that closes the write side
  cShutWrite = 1;

type
  THttp2AsyncServer = class;
  THttp2AsyncConnection = class;

  /// the protocol that a connection speaks, once it is known
  TConnectionMode = (cmUndecided, cmHttp2, cmHttp1);

  /// one connection of the HTTP/2 async server
  ///
  /// The object owns one TServerConnectionCore.  The core holds its own lock,
  /// and every stream takes that lock too, so a handler buffer operation never
  /// races the IO thread.
  THttp2AsyncConnection = class(TAsyncConnection)
  public
    FServer: THttp2AsyncServer;   // weak reference; the owner frees this
    FCore: TServerConnectionCore;
    FEvents: IConnectionEvents;
    FWaker: IWriteWaker;
    FMethodWaker: TMethodWaker;
    /// the protocol of the connection; undecided until the first octets
    FMode: TConnectionMode;
    /// the verified client certificate of this connection; nil when none
    FClientCert: IClientCertificate;
    FTlsAdapter: TServerTlsAdapter;
    FPendingTlsPlain: TBytes;
    FPendingTlsOffset: SizeInt;
    FPendingTlsCount: SizeInt;
    FHandshakeDeadlineMs: Int64;
    FClearTextTransport: Boolean;
    FPeerTlsClosed: Boolean;
    FLocalTlsShutdown: Boolean;
    /// the HTTP/1.1 core; nil on an HTTP/2 connection
    FH1: TH1Driver;
    FH1Events: IH1Events;
    /// the second at which a staged close ends; 0 while the connection serves
    /// the monotonic second at which the first header block must have ended
    // - zero once the first request reached the core
    FHeaderDeadlineSec: TAsyncConnectionSec;
    /// the idle period of this connection, in seconds
    // - taken from the factory; zero disables the idle close
    FIdleSeconds: cardinal;
    /// guards the write path against its own nested AfterWrite callback
    // - fOwner.Write may call AfterWrite before it returns, so this flag keeps
    //   one send loop per connection
    FInSend: Boolean;
    /// a wake-up that arrived while the send loop ran
    // - the outer loop repeats when this flag is set, so a wake-up that
    //   loses the race to the loop exit is never lost
    FSendRequested: Boolean;
    /// guards the two send flags
    FSendLock: TCriticalSection;
    FAcceptedMs: QWord; // the accept time in milliseconds, for the age sweep
    FJitterPermille: Integer; // the age reduction in permille, drawn at accept
    FRetireDeadlineMs: QWord; // the end of the retire grace, or 0
    FLastWriteProgressMs: QWord; FLastSweepBacklog: Int64; // the stall state of the sweep
    FLastSocketBytesSent, FLastKernelQueueBytes: Int64;
    FHasKernelQueueSample: Boolean;
    function PumpTlsInput(out AProgress: Boolean): Boolean;
    function PumpTlsOutput: Boolean;
    function AcceptPendingTlsPlaintext: Boolean;
    function DrainTlsClose: Boolean;
    procedure StartHttp2;
    procedure StartHttp1;
    /// the retire notice of a core: raise it on the observer of the server
    procedure RetireNotified(const AEvent: TServerEvent);
    /// the retire notice of the HTTP/1.1 core: raise it without a GOAWAY,
    /// because no GOAWAY frame leaves the server on a HTTP/1.1 retire
    procedure H1RetireNotified(const AEvent: TServerEvent);
    /// the method the waker calls: drain the core and write
    procedure WakeOutput;
    function OnReadHttp1: TPollAsyncSocketOnReadWrite;
    function CheckHeaderDeadline: Boolean;
    function PendingWriteBytes: Int64;
    function PullOutput(out AData: TBytes): Boolean;
    function OutputPending: Boolean;
    procedure ApplyClosePhase;
    procedure CloseAbortively;
    /// drop the state of the connection that ended: both cores, the waker and the lock
    procedure ReleaseState;
  protected
    procedure AfterCreate; override;
    procedure BeforeDestroy; override;
    /// mORMot2 reuses the instance of a closed connection and calls this method, not
    /// BeforeDestroy, so the state of the old connection must go here
    procedure Recycle(const aRemoteIP: TNetAddr); override;
    /// reject an accepted connection when the server is draining
    function OnFirstRead(aOwner: TPollAsyncSockets): boolean; override;
    function OnRead: TPollAsyncSocketOnReadWrite; override;
    function AfterWrite: TPollAsyncSocketOnReadWrite; override;
    function OnLastOperationIdle(nowsec: TAsyncConnectionSec): boolean; override;
    procedure OnClose; override;
  public
    /// encode the pending headers, drain the stream buffers and queue the
    /// frames for the socket
    function SendPendingOutput: Boolean;
    /// the age-sweep decision of the server for this connection
    procedure CheckAge(const ANowMs: QWord;
      const AMaxAgeMs, AGraceMs: Integer);
    /// the write-stall decision of the server for this connection
    procedure CheckWriteStall(const ANowMs: QWord; const ATimeoutMs: Integer);
    procedure CheckHandshakeDeadline(const ANowMs: QWord);
    /// the connection core (test and observer seam)
    property Core: TServerConnectionCore read FCore;
    /// the write waker of this connection
    property Waker: IWriteWaker read FWaker;
    property H1: TH1Driver read FH1;
    property LastWriteProgressMs: QWord read FLastWriteProgressMs write FLastWriteProgressMs; // the test seam of the write check
    property BytesSentForProgress: Int64 read fBytesSend;
  end;

  /// the HTTP/2 async server
  ///
  /// The record form of the factory is copied at Create time.  The server owns
  /// the handler pool, because the pool and its queue are shared by every
  /// connection.
  THttp2AsyncServer = class(TAsyncServer)
  public
    FFactory: THttp2ServerFactory;
    FHandlers: THandlerPool;
    /// the registry of detached streams: the limit, the list, the queue sizes
    FChannels: IChannelRegistry;
    /// the same object as FChannels, kept to set its provider and settings
    FChannelImpl: TChannelRegistry;
    /// the streaming pool: the application work of detached streams
    FStreamPool: TStreamPool;
    FTlsBinding: ITlsServerBinding;
    FCoreOptions: TConnectionCoreOptions;
    FControlBucket: TTokenBucketOptions;
    FStarted: Boolean;
    /// Stop began: new connections close at once
    FDraining: Boolean;
    /// the observer of the server; nil when the caller set none
    FObserver: IHttp2ServerObserver;
    /// the connection, reset, trip and handshake counters
    FCounters: TServerCounters;
  protected
    /// the idle period before OnLastOperationIdle runs, in seconds
    // - the base class returns zero, which disables the event, so the server
    //   enables it with the factory idle timeout
    function GetLastOperationIdleSeconds: cardinal; override;
    /// retire the connections past their maximum age, once per second
    // - the idle callback misses busy connections, so the sweep runs here
    procedure IdleEverySecond; override;
  public
    /// create the listener from the factory
    // - the factory must pass Validate before this call
    constructor Create(const AFactory: THttp2ServerFactory); reintroduce;
    destructor Destroy; override;

    /// bind, then install the server TLS context and the ALPN callback
    procedure Start;
    /// stop the handler pool and shut the IO pools down
    // - AWaitMs bounds each wait of the handler pool; -1 uses the graceful timeout
    procedure Stop(const AWaitMs: Integer = -1);

    /// the handler pool that serves every connection
    property Handlers: THandlerPool read FHandlers;
    /// the registry of the detached streams of the server
    property Channels: IChannelRegistry read FChannels;
    /// the streaming pool
    property StreamPool: TStreamPool read FStreamPool;
    /// the core options every connection uses
    property CoreOptions: TConnectionCoreOptions read FCoreOptions;
    /// the single control-frame bucket the core charges
    property ControlBucket: TTokenBucketOptions read FControlBucket;
    /// the TCP port the listening socket holds, after Start
    function BoundPort: Integer;
    /// the factory the server was built from
    property Factory: THttp2ServerFactory read FFactory;
    /// the observer of the server
    // - the observer runs on the thread that raised the event, so it must be
    //   set before Start and never changed while the server runs
    property Observer: IHttp2ServerObserver read FObserver write FObserver;
    /// the counters of the server; they live as long as the server object
    property Counters: TServerCounters read FCounters;
    /// count one accepted connection and tell the observer, on the IO thread
    procedure ConnectionOpened;
    /// count one closed connection and tell the observer, on the IO thread
    procedure ConnectionClosed;
    /// send one event to the observer, on the thread that raised it
    procedure Notify(const AEvent: TServerEvent); overload;
    procedure Notify(const AKind: TServerEventKind; const AStreamId: LongWord;
      const ALimit: TLimitKind; const ADetail: string); overload;
    /// queue a GOAWAY frame on every open connection, then wake its output
    // - the last stream identifier that the core processed goes into the
    //   frame, so a peer keeps the streams below it
    procedure WaitBindDone;
    procedure AfterConstruction; override;
    procedure BroadcastGoAway(const AErrorCode: THttp2ErrorCode);
    /// refuse new connections and tell every HTTP/1.1 connection to close after
    /// the request it serves
    procedure BeginDrain;
    property Draining: Boolean read FDraining;
    /// close every detached stream: the graceful form sends the queued bytes
    /// and END_STREAM, the abort form resets the stream
    procedure CloseChannels(const AMode: TChannelClose);
    /// the streams that are open on every connection now
    function OpenStreamTotal: Integer;
    /// count one failed handshake and tell the observer, on the IO thread
    procedure TlsHandshakeFailed(const ADetail: string);
  end;

implementation
const
  /// the seconds WaitStarted waits for the bind to complete
  cBindWaitSeconds = 5;
  /// the write timeout a handler-thread wake-up tolerates, in milliseconds
  cWriteTimeoutMs = 1000;
var
  /// serializes the set of DefaultListenBacklog with the bind that reads it
  GBindLock: TCriticalSection;
{ THttp2AsyncConnection }
procedure THttp2AsyncConnection.WakeOutput;
begin
  try
    SendPendingOutput;
  except
    on ETlsSessionError do
      // A socket close can fail the TLS session before a handler or Stop
      // wakes this connection to drain its final output.  SendPendingOutput
      // has released its send guard here, so only this failed connection is
      // removed and the wake caller cannot lose a pool thread or stop sequence.
      CloseAbortively;
  end;
end;
procedure THttp2AsyncConnection.AfterCreate;
begin
  FServer := THttp2AsyncServer(fOwner);
  ApplySocketOptions(fSocket, FServer.Factory.Socket);
  FAcceptedMs := mormot.core.os.GetTickCount64; FJitterPermille := Random(101);
  if FServer.FTlsBinding <> nil then
    FHandshakeDeadlineMs := TlsHandshakeDeadline(FAcceptedMs,
      FServer.FTlsBinding.Context.Info.HandshakeTimeoutMs);
  FLastWriteProgressMs := FAcceptedMs; FLastSweepBacklog := 0;
  FLastSocketBytesSent := fBytesSend; FLastKernelQueueBytes := 0;
  FHasKernelQueueSample := False;
  FHeaderDeadlineSec := HeaderDeadlineSec(mormot.core.os.GetTickCount64,
    FServer.Factory.HeaderTimeoutMs);
  FIdleSeconds := cardinal(FServer.Factory.IdleTimeoutMs div 1000);
  FSendLock := TCriticalSection.Create;
  FMode := cmUndecided;
  FServer.ConnectionOpened;
end;
procedure THttp2AsyncConnection.StartHttp2;
begin
  FEvents := THttp2ConnectionEvents.Create(FServer.Handlers, FServer.Notify,
    FServer.Counters.StreamResetted, FServer.Counters.BucketTripped,
    PeerAddressText(RemoteIP, fRemoteIP4), FClientCert);
  FCore := TServerConnectionCore.Create(FServer.CoreOptions, FEvents,
    BuildConnectionLimits(FServer.Factory), FServer.Factory.Clock);
  FMethodWaker := TMethodWaker.Create(WakeOutput);
  FWaker := FMethodWaker;
  FCore.SetWriteWaker(FWaker);
  FCore.OnRetired := RetireNotified;
  FMode := cmHttp2;
end;

procedure THttp2AsyncConnection.StartHttp1;
var
  Core: TH1Core;
begin
  FH1Events := THttp1ConnectionEvents.Create(FServer.Handlers,
    PeerAddressText(RemoteIP, fRemoteIP4), FClientCert);
  Core := TH1Core.Create(
    BuildH1CoreOptions(FServer.Factory, FTlsAdapter <> nil), FH1Events);
  Core.OnRetired := H1RetireNotified;
  FMethodWaker := TMethodWaker.Create(WakeOutput);
  FWaker := FMethodWaker;
  Core.SetWriteWaker(FWaker);
  Core.SetPendingProbe(PendingWriteBytes);
  // a TLS connection cannot close its write side alone, so it closes at once
  FH1 := TH1Driver.Create(Core, FTlsAdapter = nil);
  FMode := cmHttp1;
end;

procedure THttp2AsyncConnection.ReleaseState;
begin
  // a handler thread must not call into this connection while it is freed
  if FMethodWaker <> nil then
    FMethodWaker.Detach;
  if FCore <> nil then
    FCore.ReleaseHost;
  if FH1 <> nil then
    FH1.Core.ReleaseHost;
  FreeAndNil(FTlsAdapter);
  if FServer <> nil then
    FServer.ConnectionClosed;
  FreeAndNil(FSendLock);
  FreeAndNil(FCore);
  FreeAndNil(FH1);
  FH1Events := nil;
  FWaker := nil;
  FMethodWaker := nil;
  FEvents := nil;
  FInSend := False;
  FSendRequested := False;
  FClientCert := nil;
  FPendingTlsPlain := nil;
  FPendingTlsOffset := 0;
  FPendingTlsCount := 0;
  FHandshakeDeadlineMs := 0;
  FClearTextTransport := False;
  FPeerTlsClosed := False;
  FLocalTlsShutdown := False;
  FMode := cmUndecided;
  FRetireDeadlineMs := 0; FLastWriteProgressMs := 0; FLastSweepBacklog := 0;
  FLastSocketBytesSent := 0; FLastKernelQueueBytes := 0; FHasKernelQueueSample := False;
  FServer := nil;
end;

procedure THttp2AsyncConnection.BeforeDestroy;
begin
  ReleaseState;
end;

procedure THttp2AsyncConnection.Recycle(const aRemoteIP: TNetAddr);
begin
  // the instance of a closed connection serves the next one. Without this reset the
  // new connection keeps the HTTP/1.1 core of the old one, PullOutput reads that
  // core, and the output of the new connection never leaves
  ReleaseState;
  inherited Recycle(aRemoteIP);
end;

{$I Http2.Server.Async.Tls.inc}

function THttp2AsyncConnection.SendPendingOutput: Boolean;
var
  Data: TBytes;
  Again, PendingPlainProgress, OwnsSend: Boolean; Before, After: Int64;
begin
  result := False;
  OwnsSend := False;
  if ((FCore = nil) and (FH1 = nil)) or IsClosed then
    exit;
  // a wake-up that arrives while the loop runs is recorded and not dropped,
  // because the outer loop repeats once the flag is set.  The lock closes the
  // race between the loop exit and the last wake-up
  FSendLock.Acquire;
  try
    FSendRequested := True;
    if FInSend then
      exit;   // the running loop owns the send path and will repeat
    FInSend := True;
    OwnsSend := True;
  finally
    FSendLock.Release;
  end;
  try
    Again := True;
    while Again do
    begin
      FSendLock.Acquire;
      try
        FSendRequested := False;
      finally
        FSendLock.Release;
      end;
      PendingPlainProgress := False;
      // the drain turns the handler buffers into DATA frames.  It runs under
      // the core lock, which every stream also takes, so the HPACK encoder
      // keeps one owner per connection
      if FCore <> nil then
      begin
        FCore.DrainPending;
        // the output queue passed its cap: the peer does not read, so the
        // connection ends at once and the queued bytes are dropped
        if FCore.Aborted then
        begin
          CloseAbortively;
          exit;
        end;
      end;
      if FTlsAdapter <> nil then
      begin
        Before := FPendingTlsCount;
        if not AcceptPendingTlsPlaintext then
        begin
          if FTlsAdapter.TransportFailed then
          begin
            CloseAbortively;
            exit;
          end;
          PumpTlsOutput;
        end;
        PendingPlainProgress := (Before > FPendingTlsCount);
      end;
      while ((FTlsAdapter = nil) or (FPendingTlsCount = 0)) and
            PullOutput(Data) do
      begin
        if FTlsAdapter <> nil then
        begin
          FPendingTlsPlain := Data;
          FPendingTlsOffset := 0;
          FPendingTlsCount := Length(Data);
          if not AcceptPendingTlsPlaintext then
          begin
            if FTlsAdapter.TransportFailed then
            begin
              CloseAbortively;
              exit;
            end;
            Break;
          end;
          PendingPlainProgress := FPendingTlsCount < Length(Data);
          result := True;
          if (FServer.CoreOptions.MaxOutputBytes > 0) and
             (PendingWriteBytes > Int64(FServer.CoreOptions.MaxOutputBytes)) then
          begin
            CloseAbortively;
            exit;
          end;
          Continue;
        end;
        Before := PendingWriteBytes;
        // the mORMot2 write path takes the connection write lock, sends at
        // once when it can, and otherwise subscribes for the write event.  A
        // false answer means the lock went to the IO thread, so one retry runs
        // the second check of the mORMot2 wake-up pattern
        if not fOwner.Write(Self, pointer(Data), Length(Data),
             cWriteTimeoutMs) then
          if not fOwner.Write(Self, pointer(Data), Length(Data),
               cWriteTimeoutMs) then
          begin
            // the bytes did not reach the write path. A stream with a hole in it
            // cannot continue, so the connection ends
            CloseAbortively;
            exit;
          end;
        result := True;
        // a shrunk or new backlog is progress; the sweep measures from here
        After := PendingWriteBytes;
        if (After < Before) or ((Before = 0) and (After > 0)) then
          FLastWriteProgressMs := mormot.core.os.GetTickCount64;
        // the batch reached the write path, so the budget releases what the
        // peer received; the core call takes the connection lock itself
        if (FCore <> nil) and (FTlsAdapter = nil) then
          FCore.ReportWritten(FCore.HandedOutTotal - PendingWriteBytes);
        // the bytes that mORMot2 holds for the socket count against the cap too
        if (FServer.CoreOptions.MaxOutputBytes > 0) and
           (PendingWriteBytes > Int64(FServer.CoreOptions.MaxOutputBytes)) then
        begin
          CloseAbortively;
          exit;
        end;
      end;
      // The exit decision and the FInSend clear share one lock hold.  A
      // handler that writes during the drain finds FInSend true and only
      // records FSendRequested, so the clear must re-read that flag in the
      // same hold that ends the loop.  A clear in a later hold would drop the
      // record, and the handler would wait for a drain that never comes.
      FSendLock.Acquire;
      try
        if FSendRequested or
           ((FPendingTlsCount > 0) and PendingPlainProgress) or
           ((FPendingTlsCount = 0) and OutputPending) then
          Again := True
        else
        begin
          FInSend := False;
          OwnsSend := False;
          Again := False;
        end;
      finally
        FSendLock.Release;
      end;
      // the loop repeats for a late wake-up or for output a handler just made
    end;
  finally
    // Exceptional and abort exits still release this invocation's claim.
    // The normal loop exit already released it atomically with its wake check;
    // do not clear a new sender's claim after that handoff.
    if OwnsSend then
    begin
      FSendLock.Acquire;
      try
        FInSend := False;
        OwnsSend := False;
      finally
        FSendLock.Release;
      end;
    end;
  end;
  // the close decision of an HTTP/1.1 exchange can come after the last write,
  // so the end of every send loop looks at it too
  if FMode = cmHttp1 then
    ApplyClosePhase;
end;

function THttp2AsyncConnection.OnLastOperationIdle(
  nowsec: TAsyncConnectionSec): boolean;
begin
  result := false;
  if FMode = cmHttp1 then
  begin
    case FH1.IdleAction(nowsec, fLastOperation, FIdleSeconds, mormot.core.os.GetTickCount64,
      FServer.Factory.HeaderTimeoutMs) of
      iaFlush:
        SendPendingOutput;
      iaClose:
        begin
          fOwner.ConnectionRemove(Handle);
          exit(True);
        end;
    end;
    exit;
  end;
  if FMode = cmUndecided then
  begin
    if IdleUndecidedClose(nowsec, FHeaderDeadlineSec, fLastOperation, FIdleSeconds) then
    begin
      fOwner.ConnectionRemove(Handle);
      exit(True);
    end;
    exit;
  end;
  if (FCore <> nil) and IdleHttp2Close(nowsec, FHeaderDeadlineSec,
    fLastOperation, FIdleSeconds, FCore.OpenStreams, FCore.HasOutput) then
  begin
    fOwner.ConnectionRemove(Handle);
    Result := True;
  end;
end;

procedure THttp2AsyncConnection.RetireNotified(const AEvent: TServerEvent);
begin
  FServer.Notify(AEvent);
  FServer.Notify(seGoAwaySent, 0, lkReset,
    'the server sends GOAWAY on a retired connection');
end;

procedure THttp2AsyncConnection.H1RetireNotified(const AEvent: TServerEvent);
begin
  FServer.Notify(AEvent);
end;

procedure THttp2AsyncConnection.CheckAge(const ANowMs: QWord;
  const AMaxAgeMs, AGraceMs: Integer);
var
  Action: TAgeAction;
begin
  if FMode = cmUndecided then
  begin
    if AgeExpired(ANowMs, FAcceptedMs, AMaxAgeMs, FJitterPermille) then
      fOwner.ConnectionRemove(Handle);
    Exit;
  end;
  if FMode = cmHttp1 then
    Action := Http1AgeAction(FH1, ANowMs, FAcceptedMs, AMaxAgeMs,
      FJitterPermille, FRetireDeadlineMs)
  else
    Action := Http2AgeAction(FCore, ANowMs, FAcceptedMs, AMaxAgeMs,
      FJitterPermille, PendingWrite, FRetireDeadlineMs);
  case Action of
    aaCloseNow:
      fOwner.ConnectionRemove(Handle);
    aaRetireH2:
      FCore.Retire(RetireDetailMaxAge);
    aaFinalizeH2:
      FCore.SendFinalGoAway;
    aaDrainH1:
      begin
        FH1.Core.BeginDrain;
        FServer.Notify(seConnectionRetired, 0, lkReset, RetireDetailMaxAge);
      end;
  end;
  // every forward step except the at-once close wakes the writer: the
  // retire and the drain still have a GOAWAY or a close to send
  if Action in [aaRetireH2, aaFinalizeH2, aaDrainH1] then
    FWaker.Signal;
  if Action in [aaRetireH2, aaDrainH1] then
    FRetireDeadlineMs := ANowMs + QWord(AGraceMs);
  // a zero grace closes at once, as Stop with a zero wait does
  if (Action in [aaRetireH2, aaDrainH1]) and (AGraceMs <= 0) then
    fOwner.ConnectionRemove(Handle);
end;

procedure THttp2AsyncConnection.CheckWriteStall(const ANowMs: QWord;
  const ATimeoutMs: Integer);
var
  Backlog: Int64;
begin
  if ATimeoutMs <= 0 then Exit;
  if FMode = cmHttp1 then
  begin
    // Preserve HTTP/1 idle and output-progress behavior.
    Backlog := FH1.Core.OutputBacklog;
    if (Backlog > 0) and
       ((FLastSweepBacklog <= 0) or (Backlog < FLastSweepBacklog)) then
      FLastWriteProgressMs := ANowMs;
    FLastSweepBacklog := Backlog;
  end
  else begin
    Backlog := PendingWriteBytes;
    if not ObserveWriteProgress(fOwner, Self, Backlog, ANowMs,
      FLastSweepBacklog, FLastSocketBytesSent, FLastKernelQueueBytes,
      FHasKernelQueueSample, FLastWriteProgressMs) then
      Exit;
  end;
  if WriteStalled(ANowMs, FLastWriteProgressMs, ATimeoutMs, Backlog) then
  begin
    CloseAbortively;
    Exit;
  end;
  if FMode = cmHttp1 then
    case FH1.IdleAction(Cardinal(ANowMs div 1000), fLastOperation,
      FIdleSeconds, ANowMs, FServer.Factory.HeaderTimeoutMs) of
      iaFlush: SendPendingOutput;
      iaClose: fOwner.ConnectionRemove(Handle);
    end;
end;

procedure THttp2AsyncConnection.CheckHandshakeDeadline(const ANowMs: QWord);
var
  H: TConnectionAsyncHandle;
  Current: TAsyncConnection;
  Expired: Boolean;
begin
  if FClearTextTransport or (FServer = nil) or
     (FServer.FTlsBinding = nil) then Exit;
  H := Handle;
  Current := fOwner.ConnectionFind(H);
  if Current <> Self then Exit;
  if (FTlsAdapter <> nil) and (FPeerTlsClosed or FLocalTlsShutdown) then
  begin
    if DrainTlsClose then
      fOwner.ConnectionRemove(H);
    Exit;
  end;
  if FHandshakeDeadlineMs <= 0 then Exit;
  Expired := ((FTlsAdapter = nil) or
    (FTlsAdapter.State in [tssNew, tssHandshaking])) and
    (Int64(ANowMs) >= FHandshakeDeadlineMs);
  if Expired then
    fOwner.ConnectionRemove(H);
end;

procedure THttp2AsyncConnection.OnClose;
begin
  if (FTlsAdapter <> nil) and not FPeerTlsClosed and
     not FLocalTlsShutdown then
    try
      FTlsAdapter.NotifyTransportEof;
    except
      on ETlsSessionError do ;
    end;
  // the socket is gone: cancel the streams, so that a waiting handler and the
  // sink of a detached stream learn it now and not at their next timeout
  if FCore <> nil then
    FCore.ConnectionLost;
  if FH1 <> nil then
    FH1.Core.ConnectionLost;
  inherited OnClose;
end;

function THttp2AsyncConnection.PullOutput(out AData: TBytes): Boolean;
begin
  if FH1 <> nil then
    Result := FH1.Core.TakeOutput(AData)
  else
    Result := FCore.TakeOutput(AData);
end;

function THttp2AsyncConnection.OutputPending: Boolean;
begin
  if FH1 <> nil then
    Result := FH1.Core.HasOutput
  else
    Result := FCore.HasOutput;
end;

function THttp2AsyncConnection.PendingWriteBytes: Int64;
begin
  Result := PendingWrite;
end;

procedure THttp2AsyncConnection.ApplyClosePhase;
begin
  FH1.Core.NotifyDrain;
  case FH1.ClosePhase(PendingWrite, TAsyncConnectionSec(mormot.core.os.GetTickCount64 div 1000),
    cDrainSeconds) of
    cpHalfClose:
      begin
        if FTlsAdapter <> nil then
        begin
          if DrainTlsClose then
            fOwner.ConnectionRemove(Handle);
          Exit;
        end;
        // The response left the socket. A close while the peer still sends would
        // reset the connection and could destroy the response in the buffer of
        // the peer, so the write side closes first and the octets that still
        // arrive are dropped (RFC 9112 section 9.6)
        {$IFDEF UNIX}Sockets.fpshutdown(LongInt(fSocket.Socket), cShutWrite);{$ENDIF}
      end;
    cpCloseNow:
      if FH1.Core.AbortRequested then
        CloseAbortively
      else if DrainTlsClose then
        fOwner.ConnectionRemove(Handle);
  end;
end;

procedure THttp2AsyncConnection.CloseAbortively;
begin
  // mORMot's Stop closes with the accepted socket's SO_LINGER value. A
  // positive linger can block this handler while queued output has no reader.
  if fSocket <> nil then
    fSocket.SetLinger(0);
  fOwner.ConnectionRemove(Handle);
end;

function THttp2AsyncConnection.OnReadHttp1: TPollAsyncSocketOnReadWrite;
var
  Data: TBytes;
begin
  result := soContinue;
  Data := nil;
  if fRd.Len > 0 then
  begin
    SetLength(Data, fRd.Len);
    Move(fRd.Buffer^, Data[0], fRd.Len);
    fRd.Reset;
  end;
  FH1.Received(Data, FServer.Factory.HeaderTimeoutMs);
  // the send loop ends with the close phase, so no second call runs here
  SendPendingOutput;
end;

{ THttp2AsyncServer }

constructor THttp2AsyncServer.Create(const AFactory: THttp2ServerFactory);
var
  Options: TAsyncConnectionsOptions;
begin
  FFactory := AFactory;
  if AFactory.TlsContext <> nil then
    FTlsBinding := NewTlsServerBinding(AFactory.TlsContext);
  if (AFactory.TlsContext = nil) and not AFactory.ClearTextAllowed then
    raise EHttpConnectionError.Create(
      'A TLS context is required when cleartext is disabled');
  if (AFactory.TlsContext <> nil) and
     AFactory.TlsContext.Info.RequiresClientCertificate and
     AFactory.ClearTextAllowed then
    raise EHttpConnectionError.Create(
      'Required client authentication cannot use cleartext');
  FCoreOptions := BuildConnectionCoreOptions(FFactory);
  FControlBucket := LeastControlBucket(FFactory);
  FCounters := TServerCounters.Create;
  FHandlers := THandlerPool.Create(AFactory);
  FChannelImpl := TChannelRegistry.Create(AFactory.MaxDetachedStreams,
    AFactory.ChannelQueueLimit, AFactory.ChannelLowWater);
  FChannelImpl.KeepAliveMs := AFactory.SseKeepAliveMs;
  FChannelImpl.StallTimeoutMs := AFactory.SseStallTimeoutMs;
  FChannels := FChannelImpl;
  FHandlers.ChannelRegistry := FChannels;
  FStreamPool := TStreamPool.Create(AFactory.StreamPoolSize);
  FChannelImpl.SourceProvider := FStreamPool.NewSource;
  FObserver := nil;
  Options := ASYNC_OPTION_PROD;
  if AFactory.Socket.ReusePort then
    include(Options, acoReusePort);
  inherited Create(BindAddressText(AFactory.Host, AFactory.Port), nil, nil,
    THttp2AsyncConnection, 'http2', nil, Options, AFactory.IOThreads);
  // mORMot2 tests the count before the new socket joins the set, and the
  // test is strict, so a factory value of N maps to N minus one; 0 means
  // no cap
  if AFactory.ServerLimits.MaxConnections <= 0 then
    MaxConnections := MaxInt
  else
    MaxConnections := AFactory.ServerLimits.MaxConnections - 1;
end;

procedure THttp2AsyncServer.AfterConstruction;
begin
  // the thread that binds starts here, at the end of the construction. The
  // backlog of the factory reaches listen() through a mORMot2 global
  // (mormot.net.sock.pas, DefaultListenBacklog), so the global is set before
  // the thread starts and kept under a lock until that thread has left the
  // binding state. Two servers that are built at once keep their own backlog
  GBindLock.Enter;
  try
    DefaultListenBacklog := FFactory.Backlog;
    inherited AfterConstruction;
    WaitBindDone;
  finally
    GBindLock.Leave;
  end;
end;

destructor THttp2AsyncServer.Destroy;
begin
  Stop;
  FHandlers.Free;
  FHandlers := nil;
  FChannelImpl.SourceProvider := nil;
  FStreamPool.Free;
  FStreamPool := nil;
  FChannels := nil;
  FChannelImpl := nil;
  inherited Destroy;
  // the connections close inside the inherited destructor and still count
  FCounters.Free;
  FCounters := nil;
end;

function THttp2AsyncServer.GetLastOperationIdleSeconds: cardinal;
begin
  result := IdleCheckSeconds(FFactory.IdleTimeoutMs, FFactory.HeaderTimeoutMs);
end;

procedure THttp2AsyncServer.IdleEverySecond;
begin
  inherited IdleEverySecond;
  if (FFactory.MaxConnectionAgeMs <= 0) and
     (FFactory.ServerLimits.WriteTimeoutMs <= 0) and (FTlsBinding = nil) then
    Exit;
  SweepAgedConnections(Self, FFactory.MaxConnectionAgeMs,
    FFactory.GracefulStopTimeoutMs, FFactory.ServerLimits.WriteTimeoutMs);
end;

procedure THttp2AsyncServer.ConnectionOpened;
begin
  ReportOpened(FCounters, FObserver);
end;

procedure THttp2AsyncServer.ConnectionClosed;
begin
  ReportClosed(FCounters, FObserver);
end;

procedure THttp2AsyncServer.Notify(const AEvent: TServerEvent);
begin
  ReportEvent(FObserver, AEvent);
end;

procedure THttp2AsyncServer.TlsHandshakeFailed(const ADetail: string);
begin
  ReportTlsFailed(FCounters, FObserver, ADetail);
end;

procedure THttp2AsyncServer.WaitBindDone;
var
  Deadline: QWord;
begin
  // the thread that binds leaves the not-started and binding states once
  // listen() ran or the bind failed. A failure is raised later by WaitStarted
  Deadline := mormot.core.os.GetTickCount64 + QWord(cBindWaitSeconds) * 1000;
  while (fExecuteState in [esNotStarted, esBinding]) and
        (mormot.core.os.GetTickCount64 < Deadline) do
    Sleep(1);
end;

procedure THttp2AsyncServer.BeginDrain;
begin
  FDraining := True;
  DrainH1Connections(Self);
end;

procedure THttp2AsyncServer.BroadcastGoAway(
  const AErrorCode: THttp2ErrorCode);
begin
  GoAwayAllConnections(Self, AErrorCode);
  Notify(seGoAwaySent, 0, lkReset,
    'the server sends GOAWAY on every connection');
end;

function THttp2AsyncServer.OpenStreamTotal: Integer;
begin
  Result := CountOpenStreams(Self);
end;

procedure THttp2AsyncServer.Notify(const AKind: TServerEventKind;
  const AStreamId: LongWord; const ALimit: TLimitKind; const ADetail: string);
begin
  ReportEventKind(FObserver, AKind, AStreamId, ALimit, ADetail);
end;

procedure THttp2AsyncServer.Start;
var
  Port: Integer;
begin
  if FStarted then
    exit;
  // Execute binds the port on its own thread; WaitStarted returns once the
  // socket is bound, and it raises when the bind failed
  WaitStarted(cBindWaitSeconds);
  // mORMot2 uses fSockPort as a numeric port when it opens the temporary
  // connection that wakes its poll threads during Shutdown. The bind input
  // includes host:port, so replace it with the actual numeric value.
  Port := BoundPort;
  if Port <= 0 then
    raise EHttpConnectionError.Create('The listener has no bound port');
  fSockPort := RawUtf8(IntToStr(Port));
  FStarted := True;
end;

procedure THttp2AsyncServer.CloseChannels(const AMode: TChannelClose);
begin
  if FChannels <> nil then
    FChannels.CloseAll(AMode);
end;

procedure THttp2AsyncServer.Stop(const AWaitMs: Integer);
begin
  FDraining := True;
  // the channels that are still open end first, so no stream outlives its
  // handler pool; a channel that already ended is not touched twice
  if FChannels <> nil then
    FChannels.CloseAll(ccAbort);
  if FHandlers <> nil then
    FHandlers.Stop(AWaitMs);
  Shutdown;
  if FStreamPool <> nil then
    FStreamPool.Stop;
end;

function THttp2AsyncServer.BoundPort: Integer;
var
  Addr: TNetAddr;
begin
  // a factory port of 0 asks the operating system for a free port, so the
  // bound port must be read back from the socket itself
  result := StrToIntDef(Server.Port, 0);
  if (result = 0) and (Server <> nil) and (Server.Sock <> nil) then
    if Server.Sock.GetName(Addr) = nrOk then
      result := Addr.Port;
end;

initialization
  GBindLock := TCriticalSection.Create;

finalization
  GBindLock.Free;

end.
