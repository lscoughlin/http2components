{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, identity, tlslib
notes:
  - This provider unit keeps native credentials behind neutral identities.
---
}
unit Http2.TlsLib.Identity;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity;

type
  ITlsLibIdentityMarker = interface(IInterface)
    ['{D8F7E0E6-6D0D-4DF4-BEAB-5DB3A0E0D606}']
    function ApplyClientCredential(const ABuilder: IInterface): IInterface;
    function ApplyServerCredential(const ABuilder: IInterface): IInterface;
    function CertificateBytes: SizeInt;
  end;

function TlsLibCreateIdentity(const ACertificate, AKey, APassword: TBytes;
  const APassphrase: string; const AFormat: TTlsIdentityFormat): ITLSIdentity;

implementation

uses
  Http2.TlsLib.Diagnostics, Http2.TlsLib.Certificate,
  TlpTlsCredential, TlpDefaultCryptoProvider, TlpDefaultPkixProvider,
  TlpCryptoDomainTypes, TlpITlsConfigBuilder;

type
  PTlsCredential = ^TTlsCredential;

  TTlsLibCredentialIdentity = class(TInterfacedObject, ITLSIdentity,
    ITlsLibIdentityMarker)
  private
    FCredential: Pointer;
    FLeaf: TTlsCertificateSummary;
    FFormats: TTlsIdentityFormats;
    FCounted: Boolean;
    FCertificateBytes: SizeInt;
  public
    constructor Create(const ACertificate, AKey, APassword: TBytes;
      const APassphrase: string; const AFormat: TTlsIdentityFormat);
    destructor Destroy; override;
    function BackendName: string;
    function Leaf: TTlsCertificateSummary;
    function Formats: TTlsIdentityFormats;
    function ApplyClientCredential(const ABuilder: IInterface): IInterface;
    function ApplyServerCredential(const ABuilder: IInterface): IInterface;
    function CertificateBytes: SizeInt;
  end;

function TlsLibCreateIdentity(const ACertificate, AKey, APassword: TBytes;
  const APassphrase: string; const AFormat: TTlsIdentityFormat): ITLSIdentity;
begin
  Result := TTlsLibCredentialIdentity.Create(ACertificate, AKey, APassword,
    APassphrase, AFormat);
end;

constructor TTlsLibCredentialIdentity.Create(const ACertificate, AKey,
  APassword: TBytes; const APassphrase: string; const AFormat: TTlsIdentityFormat);
var C: TTlsCredential; I: Integer;
begin
  inherited Create;
  if (Length(ACertificate) > 4 * 1024 * 1024) or
     (Length(AKey) > 4 * 1024 * 1024) then
    raise ETlsContextError.Create('TlsLib identity input exceeds the 4 MiB limit');
  try
    if AFormat = tifPkcs12 then
      C := TTlsCredential.LoadPkcs12(TDefaultCryptoProvider.Shared, ACertificate,
        APassphrase)
    else
      C := TTlsCredential.Load(TDefaultCryptoProvider.Shared,
        TDefaultPkixProvider.Shared, ACertificate, AKey, APassphrase);
    if C.Consistency(TDefaultPkixProvider.Shared.Certificates) <>
      TCredentialConsistency.Consistent then
      raise ETlsContextError.Create('TlsLib certificate and private key do not match');
  except
    on E: ETlsContextError do raise;
    on E: Exception do
      raise ETlsContextError.Create('TlsLib identity is malformed or the passphrase is incorrect');
  end;
  New(PTlsCredential(FCredential));
  PTlsCredential(FCredential)^ := C;
  FCertificateBytes := 0;
  for I := 0 to High(C.CertificateChain) do
    Inc(FCertificateBytes, Length(C.CertificateChain[I]));
  FFormats := [AFormat];
  FLeaf := TlsLibCertificateSummary(C.CertificateChain[0]);
  TlsLibCountCredential(1);
  FCounted := True;
end;

destructor TTlsLibCredentialIdentity.Destroy;
begin
  if FCounted then TlsLibCountCredential(-1);
  if FCredential <> nil then Dispose(PTlsCredential(FCredential));
  inherited Destroy;
end;

function TTlsLibCredentialIdentity.BackendName: string; begin Result := 'TlsLib'; end;
function TTlsLibCredentialIdentity.Leaf: TTlsCertificateSummary; begin Result := FLeaf; end;
function TTlsLibCredentialIdentity.Formats: TTlsIdentityFormats; begin Result := FFormats; end;
function TTlsLibCredentialIdentity.CertificateBytes: SizeInt; begin Result := FCertificateBytes; end;

function TTlsLibCredentialIdentity.ApplyClientCredential(const ABuilder: IInterface): IInterface;
var B: ITlsClientConfigBuilder;
begin
  B := ABuilder as ITlsClientConfigBuilder;
  B := B.WithCredential(PTlsCredential(FCredential)^);
  Result := B;
end;

function TTlsLibCredentialIdentity.ApplyServerCredential(const ABuilder: IInterface): IInterface;
var B: ITlsServerConfigBuilder;
begin
  B := ABuilder as ITlsServerConfigBuilder;
  B := B.WithCredential(PTlsCredential(FCredential)^);
  Result := B;
end;

end.
