{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, identity, certificate
notes:
  - This unit defines immutable identity and peer certificate interfaces.
---
}
unit Http2.Common.Tls.Identity;
{$mode delphi}{$H+}{$interfaces com}
interface
uses Http2.Common.Tls.Types;
type
  TTlsCertificateSummary = record
    Subject, Issuer, CommonName, Serial, FingerprintSha256, Pem: string;
    NotBeforeUtc, NotAfterUtc: TDateTime;
  end;

  ITLSIdentity = interface(IInterface)
    ['{C9F620E7-0F0C-4785-8D69-7CF7A2D92303}']
    function BackendName: string;
    function Leaf: TTlsCertificateSummary;
    function Formats: TTlsIdentityFormats;
  end;

  ITLSPeerCertificate = interface(IInterface)
    ['{4C41A6B3-9685-4865-89D3-4B3C991E2303}']
    function Verified: Boolean;
    function Leaf: TTlsCertificateSummary;
    function Chain: TArray<TTlsCertificateSummary>;
    function DnsNames: TArray<string>;
    function IpAddresses: TArray<string>;
    function UriNames: TArray<string>;
    function EmailAddresses: TArray<string>;
  end;

  TTlsPeerCertificateData = class(TInterfacedObject, ITLSPeerCertificate)
  private
    FVerified: Boolean;
    FLeaf: TTlsCertificateSummary;
    FChain: TArray<TTlsCertificateSummary>;
    FDns, FIp, FUri, FEmail: TArray<string>;
  public
    constructor Create(const AVerified: Boolean; const ALeaf: TTlsCertificateSummary;
      const AChain: array of TTlsCertificateSummary; const ADns, AIp, AUri,
      AEmail: array of string);
    function Verified: Boolean;
    function Leaf: TTlsCertificateSummary;
    function Chain: TArray<TTlsCertificateSummary>;
    function DnsNames: TArray<string>;
    function IpAddresses: TArray<string>;
    function UriNames: TArray<string>;
    function EmailAddresses: TArray<string>;
  end;

function NewTlsPeerCertificate(const AVerified: Boolean;
  const ALeaf: TTlsCertificateSummary; const AChain: array of TTlsCertificateSummary;
  const ADns, AIp, AUri, AEmail: array of string): ITLSPeerCertificate;
implementation
function CopyStrings(const AValues: array of string): TArray<string>;
var I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do Result[I] := AValues[I];
end;
function CopySummaries(const AValues: array of TTlsCertificateSummary): TArray<TTlsCertificateSummary>;
var I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do Result[I] := AValues[I];
end;
constructor TTlsPeerCertificateData.Create(const AVerified: Boolean;
  const ALeaf: TTlsCertificateSummary; const AChain: array of TTlsCertificateSummary;
  const ADns, AIp, AUri, AEmail: array of string);
begin
  inherited Create;
  FVerified := AVerified; FLeaf := ALeaf; FChain := CopySummaries(AChain);
  FDns := CopyStrings(ADns); FIp := CopyStrings(AIp);
  FUri := CopyStrings(AUri); FEmail := CopyStrings(AEmail);
end;
function TTlsPeerCertificateData.Verified: Boolean; begin Result := FVerified; end;
function TTlsPeerCertificateData.Leaf: TTlsCertificateSummary; begin Result := FLeaf; end;
function TTlsPeerCertificateData.Chain: TArray<TTlsCertificateSummary>; begin Result := Copy(FChain); end;
function TTlsPeerCertificateData.DnsNames: TArray<string>; begin Result := Copy(FDns); end;
function TTlsPeerCertificateData.IpAddresses: TArray<string>; begin Result := Copy(FIp); end;
function TTlsPeerCertificateData.UriNames: TArray<string>; begin Result := Copy(FUri); end;
function TTlsPeerCertificateData.EmailAddresses: TArray<string>; begin Result := Copy(FEmail); end;
function NewTlsPeerCertificate(const AVerified: Boolean; const ALeaf: TTlsCertificateSummary;
  const AChain: array of TTlsCertificateSummary; const ADns, AIp, AUri,
  AEmail: array of string): ITLSPeerCertificate;
begin
  Result := TTlsPeerCertificateData.Create(AVerified, ALeaf, AChain, ADns, AIp, AUri, AEmail);
end;
end.
