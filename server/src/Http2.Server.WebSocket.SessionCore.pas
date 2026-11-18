{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session core, sending, closing handshake, heartbeat, state
notes:
  - This unit holds the part of a WebSocket session that does not depend on how
    events reach it. It holds the state, the sender, the closing handshake, the end of
    the session, the credit rule and the timers. The class in Http2.Server.WebSocket.Session
    adds the task queue, Init, the receive path and the stop of the server.
  - The lock of a session guards its flags and its task queue only. It is never
    held across a call into the channel or the handler.
  - A Send writes the frames of one message with one call of the channel, so the
    frames of two messages never mix and a refusal leaves nothing half written.
---
}
/// The state, the sender and the timers of a WebSocket session
unit Http2.Server.WebSocket.SessionCore;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2.Server.Errors, Http2.Common.Hpack, Http2.Common.Body, Http2.Server.Seam, Http2.Server.Duplex,
  Http2.Server.Limits, Http2.Server.Observer, Http2.Server.WebSocket.Options,
  Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Parser,
  Http2.Server.WebSocket.Reader, Http2.Server.WebSocket.Close, Http2.Server.WebSocket.Utf8,
  Http2.Server.ClientCert, Http2.Server.WebSocket.Budget, Http2.Server.WebSocket.Pump,
  Http2.Server.WebSocket.Snapshot, Http2.Server.WebSocket.Inbound;

type
  TWsState = (wsInit, wsOpen, wsClosing, wsEnded);

  TWsTaskKind = (wtInit, wtMessage, wtPong, wtClosed, wtReply);

  TWsTask = record
    Kind: TWsTaskKind;
    Data: TBytes;
    Text: Boolean;
    Code: Word;
    Reason: string;
    Clean: Boolean;
    /// wtReply: the opcode of the control frame to send
    Opcode: Byte;
    /// wtReply: close the channel gracefully after the frame
    CloseAfter: Boolean;
    /// wtMessage: what the handler reads; a memory reader or a pipe
    Reader: IBodyReader;
    /// wtMessage: the pipe of a streamed message; nil for a message in memory
    Pipe: TWsMessagePipe;
    /// wtMessage: the octets that the budget counted at the start of the message
    Charge: Int64;
  end;

  TWsSessionCore = class(TInterfacedObject, IWsSession, IWsPumpHost)
  protected
    FEnv: IWsEnvironment;
    FOpts: TWsOptions;
    FChannel: IDuplexChannel;
    FRegistry: IChannelRegistry;
    FSource: IStreamSource;
    FHandler: IWsHandler;
    FHandshake: IWsHandshake;
    FSnapshot: TWsRequestSnapshot;
    FRequest: IServerRequest;
    FOffered: TArray<string>;
    FId: Int64;
    FLock: TCriticalSection;
    FSendLock: TCriticalSection;
    FReadLock: TCriticalSection;
    FState: TWsState;
    FInputClosed, FOutputClosed: Boolean;
    FInitDecided: Boolean;
    FCounted: Boolean;
    FDelivered: Boolean;
    FStopRequested: Boolean;
    FTimerArmed: Boolean;
    FSubprotocol: string;
    FContext: IInterface;
    FTasks: TList<TWsTask>;
    FQueuedMsgs: Integer;
    FHeldCredit: Int64;
    /// the server-wide budget of the queued octets and the sessions; nil when none
    FBudget: TWsByteBudget;
    /// True while the session holds a slot of the session cap
    FSlotHeld: Boolean;
    /// the octets of the queued messages that the budget counts for this session
    FQueuedBytes: Int64;
    FReader: TWsReader;
    /// the due time of the armed timer, in the tick count of GetTickCount64
    FArmedDue: QWord;
    /// replies to the peer that wait on the streaming pool, because the send
    /// lock was busy when the IO thread had to answer
    FDeferred: Integer;
    /// the messages that wait are dropped: the session was aborted or failed
    FDropMessages: Boolean;
    FControl, FMessages: TTokenBucket;
    FLastInboundMs, FPingSentMs, FCloseSentMs: QWord;
    FSelf: IInterface;
    /// the pump of the stream that SendStream started; guarded by FLock
    FPump: IWsPump;
    /// a stream was accepted and its last fragment is not queued yet; guarded by FLock
    FStreamActive: Boolean;
    /// the pool runs one Step of the pump
    procedure PumpEntry;
    /// the pool runs the park timer of the pump
    procedure PumpTimerEntry;
    /// the stream is over: the pump stops and the reader is released
    procedure DropPump;
    /// queue a task for the application and run it on the streaming pool
    procedure Post(const ATask: TWsTask); virtual; abstract;
    /// stop the time limit of Init
    procedure UnwatchInit; virtual; abstract;
    /// the session has ended: the pipe of a message that still arrives is aborted, so a
    /// handler that waits in Read wakes up
    procedure AbortInbound; virtual; abstract;
    /// the session no longer closes its channel when the server stops
    procedure DropCloser; virtual; abstract;
    procedure DoTick;
    procedure TickEntry;
    procedure Arm;
    procedure Fail(const E: Exception);
    function TryEnd: Boolean;
    procedure EndWithClosed(const ACode: Word; const AReason: string; const AClean: Boolean);
    procedure EndQuietly;
    function SendControl(const AOpcode: Byte; const APayload: TBytes): TSendResult;
    procedure SendCloseFrame(const ACode: Word; const AReason: string);
    /// the payload of a Close frame, with the reason cut on a character boundary
    function ClosePayload(const ACode: Word; const AReason: string): TBytes;
    /// answer the peer from the IO thread without ever waiting for the send lock
    // - the IO thread holds the connection lock, and a thread that holds the send
    //   lock waits for the connection lock, so waiting here would deadlock. When
    //   the lock is busy, or an earlier reply waits, the reply goes to the pool
    procedure IoSend(const AOpcode: Byte; const APayload: TBytes;
      const ACloseAfter: Boolean);
    /// the messages that wait are dropped from now on
    procedure DropPending;
    procedure ReleaseCredit(const AMessageDone: Boolean);
    /// give back all the credit that the hold rule keeps; a streamed message starts, so
    /// its inline octets must not wait for the queue to fall
    procedure FlushHeldCredit;
    /// the cap of the pipe of a streamed message: InboundPipeBytes on a channel that
    /// returns no credit, and none on a channel whose window bounds the unread octets
    function PipeCap: Integer;
    /// give back the octets of a message that left the queue; never more than the
    /// session still holds
    procedure ReleaseQueued(const ABytes: Int64);
    /// give back the slot of the session cap and the octets that wait; runs once,
    /// when the session ends
    procedure ReleaseSessionSlot;
  public
    /// take the slot of the session cap that the caller has taken for this session
    procedure AdoptSlot(const ABudget: TWsByteBudget);
    constructor Create(const AEnv: IWsEnvironment; const AChannel: IDuplexChannel;
      const ASource: IStreamSource; const AHandler: IWsHandler;
      const AHandshake: IWsHandshake; const ARequest: IServerRequest;
      const AOffered: TArray<string>);
    destructor Destroy; override;

    // IWsSession
    function Send(const AData: TBytes; const AText: Boolean): TSendResult;
    function SendStream(const AReader: IBodyWriter; const AText: Boolean): TSendResult;
    procedure Ping(const AData: TBytes);
    procedure Close(const ACode: Word = 1000; const AReason: string = '');
    procedure Abort;
    function IsOpen: Boolean;
    function InputClosed: Boolean;
    function OutputClosed: Boolean;
    function Subprotocol: string;
    function Request: IServerRequest;
    function Id: Int64;
    function Context: IInterface;
    procedure SetContext(const AValue: IInterface);

    // IWsPumpHost
    function PumpWrite(const AWire: TBytes; const AFin: Boolean): TSendResult;
    procedure PumpCount(const APayload: Integer);
    function PumpSchedule: Boolean;
    function PumpScheduleAfter(const ADelayMs: Integer): Boolean;
    procedure PumpEnded(const AFailure: Exception);
    procedure PumpDefect(const AText: string);
  end;

implementation

{ TWsSessionCore }

constructor TWsSessionCore.Create(const AEnv: IWsEnvironment;
  const AChannel: IDuplexChannel; const ASource: IStreamSource;
  const AHandler: IWsHandler; const AHandshake: IWsHandshake;
  const ARequest: IServerRequest; const AOffered: TArray<string>);
var
  Limits: TWsLimits;
begin
  inherited Create;
  FEnv := AEnv;
  FOpts := AEnv.Options;
  FChannel := AChannel;
  FRegistry := AChannel.Registry;
  FSource := ASource;
  FHandler := AHandler;
  FHandshake := AHandshake;
  FSnapshot := TWsRequestSnapshot.Create(ARequest);
  FRequest := FSnapshot;
  FOffered := Copy(AOffered);
  FId := AEnv.NextId;
  FLock := TCriticalSection.Create;
  FSendLock := TCriticalSection.Create;
  FReadLock := TCriticalSection.Create;
  FTasks := TList<TWsTask>.Create;
  Limits.MaxFrameSize := FOpts.MaxFrameSize;
  Limits.MaxMessageSize := FOpts.MaxMessageSize;
  Limits.MaxFragments := FOpts.MaxFragments;
  FReader := TWsReader.Create(Limits, {ARequireMasked=}True, FOpts.InlineLimit);
  FControl := TTokenBucket.Create(AEnv.Clock, FOpts.ControlBucket);
  FMessages := TTokenBucket.Create(AEnv.Clock, FOpts.MessageBucket);
  FLastInboundMs := GetTickCount64;
  FState := wsInit;
end;

destructor TWsSessionCore.Destroy;
begin
  DropPump;
  ReleaseSessionSlot;
  FReader.Free;
  FControl.Free;
  FMessages.Free;
  FTasks.Free;
  FReadLock.Free;
  FSendLock.Free;
  FLock.Free;
  inherited Destroy;
end;

function TWsSessionCore.TryEnd: Boolean;
begin
  FLock.Acquire;
  try
    Result := FState <> wsEnded;
    if Result then
      FState := wsEnded;
  finally
    FLock.Release;
  end;
  if not Result then
    Exit;
  UnwatchInit;
  // before the pool stops: a handler that waits in Read must be able to return
  AbortInbound;
  if FCounted then
    FEnv.SessionClosed;
  ReleaseSessionSlot;
  FSnapshot.Cancel;
  // the session has ended: the stream stops and its reader is released
  DropPump;
end;

procedure TWsSessionCore.DropPump;
var
  P: IWsPump;
begin
  FLock.Acquire;
  try
    P := FPump;
    FPump := nil;
    FStreamActive := False;
  finally
    FLock.Release;
  end;
  // Stop can release the writer here, on the IO thread: its destructor must not
  // block and must not take a lock that a caller of Send can hold
  if P <> nil then
    P.Stop;
end;

/// the session ends and the application hears Closed
procedure TWsSessionCore.EndWithClosed(const ACode: Word; const AReason: string;
  const AClean: Boolean);
var
  T: TWsTask;
begin
  if not TryEnd then
    Exit;
  T := Default(TWsTask);
  T.Kind := wtClosed;
  T.Code := ACode;
  T.Reason := AReason;
  T.Clean := AClean;
  Post(T);
end;

/// the session ends and no callback follows
procedure TWsSessionCore.EndQuietly;
begin
  DropPending;
  TryEnd;
  if FRegistry <> nil then
    DropCloser;
  FSource.Close;
  FSelf := nil;
end;

procedure TWsSessionCore.Fail(const E: Exception);
begin
  // a callback raised: Failed is the one ending call, then a Close frame 1011
  DropPending;
  if not TryEnd then
    Exit;
  FEnv.Report(seWsFailed, 0, E.ClassName + ': ' + E.Message);
  try
    FHandler.Failed(Self, E);
  except
    ;   // Failed must not raise; if it does, the session ends all the same
  end;
  if not FOutputClosed then
  begin
    FOutputClosed := True;
    try
      SendCloseFrame(WsCloseInternal, 'the handler failed');
    except
      ;
    end;
  end;
  FChannel.Close(ccGraceful);
  if FRegistry <> nil then
    DropCloser;
  FSource.Close;
  FSelf := nil;
end;

procedure TWsSessionCore.DropPending;
begin
  FLock.Acquire;
  try
    FDropMessages := True;
  finally
    FLock.Release;
  end;
end;

procedure TWsSessionCore.AdoptSlot(const ABudget: TWsByteBudget);
begin
  FLock.Acquire;
  try
    FBudget := ABudget;
    FSlotHeld := True;
  finally
    FLock.Release;
  end;
end;

procedure TWsSessionCore.ReleaseQueued(const ABytes: Int64);
var
  Give: Int64;
begin
  FLock.Acquire;
  try
    Give := ABytes;
    if Give > FQueuedBytes then
      Give := FQueuedBytes;
    Dec(FQueuedBytes, Give);
  finally
    FLock.Release;
  end;
  if (Give > 0) and (FBudget <> nil) then
    FBudget.ReleaseBytes(Give);
end;

procedure TWsSessionCore.ReleaseSessionSlot;
var
  Held: Boolean;
  Bytes: Int64;
begin
  if FBudget = nil then
    Exit;
  FLock.Acquire;
  try
    Held := FSlotHeld;
    FSlotHeld := False;
    Bytes := FQueuedBytes;
    FQueuedBytes := 0;
  finally
    FLock.Release;
  end;
  if Bytes > 0 then
    FBudget.ReleaseBytes(Bytes);
  if Held then
    FBudget.CloseSession;
end;

procedure TWsSessionCore.ReleaseCredit(const AMessageDone: Boolean);
var
  Give: Int64;
begin
  Give := 0;
  FLock.Acquire;
  try
    if AMessageDone and (FQueuedMsgs > 0) then
      Dec(FQueuedMsgs);
    if (FHeldCredit > 0) and (FQueuedMsgs * 2 < FOpts.QueuedMessages) then
    begin
      Give := FHeldCredit;
      FHeldCredit := 0;
    end;
  finally
    FLock.Release;
  end;
  if Give > 0 then
    FChannel.ReturnCredit(Give);
end;

procedure TWsSessionCore.FlushHeldCredit;
var
  Give: Int64;
begin
  FLock.Acquire;
  try
    Give := FHeldCredit;
    FHeldCredit := 0;
  finally
    FLock.Release;
  end;
  if Give > 0 then
    FChannel.ReturnCredit(Give);
end;

function TWsSessionCore.PipeCap: Integer;
var
  Flow: IChannelFlow;
begin
  // on a channel that returns credit, the stream window bounds the unread octets
  if Supports(FChannel, IChannelFlow, Flow) and Flow.ReturnsCredit then
    Result := MaxInt
  else
    Result := FOpts.InboundPipeBytes;
end;

{ the timer }

procedure TWsSessionCore.Arm;
var
  In_: TWsTimerInput;
  Delay: Integer;
begin
  FLock.Acquire;
  try
    if FState = wsEnded then
      Exit;
    In_.NowMs := GetTickCount64;
    In_.LastInboundMs := FLastInboundMs;
    In_.PingSentMs := FPingSentMs;
    In_.CloseSentMs := FCloseSentMs;
    In_.Open := (FState = wsOpen) and not FOutputClosed;
    In_.InputClosed := FInputClosed;
    In_.PingIntervalMs := FOpts.PingIntervalMs;
    In_.PongTimeoutMs := FOpts.PongTimeoutMs;
    In_.CloseTimeoutMs := FOpts.CloseTimeoutMs;
    WsTimerStep(In_, Delay);
    if Delay = 0 then
      Exit;
    // a timer is armed already. A new deadline that is earlier, a close timeout
    // against a ping timer, needs its own timer. The armed timer stays: when it
    // fires it finds nothing due and arms again
    if FTimerArmed and (In_.NowMs + QWord(Delay) >= FArmedDue) then
      Exit;
    FTimerArmed := True;
    FArmedDue := In_.NowMs + QWord(Delay);
  finally
    FLock.Release;
  end;
  if not FSource.PostAfter(Delay, TickEntry) then
    FTimerArmed := False;
end;

procedure TWsSessionCore.TickEntry;
var
  Keep: IInterface;
begin
  Keep := Self;
  Http2AssertStreamThread('TWsSessionCore.TickEntry');
  DoTick;
end;

procedure TWsSessionCore.DoTick;
var
  In_: TWsTimerInput;
  Delay: Integer;
  Action: TWsTimerAction;
begin
  FLock.Acquire;
  try
    FTimerArmed := False;
    if FState = wsEnded then
      Exit;
    In_.NowMs := GetTickCount64;
    In_.LastInboundMs := FLastInboundMs;
    In_.PingSentMs := FPingSentMs;
    In_.CloseSentMs := FCloseSentMs;
    In_.Open := (FState = wsOpen) and not FOutputClosed;
    In_.InputClosed := FInputClosed;
    In_.PingIntervalMs := FOpts.PingIntervalMs;
    In_.PongTimeoutMs := FOpts.PongTimeoutMs;
    In_.CloseTimeoutMs := FOpts.CloseTimeoutMs;
    Action := WsTimerStep(In_, Delay);
  finally
    FLock.Release;
  end;
  case Action of
    taSendPing:
      begin
        FLock.Acquire;
        try
          FPingSentMs := GetTickCount64;
        finally
          FLock.Release;
        end;
        SendControl(WsOpPing, nil);
      end;
    taPongTimeout:
      begin
        FEnv.Count(wcPingTimeouts, 1);
        Close(WsCloseInternal, 'ping timeout');
      end;
    taCloseTimeout:
      begin
        // the peer is silent: the closing handshake did not finish
        EndWithClosed(WsCloseAbnormal, 'the peer did not answer the Close frame', False);
        FChannel.Close(ccAbort);
      end;
  end;
  Arm;
end;

{ sending }

function TWsSessionCore.SendControl(const AOpcode: Byte; const APayload: TBytes): TSendResult;
var
  Key: TWsMaskKey;
begin
  Key := WsMaskKeyFromLongWord(0);
  FSendLock.Acquire;
  try
    Result := FChannel.Send(WsEncodeFrame(AOpcode, True, APayload, False, Key));
  finally
    FSendLock.Release;
  end;
end;

function TWsSessionCore.ClosePayload(const ACode: Word; const AReason: string): TBytes;
begin
  // a reason is cut on the boundary of a character, so it stays valid UTF-8
  Result := WsBuildClosePayload(ACode,
    WsTruncateUtf8(RawByteString(AReason), WsMaxCloseReason));
end;

procedure TWsSessionCore.SendCloseFrame(const ACode: Word; const AReason: string);
begin
  SendControl(WsOpClose, ClosePayload(ACode, AReason));
end;

procedure TWsSessionCore.IoSend(const AOpcode: Byte; const APayload: TBytes;
  const ACloseAfter: Boolean);
var
  Direct: Boolean;
  Key: TWsMaskKey;
  T: TWsTask;
begin
  Key := WsMaskKeyFromLongWord(0);
  FLock.Acquire;
  try
    Direct := FDeferred = 0;
    if not Direct then
      Inc(FDeferred);
  finally
    FLock.Release;
  end;
  if Direct and FSendLock.TryEnter then
  begin
    try
      FChannel.Send(WsEncodeFrame(AOpcode, True, APayload, False, Key));
    finally
      FSendLock.Release;
    end;
    if ACloseAfter then
      FChannel.Close(ccGraceful);
    Exit;
  end;
  if Direct then
  begin
    FLock.Acquire;
    try
      Inc(FDeferred);
    finally
      FLock.Release;
    end;
  end;
  // the send lock is busy, or an earlier reply waits: the pool sends this one,
  // in order, and closes the channel afterwards when the caller asked for it
  T := Default(TWsTask);
  T.Kind := wtReply;
  T.Opcode := AOpcode;
  T.Data := APayload;
  T.CloseAfter := ACloseAfter;
  Post(T);
end;

function TWsSessionCore.Send(const AData: TBytes; const AText: Boolean): TSendResult;
var
  Op: Byte;
  Wire: TBytes;
  Closed, Streaming: Boolean;
begin
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit(srClosed);
    // a stream runs: no other message may go out between its fragments
    if FStreamActive then
      Exit(srFull);
  finally
    FLock.Release;
  end;
  if AText then
    Op := WsOpText
  else
    Op := WsOpBinary;
  // the encoding is slow for a large message and needs no lock
  Wire := WsEncodeMessage(Op, AData, FOpts.FrameSize);
  FSendLock.Acquire;
  try
    // RFC 6455 section 5.5.1: no data frame follows a Close frame. A Close
    // that came while the message was encoded is seen here, and the Close
    // frame itself needs the send lock, so it cannot slip in after this check
    FLock.Acquire;
    try
      Closed := (FState = wsEnded) or FOutputClosed;
      // a stream that started while this message waited for the lock owns the
      // channel: this check is under the send lock, so no message can split it
      Streaming := FStreamActive;
    finally
      FLock.Release;
    end;
    if Closed then
      Exit(srClosed);
    if Streaming then
      Exit(srFull);
    Result := FChannel.Send(Wire);
  finally
    FSendLock.Release;
  end;
  if Result = srQueued then
  begin
    FEnv.Count(wcMessagesOut, 1);
    FEnv.Count(wcBytesOut, Length(AData));
  end
  else if Result = srClosed then
    EndWithClosed(WsCloseAbnormal, 'the channel is closed', False);
end;

function TWsSessionCore.SendStream(const AReader: IBodyWriter; const AText: Boolean): TSendResult;
var
  Old: IWsPump;
  Hold: IBodyWriter;
begin
  if AReader = nil then
    raise EHttpError.Create('SendStream needs a writer');
  Hold := AReader; // a const parameter takes no reference: a refused writer would leak
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit(srClosed);
    if FStreamActive then
      Exit(srFull);
    FStreamActive := True;
    Old := FPump;
    FPump := TWsStreamPump.Create(AReader, AText, FOpts.FrameSize,
      FOpts.MaxMessageSize, WsPumpStepChunks, Self);
  finally
    FLock.Release;
  end;
  Old := nil;
  if not PumpSchedule then
  begin
    EndQuietly;
    Exit(srClosed);
  end;
  Result := srQueued;
end;

function TWsSessionCore.PumpWrite(const AWire: TBytes; const AFin: Boolean): TSendResult;
var
  Closed: Boolean;
begin
  FSendLock.Acquire;
  try
    FLock.Acquire;
    try
      Closed := (FState = wsEnded) or FOutputClosed;
    finally
      FLock.Release;
    end;
    // RFC 6455 section 5.5.1: no data frame follows a Close frame. This srClosed is
    // quiet: the application closed, and the closing handshake goes on
    if Closed then
      Exit(srClosed);
    Result := FChannel.Send(AWire);
    if (Result = srQueued) and AFin then
    begin
      // the last fragment is queued: a Send that waits for the send lock may go
      FLock.Acquire;
      FStreamActive := False;
      FLock.Release;
    end;
  finally
    FSendLock.Release;
  end;
  if (Result = srQueued) and AFin then
    FEnv.Count(wcMessagesOut, 1)
  else if Result = srClosed then
    // only the channel answers srClosed here: the transport is gone
    EndWithClosed(WsCloseAbnormal, 'the channel is closed', False);
end;

procedure TWsSessionCore.PumpCount(const APayload: Integer);
begin
  FEnv.Count(wcBytesOut, APayload);
end;

procedure TWsSessionCore.PumpDefect(const AText: string);
begin
  FEnv.Report(seHandlerException, 0, AText);
end;

function TWsSessionCore.PumpSchedule: Boolean;
begin
  Result := FSource.Post(PumpEntry);
end;

function TWsSessionCore.PumpScheduleAfter(const ADelayMs: Integer): Boolean;
begin
  Result := FSource.PostAfter(ADelayMs, PumpTimerEntry);
end;

procedure TWsSessionCore.PumpEntry;
var
  Keep: IInterface;
  P: IWsPump;
begin
  // The pool runs one task of a session at a time (one source for each session;
  // StreamPool.pas: PostTask, NextTask, FinishTask; S00). A stale schedule acts on
  // the current pump: this is harmless only because of that rule. The FInStep
  // guard in Enter still prevents a double write
  Keep := Self;
  Http2AssertStreamThread('TWsSessionCore.PumpEntry');
  FLock.Acquire;
  P := FPump;
  FLock.Release;
  if P <> nil then
    P.Step;
end;

procedure TWsSessionCore.PumpTimerEntry;
var
  Keep: IInterface;
  P: IWsPump;
begin
  Keep := Self;
  Http2AssertStreamThread('TWsSessionCore.PumpTimerEntry');
  FLock.Acquire;
  P := FPump;
  FLock.Release;
  // A stale timer acts on the current pump and wakes a later park early at worst.
  // This is harmless because the pool runs one task of a session at a time (S00;
  // StreamPool.pas); the FInStep guard in Enter still prevents a double write
  if P <> nil then
    P.TimerFired;
end;

procedure TWsSessionCore.PumpEnded(const AFailure: Exception);
var
  Old: IWsPump;
begin
  if AFailure <> nil then
  begin
    // The stream stays active until the session ends, so no Send can split it.
    // Fail goes to TryEnd, and TryEnd calls DropPump, which clears the fields
    Fail(AFailure);
    Exit;
  end;
  // a normal end: this breaks the cycle of the pump and the session
  FLock.Acquire;
  FStreamActive := False;
  Old := FPump;
  FPump := nil;
  FLock.Release;
  Old := nil;
end;

procedure TWsSessionCore.Ping(const AData: TBytes);
begin
  if Length(AData) > WsMaxControlPayload then
    raise EHttpError.Create('a Ping payload is over 125 octets');
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit;
    if FPingSentMs = 0 then
      FPingSentMs := GetTickCount64;
  finally
    FLock.Release;
  end;
  SendControl(WsOpPing, AData);
end;

procedure TWsSessionCore.Close(const ACode: Word; const AReason: string);
var
  Finish: Boolean;
begin
  if not WsCloseCodeSendable(ACode) then
    raise EHttpError.CreateFmt('the close code %d cannot be sent', [ACode]);
  if Length(AReason) > WsMaxCloseReason then
    raise EHttpError.Create('a close reason is over 123 octets');
  // RFC 6455 section 5.5.1: the reason is UTF-8 text
  if (Length(AReason) > 0) and not WsUtf8IsValid(AReason[1], Length(AReason)) then
    raise EHttpError.Create('a close reason is not valid UTF-8');
  FLock.Acquire;
  try
    if (FState = wsEnded) or FOutputClosed then
      Exit;
    FOutputClosed := True;
    if FState = wsOpen then
      FState := wsClosing;
    if FState <> wsInit then
      FCloseSentMs := GetTickCount64;
    Finish := FInputClosed;
  finally
    FLock.Release;
  end;
  SendCloseFrame(ACode, AReason);
  // the Close frame is out: the stream is over and its message stays incomplete
  DropPump;
  if Finish then
    // the peer closed first: both Close frames are out
    FChannel.Close(ccGraceful)
  else
    Arm;
end;

procedure TWsSessionCore.Abort;
begin
  DropPending;
  if TryEnd then
  begin
    FChannel.Close(ccAbort);
    if FRegistry <> nil then
      DropCloser;
    FSource.Close;
    FSelf := nil;
  end;
end;

function TWsSessionCore.IsOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FState in [wsInit, wsOpen]) and not FOutputClosed;
  finally
    FLock.Release;
  end;
end;

function TWsSessionCore.InputClosed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FInputClosed;
  finally
    FLock.Release;
  end;
end;

function TWsSessionCore.OutputClosed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FOutputClosed;
  finally
    FLock.Release;
  end;
end;

function TWsSessionCore.Subprotocol: string;
begin
  Result := FSubprotocol;
end;

function TWsSessionCore.Request: IServerRequest;
begin
  Result := FRequest;
end;

function TWsSessionCore.Id: Int64;
begin
  Result := FId;
end;

function TWsSessionCore.Context: IInterface;
begin
  FLock.Acquire;
  try
    Result := FContext;
  finally
    FLock.Release;
  end;
end;

procedure TWsSessionCore.SetContext(const AValue: IInterface);
begin
  FLock.Acquire;
  try
    FContext := AValue;
  finally
    FLock.Release;
  end;
end;

end.
