{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, test, fake
notes:
  - This unit provides deterministic bounded TLS context and session fakes.
---
}
unit Http2.Test.Tls.Fake;
{$mode delphi}{$H+}{$interfaces com}
interface
uses Http2.Common.Tls.Types, Http2.Common.Tls.Session,
  Http2.Common.Tls.Context, Http2.Common.Tls.Policy;
type
  ITlsFakeLifetime = interface(IInterface)
    ['{22301853-7D70-4479-9D68-BAF7CC0C2303}']
    function IsAlive: Boolean;
  end;
  ITlsFakeContextControl = interface(IInterface)
    ['{C3B9F777-4B9D-45E4-88DB-455BB27E2303}']
    function Lifetime: ITlsFakeLifetime;
  end;
  ITlsFakeSessionInfo = interface(IInterface)
    ['{0B515A2D-2243-48E9-9BD3-D45CA0D82303}']
    function IsServer: Boolean;
    function ClientOptions: TTlsClientSessionOptions;
    function ServerOptions: TTlsServerSessionOptions;
  end;
  TTlsFakeContext = class(TInterfacedObject, ITLSContext, ITlsFakeContextControl)
  private
    FInfo: TTlsContextInfo;
    FNextId: Integer;
    FLock: TRTLCriticalSection;
    FLifetime: ITlsFakeLifetime;
    FHoldHandshake: Boolean;
  public
    constructor Create(const ARoles: TTlsRoles; const AAuth: TTlsClientAuthMode;
      const ATimeoutMs: Cardinal; const AHoldHandshake: Boolean = False);
    destructor Destroy; override;
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function Lifetime: ITlsFakeLifetime;
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
  end;
implementation
uses SysUtils;
type
  TTlsFakeLifetime = class(TInterfacedObject, ITlsFakeLifetime)
  private FAlive: Boolean;
  public
    constructor Create;
    procedure MarkDead;
    function IsAlive: Boolean;
  end;
  TTlsFakeSession = class(TInterfacedObject, ITLSSession, ITlsFakeSessionInfo)
  private
    FState: TTlsSessionState;
    FRole: TTlsRole;
    FId: Integer;
    FOwner: ITLSContext;
    FDeadlineMs: Int64;
    FHoldHandshake, FShutdownPending, FIsServer: Boolean;
    FClientOptions: TTlsClientSessionOptions;
    FServerOptions: TTlsServerSessionOptions;
    FInput, FOutput, FPlaintext: TBytes;
    FFailureCategory: TTlsErrorCategory;
    FFailureMessage: string;
    procedure Fail(const ACategory: TTlsErrorCategory; const AMessage: string);
    procedure RequireWritable;
  public
    constructor Create(const AOwner: ITLSContext; const ARole: TTlsRole;
      const AId: Integer; const ADeadlineMs: Int64;
      const AClientOptions: TTlsClientSessionOptions;
      const AServerOptions: TTlsServerSessionOptions;
      const AHoldHandshake: Boolean);
    function State: TTlsSessionState;
    function FeedEncrypted(const ABuffer: TBytes; const AOffset, ACount: SizeInt): SizeInt;
    function DrainEncrypted(var ABuffer: TBytes; const AOffset, ACapacity: SizeInt): SizeInt;
    function WritePlaintext(const ABuffer: TBytes; const AOffset, ACount: SizeInt): SizeInt;
    function ReadPlaintext(var ABuffer: TBytes; const AOffset, ACapacity: SizeInt): SizeInt;
    function Advance(const AMonotonicMs: Int64): TTlsProgress;
    procedure NotifyTransportEof;
    procedure BeginShutdown;
    procedure Abort;
    function NegotiatedInfo: TTlsNegotiatedInfo;
    function IsServer: Boolean;
    function ClientOptions: TTlsClientSessionOptions;
    function ServerOptions: TTlsServerSessionOptions;
  end;

constructor TTlsFakeLifetime.Create;
begin inherited Create; FAlive := True; end;
procedure TTlsFakeLifetime.MarkDead;
begin FAlive := False; end;
function TTlsFakeLifetime.IsAlive: Boolean;
begin Result := FAlive; end;

constructor TTlsFakeContext.Create(const ARoles: TTlsRoles;
  const AAuth: TTlsClientAuthMode; const ATimeoutMs: Cardinal;
  const AHoldHandshake: Boolean);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FLifetime := TTlsFakeLifetime.Create;
  FInfo.Roles := ARoles;
  FInfo.ClientAuth := AAuth;
  FInfo.HandshakeTimeoutMs := ATimeoutMs;
  FHoldHandshake := AHoldHandshake;
end;
destructor TTlsFakeContext.Destroy;
var Life: ITlsFakeLifetime;
begin
  Life := FLifetime;
  (Life as TTlsFakeLifetime).MarkDead;
  FLifetime := nil;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;
function TTlsFakeContext.BackendName: string;
begin Result := 'fake'; end;
function TTlsFakeContext.Capabilities: TTlsCapabilities;
begin
  Result := Default(TTlsCapabilities);
  Result.Roles := FInfo.Roles;
  Result.Versions := [tls12, tls13];
end;
function TTlsFakeContext.Info: TTlsContextInfo;
begin Result := FInfo; end;
function TTlsFakeContext.Lifetime: ITlsFakeLifetime;
begin Result := FLifetime; end;
function TTlsFakeContext.CreateClientSession(
  const AOptions: TTlsClientSessionOptions): ITLSSession;
var Deadline: Int64;
begin
  if not (trClient in FInfo.Roles) then
    raise ETlsContextError.Create('Client role is unavailable');
  Deadline := AOptions.HandshakeDeadlineMs;
  if FInfo.HandshakeTimeoutMs > 0 then
    if (Deadline = 0) or (AOptions.HandshakeStartMs + FInfo.HandshakeTimeoutMs < Deadline) then
      Deadline := AOptions.HandshakeStartMs + FInfo.HandshakeTimeoutMs;
  EnterCriticalSection(FLock);
  try
    Inc(FNextId);
    Result := TTlsFakeSession.Create(Self as ITLSContext, trClient, FNextId,
      Deadline, AOptions, Default(TTlsServerSessionOptions), FHoldHandshake);
  finally
    LeaveCriticalSection(FLock);
  end;
end;
function TTlsFakeContext.CreateServerSession(
  const AOptions: TTlsServerSessionOptions): ITLSSession;
var Deadline: Int64;
begin
  if not (trServer in FInfo.Roles) then
    raise ETlsContextError.Create('Server role is unavailable');
  Deadline := AOptions.HandshakeDeadlineMs;
  if FInfo.HandshakeTimeoutMs > 0 then
    if (Deadline = 0) or (AOptions.HandshakeStartMs + FInfo.HandshakeTimeoutMs < Deadline) then
      Deadline := AOptions.HandshakeStartMs + FInfo.HandshakeTimeoutMs;
  EnterCriticalSection(FLock);
  try
    Inc(FNextId);
    Result := TTlsFakeSession.Create(Self as ITLSContext, trServer, FNextId,
      Deadline, Default(TTlsClientSessionOptions), AOptions, FHoldHandshake);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

constructor TTlsFakeSession.Create(const AOwner: ITLSContext;
  const ARole: TTlsRole; const AId: Integer; const ADeadlineMs: Int64;
  const AClientOptions: TTlsClientSessionOptions;
  const AServerOptions: TTlsServerSessionOptions;
  const AHoldHandshake: Boolean);
begin
  inherited Create;
  FOwner := AOwner;
  FRole := ARole;
  FId := AId;
  FDeadlineMs := ADeadlineMs;
  FClientOptions := AClientOptions;
  FServerOptions := AServerOptions;
  FHoldHandshake := AHoldHandshake;
  FIsServer := ARole = trServer;
  FState := tssNew;
end;
procedure TTlsFakeSession.Fail(const ACategory: TTlsErrorCategory; const AMessage: string);
begin
  if FState <> tssFailed then begin
    FFailureCategory := ACategory;
    FFailureMessage := AMessage;
    FState := tssFailed;
    if Length(FOutput) <= TlsMaxEncryptedOutput - 2 then
      FOutput := FOutput + [$15, $02];
  end;
end;
procedure TTlsFakeSession.RequireWritable;
begin
  if FState = tssFailed then
    raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
  if FState = tssClosed then
    raise ETlsSessionError.Create('Session is closed', tecProtocol);
end;
function TTlsFakeSession.State: TTlsSessionState;
begin Result := FState; end;
function TTlsFakeSession.FeedEncrypted(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
var I, OldLength: SizeInt;
begin
  RequireWritable;
  if (AOffset < 0) or (ACount < 0) or (AOffset > Length(ABuffer)) or
    (ACount > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid encrypted input range', tecProtocol);
  Result := TlsMaxEncryptedInput - Length(FInput);
  if Result > ACount then Result := ACount;
  OldLength := Length(FInput);
  SetLength(FInput, OldLength + Result);
  for I := 0 to Result - 1 do FInput[OldLength + I] := ABuffer[AOffset + I];
  if (Result > 0) and (FState = tssNew) then FState := tssHandshaking;
end;
function TTlsFakeSession.DrainEncrypted(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
var I, OldLength: SizeInt;
begin
  { A failure can retain an alert. Abort clears the output queue. }
  if (AOffset < 0) or (ACapacity < 0) or (AOffset > Length(ABuffer)) or
    (ACapacity > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid encrypted output range', tecProtocol);
  Result := Length(FOutput);
  if Result > ACapacity then Result := ACapacity;
  for I := 0 to Result - 1 do ABuffer[AOffset + I] := FOutput[I];
  Delete(FOutput, 0, Result);
end;
function TTlsFakeSession.WritePlaintext(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
var I, OldLength: SizeInt;
begin
  RequireWritable;
  if (AOffset < 0) or (ACount < 0) or (AOffset > Length(ABuffer)) or
    (ACount > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid plaintext input range', tecProtocol);
  if FState <> tssOpen then Exit(0);
  Result := TlsMaxEncryptedOutput - 2 - Length(FOutput);
  if Result > ACount then Result := ACount;
  OldLength := Length(FOutput);
  SetLength(FOutput, OldLength + Result);
  for I := 0 to Result - 1 do FOutput[OldLength + I] := ABuffer[AOffset + I];
end;
function TTlsFakeSession.ReadPlaintext(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
var I: SizeInt;
begin
  if (AOffset < 0) or (ACapacity < 0) or (AOffset > Length(ABuffer)) or
    (ACapacity > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid plaintext output range', tecProtocol);
  Result := Length(FPlaintext);
  if Result > ACapacity then Result := ACapacity;
  for I := 0 to Result - 1 do ABuffer[AOffset + I] := FPlaintext[I];
  Delete(FPlaintext, 0, Result);
  if (Result = 0) and (FState = tssFailed) then
    raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
end;
function TTlsFakeSession.Advance(const AMonotonicMs: Int64): TTlsProgress;
var I, OldLength, N: SizeInt; B: Byte; PeerClosed: Boolean;
begin
  Result := Default(TTlsProgress);
  if FState in [tssFailed, tssClosed] then begin
    Result.State := FState;
    Result.NeedOutput := Length(FOutput) > 0;
    Exit;
  end;
  if (FDeadlineMs > 0) and (AMonotonicMs >= FDeadlineMs) and
    (FState in [tssNew, tssHandshaking]) then begin
    Fail(tecTimeout, 'Handshake deadline expired');
    raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
  end;
  if (FState in [tssNew, tssHandshaking]) and FHoldHandshake and
    (Length(FInput) = 0) then begin
    FState := tssHandshaking;
    Result.State := FState;
    Result.NeedInput := True;
    Exit;
  end;
  if FState in [tssNew, tssHandshaking] then begin
    if FHoldHandshake and (Length(FInput) > 0) and (FInput[0] = $FC) then
      Delete(FInput, 0, 1);
    FState := tssOpen;
    FOutput := FOutput + [$16, $03, $03, $00];
    Result.MadeProgress := True;
  end;
  I := 0;
  PeerClosed := False;
  N := Length(FInput);
  if N > TlsMaxPlaintextBuffer - Length(FPlaintext) then
    N := TlsMaxPlaintextBuffer - Length(FPlaintext);
  while I < N do begin
    B := FInput[I];
    if B = $FF then begin
      if I > 0 then begin
        OldLength := Length(FPlaintext); SetLength(FPlaintext, OldLength + I);
        for N := 0 to I - 1 do FPlaintext[OldLength + N] := FInput[N];
        Delete(FInput, 0, I);
      end;
      Fail(tecAlert, 'Fake peer sent a fatal alert');
      raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
    end;
    if B = $FD then begin
      if I > 0 then begin
        OldLength := Length(FPlaintext); SetLength(FPlaintext, OldLength + I);
        for N := 0 to I - 1 do FPlaintext[OldLength + N] := FInput[N];
        Delete(FInput, 0, I);
      end;
      Fail(tecVerification, 'Fake peer verification failed');
      raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
    end;
    if B = $FE then begin
      PeerClosed := True;
      Inc(I);
      Result.MadeProgress := True;
      Break;
    end;
    Inc(I);
    Result.MadeProgress := True;
  end;
  if PeerClosed then N := I - 1 else N := I;
  if N > 0 then begin
    OldLength := Length(FPlaintext);
    SetLength(FPlaintext, OldLength + N);
    for I := 0 to N - 1 do FPlaintext[OldLength + I] := FInput[I];
  end;
  if PeerClosed then begin Delete(FInput, 0, N + 1); FState := tssClosed; end
  else if N > 0 then Delete(FInput, 0, N);
  if FShutdownPending and (Length(FOutput) <= TlsMaxEncryptedOutput - 2) then begin
    FOutput := FOutput + [$15, $00];
    FShutdownPending := False;
    Result.MadeProgress := True;
  end;
  if (FState = tssClosing) and (Length(FOutput) = 0) and
    not FShutdownPending then FState := tssClosed;
  Result.State := FState;
  Result.NeedOutput := Length(FOutput) > 0;
  Result.NeedInput := (FState = tssOpen) and (not Result.MadeProgress);
end;
procedure TTlsFakeSession.NotifyTransportEof;
begin
  if FState in [tssClosed, tssFailed] then Exit;
  Fail(tecTransportEof, 'Transport ended without close-notify');
end;
procedure TTlsFakeSession.BeginShutdown;
begin
  if FState <> tssOpen then begin
    if FState = tssFailed then
      raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
    raise ETlsSessionError.Create('Session is not open', tecProtocol);
  end;
  FState := tssClosing;
  FShutdownPending := True;
end;
procedure TTlsFakeSession.Abort;
begin
  FInput := nil;
  FOutput := nil;
  FPlaintext := nil;
  FState := tssFailed;
  FFailureCategory := tecInternal;
  FFailureMessage := 'Session was aborted';
end;
function TTlsFakeSession.NegotiatedInfo: TTlsNegotiatedInfo;
begin
  if FState <> tssOpen then
    raise ETlsSessionError.Create('Handshake is not complete', tecProtocol);
  Result := Default(TTlsNegotiatedInfo);
  Result.Role := FRole;
  Result.Version := tls13;
  Result.CipherName := 'FAKE-AEAD';
  Result.SelectedAlpn := 'h2';
end;
function TTlsFakeSession.IsServer: Boolean;
begin Result := FIsServer; end;
function TTlsFakeSession.ClientOptions: TTlsClientSessionOptions;
begin Result := FClientOptions; end;
function TTlsFakeSession.ServerOptions: TTlsServerSessionOptions;
begin Result := FServerOptions; end;
end.
