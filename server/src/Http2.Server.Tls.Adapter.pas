{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, adapter, server, session
notes:
  - This unit serializes all common TLS session calls for one server socket.
  - The raw socket writer runs after this unit releases its session lock.
---
}
unit Http2.Server.Tls.Adapter;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, SyncObjs, Http2.Common.Tls.Types, Http2.Common.Tls.Session,
  Http2.Server.Tls.Binding;
type
  TServerTlsAdapter = class
  private
    FSession: ITLSSession;
    FLock: TCriticalSection;
    FPendingCipher: TBytes;
    FPendingCipherCount: SizeInt;
    FCipherWriting: Boolean;
    FTransportFailed: Boolean;
    FPlainAccepted: Int64;
    FDeadlineMs: Int64;
    FCreditReady: Boolean;
    FProgressReady: Boolean;
    FCompletedPlaintext: Int64;
    FHasCompletedPlaintext: Boolean;
    FProviderPlainPending: SizeInt;
    FProviderOutputDrained: Boolean;
    function AdvanceLocked(const ANowMs: Int64): TTlsProgress;
  public
    constructor Create(const ABinding: ITlsServerBinding;
      const AStartedMs: Int64; const AAllowHttp11: Boolean);
    destructor Destroy; override;
    function FeedEncrypted(const AData: TBytes; const AOffset,
      ACount: SizeInt): SizeInt;
    function Advance(const ANowMs: Int64): TTlsProgress;
    function ReadPlaintext(var AData: TBytes; const AOffset,
      ACapacity: SizeInt): SizeInt;
    function WritePlaintext(const AData: TBytes; const AOffset,
      ACount: SizeInt): SizeInt;
    function PrepareCipher(out AData: TBytes): Boolean;
    procedure CompleteCipher(const AAccepted: Boolean);
    function NegotiatedInfo: TTlsNegotiatedInfo;
    function State: TTlsSessionState;
    function PlainAccepted: Int64;
    function DeadlineMs: Int64;
    function TransportFailed: Boolean;
    function CipherWriting: Boolean;
    function PendingCipherCount: SizeInt;
    function OutputDrained: Boolean;
    function CreditReady: Boolean;
    function TryGetCompletedPlaintext(out ATotal: Int64): Boolean;
    procedure BeginShutdown;
    procedure NotifyTransportEof;
    procedure Abort;
  end;
implementation
uses mormot.core.os;
constructor TServerTlsAdapter.Create(const ABinding: ITlsServerBinding;
  const AStartedMs: Int64; const AAllowHttp11: Boolean);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSession := ABinding.CreateSession(AStartedMs, AAllowHttp11);
  FDeadlineMs := TlsHandshakeDeadline(AStartedMs,
    ABinding.Context.Info.HandshakeTimeoutMs);
end;
destructor TServerTlsAdapter.Destroy;
begin
  Abort;
  FSession := nil;
  FLock.Free;
  inherited Destroy;
end;
function TServerTlsAdapter.FeedEncrypted(const AData: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin
  FLock.Acquire;
  try
    Result := FSession.FeedEncrypted(AData, AOffset, ACount);
    if Result > 0 then
    begin
      FProgressReady := False;
      FCreditReady := False;
      FProviderOutputDrained := False;
    end;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.AdvanceLocked(const ANowMs: Int64): TTlsProgress;
begin
  try
    Result := FSession.Advance(ANowMs);
    FProviderPlainPending := Result.PendingPlaintextOutput;
    FProviderOutputDrained := False;
    FProgressReady := (Result.State in [tssOpen, tssClosing]) and
      (Result.PendingPlaintextOutput = 0);
  except
    on ETlsSessionError do
    begin
      FProgressReady := False;
      FCreditReady := False;
      FProviderOutputDrained := False;
      raise;
    end;
  end;
end;
function TServerTlsAdapter.Advance(const ANowMs: Int64): TTlsProgress;
begin
  FLock.Acquire;
  try Result := AdvanceLocked(ANowMs);
  finally FLock.Release; end;
end;
function TServerTlsAdapter.ReadPlaintext(var AData: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin
  FLock.Acquire;
  try Result := FSession.ReadPlaintext(AData, AOffset, ACapacity);
  finally FLock.Release; end;
end;
function TServerTlsAdapter.WritePlaintext(const AData: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin
  FLock.Acquire;
  try
    Result := FSession.WritePlaintext(AData, AOffset, ACount);
    Inc(FPlainAccepted, Result);
    if Result > 0 then
    begin
      FProgressReady := False;
      FCreditReady := False;
      FProviderOutputDrained := False;
    end;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.PrepareCipher(out AData: TBytes): Boolean;
var N: SizeInt; Progress: TTlsProgress; Advanced: Boolean;
begin
  Result := False;
  Progress := Default(TTlsProgress);
  Advanced := True;
  FLock.Acquire;
  try
    if FCipherWriting then Exit;
    try
      Progress := AdvanceLocked(mormot.core.os.GetTickCount64);
    except
      on ETlsSessionError do
      begin
        Advanced := False;
        // pending alert bytes are still drained below
      end;
    end;
    if FPendingCipherCount = 0 then
    begin
      SetLength(FPendingCipher, 16384);
      FPendingCipherCount := FSession.DrainEncrypted(FPendingCipher, 0,
        Length(FPendingCipher));
    end;
    N := FPendingCipherCount;
    if N <= 0 then
    begin
      if Advanced then
      begin
        FProviderPlainPending := Progress.PendingPlaintextOutput;
        FProviderOutputDrained := (Progress.PendingPlaintextOutput = 0) and
        (Progress.State in [tssClosing, tssClosed]) and not Progress.NeedOutput;
      end;
      FCreditReady := FProgressReady and
        (FSession.State in [tssOpen, tssClosing]) and
        (not FTransportFailed);
      if FCreditReady then
      begin
        FCompletedPlaintext := FPlainAccepted;
        FHasCompletedPlaintext := True;
      end;
      Exit;
    end;
    FCreditReady := False;
    SetLength(AData, N);
    Move(FPendingCipher[0], AData[0], N);
    FCipherWriting := True;
    Result := True;
  finally FLock.Release; end;
end;
procedure TServerTlsAdapter.CompleteCipher(const AAccepted: Boolean);
begin
  FLock.Acquire;
  try
    FCipherWriting := False;
    if AAccepted then
    begin
      FPendingCipher := nil;
      FPendingCipherCount := 0;
    end
    else
    begin
      FTransportFailed := True;
      FCreditReady := False;
    end;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.NegotiatedInfo: TTlsNegotiatedInfo;
begin
  FLock.Acquire;
  try Result := FSession.NegotiatedInfo;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.State: TTlsSessionState;
begin
  FLock.Acquire;
  try Result := FSession.State;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.PlainAccepted: Int64;
begin
  FLock.Acquire;
  try Result := FPlainAccepted;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.DeadlineMs: Int64;
begin Result := FDeadlineMs; end;
function TServerTlsAdapter.TransportFailed: Boolean;
begin
  FLock.Acquire;
  try Result := FTransportFailed;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.CipherWriting: Boolean;
begin
  FLock.Acquire;
  try Result := FCipherWriting;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.PendingCipherCount: SizeInt;
begin
  FLock.Acquire;
  try Result := FPendingCipherCount;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.OutputDrained: Boolean;
begin
  FLock.Acquire;
  try
    Result := (FSession.State in [tssClosing, tssClosed]) and
      (FProviderPlainPending = 0) and FProviderOutputDrained and
      (FPendingCipherCount = 0) and not FCipherWriting and not FTransportFailed;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.CreditReady: Boolean;
begin
  FLock.Acquire;
  try Result := FCreditReady;
  finally FLock.Release; end;
end;
function TServerTlsAdapter.TryGetCompletedPlaintext(out ATotal: Int64): Boolean;
begin
  FLock.Acquire;
  try
    Result := FHasCompletedPlaintext and not FTransportFailed and
      not (FSession.State in [tssFailed, tssClosed]);
    if Result then ATotal := FCompletedPlaintext else ATotal := 0;
  finally FLock.Release; end;
end;
procedure TServerTlsAdapter.BeginShutdown;
begin
  FLock.Acquire;
  try
    if FSession.State = tssOpen then
    begin
      FSession.BeginShutdown;
      FProgressReady := False;
      FCreditReady := False;
      FProviderOutputDrained := False;
    end;
  finally FLock.Release; end;
end;
procedure TServerTlsAdapter.NotifyTransportEof;
begin
  FLock.Acquire;
  try
    FSession.NotifyTransportEof;
    FProgressReady := False;
    FCreditReady := False;
    FHasCompletedPlaintext := False;
    FProviderOutputDrained := False;
  finally FLock.Release; end;
end;
procedure TServerTlsAdapter.Abort;
begin
  if FSession = nil then Exit;
  FLock.Acquire;
  try
    FSession.Abort;
    FPendingCipher := nil;
    FPendingCipherCount := 0;
    FCreditReady := False;
    FHasCompletedPlaintext := False;
    FProviderOutputDrained := False;
  finally FLock.Release; end;
end;
end.
