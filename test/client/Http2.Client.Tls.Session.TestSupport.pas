{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, tls, test, support
notes:
  - These helpers provide partial streams and bounded worker threads.
---
}
unit Http2.Client.Tls.Session.TestSupport;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Http2.Client.Errors,
  Http2.Client.Tls.Types, Http2.Client.Pool, Http2.Client.ClientCert,
  Http2.Common.Tls.Context, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session,
  Http2.Common.Tls.Types, mormot.core.os;

type
  TPoolLockProbeThread = class;

  TLockProbeSelector = class(TInterfacedObject, IClientIdentitySelector)
  private
    FPool: TConnectionPool;
    FCalls: Integer;
    FPoolLockAvailable: LongInt;
    FProbeThread: TPoolLockProbeThread;
  public
    constructor Create(const APool: TConnectionPool);
    destructor Destroy; override;
    function Select(const AHost: string; const APort: Word): IClientIdentity;
    property Calls: Integer read FCalls;
    function PoolLockAvailable: Boolean;
    procedure JoinProbe;
  end;

  TPoolLockProbeThread = class(TThread)
  private
    FPool: TConnectionPool;
    FProbe: TLockProbeSelector;
  protected
    procedure Execute; override;
  public
    constructor Create(const APool: TConnectionPool;
      const AProbe: TLockProbeSelector);
  end;

  TTlsReadWorker = class(TThread)
  private
    FReader: IPartialReader;
    FDone: PRTLEvent;
    FError: string;
    FCompleted: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: IHttp2Socket);
    destructor Destroy; override;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Error: string read FError;
  end;

  TTlsWriteWorker = class(TThread)
  private
    FSocket: IHttp2Socket;
    FDone: PRTLEvent;
    FError: string;
    FCompleted: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASocket: IHttp2Socket);
    destructor Destroy; override;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Error: string read FError;
  end;

  TPartialStream = class(TInterfacedObject, IHttp2Socket, IPartialReader,
    IPendingInput)
  private
    FInput, FOutput: TBytes;
    FOpen: Boolean;
    FMaxWrite: Integer;
    FReadTimeoutMs: Integer;
    FReads, FWrites: Integer;
    FTrickleDelayMs: Integer;
    FReadStarted, FReadRelease: PRTLEvent;
    FWriteStarted, FWriteRelease: PRTLEvent;
    FBlockRead, FReadHasStarted, FHoldRead: Boolean;
    FBlockWrite, FWriteHasStarted: Boolean;
    FFailNextWrite: Boolean;
    FFailAllWrites: Boolean;
  public
    constructor Create(const AMaxWrite: Integer = 3);
    destructor Destroy; override;
    procedure EnableReadBlocking;
    procedure ReleaseBlockedRead;
    procedure HoldBlockedReadUntilReleased;
    procedure EnableTrickleReads(const ADelayMs: Integer);
    function WaitForReadStart(const ATimeoutMs: Integer): Boolean;
    procedure EnableWriteBlocking;
    procedure FailNextWrite;
    procedure FailAllWrites;
    function WaitForWriteStart(const ATimeoutMs: Integer): Boolean;
    procedure ReleaseBlockedWrite;
    procedure Push(const ABytes: TBytes);
    function HasPendingInput: Boolean;
    function Output: TBytes;
    function ReadCount: Integer;
    function WriteCount: Integer;
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

  TContextSpy = class(TInterfacedObject, ITLSContext)
  private
    FInner: ITLSContext;
    FLastOptions: TTlsClientSessionOptions;
    FCalls: Integer;
  public
    constructor Create(const AInner: ITLSContext);
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
    property LastOptions: TTlsClientSessionOptions read FLastOptions;
    property Calls: Integer read FCalls;
  end;

procedure Check(const ACondition: Boolean; const AMessage: string);
function Bytes(const AText: AnsiString): TBytes;

implementation

constructor TPartialStream.Create(const AMaxWrite: Integer);
begin
  inherited Create;
  FOpen := True;
  FMaxWrite := AMaxWrite;
  FReadTimeoutMs := 1000;
  FReadStarted := nil;
  FReadRelease := nil;
  FWriteStarted := nil;
  FWriteRelease := nil;
  FBlockRead := False;
  FHoldRead := False;
  FReadHasStarted := False;
  FBlockWrite := False;
  FWriteHasStarted := False;
  FFailNextWrite := False;
  FFailAllWrites := False;
  FTrickleDelayMs := 0;
end;

destructor TPartialStream.Destroy;
begin
  Close;
  if FReadStarted <> nil then RTLEventDestroy(FReadStarted);
  if FReadRelease <> nil then RTLEventDestroy(FReadRelease);
  if FWriteStarted <> nil then RTLEventDestroy(FWriteStarted);
  if FWriteRelease <> nil then RTLEventDestroy(FWriteRelease);
  inherited Destroy;
end;
procedure TPartialStream.EnableReadBlocking;
begin
  FReadStarted := RTLEventCreate;
  FReadRelease := RTLEventCreate;
  FBlockRead := True;
end;
procedure TPartialStream.HoldBlockedReadUntilReleased;
begin
  FHoldRead := True; // a blocked read ignores the read timeout
end;
procedure TPartialStream.ReleaseBlockedRead;
begin
  if FReadRelease <> nil then RTLEventSetEvent(FReadRelease);
end;
procedure TPartialStream.EnableTrickleReads(const ADelayMs: Integer);
begin
  FTrickleDelayMs := ADelayMs;
end;

function TPartialStream.WaitForReadStart(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FReadStarted, ATimeoutMs);
  Result := FReadHasStarted;
end;
procedure TPartialStream.EnableWriteBlocking;
begin
  FWriteStarted := RTLEventCreate;
  FWriteRelease := RTLEventCreate;
  FBlockWrite := True;
end;
procedure TPartialStream.FailNextWrite;
begin
  FFailNextWrite := True;
end;
procedure TPartialStream.FailAllWrites;
begin
  FFailAllWrites := True;
end;

function TPartialStream.WaitForWriteStart(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FWriteStarted, ATimeoutMs);
  Result := FWriteHasStarted;
end;
procedure TPartialStream.ReleaseBlockedWrite;
begin
  if FWriteRelease <> nil then RTLEventSetEvent(FWriteRelease);
end;

constructor TLockProbeSelector.Create(const APool: TConnectionPool);
begin
  inherited Create;
  FPool := APool;
  FProbeThread := nil;
end;

destructor TLockProbeSelector.Destroy;
begin
  JoinProbe;
  inherited Destroy;
end;

function TLockProbeSelector.PoolLockAvailable: Boolean;
begin
  Result := InterlockedCompareExchange(FPoolLockAvailable, 0, 0) <> 0;
end;
procedure TLockProbeSelector.JoinProbe;
begin
  if FProbeThread = nil then
    Exit;
  FProbeThread.WaitFor;
  FProbeThread.Free;
  FProbeThread := nil;
end;

function TLockProbeSelector.Select(const AHost: string;
  const APort: Word): IClientIdentity;
var
  Started: QWord;
begin
  Inc(FCalls);
  FProbeThread := TPoolLockProbeThread.Create(FPool, Self);
  FProbeThread.Start;
  Started := mormot.core.os.GetTickCount64;
  while not PoolLockAvailable and
    (mormot.core.os.GetTickCount64 - Started < 200) do
    Sleep(1);
  Result := nil;
end;

constructor TPoolLockProbeThread.Create(const APool: TConnectionPool;
  const AProbe: TLockProbeSelector);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPool := APool;
  FProbe := AProbe;
end;
procedure TPoolLockProbeThread.Execute;
begin
  FPool.ConnectionCount;
  InterlockedExchange(FProbe.FPoolLockAvailable, 1);
end;
function TPartialStream.HasPendingInput: Boolean;
begin
  Result := Length(FInput) > 0;
end;

procedure TPartialStream.Push(const ABytes: TBytes);
var OldLength: Integer;
begin
  OldLength := Length(FInput);
  SetLength(FInput, OldLength + Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], FInput[OldLength], Length(ABytes));
end;

function TPartialStream.Output: TBytes;
begin Result := Copy(FOutput); end;
function TPartialStream.ReadCount: Integer;
begin Result := FReads; end;
function TPartialStream.WriteCount: Integer;
begin Result := FWrites; end;

function TPartialStream.Read(var ABuffer; ACount: Integer): Integer;
var P: PByte;
begin
  Result := 0;
  P := PByte(@ABuffer);
  while Result < ACount do
  begin
    Inc(Integer(Result), ReadSome(P[Result], ACount - Result));
    if (Result = 0) or (Length(FInput) = 0) then Break;
  end;
end;

function TPartialStream.ReadSome(var ABuffer; ACount: Integer): Integer;
var N: Integer;
begin
  Inc(FReads);
  if FBlockRead and (FReadStarted <> nil) and FOpen and
     (Length(FInput) = 0) then
  begin
    FReadHasStarted := True;
    RTLEventSetEvent(FReadStarted);
    if FHoldRead then
      RTLEventWaitFor(FReadRelease, 5000)
    else if FReadTimeoutMs > 0 then
      RTLEventWaitFor(FReadRelease, FReadTimeoutMs)
    else
      RTLEventWaitFor(FReadRelease, 5000);
  end;
  if (not FOpen) or (Length(FInput) = 0) or (ACount <= 0) then Exit(0);
  N := Length(FInput);
  if N > ACount then N := ACount;
  if FTrickleDelayMs > 0 then
  begin
    if N > 1 then N := 1;
    Sleep(FTrickleDelayMs);
  end
  else if N > 2 then
    N := 2;
  Move(FInput[0], ABuffer, N);
  Delete(FInput, 0, N);
  Result := N;
end;

function TPartialStream.Write(const ABuffer; ACount: Integer): Integer;
var OldLength: Integer;
begin
  Inc(FWrites);
  if not FOpen then Exit(0);
  if FFailAllWrites or FFailNextWrite then
  begin
    FFailNextWrite := False;
    raise EHttpConnectionClosed.Create('scripted socket write failed');
  end;
  if FBlockWrite and not FWriteHasStarted then
  begin
    FWriteHasStarted := True;
    RTLEventSetEvent(FWriteStarted);
    RTLEventWaitFor(FWriteRelease, 5000);
  end;
  if not FOpen then Exit(0);
  Result := ACount;
  if Result > FMaxWrite then Result := FMaxWrite;
  if Result <= 0 then Exit;
  OldLength := Length(FOutput);
  SetLength(FOutput, OldLength + Result);
  Move(ABuffer, FOutput[OldLength], Result);
end;
procedure TPartialStream.Close;
begin
  FOpen := False;
  if FReadRelease <> nil then RTLEventSetEvent(FReadRelease);
  ReleaseBlockedWrite;
end;
function TPartialStream.GetConnected: Boolean;
begin Result := FOpen; end;
function TPartialStream.GetConnectTimeoutMs: Integer;
begin Result := 1000; end;
procedure TPartialStream.SetConnectTimeoutMs(const AValue: Integer);
begin end;
function TPartialStream.GetReadTimeoutMs: Integer;
begin Result := FReadTimeoutMs; end;
procedure TPartialStream.SetReadTimeoutMs(const AValue: Integer);
begin FReadTimeoutMs := AValue; end;
function TPartialStream.GetWriteTimeoutMs: Integer;
begin Result := 1000; end;
procedure TPartialStream.SetWriteTimeoutMs(const AValue: Integer);
begin end;

constructor TTlsReadWorker.Create(const ASocket: IHttp2Socket);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  if not Supports(ASocket, IPartialReader, FReader) then
    raise Exception.Create('TLS socket has no partial-reader interface');
  FDone := RTLEventCreate;
end;

destructor TTlsReadWorker.Destroy;
begin
  WaitFor;
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

function TTlsReadWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FDone, ATimeoutMs);
  Result := FCompleted;
end;
procedure TTlsReadWorker.Execute;
var Buffer: array[0..3] of Byte;
begin
  try
    FReader.ReadSome(Buffer[0], SizeOf(Buffer));
  except
    on E: Exception do FError := E.ClassName + ': ' + E.Message;
  end;
  FCompleted := True;
  RTLEventSetEvent(FDone);
end;

constructor TTlsWriteWorker.Create(const ASocket: IHttp2Socket);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSocket := ASocket;
  FDone := RTLEventCreate;
end;

destructor TTlsWriteWorker.Destroy;
begin
  WaitFor;
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

function TTlsWriteWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FDone, ATimeoutMs);
  Result := FCompleted;
end;
procedure TTlsWriteWorker.Execute;
var Data: TBytes;
begin
  try
    SetLength(Data, 5);
    Data[0] := Ord('w'); Data[1] := Ord('r'); Data[2] := Ord('i');
    Data[3] := Ord('t'); Data[4] := Ord('e');
    FSocket.Write(Data[0], Length(Data));
  except
    on E: Exception do FError := E.ClassName + ': ' + E.Message;
  end;
  FCompleted := True;
  RTLEventSetEvent(FDone);
end;

constructor TContextSpy.Create(const AInner: ITLSContext);
begin inherited Create; FInner := AInner; end;
function TContextSpy.BackendName: string;
begin Result := FInner.BackendName; end;
function TContextSpy.Capabilities: TTlsCapabilities;
begin Result := FInner.Capabilities; end;
function TContextSpy.Info: TTlsContextInfo;
begin Result := FInner.Info; end;
function TContextSpy.CreateClientSession(
  const AOptions: TTlsClientSessionOptions): ITLSSession;
begin
  Inc(FCalls);
  FLastOptions := AOptions;
  Result := FInner.CreateClientSession(AOptions);
end;
function TContextSpy.CreateServerSession(
  const AOptions: TTlsServerSessionOptions): ITLSSession;
begin Result := FInner.CreateServerSession(AOptions); end;
procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise Exception.Create(AMessage);
end;

function Bytes(const AText: AnsiString): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then Move(AText[1], Result[0], Length(AText));
end;

end.
