{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Request observer tests (doc/design/request-observability.md)
// - NOTHING here opens a real socket: the HTTP/2 cases run against the scripted
//   frame-level peer of Http2.Client.Redirects.Test, the cleartext and HTTP/1.1 cases
//   against the scripted sockets of Http2.Client.ClearText.Test.
// - non-vacuous by construction: the injected header values are asserted from
//   the DECODED request HEADERS the peer captured, the attempt order from the
//   events a recording observer saw, and every end is counted, so a missing,
//   duplicated or premature OnAttemptEnd fails a test.
// - waits are event-driven with bounded timeouts; nothing sleeps to wait for
//   another thread.
unit Http2.Client.RequestObserver.Support;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Redirects.Test,
  Http2.Client.ClearText.Support, Http2.Client.Http1, Http2.Client.Http1.Test, Http2.Client.Sse;

type
  /// a thread-safe ordered log shared by several observers
  TEventLog = class
  private
    FLock: TCriticalSection;
    FItems: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AItem: string);
    function Text: string;
    function Count: Integer;
  end;

  /// one recorded outcome with the exception reduced to its class name
  TRecordedOutcome = record
    O: THttpOutcome;
    ErrorClass: string;
    ErrorMessage: string;
  end;

  /// an observer that records every callback.  Attempt n gets token n, and the
  /// log reads 'S0 H0 R0 E0 S1 ...' (Start, Headers, Redirect, reTry, End).
  TRecordingRequestObserver = class(TBaseRequestObserver)
  private
    FLock: TCriticalSection;
    FChanged: PRTLEvent;
    FLog: TEventLog;
    FOwnLog: Boolean;
    FTag: string;
    FAttempts: TList<THttpAttempt>;
    FOutcomes: TList<TRecordedOutcome>;
    FEndCount: Integer;
    FStarts: Integer;
    procedure Note(const AKind: Char; const AToken: IInterface);
    procedure MaybeRaise(const ACallback: string);
  public
    /// header to inject on every attempt ('' = none); the value is
    /// '<prefix>-<n>', fresh per attempt
    InjectName: string;
    InjectPrefix: string;
    /// the first value of InjectName seen before the injection, per attempt
    SeenBefore: TStringList;
    /// callbacks (comma separated, e.g. 'OnAttemptEnd') that raise
    RaiseOn: string;
    constructor Create(const ALog: TEventLog = nil; const ATag: string = '');
    destructor Destroy; override;
    function OnAttemptStart(const A: THttpAttempt): IInterface; override;
    procedure OnResponseHeaders(const AToken: IInterface;
      const AResponse: IHttpResponse); override;
    procedure OnRedirect(const AToken: IInterface; const AFromUrl,
      AToUrl: string; const AStatus: LongInt); override;
    procedure OnRetry(const AToken: IInterface;
      const AReason: string); override;
    procedure OnAttemptEnd(const AToken: IInterface;
      const O: THttpOutcome); override;
    /// the callbacks seen, as 'S0 H0 R0 E0 S1 ...'
    function Order: string;
    function Attempt(const AIndex: Integer): THttpAttempt;
    function Outcome(const AIndex: Integer): TRecordedOutcome;
    function StartCount: Integer;
    function EndCount: Integer;
    /// bounded wait until at least ACount ends were recorded
    function WaitForEnds(const ACount, ATimeoutMs: Integer): Boolean;
  end;

  /// a logger that keeps its messages
  TRecordingLogger = class(TInterfacedObject, IHttpLogger)
  private
    FLock: TCriticalSection;
    FLevels: TList<TLogLevel>;
    FMessages: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Log(const ALevel: TLogLevel; const AMessage: string);
    function Count: Integer;
    function MessageAt(const AIndex: Integer): string;
    function LevelAt(const AIndex: Integer): TLogLevel;
  end;

  /// counts how often a codec reports an end
  TCountingExchange = class(TInterfacedObject, IExchangeObserver)
  private
    FEnds: LongInt;
    FAbandoned: LongInt;
  public
    procedure RouteChosen(const AProtocol: TNegotiatedProtocol;
      const AReused: Boolean);
    procedure RequestWritten(const ABytesOut: Int64);
    procedure ExchangeEnded(const AEnd: TExchangeEnd);
    property Ends: LongInt read FEnds;
    property Abandoned: LongInt read FAbandoned;
  end;


  TMessageRecordingObserver = class(TRecordingRequestObserver,
    IHttpMessageObserver)
  private
    FMsgLock: TCriticalSection;
    FMessages: TList<TMessageInfo>;
    FData: TStringList;       // the Sse^.Data read inside each callback
    FWantsCalls: Integer;
  public
    /// what WantsMessages answers
    Wants: TMessageKinds;
    /// OnMessage raises (after recording)
    RaiseOnMessage: Boolean;
    constructor Create(const AWants: TMessageKinds);
    destructor Destroy; override;
    function WantsMessages(const A: THttpAttempt): TMessageKinds;
    procedure OnMessage(const AToken: IInterface; const M: TMessageInfo);
    function MessageCount: Integer;
    function MessageAt(const AIndex: Integer): TMessageInfo;
    function DataAt(const AIndex: Integer): string;
    property WantsCalls: Integer read FWantsCalls;
  end;


type
  TStagedSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader)
  private
    FChunks: TArray<string>;
    FStamps: TArray<Int64>;
    FIndex: Integer;
    FOffset: Integer;
  public
    procedure Add(const AChunk: string; const AStampUs: Int64);
    function Read(var ABuffer; ACount: Integer): Integer;
    function ReadSome(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
  end;

  /// keeps the last end a codec reported
  TCapturedExchange = class(TInterfacedObject, IExchangeObserver)
  public
    Ends: Integer;
    Last: TExchangeEnd;
    procedure RouteChosen(const AProtocol: TNegotiatedProtocol;
      const AReused: Boolean);
    procedure RequestWritten(const ABytesOut: Int64);
    procedure ExchangeEnded(const AEnd: TExchangeEnd);
  end;

function CountPingAcks(const AFrames: TArray<TFrame>): Integer;

var
  /// the scripted clock the arrival tests install
  GScriptedUs: Int64;
function ScriptedClock: Int64;

implementation

function BytesOf(const S: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(S));
  for I := 1 to Length(S) do
    Result[I - 1] := Ord(S[I]);
end;

{ TEventLog }

constructor TEventLog.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TStringList.Create;
end;

destructor TEventLog.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TEventLog.Add(const AItem: string);
begin
  FLock.Acquire;
  try
    FItems.Add(AItem);
  finally
    FLock.Release;
  end;
end;

function TEventLog.Text: string;
var
  I: Integer;
begin
  FLock.Acquire;
  try
    Result := '';
    for I := 0 to FItems.Count - 1 do
    begin
      if I > 0 then
        Result := Result + ' ';
      Result := Result + FItems[I];
    end;
  finally
    FLock.Release;
  end;
end;

function TEventLog.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FItems.Count;
  finally
    FLock.Release;
  end;
end;

type
  IAttemptIndex = interface
    ['{7D1E5A02-3B94-4C6F-8E21-5A0C9B3D6FA1}']
    function GetIndex: Integer;
  end;

  /// the token an observer hands back: the attempt's index
  TAttemptToken = class(TInterfacedObject, IAttemptIndex)
  public
    Index: Integer;
    function GetIndex: Integer;
  end;

function TAttemptToken.GetIndex: Integer;
begin
  Result := Index;
end;

{ TRecordingRequestObserver }

constructor TRecordingRequestObserver.Create(const ALog: TEventLog;
  const ATag: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FChanged := RTLEventCreate;
  FAttempts := TList<THttpAttempt>.Create;
  FOutcomes := TList<TRecordedOutcome>.Create;
  SeenBefore := TStringList.Create;
  FTag := ATag;
  if ALog = nil then
  begin
    FLog := TEventLog.Create;
    FOwnLog := True;
  end
  else
    FLog := ALog;
end;

destructor TRecordingRequestObserver.Destroy;
begin
  if FOwnLog then
    FLog.Free;
  SeenBefore.Free;
  FOutcomes.Free;
  FAttempts.Free;
  RTLEventDestroy(FChanged);
  FLock.Free;
  inherited Destroy;
end;

procedure TRecordingRequestObserver.Note(const AKind: Char;
  const AToken: IInterface);
var
  Index: Integer;
begin
  Index := -1;
  if AToken <> nil then
    Index := (AToken as IAttemptIndex).GetIndex;
  if FTag <> '' then
    FLog.Add(FTag + '.' + AKind)
  else
    FLog.Add(AKind + IntToStr(Index));
end;

procedure TRecordingRequestObserver.MaybeRaise(const ACallback: string);
begin
  if Pos(ACallback, RaiseOn) > 0 then
    raise Exception.Create('observer failed in ' + ACallback);
end;

function TRecordingRequestObserver.OnAttemptStart(
  const A: THttpAttempt): IInterface;
var
  T: TAttemptToken;
  N: Integer;
begin
  FLock.Acquire;
  try
    N := FStarts;
    Inc(FStarts);
    FAttempts.Add(A);
  finally
    FLock.Release;
  end;
  T := TAttemptToken.Create;
  T.Index := N;
  Result := T;
  if FTag <> '' then
    FLog.Add(FTag + '.S')
  else
    FLog.Add('S' + IntToStr(N));
  MaybeRaise('OnAttemptStart');
  if InjectName <> '' then
  begin
    SeenBefore.Add(A.Headers.GetFirst(InjectName));
    A.Headers.SetValue(InjectName, InjectPrefix + '-' + IntToStr(N + 1));
  end;
end;

procedure TRecordingRequestObserver.OnResponseHeaders(const AToken: IInterface;
  const AResponse: IHttpResponse);
begin
  Note('H', AToken);
  MaybeRaise('OnResponseHeaders');
end;

procedure TRecordingRequestObserver.OnRedirect(const AToken: IInterface;
  const AFromUrl, AToUrl: string; const AStatus: LongInt);
begin
  Note('R', AToken);
  MaybeRaise('OnRedirect');
end;

procedure TRecordingRequestObserver.OnRetry(const AToken: IInterface;
  const AReason: string);
begin
  Note('T', AToken);
  MaybeRaise('OnRetry');
end;

procedure TRecordingRequestObserver.OnAttemptEnd(const AToken: IInterface;
  const O: THttpOutcome);
var
  Rec: TRecordedOutcome;
begin
  Rec.O := O;
  Rec.O.Error := nil;
  Rec.ErrorClass := '';
  Rec.ErrorMessage := '';
  if O.Error <> nil then
  begin
    Rec.ErrorClass := O.Error.ClassName;
    Rec.ErrorMessage := O.Error.Message;
  end;
  FLock.Acquire;
  try
    FOutcomes.Add(Rec);
    Inc(FEndCount);
  finally
    FLock.Release;
  end;
  Note('E', AToken);
  RTLEventSetEvent(FChanged);
  MaybeRaise('OnAttemptEnd');
end;

function TRecordingRequestObserver.Order: string;
begin
  Result := FLog.Text;
end;

function TRecordingRequestObserver.Attempt(const AIndex: Integer): THttpAttempt;
begin
  FLock.Acquire;
  try
    Result := FAttempts[AIndex];
  finally
    FLock.Release;
  end;
end;

function TRecordingRequestObserver.Outcome(
  const AIndex: Integer): TRecordedOutcome;
begin
  FLock.Acquire;
  try
    Result := FOutcomes[AIndex];
  finally
    FLock.Release;
  end;
end;

function TRecordingRequestObserver.StartCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FStarts;
  finally
    FLock.Release;
  end;
end;

function TRecordingRequestObserver.EndCount: Integer;
begin
  FLock.Acquire;
  try
    Result := FEndCount;
  finally
    FLock.Release;
  end;
end;

function TRecordingRequestObserver.WaitForEnds(const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if EndCount >= ACount then
      Exit(True);
    if GetTickCount64 >= Deadline then
      Exit(False);
    RTLEventWaitFor(FChanged, 20);
  end;
end;

{ TRecordingLogger }

constructor TRecordingLogger.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLevels := TList<TLogLevel>.Create;
  FMessages := TStringList.Create;
end;

destructor TRecordingLogger.Destroy;
begin
  FMessages.Free;
  FLevels.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TRecordingLogger.Log(const ALevel: TLogLevel;
  const AMessage: string);
begin
  FLock.Acquire;
  try
    FLevels.Add(ALevel);
    FMessages.Add(AMessage);
  finally
    FLock.Release;
  end;
end;

function TRecordingLogger.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FMessages.Count;
  finally
    FLock.Release;
  end;
end;

function TRecordingLogger.MessageAt(const AIndex: Integer): string;
begin
  FLock.Acquire;
  try
    Result := FMessages[AIndex];
  finally
    FLock.Release;
  end;
end;

function TRecordingLogger.LevelAt(const AIndex: Integer): TLogLevel;
begin
  FLock.Acquire;
  try
    Result := FLevels[AIndex];
  finally
    FLock.Release;
  end;
end;

{ TCountingExchange }

procedure TCountingExchange.RouteChosen(const AProtocol: TNegotiatedProtocol;
  const AReused: Boolean);
begin
end;

procedure TCountingExchange.RequestWritten(const ABytesOut: Int64);
begin
end;

procedure TCountingExchange.ExchangeEnded(const AEnd: TExchangeEnd);
begin
  InterlockedIncrement(FEnds);
  if AEnd.Abandoned then
    InterlockedIncrement(FAbandoned);
end;

{ TClockTest }
function ScriptedClock: Int64;
begin
  Result := GScriptedUs;
end;

{ TMessageRecordingObserver }

constructor TMessageRecordingObserver.Create(const AWants: TMessageKinds);
begin
  inherited Create;
  Wants := AWants;
  FMsgLock := TCriticalSection.Create;
  FMessages := TList<TMessageInfo>.Create;
  FData := TStringList.Create;
end;

destructor TMessageRecordingObserver.Destroy;
begin
  FData.Free;
  FMessages.Free;
  FMsgLock.Free;
  inherited Destroy;
end;

function TMessageRecordingObserver.WantsMessages(
  const A: THttpAttempt): TMessageKinds;
begin
  FMsgLock.Acquire;
  try
    Inc(FWantsCalls);
  finally
    FMsgLock.Release;
  end;
  Result := Wants;
end;

procedure TMessageRecordingObserver.OnMessage(const AToken: IInterface;
  const M: TMessageInfo);
var
  Data: string;
begin
  // the pointer is valid only here: read what the test needs now
  Data := '';
  if M.Sse <> nil then
    Data := M.Sse^.Data;
  FMsgLock.Acquire;
  try
    FMessages.Add(M);
    FData.Add(Data);
  finally
    FMsgLock.Release;
  end;
  if RaiseOnMessage then
    raise Exception.Create('observer failed in OnMessage');
end;

function TMessageRecordingObserver.MessageCount: Integer;
begin
  FMsgLock.Acquire;
  try
    Result := FMessages.Count;
  finally
    FMsgLock.Release;
  end;
end;

function TMessageRecordingObserver.MessageAt(
  const AIndex: Integer): TMessageInfo;
begin
  FMsgLock.Acquire;
  try
    Result := FMessages[AIndex];
  finally
    FMsgLock.Release;
  end;
end;

function TMessageRecordingObserver.DataAt(const AIndex: Integer): string;
begin
  FMsgLock.Acquire;
  try
    Result := FData[AIndex];
  finally
    FMsgLock.Release;
  end;
end;

{ TMessageObserverTest }


function CountPingAcks(const AFrames: TArray<TFrame>): Integer;
var
  K: Integer;
begin
  Result := 0;
  for K := 0 to High(AFrames) do
    if (AFrames[K].Header.FrameType = ftPing) and AFrames[K].IsAck then
      Inc(Result);
end;


procedure TStagedSocket.Add(const AChunk: string; const AStampUs: Int64);
begin
  SetLength(FChunks, Length(FChunks) + 1);
  SetLength(FStamps, Length(FStamps) + 1);
  FChunks[High(FChunks)] := AChunk;
  FStamps[High(FStamps)] := AStampUs;
end;

function TStagedSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
var
  Rest: Integer;
begin
  if FIndex >= Length(FChunks) then
    Exit(0);
  if FOffset = 0 then
    GScriptedUs := FStamps[FIndex];
  Rest := Length(FChunks[FIndex]) - FOffset;
  Result := ACount;
  if Result > Rest then
    Result := Rest;
  Move(FChunks[FIndex][FOffset + 1], PByte(@ABuffer)^, Result);
  Inc(FOffset, Result);
  if FOffset >= Length(FChunks[FIndex]) then
  begin
    Inc(FIndex);
    FOffset := 0;
  end;
end;

function TStagedSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := ReadSome(ABuffer, ACount);
end;

function TStagedSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := ACount;
end;

procedure TStagedSocket.Close;
begin
end;

function TStagedSocket.GetConnected: Boolean;
begin
  Result := True;
end;

function TStagedSocket.GetConnectTimeoutMs: Integer;
begin
  Result := 1000;
end;

procedure TStagedSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
end;

function TStagedSocket.GetReadTimeoutMs: Integer;
begin
  Result := 1000;
end;

procedure TStagedSocket.SetReadTimeoutMs(const AValue: Integer);
begin
end;

function TStagedSocket.GetWriteTimeoutMs: Integer;
begin
  Result := 1000;
end;

procedure TStagedSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
end;

procedure TCapturedExchange.RouteChosen(const AProtocol: TNegotiatedProtocol;
  const AReused: Boolean);
begin
end;

procedure TCapturedExchange.RequestWritten(const ABytesOut: Int64);
begin
end;

procedure TCapturedExchange.ExchangeEnded(const AEnd: TExchangeEnd);
begin
  Inc(Ends);
  Last := AEnd;
end;



end.
