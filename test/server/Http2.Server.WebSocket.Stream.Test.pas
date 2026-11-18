{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, sendstream, session, test, fpcunit
notes:
  - These tests drive SendStream of the WebSocket session with the fake channel of
    Http2.Server.WebSocket.TestKit. A writer answers True for each chunk and False for
    the end, unless a test says otherwise.
  - A test parks the stream in one of two ways. Full refuses every Send, control
    frames too. SetFullCount refuses only the next Send, so a Ping or a Close frame
    goes out while the pump is parked.
  - The writers report their calls and their release to global counters. A test waits
    for the release of a writer before it reads the end state of the stream.
  - The thread tests are in Http2.Server.WebSocket.Stream.Threads.Test.
---
}
/// Session level tests of the streamed WebSocket message (SendStream)
unit Http2.Server.WebSocket.Stream.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  mormot.core.os,
  Http2.Common.Body, Http2.Server.Errors, Http2.Server.Duplex, Http2.Server.Seam,
  Http2.Server.Observer, Http2.Server.Sse.Test, Http2.Server.WebSocket.Options,
  Http2.Server.WebSocket.Types, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.Pump, Http2.Server.WebSocket.Session,
  Http2.Server.WsHardening.Test, Http2.Server.WebSocket.TestKit,
  Http2.Server.WebSocket.Inbound;

type
  /// one frame of the server output, as the server wrote it
  TRawFrame = record
    Opcode: Byte;
    Fin: Boolean;
    Payload: TBytes;
  end;

  /// an IBodyWriter that answers from a list of chunks
  // - a call after the last chunk answers False without octets. With ALastFalse the last
  //   chunk goes out with False: the octets of a False call are the last chunk
  // - each call counts in GWriterCalls. The release counts in GWriterDestroyed
  TStreamWriter = class(TInterfacedObject, IBodyWriter)
  private
    FChunks: TArray<TBytes>;
    FNext: Integer;
    FLastFalse: Boolean;
    FCall: Integer;
    FRaiseAt: Integer;
    FHookAt: Integer;
    FHook: TProc_;
    FGate: TEvent;
    FGateMs: Integer;
  public
    constructor Create(const AChunks: TArray<TBytes>; const ALastFalse: Boolean = False);
    destructor Destroy; override;
    function NextChunk(const ABuffer: TStream): Boolean;
    /// the call that raises an exception (0 means none)
    property RaiseAt: Integer read FRaiseAt write FRaiseAt;
    /// the call that runs Hook before it answers (0 means none)
    property HookAt: Integer read FHookAt write FHookAt;
    property Hook: TProc_ read FHook write FHook;
    /// when set, each call waits for the event; the wait ends after GateMs at the latest
    property Gate: TEvent read FGate write FGate;
    /// the longest wait of a call on Gate (default 10 seconds)
    property GateMs: Integer read FGateMs write FGateMs;
  end;

  /// a handler that streams in Init and that passes the rest to a recording handler
  // - Init sends the writer when one is set. CloseOn makes Message close the session
  TStreamProbeHandler = class(TInterfacedObject, IWsHandler)
  private
    FInner: TRecordingHandler;
    FChannel: TFakeWsChannel;
  public
    /// the writer that Init streams; Init releases it
    Writer: IBodyWriter;
    /// the result of the SendStream call of Init
    InitSendResult: TSendResult;
    /// the text of a message that makes Message call Close
    CloseOn: string;
    constructor Create(const AInner: TRecordingHandler; const AChannel: TFakeWsChannel);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// the base of the session tests of SendStream; it has no tests of its own
  TWsStreamBase = class(TTestCase)
  protected
    FRig: TWsRig;
    FHandler: TRecordingHandler;
    FInnerRef: IWsHandler;
    FProbe: TStreamProbeHandler;
    FHandlerRef: IWsHandler;
    FChannel: TFakeWsChannel;
    FChannelRef: IDuplexChannel;
    FSession: IWsSession;
    FRequest: TFakeRequest;
    FRequestRef: IServerRequest;
    FGate: TEvent;
    FNeedle: string;
    FWantCalls, FWantGone, FWantFins, FWantCode, FWantCount: Integer;
    FSavedStepChunks: Integer;
    FStepChanged: Boolean;
    function ChannelActivated: Boolean;
    function ChannelCompleted: Boolean;
    function CallsReached: Boolean;
    function NoWriterInCall: Boolean;
    function WriterGone: Boolean;
    function DataFins: Integer;
    function StreamDone: Boolean;
    function FinCountReached: Boolean;
    function CloseCodeOut: Boolean;
    function HandlerHas: Boolean;
    function BytesOutDone: Boolean;
    function MessagesOutDone: Boolean;
    function CleanCloseCount: Integer;
    function CleanClosesReached: Boolean;
    procedure HookRefuseNext;
    procedure DrainOnce;
    procedure Start(const AOptions: TWsOptions; const AInitWriter: IBodyWriter;
      const AFullOnInit, ARejectInit: Boolean);
    procedure Build(const AOptions: TWsOptions);
    procedure DropRig;
    function Quick: TWsOptions;
    function WaitHandler(const AText: string; const AMs: Integer = 5000): Boolean;
    function OutFrames: TArray<TRawFrame>;
    function ServerStats: TServerStats;
    procedure CheckFrame(const AFrame: TRawFrame; const AOp: Byte; const AFin: Boolean;
      const APayload: string);
    procedure CheckRowFragments(const L: TArray<TRawFrame>);
    procedure SetUp; override;
    procedure TearDown; override;
  end;

  /// the session tests of SendStream
  TWsStreamTest = class(TWsStreamBase)
  published
    procedure TestStreamArrivesAsFragments;
    procedure TestSendStreamReturnsAtOnce;
    procedure TestFullParksAndDrainResumes;
    procedure TestDrainOnIoThreadDoesNotDeadlock;
    procedure TestLostDrainIsCoveredByThePoll;
    procedure TestSendDuringStreamIsRefused;
    procedure TestPingGoesBetweenFragments;
    procedure TestCloseDuringStreamSendsNoMoreData;
    procedure TestMessageIsDeliveredBetweenPumpSteps;
    procedure TestSendStreamFromInit;
    procedure TestSendStreamFromInitRejected;
    procedure TestAbortReleasesTheWriter;
    procedure TestPeerCloseReleasesTheWriter;
    procedure TestWriterExceptionEndsWithFailed;
    procedure TestSecondStreamAfterTheFirstIsAccepted;
    procedure TestSendStreamOnEndedSessionReturnsClosed;
    procedure TestStreamedTextWithSplitUtf8;
    procedure TestCountersCountStreamOnce;
    procedure TestLastChunkWithFalseCarriesTheFin;
  end;

/// the frames of a server output, read one by one
function RawFrames(const AData: TBytes): TArray<TRawFrame>;
/// the data octets of the frames, joined in order
function JoinedData(const L: TArray<TRawFrame>): TBytes;
/// one chunk for each string
function TextChunks(const AParts: array of string): TArray<TBytes>;
/// one chunk of one octet
function OneOctet(const AValue: Byte): TBytes;
/// ACount chunks, each with the text AText
function RepeatedChunks(const AText: string; const ACount: Integer): TArray<TBytes>;
var
  /// the calls of the writers in the current test
  GWriterCalls: Integer;
  /// the calls that are inside NextChunk now
  GWriterInCall: Integer;
  /// the writers that the library released in the current test
  GWriterDestroyed: Integer;

implementation

{ TStreamWriter }

constructor TStreamWriter.Create(const AChunks: TArray<TBytes>; const ALastFalse: Boolean);
begin
  inherited Create;
  FChunks := AChunks;
  FLastFalse := ALastFalse;
  FGateMs := 10000;
end;

destructor TStreamWriter.Destroy;
begin
  InterlockedIncrement(GWriterDestroyed);
  inherited Destroy;
end;

function TStreamWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  Call: Integer;
begin
  Call := InterlockedIncrement(FCall);
  InterlockedIncrement(GWriterCalls);
  InterlockedIncrement(GWriterInCall);
  try
    if (FHookAt > 0) and (Call = FHookAt) and Assigned(FHook) then
      FHook();
    if (FRaiseAt > 0) and (Call = FRaiseAt) then
      raise Exception.Create('boom');
    if FGate <> nil then
      FGate.WaitFor(FGateMs);
    if FNext >= Length(FChunks) then
      Exit(False);
    if Length(FChunks[FNext]) > 0 then
      ChunkAppend(ABuffer, FChunks[FNext]);
    Inc(FNext);
    Result := not (FLastFalse and (FNext = Length(FChunks)));
  finally
    InterlockedDecrement(GWriterInCall);
  end;
end;

{ TStreamProbeHandler }

constructor TStreamProbeHandler.Create(const AInner: TRecordingHandler;
  const AChannel: TFakeWsChannel);
begin
  inherited Create;
  FInner := AInner;
  FChannel := AChannel;
end;

function TStreamProbeHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  Result := FInner.Init(ARequest, AOffered, ASession);
  if Writer <> nil then
  begin
    InitSendResult := ASession.SendStream(Writer, True);
    Writer := nil;
  end;
end;

procedure TStreamProbeHandler.Message(const ASession: IWsSession; const AMessage: IBodyReader;
  const AText: Boolean);
var
  AData: TBytes;
begin
  // the probe reads the message, and the inner handler gets it from memory
  AData := ReadAllBody(AMessage);
  FInner.Message(ASession, TWsMemoryReader.Create(AData), AText);
  if (CloseOn <> '') and AText and (TextOf(AData) = CloseOn) then
    ASession.Close(1000, '');
end;

procedure TStreamProbeHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
  FInner.Pong(ASession, AData);
end;

procedure TStreamProbeHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  FInner.Closed(ASession, ACode, AReason, AClean);
end;

procedure TStreamProbeHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
  FInner.Failed(ASession, E);
end;

{ helpers }

function RawFrames(const AData: TBytes): TArray<TRawFrame>;
var
  L: TList<TRawFrame>;
  P, Len: Integer;
  F: TRawFrame;
begin
  L := TList<TRawFrame>.Create;
  try
    P := 0;
    while P + 2 <= Length(AData) do
    begin
      F.Opcode := Byte(AData[P] and $0F);
      F.Fin := (AData[P] and $80) <> 0;
      Len := AData[P + 1] and $7F;
      Inc(P, 2);
      if Len = 126 then
      begin
        Len := (Integer(AData[P]) shl 8) or AData[P + 1];
        Inc(P, 2);
      end;
      SetLength(F.Payload, Len);
      if Len > 0 then
        Move(AData[P], F.Payload[0], Len);
      Inc(P, Len);
      L.Add(F);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function JoinedData(const L: TArray<TRawFrame>): TBytes;
var
  I, N, Total: Integer;
begin
  Total := 0;
  for I := 0 to High(L) do
    if L[I].Opcode <= WsOpBinary then
      Inc(Total, Length(L[I].Payload));
  SetLength(Result, Total);
  N := 0;
  for I := 0 to High(L) do
    if L[I].Opcode <= WsOpBinary then
      if Length(L[I].Payload) > 0 then
      begin
        Move(L[I].Payload[0], Result[N], Length(L[I].Payload));
        Inc(N, Length(L[I].Payload));
      end;
end;

function TextChunks(const AParts: array of string): TArray<TBytes>;
var
  I: Integer;
begin
  SetLength(Result, Length(AParts));
  for I := 0 to High(AParts) do
    Result[I] := BytesOf(AParts[I]);
end;

function OneOctet(const AValue: Byte): TBytes;
begin
  SetLength(Result, 1);
  Result[0] := AValue;
end;

function RepeatedChunks(const AText: string; const ACount: Integer): TArray<TBytes>;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := BytesOf(AText);
end;

{ TWsStreamBase }

procedure TWsStreamBase.SetUp;
begin
  inherited SetUp;
  GWriterCalls := 0;
  GWriterInCall := 0;
  GWriterDestroyed := 0;
  FGate := nil;
  FStepChanged := False;
  FWantCalls := 0;
  FWantGone := 0;
  FWantFins := 0;
  FWantCode := 0;
  FWantCount := 0;
end;

procedure TWsStreamBase.TearDown;
var
  Quiet: Boolean;
begin
  // a writer that waits on the gate must leave its call before the rig goes
  if FGate <> nil then
    FGate.SetEvent;
  DropRig;
  if FStepChanged then
  begin
    WsPumpStepChunks := FSavedStepChunks;
    FStepChanged := False;
  end;
  Quiet := WaitUntil(NoWriterInCall, 10000);
  if FGate <> nil then
  begin
    // when a writer still waits, the event stays allocated
    if Quiet then
      FreeAndNil(FGate)
    else
      FGate := nil;
  end;
  inherited TearDown;
end;

function TWsStreamBase.ChannelActivated: Boolean;
begin
  Result := FChannel.Activated;
end;

function TWsStreamBase.ChannelCompleted: Boolean;
begin
  Result := FChannel.Completed;
end;

function TWsStreamBase.CallsReached: Boolean;
begin
  Result := GWriterCalls >= FWantCalls;
end;

function TWsStreamBase.NoWriterInCall: Boolean;
begin
  Result := GWriterInCall = 0;
end;

function TWsStreamBase.WriterGone: Boolean;
begin
  Result := GWriterDestroyed >= FWantGone;
end;

function TWsStreamBase.DataFins: Integer;
var
  L: TArray<TRawFrame>;
  I: Integer;
begin
  // only a continuation frame with FIN ends a streamed message in these tests
  L := OutFrames;
  Result := 0;
  for I := 0 to High(L) do
    if L[I].Fin and (L[I].Opcode = WsOpContinuation) then
      Inc(Result);
end;

function TWsStreamBase.StreamDone: Boolean;
begin
  Result := DataFins >= 1;
end;

function TWsStreamBase.FinCountReached: Boolean;
begin
  Result := DataFins >= FWantFins;
end;

function TWsStreamBase.CloseCodeOut: Boolean;
var
  L: TArray<TRawFrame>;
  I, Code: Integer;
begin
  Result := False;
  L := OutFrames;
  for I := 0 to High(L) do
    if (L[I].Opcode = WsOpClose) and (Length(L[I].Payload) >= 2) then
    begin
      Code := (Integer(L[I].Payload[0]) shl 8) or L[I].Payload[1];
      if Code = FWantCode then
        Exit(True);
    end;
end;

function TWsStreamBase.HandlerHas: Boolean;
begin
  Result := Pos(FNeedle, FHandler.AllText) > 0;
end;

function TWsStreamBase.BytesOutDone: Boolean;
begin
  Result := ServerStats.WsBytesOut = 15;
end;

function TWsStreamBase.MessagesOutDone: Boolean;
begin
  Result := ServerStats.WsMessagesOut = 1;
end;

function TWsStreamBase.CleanCloseCount: Integer;
var
  I: Integer;
  Line: string;
begin
  Result := 0;
  for I := 0 to FHandler.Count - 1 do
  begin
    Line := FHandler.Line(I);
    if (Pos('closed 1000 ', Line) = 1) and (Pos('clean=True', Line) > 0) then
      Inc(Result);
  end;
end;

function TWsStreamBase.CleanClosesReached: Boolean;
begin
  Result := CleanCloseCount >= FWantCount;
end;

procedure TWsStreamBase.HookRefuseNext;
begin
  FChannel.SetFullCount(1);
end;

procedure TWsStreamBase.DrainOnce;
begin
  FChannel.Drain;
end;

procedure TWsStreamBase.Start(const AOptions: TWsOptions; const AInitWriter: IBodyWriter;
  const AFullOnInit, ARejectInit: Boolean);
begin
  FRig := TWsRig.Create(AOptions);
  FHandler := TRecordingHandler.Create;
  FInnerRef := FHandler;
  if ARejectInit then
    FHandler.InitResult := TWsInitResult.Rejected(403);
  FChannel := FRig.NewChannel;
  FChannelRef := FChannel;
  FRequest := TFakeRequest.Create;
  FRequestRef := FRequest;
  FProbe := TStreamProbeHandler.Create(FHandler, FChannel);
  FProbe.Writer := AInitWriter;
  FHandlerRef := FProbe;
  if AFullOnInit then
    // the first Send of the held bytes is refused: only the park timer can resume it
    FChannel.SetFullCount(1);
  FSession := WsStartSession(FChannelRef, FRequestRef, FHandlerRef,
    TFakeHandshake.Create, nil);
end;

procedure TWsStreamBase.Build(const AOptions: TWsOptions);
begin
  Start(AOptions, nil, False, False);
  AssertTrue('the session opened', WaitUntil(ChannelActivated));
end;

procedure TWsStreamBase.DropRig;
begin
  if FRig <> nil then
  begin
    FRig.Registry.CloseAll(ccGraceful);
    FRig.Registry.CloseAll(ccAbort);
  end;
  if FChannel <> nil then
  begin
    FChannel.Sink := nil;
    FreeAndNil(FChannel.ConnLock);
  end;
  FSession := nil;
  FProbe := nil;
  FChannel := nil;
  FChannelRef := nil;
  FRequest := nil;
  FRequestRef := nil;
  FHandler := nil;
  FHandlerRef := nil;
  FInnerRef := nil;
  FreeAndNil(FRig);
end;

function TWsStreamBase.Quick: TWsOptions;
begin
  Result := TWsOptions.Create
    .WithPingIntervalMs(0)
    .WithCloseTimeoutMs(300)
    .WithInitTimeoutMs(5000);
end;

function TWsStreamBase.WaitHandler(const AText: string; const AMs: Integer): Boolean;
begin
  FNeedle := AText;
  Result := WaitUntil(HandlerHas, AMs);
end;

function TWsStreamBase.OutFrames: TArray<TRawFrame>;
begin
  Result := RawFrames(FChannel.SentBytes);
end;

function TWsStreamBase.ServerStats: TServerStats;
var
  S: TServerStats;
begin
  S := Default(TServerStats);
  FRig.Env.FillStats(S);
  Result := S;
end;

procedure TWsStreamBase.CheckFrame(const AFrame: TRawFrame; const AOp: Byte;
  const AFin: Boolean; const APayload: string);
begin
  AssertEquals('opcode', Integer(AOp), Integer(AFrame.Opcode));
  AssertEquals('FIN', AFin, AFrame.Fin);
  AssertEquals('payload', APayload, TextOf(AFrame.Payload));
end;

procedure TWsStreamBase.CheckRowFragments(const L: TArray<TRawFrame>);
begin
  AssertEquals('three rows and the final frame', 4, Length(L));
  CheckFrame(L[0], WsOpText, False, 'row1;');
  CheckFrame(L[1], WsOpContinuation, False, 'row2;');
  CheckFrame(L[2], WsOpContinuation, False, 'row3;');
  CheckFrame(L[3], WsOpContinuation, True, '');
end;

{ TWsStreamTest }

procedure TWsStreamTest.TestStreamArrivesAsFragments;
begin
  Build(Quick);
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  AssertTrue('the message completes', WaitUntil(StreamDone));
  CheckRowFragments(OutFrames);
end;

procedure TWsStreamTest.TestSendStreamReturnsAtOnce;
var
  W: TStreamWriter;
  Started: QWord;
  R: TSendResult;
begin
  Build(Quick);
  FGate := TEvent.Create(nil, True, False, '');
  W := TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;']));
  W.Gate := FGate;
  Started := GetTickCount64;
  R := FSession.SendStream(W, True);
  AssertTrue('SendStream returns before the writer answers', GetTickCount64 - Started < 2000);
  AssertTrue('the stream is queued', R = srQueued);
  FGate.SetEvent;
  AssertTrue('the message completes', WaitUntil(StreamDone));
  CheckRowFragments(OutFrames);
end;

procedure TWsStreamTest.TestFullParksAndDrainResumes;
begin
  Build(Quick);
  FChannel.Full := True;
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  Sleep(500);
  AssertEquals('the writer is not asked again while the stream is parked', 1, GWriterCalls);
  FChannel.Drain;
  AssertTrue('the message completes', WaitUntil(StreamDone));
  CheckRowFragments(OutFrames);
  AssertEquals('each chunk is asked once', 4, GWriterCalls);
end;

procedure TWsStreamTest.TestDrainOnIoThreadDoesNotDeadlock;
var
  T: TProcThread;
begin
  Build(Quick);
  // the drain holds this lock while the sink runs, as the IO thread does
  FChannel.ConnLock := TCriticalSection.Create;
  FChannel.Full := True;
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  Sleep(100);
  T := TProcThread.Create(DrainOnce);
  AssertTrue('the drain on the IO thread returns', T.Done.WaitFor(5000) = wrSignaled);
  T.WaitFor;
  T.Free;
  AssertTrue('the stream completes within 5 seconds', WaitUntil(StreamDone, 5000));
  CheckRowFragments(OutFrames);
end;

procedure TWsStreamTest.TestLostDrainIsCoveredByThePoll;
begin
  Build(Quick);
  FChannel.Full := True;
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  Sleep(50);
  // no Drain call: only the park timer can find the room
  FChannel.Full := False;
  AssertTrue('the poll completes the stream within 2 seconds', WaitUntil(StreamDone, 2000));
  CheckRowFragments(OutFrames);
end;

procedure TWsStreamTest.TestSendDuringStreamIsRefused;
begin
  Build(Quick);
  FChannel.Full := True;
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  AssertTrue('Send is refused while the stream runs',
    FSession.Send(BytesOf('x'), True) = srFull);
  AssertTrue('SendStream is refused while the stream runs',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['z'])), True) = srFull);
  FChannel.Full := False;
  FChannel.Drain;
  AssertTrue('the message completes', WaitUntil(StreamDone));
  // two writers are released: the refused one at once, and the stream's writer last
  FWantGone := 2;
  AssertTrue('both writers are released', WaitUntil(WriterGone));
  CheckRowFragments(OutFrames);
  AssertTrue('Send is queued after the stream', FSession.Send(BytesOf('y'), True) = srQueued);
end;

procedure TWsStreamTest.TestPingGoesBetweenFragments;
var
  W: TStreamWriter;
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  W := TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;']));
  W.HookAt := 2;
  // the hook refuses the next Send only: the second fragment, and then the pump parks
  W.Hook := HookRefuseNext;
  AssertTrue('the stream is queued', FSession.SendStream(W, True) = srQueued);
  FWantCalls := 2;
  AssertTrue('the writer is asked for the second chunk', WaitUntil(CallsReached));
  Sleep(50);
  FSession.Ping(BytesOf('p'));
  FChannel.Drain;
  AssertTrue('the message completes', WaitUntil(StreamDone));
  L := OutFrames;
  AssertEquals('row, ping, row, row and the final frame', 5, Length(L));
  CheckFrame(L[0], WsOpText, False, 'row1;');
  CheckFrame(L[1], WsOpPing, True, 'p');
  CheckFrame(L[2], WsOpContinuation, False, 'row2;');
  CheckFrame(L[3], WsOpContinuation, False, 'row3;');
  CheckFrame(L[4], WsOpContinuation, True, '');
end;

procedure TWsStreamTest.TestCloseDuringStreamSendsNoMoreData;
var
  L: TArray<TRawFrame>;
  I: Integer;
  Seen: Boolean;
begin
  Build(Quick.WithCloseTimeoutMs(5000));
  // the first fragment is refused, so the pump parks; the Close frame still goes out
  FChannel.SetFullCount(1);
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  Sleep(50);
  FSession.Close(1000, '');
  FChannel.Drain;
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  L := OutFrames;
  Seen := False;
  for I := 0 to High(L) do
    if L[I].Opcode = WsOpClose then
      Seen := True
    else if Seen and (L[I].Opcode <= WsOpBinary) then
      Fail('a data frame follows the Close frame');
  AssertTrue('the Close frame went out', Seen);
  FChannel.Deliver(ClientClose(1000, ''));
  AssertTrue('the handler gets Closed with code 1000', WaitHandler('closed 1000 ', 5000));
  AssertTrue('the close is clean', Pos('clean=True', FHandler.AllText) > 0);
  AssertTrue('the close is not 1006', Pos('closed 1006', FHandler.AllText) = 0);
end;

procedure TWsStreamTest.TestMessageIsDeliveredBetweenPumpSteps;
var
  W: TStreamWriter;
begin
  // one chunk per step, so the pool turn comes back after each chunk
  FSavedStepChunks := WsPumpStepChunks;
  FStepChanged := True;
  WsPumpStepChunks := 1;
  Build(Quick);
  FProbe.CloseOn := 'cancel';
  // 20 chunks; each call waits 100 ms on the gate, which is never set, so the stream
  // runs for about 2 seconds. TearDown sets the gate and releases the writer at once
  FGate := TEvent.Create(nil, True, False, '');
  W := TStreamWriter.Create(RepeatedChunks('x', 20));
  W.Gate := FGate;
  W.GateMs := 100;
  AssertTrue('the stream is queued', FSession.SendStream(W, True) = srQueued);
  FWantCalls := 2;
  AssertTrue('the stream is in flight', WaitUntil(CallsReached));
  FChannel.Deliver(ClientText('cancel'));
  AssertTrue('the message arrives within 500 ms', WaitHandler('msg T cancel', 500));
  FWantGone := 1;
  AssertTrue('the Close from Message stops the stream', WaitUntil(WriterGone, 5000));
  FWantCode := 1000;
  AssertTrue('a Close frame went out', WaitUntil(CloseCodeOut, 5000));
end;

procedure TWsStreamTest.TestSendStreamFromInit;
begin
  // SendStream runs in Init, and the channel refuses its first write
  Start(Quick, TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True, False);
  AssertTrue('the session opened', WaitUntil(ChannelActivated));
  AssertEquals('the handshake answers 200', 200, FChannel.ActivatedStatus);
  AssertTrue('the stream of Init is queued', FProbe.InitSendResult = srQueued);
  AssertTrue('the message completes', WaitUntil(StreamDone, 5000));
  CheckRowFragments(OutFrames);
end;

procedure TWsStreamTest.TestSendStreamFromInitRejected;
begin
  Start(Quick, TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), False, True);
  AssertTrue('the channel completes', WaitUntil(ChannelCompleted));
  AssertEquals('the error status goes out', 403, FChannel.CompletedStatus);
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('no frame leaves before the error response', 0, Length(FChannel.SentBytes));
  AssertEquals('the writer is never asked', 0, GWriterCalls);
end;

procedure TWsStreamTest.TestAbortReleasesTheWriter;
begin
  Build(Quick);
  FChannel.Full := True;
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  FSession.Abort;
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
end;

procedure TWsStreamTest.TestPeerCloseReleasesTheWriter;
begin
  Build(Quick);
  // the first fragment is refused, so the stream is parked when the peer closes
  FChannel.SetFullCount(1);
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  FWantCalls := 1;
  AssertTrue('the writer is asked for one chunk', WaitUntil(CallsReached));
  Sleep(50);
  FChannel.Deliver(ClientClose(1000, ''));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertTrue('the handler gets Closed', WaitHandler('closed 1000 ', 5000));
end;

procedure TWsStreamTest.TestWriterExceptionEndsWithFailed;
var
  W: TStreamWriter;
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  W := TStreamWriter.Create(TextChunks(['a', 'b', 'c']));
  W.RaiseAt := 2;
  AssertTrue('the stream is queued', FSession.SendStream(W, True) = srQueued);
  AssertTrue('the handler hears Failed', WaitHandler('failed boom', 5000));
  FWantCode := 1011;
  AssertTrue('the channel ends with a Close frame of code 1011', WaitUntil(CloseCodeOut, 5000));
  L := OutFrames;
  AssertEquals('the last frame is a Close frame', Integer(WsOpClose),
    Integer(L[High(L)].Opcode));
end;

procedure TWsStreamTest.TestSecondStreamAfterTheFirstIsAccepted;
begin
  Build(Quick);
  AssertTrue('the first stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['a'])), True) = srQueued);
  AssertTrue('the first message completes', WaitUntil(StreamDone));
  FWantGone := 1;
  AssertTrue('the first writer is released', WaitUntil(WriterGone));
  AssertTrue('the second stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['b'])), True) = srQueued);
  FWantFins := 2;
  AssertTrue('the second message completes', WaitUntil(FinCountReached));
end;

procedure TWsStreamTest.TestSendStreamOnEndedSessionReturnsClosed;
begin
  Build(Quick);
  FSession.Abort;
  AssertTrue('SendStream returns srClosed',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['a'])), True) = srClosed);
  AssertTrue('Send returns srClosed', FSession.Send(BytesOf('x'), True) = srClosed);
end;

procedure TWsStreamTest.TestStreamedTextWithSplitUtf8;
var
  Parts: TArray<TBytes>;
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  // the two octets of one character, in two chunks
  SetLength(Parts, 2);
  Parts[0] := OneOctet($C3);
  Parts[1] := OneOctet($A9);
  AssertTrue('the stream is queued', FSession.SendStream(TStreamWriter.Create(Parts), True) = srQueued);
  AssertTrue('the message completes', WaitUntil(StreamDone));
  L := OutFrames;
  AssertEquals('the first chunk, the second chunk and the final frame', 3, Length(L));
  CheckFrame(L[0], WsOpText, False, #$C3);
  CheckFrame(L[1], WsOpContinuation, False, #$A9);
  CheckFrame(L[2], WsOpContinuation, True, '');
  AssertEquals('the octets join to the character', #$C3#$A9, TextOf(JoinedData(L)));
end;

procedure TWsStreamTest.TestCountersCountStreamOnce;
begin
  Build(Quick);
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;', 'row3;'])), True) = srQueued);
  AssertTrue('the message completes', WaitUntil(StreamDone));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertTrue('the bytes are counted', WaitUntil(BytesOutDone));
  AssertTrue('the message is counted once', WaitUntil(MessagesOutDone));
  AssertEquals('one message', Int64(1), ServerStats.WsMessagesOut);
  AssertEquals('the sum of the chunk lengths', Int64(15), ServerStats.WsBytesOut);
end;

procedure TWsStreamTest.TestLastChunkWithFalseCarriesTheFin;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  // this writer answers False with its last chunk, so no empty frame follows
  AssertTrue('the stream is queued',
    FSession.SendStream(TStreamWriter.Create(TextChunks(['row1;', 'row2;']), True), True) = srQueued);
  AssertTrue('the message completes', WaitUntil(StreamDone));
  L := OutFrames;
  AssertEquals('two frames and no empty frame', 2, Length(L));
  CheckFrame(L[0], WsOpText, False, 'row1;');
  CheckFrame(L[1], WsOpContinuation, True, 'row2;');
  AssertEquals('no extra call ends the body', 2, GWriterCalls);
end;

initialization
  RegisterTest(TWsStreamTest);
end.
