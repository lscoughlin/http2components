{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, duplex channel, streaming pool, init, receive path, stop
notes:
  - A session runs on any IDuplexChannel that has been detached before its
    response head. It does not know whether the channel is an HTTP/1.1 connection
    or an HTTP/2 stream.
  - The IO thread that delivers octets parses the frames, answers Ping and Close at
    once, and queues each data message. The streaming pool runs the callbacks of the
    handler, one at a time for a session and in the order of the events. The
    handler never runs on an IO thread.
  - A message that ends inside the inline limit goes to the handler as a memory reader
    when it ends. A longer message goes to the handler when it passes the limit, and a
    pipe (Http2.Server.WebSocket.Inbound) carries the octets that follow. The IO thread
    only pushes into the pipe and never waits.
  - The credit of the octets of a message in memory, and of every frame header, goes back
    to the channel when the octets arrive, so a message of up to the HTTP/2 window can
    arrive. The credit of the octets of a pipe goes back as the handler reads them, so a
    slow handler slows its own stream only. When the queue of a session is half full, the
    credit of the data octets is held until the handler has taken messages, and a queue
    over its cap closes the session with 1008. The headers of a streamed message that is
    open are never held.
  - The end of the session aborts the pipe of a message that still arrives, before the
    pool stops, so a handler that waits in Read returns.
  - The state, the sender, the closing handshake and the timers are in
    Http2.Server.WebSocket.SessionCore.
---
}
/// The WebSocket session on a duplex channel
unit Http2.Server.WebSocket.Session;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2.Server.Errors, Http2.Common.Hpack, Http2.Server.Seam, Http2.Server.Duplex,
  Http2.Server.Limits, Http2.Server.Observer, Http2.Server.WebSocket.Options,
  Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Parser,
  Http2.Server.WebSocket.Reader, Http2.Server.WebSocket.Close, Http2.Server.WebSocket.SessionCore,
  Http2.Server.WebSocket.Environment, Http2.Server.WebSocket.Budget,
  Http2.Server.WebSocket.Pump, Http2.Server.WebSocket.Pump.Producer, Http2.Common.Body,
  Http2.Server.WebSocket.Inbound;

/// start a session on AChannel, which is detached and pending
// - ARequest is the upgrade request; the session keeps a copy of what it needs
// - AOffered holds the subprotocols that the client offered
// - the first task of the session is IWsHandler.Init, on the streaming pool
// - raises EHttpError when the server has no WebSocket environment or no pool
function WsStartSession(const AChannel: IDuplexChannel; const ARequest: IServerRequest;
  const AHandler: IWsHandler; const AHandshake: IWsHandshake;
  const AOffered: TArray<string>): IWsSession;

implementation

type
  TWsSession = class(TWsSessionCore, IChannelSink, IWsReaderSink, IChannelCloser,
    IWsInitWatch, IWsProducerHost)
  private
    /// the pipe of the streamed message that still arrives, and the reference that
    /// keeps it alive; FLock guards both
    FPipe: TWsMessagePipe;
    FPipeRef: IBodyReader;
    /// the message that ends inside the inline limit, as the reader gives it
    FInline: TBytes;
    FInlineText: Boolean;
    /// the octets that this BytesReceived call gave to a pipe: the pipe credits them
    FPushed: Integer;
    /// this BytesReceived call belonged to a streamed message, which may have ended in it
    FStreamFeed: Boolean;
    /// the message bucket, the queue, the closed state and the budget; False when the
    /// session failed or ended and the message does not go on
    function Admit(const ACharge: Int64): Boolean;
    procedure StartStream(const AText: Boolean);
    /// the handler read octets of a pipe, or the pipe dropped them
    procedure PipeTaken(const ACount: Integer);
    /// a read of the handler waited too long
    procedure PipeStalled;
  protected
    procedure Post(const ATask: TWsTask); override;
    procedure UnwatchInit; override;
    procedure AbortInbound; override;
    procedure DropCloser; override;
    procedure RunTask;
    function Dropping: Boolean;
    procedure DoInit;
    procedure DoMessage(const ATask: TWsTask);
    procedure DoPong(const ATask: TWsTask);
    procedure DoClosed(const ATask: TWsTask);
    procedure ProtocolFail(const ACode: Word; const AReason: string);
    procedure FinishReject(const AResult: TWsInitResult);
  public
    procedure Start;

    // IChannelSink: the IO thread calls these
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;

    // IWsReaderSink: called from BytesReceived
    procedure MessageBegin(const AText: Boolean);
    procedure MessageData(const AData; const ACount: Integer);
    procedure MessageEnd;
    procedure Control(const AOpcode: Byte; const AData: TBytes);

    // IWsProducerHost: PumpReplies is a method of the session core
    function PumpStallMs: Integer;
    procedure PumpStalled;

    // IChannelCloser, IWsInitWatch
    procedure CloseForStop(const AMode: TChannelClose);
    procedure InitTimedOut;
  end;

{ TWsSession }

procedure TWsSession.UnwatchInit;
begin
  FEnv.UnwatchInit(Self);
end;

procedure TWsSession.AbortInbound;
var
  P: TWsMessagePipe;
  Ref: IBodyReader;
begin
  FLock.Acquire;
  try
    P := FPipe;
    Ref := FPipeRef;
    FPipe := nil;
    FPipeRef := nil;
  finally
    FLock.Release;
  end;
  // a finished pipe is not here: it stays readable for a message that arrived whole
  if P <> nil then
  begin
    P.Abort;
    P.Detach;
  end;
  Ref := nil;
end;

procedure TWsSession.PipeTaken(const ACount: Integer);
begin
  // no hold rule: the pipe holds at most what the window and the cap allow
  FChannel.ReturnCredit(ACount);
end;

procedure TWsSession.PipeStalled;
begin
  // the handler thread runs here. The pipe is aborted already, and the read raises
  try
    Close(WsClosePolicy, 'the message stalled');
  except
    ;   // the session ended in the meantime
  end;
end;

function TWsSession.PumpStallMs: Integer;
begin
  Result := FOpts.OutboundStallMs;
end;

procedure TWsSession.PumpStalled;
begin
  // the peer takes no octet of the fragment: the session closes, and the Close frame
  // goes out when the channel takes it. The close timeout ends the session otherwise
  try
    Close(WsClosePolicy, 'the send stalled');
  except
    ;   // the session ended in the meantime
  end;
end;

procedure TWsSession.DropCloser;
begin
  if FRegistry <> nil then
    FRegistry.RemoveCloser(Self);
end;

procedure TWsSession.Start;
var
  T: TWsTask;
begin
  FSelf := Self;
  // the session closes its own channel when the server stops, so the registry
  // lists it as a closer and not as a plain channel
  if FRegistry <> nil then
  begin
    FRegistry.Remove(FChannel);
    FRegistry.AddCloser(Self);
  end;
  FChannel.SetSink(Self);
  FEnv.WatchInit(Self, GetTickCount64 + QWord(FOpts.InitTimeoutMs));
  T := Default(TWsTask);
  T.Kind := wtInit;
  Post(T);
end;

procedure TWsSession.Post(const ATask: TWsTask);
begin
  FLock.Acquire;
  try
    FTasks.Add(ATask);
  finally
    FLock.Release;
  end;
  if not FSource.Post(RunTask) then
    // the pool has stopped: nothing runs again
    EndQuietly;
end;

procedure TWsSession.RunTask;
var
  T: TWsTask;
  Keep: IInterface;
begin
  // the session lives while a task of it runs
  Keep := Self;
  Http2AssertStreamThread('TWsSession.RunTask');
  FLock.Acquire;
  try
    if FTasks.Count = 0 then
      Exit;
    T := FTasks[0];
    FTasks.Delete(0);
  finally
    FLock.Release;
  end;
  case T.Kind of
    wtInit: DoInit;
    wtMessage: DoMessage(T);
    wtPong: DoPong(T);
    wtClosed: DoClosed(T);
    wtReply: ReplyTask(T);
  end;
end;

procedure TWsSession.FinishReject(const AResult: TWsInitResult);
var
  Status: Integer;
begin
  Status := AResult.Status;
  if Status = 0 then
    Status := 403;
  EndQuietly;
  FEnv.Report(seWsRejected, Status, 'Init refused the upgrade');
  // the error response goes out and the connection returns to its protocol core
  try
    FChannel.Complete(Status, AResult.RejectHeaders, AResult.RejectBody);
  except
    FChannel.Close(ccAbort);
  end;
end;

procedure TWsSession.DoInit;
var
  R: TWsInitResult;
  Act: TWsActivation;
  I: Integer;
  Known: Boolean;
  Decided: Boolean;
begin
  if FSnapshot.IsCancelled then
    Exit;
  try
    R := FHandler.Init(FRequest, FOffered, Self);
  except
    on EStreamCancelled do
      Exit;
    on E: Exception do
    begin
      FLock.Acquire;
      try
        Decided := FInitDecided;
        FInitDecided := True;
      finally
        FLock.Release;
      end;
      if not Decided then
      begin
        FEnv.Report(seHandlerException, 500, E.ClassName + ' in Init');
        FinishReject(TWsInitResult.Rejected(500));
      end;
      Exit;
    end;
  end;
  FLock.Acquire;
  try
    Decided := FInitDecided;
    FInitDecided := True;
  finally
    FLock.Release;
  end;
  if Decided then
    Exit;   // the time limit passed; the upgrade was answered with 503
  UnwatchInit;
  if FState = wsEnded then
    Exit;   // the peer left while Init ran
  if not R.Accept then
  begin
    FinishReject(R);
    Exit;
  end;
  // a subprotocol that the client did not offer is an error of the application
  Known := R.Subprotocol = '';
  for I := 0 to High(FOffered) do
    if FOffered[I] = R.Subprotocol then
      Known := True;
  if not Known then
  begin
    FEnv.Report(seHandlerException, 500, 'Init chose a subprotocol that was not offered');
    FinishReject(TWsInitResult.Rejected(500));
    Exit;
  end;
  FSubprotocol := R.Subprotocol;
  try
    Act := FHandshake.Activation(R.Subprotocol, R.ResponseHeaders);
    FLock.Acquire;
    try
      if FState = wsEnded then
        Exit;
      if FOutputClosed then
        FState := wsClosing
      else
        FState := wsOpen;
      FCounted := True;
    finally
      FLock.Release;
    end;
    FEnv.SessionOpened;
    FLastInboundMs := GetTickCount64;
    // the response goes out, then the frames that Init queued, in order
    FChannel.Activate(Act.Status, Act.Headers);
  except
    on E: Exception do
    begin
      FEnv.Report(seHandlerException, 500, E.ClassName + ' in the handshake');
      EndQuietly;
      FChannel.Close(ccAbort);
      Exit;
    end;
  end;
  FEnv.Report(seWsOpened, 0, FSubprotocol);
  if FOutputClosed then
  begin
    FLock.Acquire;
    try
      FCloseSentMs := GetTickCount64;
    finally
      FLock.Release;
    end;
  end;
  if FStopRequested then
    Close(WsCloseGoingAway, 'the server stops');
  Arm;
end;

function TWsSession.Dropping: Boolean;
begin
  FLock.Acquire;
  try
    Result := FDropMessages;
  finally
    FLock.Release;
  end;
end;

procedure TWsSession.DoMessage(const ATask: TWsTask);
begin
  // a message that arrived before a Close frame is delivered, whatever the state
  // of the session now. An abort, a failure of the session or a protocol error
  // drops the messages that wait
  // a streamed message whose pipe was aborted before the handler started is dropped too
  if Dropping or ((ATask.Pipe <> nil) and ATask.Pipe.Aborted) then
  begin
    if ATask.Pipe <> nil then
      ATask.Pipe.Release;
    ReleaseCredit(True);
    ReleaseQueued(ATask.Charge);
    Exit;
  end;
  try
    FHandler.Message(Self, ATask.Reader, ATask.Text);
  except
    on EStreamCancelled do
      ;
    on E: Exception do
      Fail(E);
  end;
  // the handler reads no more: the octets that wait and the octets that still arrive
  // are dropped, and the pipe returns their credit, so the peer is not held back
  if ATask.Pipe <> nil then
    ATask.Pipe.Release;
  ReleaseCredit(True);
  ReleaseQueued(ATask.Charge);
end;

procedure TWsSession.DoPong(const ATask: TWsTask);
begin
  if Dropping then
    Exit;
  try
    FHandler.Pong(Self, ATask.Data);
  except
    on EStreamCancelled do
      ;
    on E: Exception do
      Fail(E);
  end;
end;

procedure TWsSession.DoClosed(const ATask: TWsTask);
begin
  FLock.Acquire;
  try
    if FDelivered then
      Exit;
    FDelivered := True;
  finally
    FLock.Release;
  end;
  FEnv.Report(seWsClosed, ATask.Code, ATask.Reason);
  try
    FHandler.Closed(Self, ATask.Code, ATask.Reason, ATask.Clean);
  except
    on E: Exception do
      FEnv.Report(seWsFailed, 0, E.ClassName + ' in Closed');
  end;
  if FRegistry <> nil then
    FRegistry.RemoveCloser(Self);
  FSource.Close;
  FSelf := nil;
end;

{ the receive path }

procedure TWsSession.BytesReceived(const AData; const ACount: Integer);
var
  State: TWsState;
  Data: Int64;
  Hold: Boolean;
  Ok: Boolean;
  Failure: TWsFailure;
begin
  if ACount <= 0 then
    Exit;
  FReadLock.Acquire;
  try
    FLock.Acquire;
    try
      State := FState;
      FLastInboundMs := GetTickCount64;
    finally
      FLock.Release;
    end;
    if State = wsEnded then
      Exit;
    if State = wsInit then
    begin
      // WebSocket octets before the handshake response are a protocol error
      EndQuietly;
      FChannel.Close(ccAbort);
      Exit;
    end;
    FPushed := 0;
    FStreamFeed := False;
    Ok := FReader.Feed(AData, ACount, Self);
    // every octet is credited once, when it is consumed: the octets of a frame
    // that arrives in pieces are credited piece by piece, so a control frame in
    // pieces cannot raise the window above what the server consumed. The octets that
    // went to a pipe are credited by the pipe, when the handler reads them. The credit
    // waits when the queue of the session is half full, until the handler has
    // taken messages; the headers of a streamed message that is open never wait, or a
    // small queue limit could stall the peer inside a message
    Data := ACount - FPushed;
    FLock.Acquire;
    try
      Hold := (FQueuedMsgs * 2 >= FOpts.QueuedMessages) and (FPipe = nil) and
        not FStreamFeed;
      if Hold then
        Inc(FHeldCredit, Data);
    finally
      FLock.Release;
    end;
    if not Hold and (Data > 0) then
      FChannel.ReturnCredit(Data);
    if not Ok then
    begin
      Failure := FReader.Failure;
      ProtocolFail(Failure.Code, Failure.Reason);
    end;
  finally
    FReadLock.Release;
  end;
end;

procedure TWsSession.ProtocolFail(const ACode: Word; const AReason: string);
var
  Send_: Boolean;
begin
  FLock.Acquire;
  try
    if FState = wsEnded then
      Exit;
    Send_ := not FOutputClosed;
    FOutputClosed := True;
  finally
    FLock.Release;
  end;
  FEnv.Count(wcProtocolErrors, 1);
  // a protocol error drops the messages that wait
  DropPending;
  if Send_ then
  begin
    // the IO thread runs here and never waits for the send lock. The Close frame
    // goes out, and the channel closes after it
    try
      IoSend(WsOpClose, ClosePayload(ACode, AReason), True);
    except
      FChannel.Close(ccGraceful);
    end;
    EndWithClosed(ACode, AReason, False);
  end
  else
  begin
    EndWithClosed(ACode, AReason, False);
    FChannel.Close(ccGraceful);
  end;
end;

function TWsSession.Admit(const ACharge: Int64): Boolean;
var
  TooMany, AfterClose, OverBudget: Boolean;
begin
  Result := False;
  if not FMessages.TryTake(1) then
  begin
    FEnv.Report(seWsBucketTripped, 0, 'the message bucket is empty');
    ProtocolFail(WsClosePolicy, 'too many messages');
    Exit;
  end;
  FLock.Acquire;
  try
    if FState = wsEnded then
      Exit;
    AfterClose := FInputClosed;
    TooMany := FQueuedMsgs >= FOpts.QueuedMessages;
    OverBudget := False;
    if not (AfterClose or TooMany) then
    begin
      // the server-wide budget counts the octets that the message can hold: its length
      // for a message in memory, the size of the pipe for a streamed message. The
      // release gives back the same number. A message that would pass the budget closes
      // the session like a message past the queue limit
      if FBudget <> nil then
        OverBudget := not FBudget.TryAddBytes(ACharge);
      if not OverBudget then
      begin
        Inc(FQueuedMsgs);
        if FBudget <> nil then
          Inc(FQueuedBytes, ACharge);
      end;
    end;
  finally
    FLock.Release;
  end;
  if AfterClose then
  begin
    ProtocolFail(WsCloseProtocolError, 'a data frame after the Close frame');
    Exit;
  end;
  if TooMany then
  begin
    ProtocolFail(WsClosePolicy, 'too many messages wait for the application');
    Exit;
  end;
  if OverBudget then
  begin
    ProtocolFail(WsClosePolicy, 'the queued bytes of the server are full');
    Exit;
  end;
  FEnv.Count(wcMessagesIn, 1);
  Result := True;
end;

procedure TWsSession.StartStream(const AText: Boolean);
var
  T: TWsTask;
  Pipe: TWsMessagePipe;
  Ref: IBodyReader;
  Ended: Boolean;
begin
  // a streamed message counts once, here, with the size of the pipe as its charge
  if not Admit(FOpts.InboundPipeBytes) then
    Exit;
  Pipe := TWsMessagePipe.Create(PipeCap, FOpts.InboundStallMs, PipeTaken, PipeStalled);
  Ref := Pipe;
  // the inline octets of this message may be held by the queue rule: give them back
  FlushHeldCredit;
  FLock.Acquire;
  try
    // the state is read under the lock that TryEnd takes before it aborts the pipe, so
    // a pipe that this call installs is either aborted by TryEnd or never installed
    Ended := FState = wsEnded;
    if not Ended then
    begin
      FPipe := Pipe;
      FPipeRef := Ref;
    end;
  finally
    FLock.Release;
  end;
  if Ended then
    Exit;
  T := Default(TWsTask);
  T.Kind := wtMessage;
  T.Text := AText;
  T.Reader := Ref;
  T.Pipe := Pipe;
  T.Charge := FOpts.InboundPipeBytes;
  Post(T);
end;

procedure TWsSession.MessageBegin(const AText: Boolean);
begin
  FInline := nil;
  FInlineText := AText;
  if FReader.Streaming then
  begin
    FStreamFeed := True;
    StartStream(AText);
  end;
end;

procedure TWsSession.MessageData(const AData; const ACount: Integer);
var
  P: TWsMessagePipe;
  Ref: IBodyReader;
  Len: Integer;
  Taken: Boolean;
begin
  if not FReader.Streaming then
  begin
    Len := Length(FInline);
    SetLength(FInline, Len + ACount);
    Move(AData, FInline[Len], ACount);
    Exit;
  end;
  FLock.Acquire;
  try
    P := FPipe;
    Ref := FPipeRef;
  finally
    FLock.Release;
  end;
  // no pipe: the message was refused or the session ended. The octets are dropped,
  // and they are credited when they arrive
  if P = nil then
    Exit;
  FEnv.Count(wcBytesIn, ACount);
  if FReader.Replaying then
    // the octets that the reader kept were credited when they arrived
    Taken := P.PushPrepaid(AData, ACount)
  else
  begin
    Inc(FPushed, ACount);
    Taken := P.Push(AData, ACount);
  end;
  if not Taken then
    // a channel that cannot slow its peer: the handler reads too slowly
    ProtocolFail(WsCloseTooBig, 'the handler reads too slowly');
end;

procedure TWsSession.MessageEnd;
var
  T: TWsTask;
  P: TWsMessagePipe;
  Ref: IBodyReader;
begin
  if FReader.Streaming then
  begin
    // the headers of the last frame belong to the message that is open: no hold
    FStreamFeed := True;
    FLock.Acquire;
    try
      P := FPipe;
      Ref := FPipeRef;
      FPipe := nil;
      FPipeRef := nil;
    finally
      FLock.Release;
    end;
    if P = nil then
      Exit;
    P.Finish;
    Exit;
  end;
  // a message that ended inside the inline limit goes to the handler now
  if not Admit(Length(FInline)) then
  begin
    FInline := nil;
    Exit;
  end;
  FEnv.Count(wcBytesIn, Length(FInline));
  T := Default(TWsTask);
  T.Kind := wtMessage;
  T.Text := FInlineText;
  T.Reader := TWsMemoryReader.Create(FInline);
  T.Charge := Length(FInline);
  FInline := nil;
  Post(T);
end;

procedure TWsSession.Control(const AOpcode: Byte; const AData: TBytes);
var
  T: TWsTask;
  Code: Integer;
  Reason: RawByteString;
  Already, Echo: Boolean;
  Echoed: Word;
begin
  if AOpcode = WsOpClose then
  begin
    // the reader checked the payload before this call, so only the values matter
    WsParseClosePayload(AData, Code, Reason);
    FLock.Acquire;
    try
      if FState = wsEnded then
        Exit;
      Already := FInputClosed;
      FInputClosed := True;
      Echo := not FOutputClosed;
      if Echo then
      begin
        FOutputClosed := True;
        if FState = wsOpen then
          FState := wsClosing;
      end;
    finally
      FLock.Release;
    end;
    if Already then
      Exit;
    if Echo then
    begin
      // the Close frame is answered with the same code, if the server may send it
      if (Code <> WsCloseNoStatus) and WsCloseCodeSendable(Code) then
        Echoed := Code
      else
        Echoed := WsCloseNormal;
      // the IO thread runs here and never waits for the send lock. The echo
      // goes out, and the channel closes after it
      try
        if Code = WsCloseNoStatus then
          IoSend(WsOpClose, nil, True)
        else
          IoSend(WsOpClose, ClosePayload(Echoed, ''), True);
      except
        FChannel.Close(ccGraceful);
      end;
      EndWithClosed(Word(Code), string(Reason), True);
    end
    else
    begin
      EndWithClosed(Word(Code), string(Reason), True);
      FChannel.Close(ccGraceful);
    end;
    Exit;
  end;
  if not FControl.TryTake(1) then
  begin
    FEnv.Report(seWsBucketTripped, 0, 'the control bucket is empty');
    ProtocolFail(WsClosePolicy, 'too many control frames');
    Exit;
  end;
  if AOpcode = WsOpPing then
  begin
    // answered before the application hears of anything, with the same payload
    FLock.Acquire;
    try
      Echo := (FState <> wsEnded) and not FOutputClosed;
    finally
      FLock.Release;
    end;
    if Echo then
      IoSend(WsOpPong, AData, False);
    Exit;
  end;
  // a Pong
  FLock.Acquire;
  try
    FPingSentMs := 0;
  finally
    FLock.Release;
  end;
  T := Default(TWsTask);
  T.Kind := wtPong;
  T.Data := AData;
  Post(T);
end;

procedure TWsSession.PeerClosed(const AClean: Boolean);
var
  State: TWsState;
begin
  FLock.Acquire;
  try
    State := FState;
  finally
    FLock.Release;
  end;
  if State = wsEnded then
    Exit;
  if State = wsInit then
  begin
    // a half close of a request that sends nothing is not the end; a reset is
    if AClean then
      Exit;
    EndQuietly;
    Exit;
  end;
  // the transport ended without a Close frame
  EndWithClosed(WsCloseAbnormal, '', False);
  // a half close leaves the other half open: END_STREAM answers it (RFC 8441 section 5)
  if AClean then
    FChannel.Close(ccGraceful);
end;

procedure TWsSession.WriteDrained;
var
  P: IWsPump;
begin
  // the drain wakes a parked stream; the call never sends. This method runs on the
  // IO thread with the channel lock held, so it only calls Wake
  FLock.Acquire;
  try
    P := FPump;
  finally
    FLock.Release;
  end;
  if P <> nil then
    P.Wake;
end;

{ the stop of the server, and the time limit of Init }

procedure TWsSession.CloseForStop(const AMode: TChannelClose);
var
  State: TWsState;
  Open: Boolean;
  Deliver: Boolean;
begin
  if AMode = ccGraceful then
  begin
    FLock.Acquire;
    try
      State := FState;
      if State = wsInit then
        FStopRequested := True;
      Open := (State = wsOpen) and not FOutputClosed;
    finally
      FLock.Release;
    end;
    if Open then
      try
        Close(WsCloseGoingAway, 'the server stops');
      except
        ;
      end;
    Exit;
  end;
  // the final stop: the pool is going away, so Closed is delivered here
  TryEnd;
  FLock.Acquire;
  try
    Deliver := FCounted and not FDelivered;
    if Deliver then
      FDelivered := True;
  finally
    FLock.Release;
  end;
  FChannel.Close(ccAbort);
  if Deliver then
  begin
    FEnv.Report(seWsClosed, WsCloseGoingAway, 'the server stopped');
    try
      FHandler.Closed(Self, WsCloseGoingAway, 'the server stopped', False);
    except
      ;
    end;
  end;
  if FRegistry <> nil then
    FRegistry.RemoveCloser(Self);
  FSource.Close;
  FSelf := nil;
end;

procedure TWsSession.InitTimedOut;
var
  Decided: Boolean;
begin
  FLock.Acquire;
  try
    Decided := FInitDecided or (FState = wsEnded);
    if not Decided then
      FInitDecided := True;
  finally
    FLock.Release;
  end;
  if Decided then
    Exit;
  // Init may hold the pool thread, so this runs on the watchdog: the upgrade is
  // answered, and the result of Init is dropped when it comes
  EndQuietly;
  FEnv.Report(seWsRejected, 503, 'Init passed its time limit');
  try
    FChannel.Complete(503, nil, nil);
  except
    FChannel.Close(ccAbort);
  end;
end;

function WsStartSession(const AChannel: IDuplexChannel; const ARequest: IServerRequest;
  const AHandler: IWsHandler; const AHandshake: IWsHandshake;
  const AOffered: TArray<string>): IWsSession;
var
  Env: IWsEnvironment;
  Budgeted: IWsBudgetSource;
  Budget: TWsByteBudget;
  Admitted: Boolean;
  Source: IStreamSource;
  Session: TWsSession;
  Registry: IChannelRegistry;
begin
  Result := nil;
  Registry := AChannel.Registry;
  if (Registry = nil) or not Supports(Registry.WsEnvironment, IWsEnvironment, Env) then
    raise EHttpError.Create('the server has no WebSocket environment');
  Budget := nil;
  if Supports(Env, IWsBudgetSource, Budgeted) then
    Budget := Budgeted.Budget;
  // a session past the cap of the server is refused before it starts
  Admitted := False;
  if Budget <> nil then
  begin
    if not Budget.TryOpenSession then
    begin
      Env.Report(seWsRejected, 503, 'the server holds its limit of WebSocket sessions');
      AChannel.Complete(503, nil, nil);
      Exit;
    end;
    Admitted := True;
  end;
  Source := Registry.NewSource;
  if Source = nil then
  begin
    if Admitted then
      Budget.CloseSession;
    raise EHttpError.Create('the server has no streaming pool');
  end;
  try
    Session := TWsSession.Create(Env, AChannel, Source, AHandler, AHandshake,
      ARequest, AOffered);
  except
    if Admitted then
      Budget.CloseSession;
    raise;
  end;
  if Admitted then
    Session.AdoptSlot(Budget);
  Result := Session;
  Session.Start;
end;

end.
