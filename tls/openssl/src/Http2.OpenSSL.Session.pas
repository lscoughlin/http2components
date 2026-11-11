{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, session
notes:
  - This unit owns OpenSSL memory-BIO sessions and ALPN callbacks.
---
}
unit Http2.OpenSSL.Session;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session,
  Http2.Common.Tls.Context, mormot.lib.openssl11;
type
  TOpenSSLSession = class(TInterfacedObject, ITLSSession)
  private
    FOwner: ITLSContext;
    FSsl: PSSL;
    FRbio, FWbio: PBIO;
    FRole: TTlsRole;
    FState: TTlsSessionState;
    FPlain: TBytes;
    FPendingWrite: TBytes;
    FInFlightWrite: TBytes;
    FFailureMessage: string;
    FFailureCategory: TTlsErrorCategory;
    FDeadline: Int64;
    FVerifyPeer: Boolean;
    FAlpns: TArray<string>;
    FIdentity: ITLSIdentity;
    FInfo: TTlsNegotiatedInfo;
    FHasInfo: Boolean;
    procedure Fail(const AMessage: string; const ACategory: TTlsErrorCategory);
    procedure RaiseFailure;
    function PendingOutput: SizeInt;
    procedure CaptureInfo;
  public
    constructor Create(const AOwner: ITLSContext; const ACtx: PSSL_CTX;
      const ARole: TTlsRole; const AHost, AServerName: string;
      const AAlpns: TArray<string>; const AStartMs, ADeadlineMs: Int64;
      const AVerifyHost, AVerifyPeer: Boolean; const AIdentity: ITLSIdentity);
    destructor Destroy; override;
    function State: TTlsSessionState;
    function FeedEncrypted(const ABuffer:TBytes; const AOffset,ACount:SizeInt):SizeInt;
    function DrainEncrypted(var ABuffer:TBytes; const AOffset,ACapacity:SizeInt):SizeInt;
    function WritePlaintext(const ABuffer:TBytes; const AOffset,ACount:SizeInt):SizeInt;
    function ReadPlaintext(var ABuffer:TBytes; const AOffset,ACapacity:SizeInt):SizeInt;
    function Advance(const AMonotonicMs:Int64):TTlsProgress;
    procedure NotifyTransportEof;
    procedure BeginShutdown;
    procedure Abort;
    function NegotiatedInfo:TTlsNegotiatedInfo;
  end;
function OpenSSLInstallServerAlpn(const ACtx: PSSL_CTX): Boolean;
function OpenSSLDisableResumption(const ACtx: PSSL_CTX): Boolean;
function OpenSSLSetVerificationDepth(const ACtx: PSSL_CTX; const ADepth: Integer): Boolean;
implementation
uses Classes, Http2.OpenSSL.Identity, mormot.core.base, mormot.core.os;
type
  TSSLSetAlpnProtos = function(ssl: PSSL; protos: PByte; protos_len: Cardinal): Integer; cdecl;
  TSSLAlpnSelectCallback = function(ssl: PSSL; out_: PPByte; outlen: PByte;
    input: PByte; inlen: Cardinal; arg: Pointer): Integer; cdecl;
  TSSLSetAlpnSelect = procedure(ctx: PSSL_CTX; cb: TSSLAlpnSelectCallback;
    arg: Pointer); cdecl;
  TSSLSetVerifyDepth = procedure(ctx: PSSL_CTX; depth: Integer); cdecl;
  TSSLCTXSetNumber = function(ctx: PSSL_CTX; value: Cardinal): Integer; cdecl;
  TSSLVersion = function(ssl: PSSL): Integer; cdecl;
const
  TlsMaxHandshakeAlpnBytes = 8192;
var
  AlpnLib: TSynLibrary;
  SetAlpnProtos: TSSLSetAlpnProtos;
  SetAlpnSelect: TSSLSetAlpnSelect;
  SetVerifyDepth: TSSLSetVerifyDepth;
  SetNumTickets, SetMaxEarlyData: TSSLCTXSetNumber;
  GetSslVersion: TSSLVersion;
  AlpnDataIndex: Integer = -1;
function EnsureAlpnFunctions: Boolean;
var Dir, Err: string;
begin
  Result := Assigned(SetAlpnProtos) and Assigned(SetAlpnSelect) and
    (AlpnDataIndex >= 0);
  if Result then Exit;
  GlobalLock;
  try
    if AlpnLib = nil then
    begin
      Dir := GetSystemEnvString('OPENSSL_LIBPATH');
      if (Dir <> '') and DirectoryExists(Dir) then Dir := IncludeTrailingPathDelimiter(Dir)
      else Dir := '';
      AlpnLib := TSynLibrary.Create;
      if not AlpnLib.TryLoadLibrary([Dir + LIB_SSL4, Dir + LIB_SSL3, Dir + LIB_SSL1], nil, @Err) then
      begin FreeAndNil(AlpnLib); Exit(False); end;
    end;
    if not Assigned(SetAlpnProtos) then
      AlpnLib.Resolve(_PU, 'SSL_set_alpn_protos', @@SetAlpnProtos, nil, @Err);
    if not Assigned(SetAlpnSelect) then
      AlpnLib.Resolve(_PU, 'SSL_CTX_set_alpn_select_cb', @@SetAlpnSelect, nil, @Err);
    if AlpnDataIndex < 0 then AlpnDataIndex := SSL_get_ex_new_index(0, nil, nil, nil, nil);
    Result := Assigned(SetAlpnProtos) and Assigned(SetAlpnSelect) and (AlpnDataIndex >= 0);
  finally
    GlobalUnLock;
  end;
end;

function EnsureVerifyDepth: Boolean;
var Err: string;
begin
  if not EnsureAlpnFunctions then Exit(False);
  GlobalLock;
  try
    if not Assigned(SetVerifyDepth) then
      AlpnLib.Resolve(_PU, 'SSL_CTX_set_verify_depth', @@SetVerifyDepth, nil, @Err);
    Result := Assigned(SetVerifyDepth);
  finally GlobalUnLock; end;
end;

function EnsureTlsControls: Boolean;
var Err: string;
begin
  if not EnsureAlpnFunctions then Exit(False);
  GlobalLock;
  try
    if not Assigned(SetNumTickets) then AlpnLib.Resolve(_PU, 'SSL_CTX_set_num_tickets', @@SetNumTickets, nil, @Err);
    if not Assigned(SetMaxEarlyData) then AlpnLib.Resolve(_PU, 'SSL_CTX_set_max_early_data', @@SetMaxEarlyData, nil, @Err);
    if not Assigned(GetSslVersion) then AlpnLib.Resolve(_PU, 'SSL_version', @@GetSslVersion, nil, @Err);
    Result := Assigned(SetNumTickets) and Assigned(SetMaxEarlyData) and Assigned(GetSslVersion);
  finally GlobalUnLock; end;
end;

function OpenSSLAlpnSelect(ssl: PSSL; out_: PPByte; outlen: PByte;
  input: PByte; inlen: Cardinal; arg: Pointer): Integer; cdecl;
var S: TOpenSSLSession; Posn, L, I, J: Cardinal; Wanted: UTF8String;
begin
  Result := 2;
  if (out_ = nil) or (outlen = nil) or (input = nil) then Exit;
  S := TOpenSSLSession(SSL_get_ex_data(ssl, AlpnDataIndex));
  if (S = nil) or (Length(S.FAlpns) = 0) then begin Result := 3; Exit; end;
  for I := 0 to High(S.FAlpns) do
  begin
    Wanted := UTF8String(S.FAlpns[I]);
    if (Length(Wanted) = 0) or (Length(Wanted) > 255) then Continue;
    Posn := 0;
    while Posn < inlen do
    begin
      L := input[Posn]; Inc(Posn);
      if (L = 0) or (Posn + L > inlen) then Exit;
      if L = Cardinal(Length(Wanted)) then
      begin
        J := 0;
        while (J < L) and (input[Posn + J] = Byte(Wanted[J + 1])) do Inc(J);
        if J = L then
        begin
          out_^ := @input[Posn]; outlen^ := L; Result := 0; Exit;
        end;
      end;
      Inc(Posn, L);
    end;
  end;
end;

function EncodeAlpns(const AValues: TArray<string>): TBytes;
var I, N, J: Integer; S: UTF8String;
begin
  Result := nil;
  for I := 0 to High(AValues) do
  begin
    S := UTF8String(AValues[I]);
    if (Length(S) = 0) or (Length(S) > 255) then
      raise ETlsContextError.Create('ALPN names must contain 1 to 255 UTF-8 bytes');
    N := Length(Result); SetLength(Result, N + Length(S) + 1);
    Result[N] := Length(S);
    for J := 1 to Length(S) do Result[N + J] := Byte(S[J]);
  end;
  if Length(Result) > TlsMaxHandshakeAlpnBytes then
    raise ETlsContextError.Create('ALPN offer exceeds the OpenSSL handshake bound');
end;

function InRange(const ALength, AOffset, ACount: SizeInt): Boolean;
begin
  Result := (AOffset >= 0) and (ACount >= 0) and (AOffset <= ALength) and
    (ACount <= ALength - AOffset);
end;

function IsIpLiteral(const AHost: string): Boolean;
var I: Integer; H: string;
begin
  H := AHost;
  if (Length(H) > 1) and (H[1] = '[') and (H[Length(H)] = ']') then
    H := Copy(H, 2, Length(H) - 2);
  Result := (H <> '') and (Pos(':', H) > 0);
  if Result then Exit;
  Result := (H <> '') and (Pos('.', H) > 0);
  if not Result then Exit;
  for I := 1 to Length(H) do
    if not (H[I] in ['0'..'9', '.']) then Exit(False);
end;

function NativeVersion(const AVersion: TTlsVersion): Integer;
begin
  if AVersion = tls12 then Result := TLS1_2_VERSION else Result := TLS1_3_VERSION;
end;

constructor TOpenSSLSession.Create(const AOwner: ITLSContext; const ACtx: PSSL_CTX;
  const ARole: TTlsRole; const AHost, AServerName: string;
  const AAlpns: TArray<string>; const AStartMs, ADeadlineMs: Int64;
  const AVerifyHost, AVerifyPeer: Boolean; const AIdentity: ITLSIdentity);
var Host, Sni: UTF8String; Alpn: TBytes;
begin
  inherited Create;
  FOwner := AOwner;
  FRole := ARole;
  FVerifyPeer := AVerifyPeer;
  FAlpns := Copy(AAlpns);
  FIdentity := AIdentity;
  FState := tssNew;
  FDeadline := ADeadlineMs;
  if (AStartMs < 0) or (ADeadlineMs < 0) then
    raise ETlsContextError.Create('handshake times must not be negative');
  if (ARole = trClient) and ((Length(AHost) > 253) or
    (Length(AServerName) > 253)) then
    raise ETlsContextError.Create('TLS host and server names must not exceed 253 bytes');
  Alpn := EncodeAlpns(AAlpns);
  if AOwner.Info.HandshakeTimeoutMs > 0 then
  begin
    if AStartMs > High(Int64) - Int64(AOwner.Info.HandshakeTimeoutMs) then
      raise ETlsContextError.Create('handshake deadline overflows monotonic time');
    if (FDeadline = 0) or (AStartMs + AOwner.Info.HandshakeTimeoutMs < FDeadline) then
      FDeadline := AStartMs + AOwner.Info.HandshakeTimeoutMs;
  end;
  FSsl := SSL_new(ACtx);
  if FSsl = nil then raise ETlsContextError.Create('SSL_new failed');
  OpenSSLIdentityInstallSession(FSsl, AIdentity);
  FRbio := BIO_new(BIO_s_mem());
  FWbio := BIO_new(BIO_s_mem());
  if (FRbio = nil) or (FWbio = nil) then
  begin
    if FRbio <> nil then BIO_free(FRbio);
    if FWbio <> nil then BIO_free(FWbio);
    SSL_free(FSsl); FSsl := nil;
    raise ETlsContextError.Create('OpenSSL memory BIO creation failed');
  end;
  SSL_set_bio(FSsl, FRbio, FWbio);
  if ARole = trClient then
  begin
    SSL_set_connect_state(FSsl);
    if AVerifyHost and (AHost = '') then
      raise ETlsContextError.Create('verified client sessions require a host name');
    if AVerifyHost and (AHost <> '') then
    begin
      Host := UTF8String(AHost);
      if SSL_set1_host(FSsl, PUtf8Char(Host)) <> 1 then
        raise ETlsContextError.Create('OpenSSL hostname verification setup failed');
    end;
    Sni := UTF8String(AServerName);
    if (Sni = '') and (AHost <> '') and not IsIpLiteral(AHost) then
      Sni := UTF8String(AHost);
    if (Sni <> '') and not IsIpLiteral(string(Sni)) then
    begin
      if SSL_ctrl(FSsl, 55, 0, PAnsiChar(Sni)) <= 0 then
        raise ETlsContextError.Create('OpenSSL SNI setup failed');
    end;
  end
  else SSL_set_accept_state(FSsl);
  if Length(AAlpns) > 0 then
  begin
    if not EnsureAlpnFunctions then
      raise ETlsContextError.Create('OpenSSL ALPN functions are not available');
    if ARole = trClient then
    begin
      // ALPN uses the per-SSL API. The encoded vector is local because OpenSSL
      // copies it before returning.
      if SetAlpnProtos(FSsl, @Alpn[0], Length(Alpn)) <> 0 then
        raise ETlsContextError.Create('OpenSSL client ALPN setup failed');
    end
    else
    begin
      if not EnsureAlpnFunctions then raise ETlsContextError.Create('OpenSSL server ALPN is unavailable');
      if SSL_set_ex_data(FSsl, AlpnDataIndex, Self) <> 1 then
        raise ETlsContextError.Create('OpenSSL server ALPN session binding failed');
    end;
  end;
end;

destructor TOpenSSLSession.Destroy;
begin
  if FSsl <> nil then SSL_free(FSsl);
  FOwner := nil;
  inherited Destroy;
end;

function TOpenSSLSession.State: TTlsSessionState; begin Result := FState; end;
function TOpenSSLSession.PendingOutput: SizeInt;
begin
  if FWbio = nil then Exit(0);
  Result := BIO_ctrl(FWbio, _BIO_CTRL_PENDING, 0, nil);
end;
procedure TOpenSSLSession.Fail(const AMessage: string; const ACategory: TTlsErrorCategory);
begin
  FState := tssFailed;
  FFailureMessage := AMessage;
  FFailureCategory := ACategory;
end;
procedure TOpenSSLSession.RaiseFailure;
begin
  raise ETlsSessionError.Create(FFailureMessage, FFailureCategory);
end;
function TOpenSSLSession.FeedEncrypted(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin
  Result := 0;
  if not InRange(Length(ABuffer), AOffset, ACount) then
    raise ETlsSessionError.Create('invalid encrypted input range', tecProtocol);
  if PendingOutput > TlsMaxEncryptedOutput then
    Fail('OpenSSL output exceeded the TLS queue limit', tecInternal);
  if FState = tssFailed then RaiseFailure;
  if FState = tssClosed then raise ETlsSessionError.Create('TLS session is closed', tecProtocol);
  if BIO_ctrl(FRbio, _BIO_CTRL_PENDING, 0, nil) >= TlsMaxEncryptedOutput then Exit;
  Result := ACount;
  if Result > TlsMaxEncryptedInput then Result := TlsMaxEncryptedInput;
  if Result > TlsMaxEncryptedOutput - BIO_ctrl(FRbio, _BIO_CTRL_PENDING, 0, nil) then
    Result := TlsMaxEncryptedOutput - BIO_ctrl(FRbio, _BIO_CTRL_PENDING, 0, nil);
  if Result = 0 then Exit;
  if BIO_write(FRbio, @ABuffer[AOffset], Result) <> Result then
  begin
    Result := 0;
    Fail('OpenSSL rejected encrypted input', tecInternal);
    RaiseFailure;
  end;
end;
function TOpenSSLSession.DrainEncrypted(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
var Pending: SizeInt;
begin
  if not InRange(Length(ABuffer), AOffset, ACapacity) then
    raise ETlsSessionError.Create('invalid encrypted output range', tecProtocol);
  Pending := PendingOutput;
  Result := ACapacity;
  if Result > Pending then Result := Pending;
  if Result > 0 then Result := BIO_read(FWbio, @ABuffer[AOffset], Result);
end;
function TOpenSSLSession.WritePlaintext(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
var Pending, QueueLength: SizeInt;
begin
  if not InRange(Length(ABuffer), AOffset, ACount) then
    raise ETlsSessionError.Create('invalid plaintext input range', tecProtocol);
  Result := 0;
  if FState = tssFailed then RaiseFailure;
  if FState <> tssOpen then Exit;
  if ACount = 0 then Exit;
  Pending := Length(FPendingWrite) + Length(FInFlightWrite);
  if Pending >= TlsMaxPlaintextBuffer then Exit;
  Result := ACount;
  if Result > TlsMaxEncryptedInput then Result := TlsMaxEncryptedInput;
  if Result > TlsMaxPlaintextBuffer - Pending then
    Result := TlsMaxPlaintextBuffer - Pending;
  QueueLength := Length(FPendingWrite);
  SetLength(FPendingWrite, QueueLength + Result);
  Move(ABuffer[AOffset], FPendingWrite[QueueLength], Result);
end;
function TOpenSSLSession.ReadPlaintext(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
var N: SizeInt;
begin
  if not InRange(Length(ABuffer), AOffset, ACapacity) then
    raise ETlsSessionError.Create('invalid plaintext output range', tecProtocol);
  N := ACapacity;
  if N > Length(FPlain) then N := Length(FPlain);
  if N > 0 then
  begin
    Move(FPlain[0], ABuffer[AOffset], N);
    Delete(FPlain, 0, N);
    Exit(N);
  end;
  if FState = tssFailed then RaiseFailure;
  Result := 0;
end;
procedure TOpenSSLSession.CaptureInfo;
var V: string; Data: PByte; Len: Cardinal; Peer: PX509;
  CipherText: array[0..255] of AnsiChar; P: Integer; Stack: Pstack_st_X509;
  I, StartAt: Integer; Chain: array of TTlsCertificateSummary;
  Dns, Ip, Uri, Email: TArray<string>; X: PX509;
begin
  FillChar(CipherText, SizeOf(CipherText), 0);
  if SSL_CIPHER_description(SSL_get_current_cipher(FSsl), @CipherText[0],
    SizeOf(CipherText)) <> nil then V := StrPas(@CipherText[0]) else V := '';
  FInfo.Role := FRole;
  if not EnsureTlsControls then
    raise ETlsSessionError.Create('OpenSSL version metadata function is not available', tecInternal);
  if GetSslVersion(FSsl) = TLS1_3_VERSION then FInfo.Version := tls13
  else if GetSslVersion(FSsl) = TLS1_2_VERSION then FInfo.Version := tls12
  else raise ETlsSessionError.Create('OpenSSL negotiated an unsupported TLS version', tecProtocol);
  P := Pos(' ', V);
  if P > 0 then FInfo.CipherName := Copy(V, 1, P - 1) else FInfo.CipherName := V;
  SSL_get0_alpn_selected(FSsl, @Data, @Len);
  if (Data <> nil) and (Len > 0) then SetString(FInfo.SelectedAlpn, PAnsiChar(Data), Len);
  Peer := SSL_get_peer_certificate(FSsl);
  if Peer <> nil then
  begin
    OpenSSLPeerNames(Peer, Dns, Ip, Uri, Email);
    SetLength(Chain, 1); Chain[0] := OpenSSLCertificateSummary(Peer);
    Stack := SSL_get_peer_cert_chain(FSsl); StartAt := 0;
    if Stack <> nil then
    begin
      if (OPENSSL_sk_num(Stack) > 0) and (OPENSSL_sk_value(Stack, 0) <> nil) then
        if OpenSSLCertificateSummary(Peer).FingerprintSha256 =
          OpenSSLCertificateSummary(OPENSSL_sk_value(Stack, 0)).FingerprintSha256 then
          StartAt := 1;
      for I := StartAt to OPENSSL_sk_num(Stack) - 1 do
      begin
        X := OPENSSL_sk_value(Stack, I);
        SetLength(Chain, Length(Chain) + 1);
        Chain[High(Chain)] := OpenSSLCertificateSummary(X);
      end;
    end;
    FInfo.PeerCertificate := NewTlsPeerCertificate(FVerifyPeer and
      (SSL_get_verify_result(FSsl) = 0), Chain[0], Chain, Dns, Ip, Uri, Email);
    X509_free(Peer);
  end;
  FHasInfo := True;
end;
function TOpenSSLSession.Advance(const AMonotonicMs: Int64): TTlsProgress;
var R, E, N, WriteCount: Integer; Temp: array[0..16383] of Byte;
  BeforeOut, BeforePlain, BeforeWrite, BeforeIn: SizeInt;
  OldState: TTlsSessionState; WriteRetryBlocked: Boolean;
begin
  Result := Default(TTlsProgress);
  if AMonotonicMs < 0 then raise ETlsSessionError.Create('monotonic time must not be negative', tecProtocol);
  if FState = tssFailed then RaiseFailure;
  if FState = tssClosed then
  begin Result.State := FState; Result.NeedOutput := PendingOutput > 0; Exit; end;
  BeforeOut := PendingOutput; BeforePlain := Length(FPlain);
  BeforeWrite := Length(FPendingWrite) + Length(FInFlightWrite);
  BeforeIn := BIO_ctrl(FRbio, _BIO_CTRL_PENDING, 0, nil); OldState := FState;
  WriteRetryBlocked := Length(FInFlightWrite) > 0;
  if FState in [tssNew, tssHandshaking] then
  begin
    if (FDeadline > 0) and (AMonotonicMs >= FDeadline) then
    begin Fail('TLS handshake deadline expired', tecTimeout); end
    else
    begin
      FState := tssHandshaking;
      ERR_clear_error;
      if FRole = trClient then R := SSL_connect(FSsl) else R := SSL_accept(FSsl);
      if R = 1 then begin FState := tssOpen; CaptureInfo; end
      else
      begin
        E := SSL_get_error(FSsl, R);
      if not (E in [SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE]) then
        if SSL_get_verify_result(FSsl) <> 0 then
          Fail('OpenSSL certificate verification failed', tecVerification)
        else
          Fail('OpenSSL handshake failed', tecAlert);
      end;
    end;
  end;
  if (FState in [tssOpen, tssClosing]) and (Length(FPendingWrite) > 0) and
     (Length(FInFlightWrite) = 0) and
     (PendingOutput + 16384 + 2048 <= TlsMaxEncryptedOutput) then
  begin
    WriteCount := Length(FPendingWrite);
    if WriteCount > SizeOf(Temp) then WriteCount := SizeOf(Temp);
    SetLength(FInFlightWrite, WriteCount);
    Move(FPendingWrite[0], FInFlightWrite[0], WriteCount);
    Delete(FPendingWrite, 0, WriteCount);
  end;
  if (FState in [tssOpen, tssClosing]) and (Length(FInFlightWrite) > 0) and
     (PendingOutput + 16384 + 2048 <= TlsMaxEncryptedOutput) then
  begin
    ERR_clear_error;
    R := SSL_write(FSsl, @FInFlightWrite[0], Length(FInFlightWrite));
    if R > 0 then
    begin
      Delete(FInFlightWrite, 0, R);
      WriteRetryBlocked := False;
    end
    else
    begin
      E := SSL_get_error(FSsl, R);
      if E in [SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE] then
        WriteRetryBlocked := True
      else
        Fail('OpenSSL rejected plaintext write', tecAlert);
    end;
  end;
  if (FState = tssClosing) and not WriteRetryBlocked then
  begin
    if (Length(FPendingWrite) = 0) and (Length(FInFlightWrite) = 0) then
    begin
      ERR_clear_error;
      R := SSL_shutdown(FSsl);
      if R = 1 then FState := tssClosed
      else if R < 0 then
      begin
        E := SSL_get_error(FSsl, R);
        if not (E in [SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE]) then
          Fail('OpenSSL shutdown failed', tecAlert);
      end;
    end;
  end;
  if (FState in [tssOpen, tssClosing]) and not WriteRetryBlocked then
  begin
    while Length(FPlain) < TlsMaxPlaintextBuffer do
    begin
      N := TlsMaxPlaintextBuffer - Length(FPlain);
      if N > SizeOf(Temp) then N := SizeOf(Temp);
      ERR_clear_error;
      N := SSL_read(FSsl, @Temp[0], N);
      if N > 0 then
      begin
        SetLength(FPlain, Length(FPlain) + N);
        Move(Temp[0], FPlain[Length(FPlain) - N], N);
      end
      else
      begin
        E := SSL_get_error(FSsl, N);
        { A peer close still needs our close_notify. The next advance drains
          accepted writes and completes SSL_shutdown before the terminal state. }
        if E = SSL_ERROR_ZERO_RETURN then FState := tssClosing
        else if not (E in [SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE]) then
          Fail('OpenSSL record processing failed', tecAlert);
        Break;
      end;
    end;
  end;
  if PendingOutput > TlsMaxEncryptedOutput then
    Fail('OpenSSL output exceeded the TLS queue limit', tecInternal);
  if FState = tssFailed then RaiseFailure;
  Result.State := FState;
  Result.PendingPlaintextOutput := Length(FPendingWrite) + Length(FInFlightWrite);
  Result.NeedOutput := PendingOutput > 0;
  Result.NeedInput := (FState in [tssHandshaking, tssOpen, tssClosing]) and not Result.NeedOutput;
  Result.MadeProgress := (PendingOutput <> BeforeOut) or
    (Length(FPlain) <> BeforePlain) or
    (Length(FPendingWrite) + Length(FInFlightWrite) <> BeforeWrite) or
    (BIO_ctrl(FRbio, _BIO_CTRL_PENDING, 0, nil) <> BeforeIn) or (FState <> OldState);
end;
procedure TOpenSSLSession.NotifyTransportEof;
begin
  if FState = tssFailed then RaiseFailure;
  if FState = tssClosed then Exit;
  Advance(0);
  if FState = tssClosed then Exit;
  Fail('transport ended without TLS close_notify', tecTransportEof);
  RaiseFailure;
end;
procedure TOpenSSLSession.BeginShutdown;
begin
  if FState = tssFailed then RaiseFailure;
  if FState <> tssOpen then Exit;
  FState := tssClosing;
end;
procedure TOpenSSLSession.Abort;
begin
  FPlain := nil;
  FPendingWrite := nil;
  FInFlightWrite := nil;
  FState := tssClosed;
  // SSL owns both BIOs and any partially decoded native records. Releasing
  // it clears those buffers even when the caller retains this interface.
  if FSsl <> nil then SSL_free(FSsl);
  FSsl := nil;
  FRbio := nil;
  FWbio := nil;
end;
function TOpenSSLSession.NegotiatedInfo: TTlsNegotiatedInfo;
begin
  if (FState <> tssOpen) or not FHasInfo then
    raise ETlsSessionError.Create('TLS negotiation is not open', tecProtocol);
  Result := FInfo;
end;

function DistinguishedName(const AName: PX509_NAME): string;
var B: PBIO; P: PAnsiChar; N: Integer;
begin
  Result := '';
  B := BIO_new(BIO_s_mem());
  if B = nil then Exit;
  try
    if X509_NAME_print_ex(B, AName, 0, $1110717) > 0 then
    begin
      N := BIO_ctrl(B, BIO_CTRL_INFO, 0, @P);
      if (N > 0) and (P <> nil) then SetString(Result, P, N);
    end;
  finally BIO_free(B); end;
end;


function OpenSSLInstallServerAlpn(const ACtx: PSSL_CTX): Boolean;
begin
  Result := EnsureAlpnFunctions;
  if Result then SetAlpnSelect(ACtx, @OpenSSLAlpnSelect, nil);
end;
function OpenSSLDisableResumption(const ACtx: PSSL_CTX): Boolean;
begin
  Result := EnsureTlsControls and (SetNumTickets(ACtx, 0) = 1) and
    (SetMaxEarlyData(ACtx, 0) = 1);
end;
function OpenSSLSetVerificationDepth(const ACtx: PSSL_CTX; const ADepth: Integer): Boolean;
begin
  Result := EnsureVerifyDepth;
  if Result then SetVerifyDepth(ACtx, ADepth);
end;
end.
