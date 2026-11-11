{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, session, tlslib
notes:
  - This unit adapts TlsLib engine sessions to the common buffer contract.
---
}
unit Http2.TlsLib.Session;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity, Http2.Common.Tls.Context,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session, TlpITlsEngine;

type
  TTlsLibSession = class(TInterfacedObject, ITLSSession)
  private
    FContextRef: ITLSContext;
    FEngine: ITlsEngine;
    FState: TTlsSessionState;
    FRole: TTlsRole;
    FDeadline: Int64;
    FPlain: TBytes;
    FCipher: TBytes;
  FErrorMessage: string;
  FErrorCategory: TTlsErrorCategory;
    FCounted: Boolean;
    FEngineCounted: Boolean;
    FInfo: TTlsNegotiatedInfo;
    procedure Fail(const AMessage: string; const ACategory: TTlsErrorCategory);
    procedure RaiseFailure;
    procedure Pump;
    procedure RefreshInfo;
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
  public
    constructor Create(const AContext: ITLSContext; const ARole: TTlsRole;
      const AEngine: ITlsEngine; const ATimeoutMs: Cardinal;
      const AStartMs, ADeadlineMs: Int64);
    destructor Destroy; override;
  end;

implementation

uses
  Http2.TlsLib.Diagnostics, Http2.TlsLib.Certificate,
  TlpTlsAlert, TlpTlsVersion, TlpTlsConnectionInfo,
  TlpTlsError;

function AddBytes(const A, B: TBytes): TBytes;
var N: Integer;
begin
  N := Length(A); SetLength(Result, N + Length(B));
  if N > 0 then Move(A[0], Result[0], N);
  if Length(B) > 0 then Move(B[0], Result[N], Length(B));
end;

function EngineFailureCategory(const AError: TTlsError): TTlsErrorCategory;
begin
  if AError.Origin = TTlsErrorOrigin.Transport then Exit(tecTransportEof);
  case AError.Alert.Description of
    TTlsAlertDescription.BadCertificate, TTlsAlertDescription.UnknownCa,
    TTlsAlertDescription.CertificateExpired, TTlsAlertDescription.CertificateRevoked,
    TTlsAlertDescription.CertificateUnknown, TTlsAlertDescription.UnsupportedCertificate:
      Result := tecVerification;
  else
    Result := tecAlert;
  end;
end;

function CipherSuiteName(const ACipherSuite: UInt16): string;
begin
  case ACipherSuite of
    $1301: Result := 'TLS_AES_128_GCM_SHA256';
    $1302: Result := 'TLS_AES_256_GCM_SHA384';
    $1303: Result := 'TLS_CHACHA20_POLY1305_SHA256';
    $1304: Result := 'TLS_AES_128_CCM_SHA256';
    $1305: Result := 'TLS_AES_128_CCM_8_SHA256';
    $C02B: Result := 'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256';
    $C02C: Result := 'TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384';
    $C02F: Result := 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256';
    $C030: Result := 'TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384';
    $CCA8: Result := 'TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256';
    $CCA9: Result := 'TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256';
  else
    Result := 'TLS_UNKNOWN_CIPHER_' + IntToHex(ACipherSuite, 4);
  end;
end;

constructor TTlsLibSession.Create(const AContext: ITLSContext; const ARole: TTlsRole;
  const AEngine: ITlsEngine; const ATimeoutMs: Cardinal;
  const AStartMs, ADeadlineMs: Int64);
var D: Int64;
begin
  inherited Create;
  FContextRef := AContext;
  FEngine := AEngine;
  FRole := ARole;
  FState := tssHandshaking;
  D := ADeadlineMs;
  if (ATimeoutMs > 0) and (AStartMs >= 0) then
  begin
    if AStartMs > High(Int64) - ATimeoutMs then
    begin
      if D = 0 then D := High(Int64);
    end
    else if (D = 0) or (AStartMs + ATimeoutMs < D) then
      D := AStartMs + ATimeoutMs;
  end;
  FDeadline := D;
  TlsLibCountSession(1);
  TlsLibCountEngine(1);
  FCounted := True;
  FEngineCounted := True;
end;

destructor TTlsLibSession.Destroy;
begin
  if FEngineCounted then TlsLibCountEngine(-1);
  if FCounted then TlsLibCountSession(-1);
  FEngine := nil;
  FContextRef := nil;
  FPlain := nil;
  FCipher := nil;
  inherited Destroy;
end;

procedure TTlsLibSession.Fail(const AMessage: string; const ACategory: TTlsErrorCategory);
begin
  if FState in [tssClosed, tssFailed] then Exit;
  FState := tssFailed;
  FErrorMessage := AMessage;
  FErrorCategory := ACategory;
end;

procedure TTlsLibSession.RaiseFailure;
begin
  if FState = tssFailed then
    raise ETlsSessionError.Create(FErrorMessage, FErrorCategory);
end;

procedure TTlsLibSession.Pump;
var N, Cap: Integer; B: TBytes;
begin
  if FEngine = nil then Exit;
  if FState = tssHandshaking then
    if not FEngine.IsHandshaking then
    begin
      if FEngine.IsTerminal then
        Fail('TlsLib handshake failed', EngineFailureCategory(FEngine.LastError))
      else begin FState := tssOpen; RefreshInfo; end;
    end;
  if FEngine.IsInboundClosed and not FEngine.IsTerminal then
  begin
    { The common session closes both directions. SendClose is idempotent. }
    FEngine.SendClose;
    FState := tssClosed;
  end;
  while (Length(FCipher) < TlsMaxEncryptedOutput) and FEngine.WantsWrite do
  begin
    Cap := TlsMaxEncryptedOutput - Length(FCipher);
    if Cap > TlsMaxEncryptedInput then Cap := TlsMaxEncryptedInput;
    SetLength(B, Cap);
    N := FEngine.TakeOutgoing(B, 0);
    if N <= 0 then Break;
    SetLength(B, N);
    FCipher := AddBytes(FCipher, B);
  end;
  if FEngine.IsInboundClosed and (FState = tssOpen) then FState := tssClosing;
  if FEngine.IsTerminal then
  begin
    if FEngine.LastError.Message <> '' then
      Fail('TlsLib TLS alert or protocol failure', EngineFailureCategory(FEngine.LastError))
    else if FState = tssHandshaking then Fail('TlsLib handshake failed', tecProtocol);
  end;
end;

procedure TTlsLibSession.RefreshInfo;
var
  C: TTlsConnectionInfo;
  Chain: TArray<TTlsCertificateSummary>;
  Dns, Ip, Uri, Email: TArray<string>;
  I: Integer;
begin
  C := FEngine.ConnectionInfo;
  FInfo := Default(TTlsNegotiatedInfo);
  FInfo.Role := FRole;
  if C.NegotiatedVersion.Equals(TTlsVersion.Create(TlsWireVersionTls12)) then FInfo.Version := tls12
  else FInfo.Version := tls13;
  FInfo.CipherName := CipherSuiteName(C.CipherSuite);
  FInfo.SelectedAlpn := TEncoding.UTF8.GetString(C.AlpnProtocol);
  FInfo.Resumed := C.Resumed;
  if Length(C.PeerCertificates) > 0 then
  begin
    SetLength(Chain, Length(C.PeerCertificates));
    for I := 0 to High(Chain) do Chain[I] := TlsLibCertificateSummary(C.PeerCertificates[I]);
    TlsLibCertificateNames(C.PeerCertificates[0], Dns, Ip, Uri, Email);
    FInfo.PeerCertificate := NewTlsPeerCertificate(Length(C.ValidatedPath) > 0, Chain[0], Chain,
      Dns, Ip, Uri, Email);
  end;
end;

function TTlsLibSession.State: TTlsSessionState; begin Result := FState; end;

function TTlsLibSession.FeedEncrypted(const ABuffer: TBytes; const AOffset, ACount: SizeInt): SizeInt;
var C: Integer; B: TBytes;
begin
  if (AOffset < 0) or (ACount < 0) or (AOffset > Length(ABuffer)) or
     (ACount > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid encrypted input range', tecProtocol);
  RaiseFailure;
  if (FEngine = nil) or (FState in [tssClosed, tssFailed]) then Exit(0);
  Result := ACount;
  if Result > TlsMaxEncryptedInput then Result := TlsMaxEncryptedInput;
  { The engine can complete one record already buffered before this feed and
    then consume one full record from this slice. Reserve for both. }
  C := TlsMaxPlaintextBuffer - Length(FPlain) - FEngine.PendingAppData;
  if C < 2 * TlsMaxEncryptedInput then Exit(0);
  if Result > TlsMaxEncryptedInput then Result := TlsMaxEncryptedInput;
  if Result = 0 then Exit;
  SetLength(B, Result); Move(ABuffer[AOffset], B[0], Result);
  try
    FEngine.ProcessInput(B, 0, Result);
  except
    on E: Exception do
    begin
      { The engine records protocol and alert failures before it raises. }
      if FEngine.LastError.Message <> '' then
        Fail('TlsLib rejected TLS input', tecAlert)
      else
        Fail('TlsLib rejected TLS input', tecProtocol);
    end;
  end;
  if FEngine.PendingAppData > 0 then
  begin
    C := TlsMaxPlaintextBuffer - Length(FPlain);
    if C > 0 then
    begin
      if C > FEngine.PendingAppData then C := FEngine.PendingAppData;
      SetLength(B, C);
      C := FEngine.ReadAppData(B, 0, C);
      if C > 0 then begin SetLength(B, C); FPlain := AddBytes(FPlain, B); end;
    end;
  end;
  if FState <> tssFailed then Pump
  else
    { Preserve a local fatal alert for the caller to drain. }
    while FEngine.WantsWrite and (Length(FCipher) < TlsMaxEncryptedOutput) do
    begin
      C := TlsMaxEncryptedOutput - Length(FCipher);
      if C > TlsMaxEncryptedInput then C := TlsMaxEncryptedInput;
      SetLength(B, C);
      C := FEngine.TakeOutgoing(B, 0);
      if C <= 0 then Break;
      SetLength(B, C);
      FCipher := AddBytes(FCipher, B);
    end;
  RaiseFailure;
end;

function TTlsLibSession.DrainEncrypted(var ABuffer: TBytes; const AOffset, ACapacity: SizeInt): SizeInt;
begin
  if (AOffset < 0) or (ACapacity < 0) or (AOffset > Length(ABuffer)) or
     (ACapacity > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid encrypted output range', tecProtocol);
  Result := ACapacity;
  if Result > Length(FCipher) then Result := Length(FCipher);
  if Result > 0 then
  begin
    Move(FCipher[0], ABuffer[AOffset], Result);
    Delete(FCipher, 0, Result);
  end;
  Pump;
end;

function TTlsLibSession.WritePlaintext(const ABuffer: TBytes; const AOffset, ACount: SizeInt): SizeInt;
var C: Integer; B: TBytes;
begin
  if (AOffset < 0) or (ACount < 0) or (AOffset > Length(ABuffer)) or
     (ACount > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid plaintext input range', tecProtocol);
  if FState <> tssOpen then Exit(0);
  if (FEngine = nil) or FEngine.WriteClosed then Exit(0);
  Result := ACount;
  C := TlsMaxEncryptedOutput - Length(FCipher) - 2048;
  if Result > C then Result := C;
  if Result > 16384 then Result := 16384;
  if Result <= 0 then Exit(0);
  SetLength(B, Result); Move(ABuffer[AOffset], B[0], Result);
  try FEngine.Write(B, 0, Result);
  except on E: Exception do Fail('TlsLib could not protect application data', tecProtocol); end;
  RaiseFailure;
  Pump;
  RaiseFailure;
end;

function TTlsLibSession.ReadPlaintext(var ABuffer: TBytes; const AOffset, ACapacity: SizeInt): SizeInt;
begin
  if (AOffset < 0) or (ACapacity < 0) or (AOffset > Length(ABuffer)) or
     (ACapacity > Length(ABuffer) - AOffset) then
    raise ETlsSessionError.Create('Invalid plaintext output range', tecProtocol);
  Result := ACapacity;
  if Result > Length(FPlain) then Result := Length(FPlain);
  if Result > 0 then
  begin Move(FPlain[0], ABuffer[AOffset], Result); Delete(FPlain, 0, Result); Exit; end;
  if FState = tssFailed then
    raise ETlsSessionError.Create(FErrorMessage, FErrorCategory);
  if (FEngine <> nil) and FEngine.IsInboundClosed then FState := tssClosed;
end;

function TTlsLibSession.Advance(const AMonotonicMs: Int64): TTlsProgress;
var E: ITlsEvent; N, OldCipher, OldPlain: Integer; OldState: TTlsSessionState; B: TBytes;
begin
  { Engine.Write protects accepted plaintext before it returns. }
  Result := Default(TTlsProgress);
  RaiseFailure;
  if FEngine = nil then
  begin
    Result.State := FState;
    Result.NeedInput := False;
    Result.NeedOutput := False;
    Result.MadeProgress := False;
    Exit;
  end;
  if FState in [tssFailed, tssClosed] then
  begin
    RaiseFailure;
    Result.State := FState;
    Result.NeedInput := False;
    Result.NeedOutput := Length(FCipher) > 0;
    Result.MadeProgress := False;
    Exit;
  end;
  OldState := FState;
  OldCipher := Length(FCipher);
  OldPlain := Length(FPlain);
  if (FDeadline > 0) and (AMonotonicMs >= FDeadline) and (FState = tssHandshaking) then
    Fail('TlsLib handshake deadline expired', tecTimeout);
  while FEngine.NextEvent(E) do
  begin
    if FState in [tssFailed, tssClosed] then Continue;
    if (E.Kind = TTlsEventKind.PeerAlert) and FEngine.IsTerminal then
      Fail('TlsLib peer sent a fatal TLS alert', tecAlert)
    else if E.Kind = TTlsEventKind.Closed then FState := tssClosed;
  end;
  if (Length(FPlain) < TlsMaxPlaintextBuffer) and (FEngine.PendingAppData > 0) then
  begin
    N := TlsMaxPlaintextBuffer - Length(FPlain);
    if N > FEngine.PendingAppData then N := FEngine.PendingAppData;
    SetLength(B, N); N := FEngine.ReadAppData(B, 0, N);
    if N > 0 then begin SetLength(B, N); FPlain := AddBytes(FPlain, B); end;
  end;
  Pump;
  RaiseFailure;
  Result.State := FState;
  Result.NeedInput := (FState in [tssNew, tssHandshaking, tssOpen, tssClosing]) and FEngine.WantsRead;
  Result.NeedOutput := Length(FCipher) > 0;
  Result.MadeProgress := (FState <> OldState) or (Length(FCipher) <> OldCipher) or
    (Length(FPlain) <> OldPlain);
end;

procedure TTlsLibSession.NotifyTransportEof;
var N: Integer; B: TBytes;
begin
  if (FEngine = nil) or (FState in [tssClosed, tssFailed]) then Exit;
  if FEngine.PendingAppData > 0 then
  begin
    N := TlsMaxPlaintextBuffer - Length(FPlain);
    if N > FEngine.PendingAppData then N := FEngine.PendingAppData;
    if N > 0 then
    begin
      SetLength(B, N);
      N := FEngine.ReadAppData(B, 0, N);
      if N > 0 then begin SetLength(B, N); FPlain := AddBytes(FPlain, B); end;
    end;
  end;
  if not FEngine.IsInboundClosed then
  begin
    Fail('Transport ended without TLS close_notify', tecTransportEof);
    RaiseFailure;
  end
  else FState := tssClosed;
end;

procedure TTlsLibSession.BeginShutdown;
begin
  if FState <> tssOpen then Exit;
  FState := tssClosing;
  try FEngine.SendClose; Pump;
  except on E: Exception do Fail('TlsLib shutdown failed', tecProtocol); end;
  RaiseFailure;
end;

procedure TTlsLibSession.Abort;
begin
  FState := tssClosed;
  FPlain := nil;
  FCipher := nil;
  FEngine := nil;
  if FEngineCounted then
  begin
    TlsLibCountEngine(-1);
    FEngineCounted := False;
  end;
end;

function TTlsLibSession.NegotiatedInfo: TTlsNegotiatedInfo;
begin
  if FState <> tssOpen then raise ETlsSessionError.Create('TlsLib session is not open', tecProtocol);
  Result := FInfo;
end;

end.
