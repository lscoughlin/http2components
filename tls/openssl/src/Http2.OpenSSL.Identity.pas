{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, identity
notes:
  - this unit owns OpenSSL certificate and private-key objects
---
}
unit Http2.OpenSSL.Identity;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  mormot.lib.openssl11;
type
  EOpenSSLProviderUnavailable = class(Exception);
  TOpenSSLIdentity = class
  public
    class function FromPemFiles(const ACertFile, AKeyFile: string;
      const APassphrase: string = ''): ITLSIdentity; static;
    class function FromPem(const ACertPem, AKeyPem: TBytes;
      const APassphrase: string = ''): ITLSIdentity; overload; static;
    class function FromPem(const ACertPem, AKeyPem: string;
      const APassphrase: string = ''): ITLSIdentity; overload; static;
    class function FromPkcs12File(const AFile: string;
      const APassphrase: string = ''): ITLSIdentity; static;
    class function FromPkcs12(const AData: TBytes;
      const APassphrase: string = ''): ITLSIdentity; static;
  end;

function OpenSSLIdentityIsNative(const AValue: ITLSIdentity): Boolean;
procedure OpenSSLIdentityInstallContext(const ACtx: PSSL_CTX; const AIdentity: ITLSIdentity);
procedure OpenSSLIdentityInstallSession(const ASsl: PSSL; const AIdentity: ITLSIdentity);
function OpenSSLCertificateSummary(const ACert: PX509): TTlsCertificateSummary;
function OpenSSLIdentityChainMetadata(const AValue: ITLSIdentity): TArray<TTlsCertificateSummary>;
function OpenSSLIdentityMaterialSize(const AValue: ITLSIdentity): SizeInt;
procedure OpenSSLPeerNames(const AX509: PX509; out ADns, AIp, AUri, AEmail: TArray<string>);

implementation
uses Classes, mormot.core.base, mormot.core.os;

type
  IOpenSSLIdentityNative = interface(ITLSIdentity)
    ['{A9AF35F5-28BB-4C93-B532-3C0AD0BE34B6}']
    function NativeLeaf: PX509;
    function NativeKey: PEVP_PKEY;
    function NativeChainCount: Integer;
    function NativeChainAt(const AIndex: Integer): PX509;
  end;
  TOpenSSLIdentityImpl = class(TInterfacedObject, ITLSIdentity, IOpenSSLIdentityNative)
  private
    FSummary: TTlsCertificateSummary;
    FLeaf: PX509;
    FKey: PEVP_PKEY;
    FChain: array of PX509;
  public
    constructor Create(const ALeaf: PX509; const AKey: PEVP_PKEY; const AChain: array of PX509);
    destructor Destroy; override;
    function BackendName: string;
    function Leaf: TTlsCertificateSummary;
    function Formats: TTlsIdentityFormats;
    function NativeLeaf: PX509;
    function NativeKey: PEVP_PKEY;
    function NativeChainCount: Integer;
    function NativeChainAt(const AIndex: Integer): PX509;
  end;
  TSSLUseCertificate = function(ssl: PSSL; cert: PX509): Integer; cdecl;
  TSSLUsePrivateKey = function(ssl: PSSL; key: PEVP_PKEY): Integer; cdecl;
  TSSLCheckPrivateKey = function(ssl: PSSL): Integer; cdecl;

var IdentityLib: TSynLibrary;
  UseCertificate: TSSLUseCertificate;
  UsePrivateKey: TSSLUsePrivateKey;
  CheckPrivateKey: TSSLCheckPrivateKey;

function OpenSSLIdentityIsNative(const AValue: ITLSIdentity): Boolean;
var N: IOpenSSLIdentityNative;
begin Result := (AValue <> nil) and Supports(AValue, IOpenSSLIdentityNative, N); end;

function OpenSSLIdentityChainMetadata(const AValue: ITLSIdentity): TArray<TTlsCertificateSummary>;
var N: IOpenSSLIdentityNative; I: Integer;
begin
  Result := nil;
  if not Supports(AValue, IOpenSSLIdentityNative, N) then
    raise ETlsContextError.Create('identity belongs to another TLS provider');
  SetLength(Result, N.NativeChainCount);
  for I := 0 to High(Result) do
    Result[I] := OpenSSLCertificateSummary(N.NativeChainAt(I));
end;

function OpenSSLIdentityMaterialSize(const AValue: ITLSIdentity): SizeInt;
var N: IOpenSSLIdentityNative; I: Integer; Summary: TTlsCertificateSummary;
begin
  if not Supports(AValue, IOpenSSLIdentityNative, N) then
    raise ETlsContextError.Create('identity belongs to another TLS provider');
  Summary := OpenSSLCertificateSummary(N.NativeLeaf);
  Result := Length(Summary.Pem);
  for I := 0 to N.NativeChainCount - 1 do
  begin
    Summary := OpenSSLCertificateSummary(N.NativeChainAt(I));
    Inc(Result, Length(Summary.Pem));
  end;
end;

function EnsureIdentityFunctions: Boolean;
var Err, Dir: string;
begin
  if Assigned(UseCertificate) and Assigned(UsePrivateKey) and Assigned(CheckPrivateKey) then Exit(True);
  GlobalLock;
  try
    if IdentityLib = nil then
    begin
      Dir := GetSystemEnvString('OPENSSL_LIBPATH');
      if (Dir <> '') and DirectoryExists(Dir) then Dir := IncludeTrailingPathDelimiter(Dir)
      else Dir := '';
      IdentityLib := TSynLibrary.Create;
      if not IdentityLib.TryLoadLibrary([Dir + LIB_SSL4, Dir + LIB_SSL3, Dir + LIB_SSL1], nil, @Err) then
      begin FreeAndNil(IdentityLib); Exit(False); end;
    end;
    IdentityLib.Resolve(_PU, 'SSL_use_certificate', @@UseCertificate, nil, @Err);
    IdentityLib.Resolve(_PU, 'SSL_use_PrivateKey', @@UsePrivateKey, nil, @Err);
    IdentityLib.Resolve(_PU, 'SSL_check_private_key', @@CheckPrivateKey, nil, @Err);
    Result := Assigned(UseCertificate) and Assigned(UsePrivateKey) and Assigned(CheckPrivateKey);
  finally GlobalUnLock; end;
end;

procedure OpenSSLIdentityInstallContext(const ACtx: PSSL_CTX; const AIdentity: ITLSIdentity);
var N: IOpenSSLIdentityNative; I: Integer; X: PX509;
begin
  if AIdentity = nil then Exit;
  if not Supports(AIdentity, IOpenSSLIdentityNative, N) then
    raise ETlsContextError.Create('identity belongs to another TLS provider');
  if (SSL_CTX_use_certificate(ACtx, N.NativeLeaf) <> 1) or
     (SSL_CTX_use_PrivateKey(ACtx, N.NativeKey) <> 1) or
     (SSL_CTX_check_private_key(ACtx) <> 1) then
    raise ETlsContextError.Create('OpenSSL identity installation failed');
  for I := 0 to N.NativeChainCount - 1 do
  begin
    X := N.NativeChainAt(I);
    if X509_up_ref(X) <> 1 then raise ETlsContextError.Create('OpenSSL chain reference failed');
    if SSL_CTX_add_extra_chain_cert(ACtx, X) <> 1 then
    begin X509_free(X); raise ETlsContextError.Create('OpenSSL chain installation failed'); end;
  end;
end;

procedure OpenSSLIdentityInstallSession(const ASsl: PSSL; const AIdentity: ITLSIdentity);
var N: IOpenSSLIdentityNative; I: Integer;
begin
  if AIdentity = nil then Exit;
  if not Supports(AIdentity, IOpenSSLIdentityNative, N) then
    raise ETlsContextError.Create('identity belongs to another TLS provider');
  if not EnsureIdentityFunctions then
    raise ETlsContextError.Create('OpenSSL session identity functions are unavailable');
  if (UseCertificate(ASsl, N.NativeLeaf) <> 1) or
     (UsePrivateKey(ASsl, N.NativeKey) <> 1) or
     (CheckPrivateKey(ASsl) <> 1) then
    raise ETlsContextError.Create('OpenSSL session identity setup failed');
  for I := 0 to N.NativeChainCount - 1 do
    if SSL_ctrl(ASsl, 89, 1, N.NativeChainAt(I)) <> 1 then
      raise ETlsContextError.Create('OpenSSL session identity chain setup failed');
end;

function DistinguishedName(const AName: PX509_NAME): string;
var B: PBIO; P: PAnsiChar; N: Integer;
begin
  Result := ''; B := BIO_new(BIO_s_mem()); if B = nil then Exit;
  try
    if X509_NAME_print_ex(B, AName, 0, $1110317) > 0 then
    begin N := BIO_ctrl(B, BIO_CTRL_INFO, 0, @P); if (N > 0) and (P <> nil) then SetString(Result, P, N); end;
  finally BIO_free(B); end;
end;

function OpenSSLCertificateSummary(const ACert: PX509): TTlsCertificateSummary;
var B: PBIO; P: PAnsiChar; N: Integer;
begin
  Result := Default(TTlsCertificateSummary);
  Result.Subject := DistinguishedName(X509_get_subject_name(ACert));
  Result.Issuer := DistinguishedName(X509_get_issuer_name(ACert));
  Result.CommonName := string(ACert^.GetSubject('CN'));
  Result.Serial := UpperCase(StringReplace(string(ACert^.SerialNumber), ':', '', [rfReplaceAll]));
  Result.FingerprintSha256 := LowerCase(StringReplace(string(ACert^.FingerPrint(EVP_sha256)), ':', '', [rfReplaceAll]));
  Result.NotBeforeUtc := ACert^.NotBefore; Result.NotAfterUtc := ACert^.NotAfter;
  B := BIO_new(BIO_s_mem());
  if B <> nil then
  try
    if PEM_write_bio_X509(B, ACert) = 1 then
    begin N := BIO_ctrl(B, BIO_CTRL_INFO, 0, @P); if (N > 0) and (P <> nil) then SetString(Result.Pem, P, N); end;
  finally BIO_free(B); end;
end;

procedure OpenSSLPeerNames(const AX509: PX509; out ADns, AIp, AUri, AEmail: TArray<string>);
var Values: TRawUtf8DynArray; I, N: Integer; V, L: string;
  procedure Add(var A: TArray<string>; const S: string);
  begin N := Length(A); SetLength(A, N + 1); A[N] := S; end;
begin
  ADns := nil; AIp := nil; AUri := nil; AEmail := nil; N := 0;
  Values := AX509^.SubjectAlternativeNames(False);
  for I := 0 to High(Values) do
  begin
    V := string(Values[I]); L := LowerCase(V);
    if Copy(L, 1, 4) = 'dns:' then Add(ADns, Copy(V, 5, MaxInt))
    else if Copy(L, 1, 3) = 'ip:' then Add(AIp, Copy(V, 4, MaxInt))
    else if Pos('ip address:', L) = 1 then Add(AIp, Copy(V, 12, MaxInt))
    else if Copy(L, 1, 4) = 'uri:' then Add(AUri, Copy(V, 5, MaxInt))
    else if Copy(L, 1, 6) = 'email:' then Add(AEmail, Copy(V, 7, MaxInt));
  end;
end;

function NewIdentity(const ALeaf: PX509; const AKey: PEVP_PKEY;
  const AChain: PX509DynArray): ITLSIdentity;
var I: Integer; Impl: TOpenSSLIdentityImpl;
begin
  if (ALeaf = nil) or (AKey = nil) then raise ETlsContextError.Create('TLS identity needs a certificate and private key');
  if X509_check_private_key(ALeaf, AKey) <> 1 then raise ETlsContextError.Create('TLS private key does not match the leaf certificate');
  Impl := TOpenSSLIdentityImpl.Create(ALeaf, AKey, AChain); Result := Impl;
end;

constructor TOpenSSLIdentityImpl.Create(const ALeaf: PX509; const AKey: PEVP_PKEY; const AChain: array of PX509);
var I: Integer; Summary: TTlsCertificateSummary; CopiedChain: array of PX509;
begin
  Summary := OpenSSLCertificateSummary(ALeaf);
  SetLength(CopiedChain, Length(AChain));
  for I := 0 to High(AChain) do CopiedChain[I] := AChain[I];
  inherited Create;
  FSummary := Summary;
  FChain := CopiedChain;
  FLeaf := ALeaf;
  FKey := AKey;
end;
destructor TOpenSSLIdentityImpl.Destroy;
var I: Integer;
begin
  for I := 0 to High(FChain) do if FChain[I] <> nil then X509_free(FChain[I]);
  if FLeaf <> nil then X509_free(FLeaf); if FKey <> nil then EVP_PKEY_free(FKey); inherited Destroy;
end;
function TOpenSSLIdentityImpl.BackendName: string; begin Result := 'OpenSSL'; end;
function TOpenSSLIdentityImpl.Leaf: TTlsCertificateSummary; begin Result := FSummary; end;
function TOpenSSLIdentityImpl.Formats: TTlsIdentityFormats; begin Result := [tifPem, tifPkcs12]; end;
function TOpenSSLIdentityImpl.NativeLeaf: PX509; begin Result := FLeaf; end;
function TOpenSSLIdentityImpl.NativeKey: PEVP_PKEY; begin Result := FKey; end;
function TOpenSSLIdentityImpl.NativeChainCount: Integer; begin Result := Length(FChain); end;
function TOpenSSLIdentityImpl.NativeChainAt(const AIndex: Integer): PX509; begin Result := FChain[AIndex]; end;

procedure FreeCertificates(const AValues: PX509DynArray);
var I: Integer;
begin for I := 0 to High(AValues) do if AValues[I] <> nil then X509_free(AValues[I]); end;
function ByteString(const AValue: TBytes): RawUtf8;
begin SetLength(Result, Length(AValue)); if Length(AValue) > 0 then Move(AValue[0], Result[1], Length(AValue)); end;
function ReadBytes(const AFile: string): TBytes;
var S: TFileStream;
begin
  Result := nil;
  try S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try SetLength(Result, S.Size); if Length(Result) > 0 then S.ReadBuffer(Result[0], Length(Result)); finally S.Free; end;
  except on E: Exception do raise ETlsContextError.CreateFmt('cannot read TLS identity file "%s"', [AFile]); end;
end;

class function TOpenSSLIdentity.FromPemFiles(const ACertFile, AKeyFile: string; const APassphrase: string): ITLSIdentity;
begin Result := FromPem(ReadBytes(ACertFile), ReadBytes(AKeyFile), APassphrase); end;
class function TOpenSSLIdentity.FromPem(const ACertPem, AKeyPem: string; const APassphrase: string): ITLSIdentity;
var C, K: TBytes;
begin
  SetLength(C, Length(ACertPem)); if Length(C) > 0 then Move(ACertPem[1], C[0], Length(C));
  SetLength(K, Length(AKeyPem)); if Length(K) > 0 then Move(AKeyPem[1], K[0], Length(K));
  Result := FromPem(C, K, APassphrase);
end;
class function TOpenSSLIdentity.FromPem(const ACertPem, AKeyPem: TBytes; const APassphrase: string): ITLSIdentity;
var Certs: PX509DynArray; Leaf: PX509; Key: PEVP_PKEY; Pass: RawUtf8; I: Integer;
begin
  if not OpenSslInitialize then raise EOpenSSLProviderUnavailable.Create('OpenSSL provider library is not available');
  if (Length(ACertPem) = 0) or (Length(AKeyPem) = 0) then raise ETlsContextError.Create('TLS certificate and key PEM input must not be empty');
  Certs := LoadCertificates(ByteString(ACertPem));
  if Length(Certs) = 0 then raise ETlsContextError.Create('TLS certificate PEM has no certificates');
  Leaf := Certs[0]; Key := nil; Pass := RawUtf8(APassphrase);
  try
    Key := LoadPrivateKey(@AKeyPem[0], Length(AKeyPem), Pass);
    if Key = nil then raise ETlsContextError.Create('cannot read TLS private key PEM or passphrase is incorrect');
    Result := NewIdentity(Leaf, Key, Copy(Certs, 1, Length(Certs) - 1));
    for I := 0 to High(Certs) do Certs[I] := nil; Leaf := nil; Key := nil;
  finally
    if Key <> nil then EVP_PKEY_free(Key); FreeCertificates(Certs);
    if Pass <> '' then begin UniqueString(Pass); FillChar(Pass[1], Length(Pass), 0); end;
  end;
end;
class function TOpenSSLIdentity.FromPkcs12File(const AFile: string; const APassphrase: string): ITLSIdentity;
begin Result := FromPkcs12(ReadBytes(AFile), APassphrase); end;
class function TOpenSSLIdentity.FromPkcs12(const AData: TBytes; const APassphrase: string): ITLSIdentity;
var Bio: PBIO; P12: PPKCS12; Leaf: PX509; Key: PEVP_PKEY; Stack: Pstack_st_X509; Chain: PX509DynArray; Pass: RawUtf8; I, N: Integer;
begin
  if not OpenSslInitialize then raise EOpenSSLProviderUnavailable.Create('OpenSSL provider library is not available');
  if Length(AData) = 0 then raise ETlsContextError.Create('PKCS#12 input must not be empty');
  Bio := BIO_new_mem_buf(@AData[0], Length(AData)); if Bio = nil then raise ETlsContextError.Create('PKCS#12 BIO creation failed');
  try P12 := d2i_PKCS12_bio(Bio, nil); finally BIO_free(Bio); end;
  if P12 = nil then raise ETlsContextError.Create('invalid PKCS#12 identity');
  Leaf := nil; Key := nil; Stack := nil; Chain := nil; Pass := RawUtf8(APassphrase);
  try
    if PKCS12_parse(P12, PUtf8Char(Pass), @Key, @Leaf, @Stack) <> 1 then raise ETlsContextError.Create('PKCS#12 passphrase is incorrect or bundle is invalid');
    if Stack <> nil then begin N := OPENSSL_sk_num(Stack); SetLength(Chain, N); for I := 0 to N - 1 do Chain[I] := OPENSSL_sk_value(Stack, I); OPENSSL_sk_free(Stack); Stack := nil; end;
    Result := NewIdentity(Leaf, Key, Chain); Leaf := nil; Key := nil; Chain := nil;
  finally
    if Stack <> nil then OPENSSL_sk_free(Stack); if Leaf <> nil then X509_free(Leaf);
    if Key <> nil then EVP_PKEY_free(Key); FreeCertificates(Chain); PKCS12_free(P12);
    if Pass <> '' then begin UniqueString(Pass); FillChar(Pass[1], Length(Pass), 0); end;
  end;
end;
end.
