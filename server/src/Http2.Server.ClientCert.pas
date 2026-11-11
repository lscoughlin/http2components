{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, identity, tls, x509
notes:
  - This unit holds the identity of a verified client certificate. The record
    is immutable once built, so one reference is shared by every stream of a
    connection and by a WebSocket session without a lock.
  - Peer data comes from verified, provider-neutral TLS session metadata.
---
}
/// The identity of a verified TLS client certificate
unit Http2.Server.ClientCert;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils,
  Http2.Common.Tls.Identity,
  Http2.Server.Mtls.Types;

type
  /// the identity of a client certificate; read-only
  IClientCertificate = interface
    ['{7E1F0C11-00E1-4A11-9C72-000000002001}']
    function GetSubjectDn: string;
    function GetIssuerDn: string;
    function GetCommonName: string;
    function GetSerialHex: string;
    function GetSha256: string;
    function GetSanDns: TArray<string>;
    function GetSanUri: TArray<string>;
    function GetSanEmail: TArray<string>;
    function GetNotBefore: TDateTime;
    function GetNotAfter: TDateTime;
    function GetPem: string;
    function GetPrincipalText: string;
    /// the subject distinguished name as text
    property SubjectDn: string read GetSubjectDn;
    /// the issuer distinguished name as text
    property IssuerDn: string read GetIssuerDn;
    /// the first common name of the subject, or empty
    property CommonName: string read GetCommonName;
    /// the serial number in upper-case hexadecimal
    property SerialHex: string read GetSerialHex;
    /// the SHA-256 fingerprint of the certificate in lower-case hexadecimal
    property Sha256: string read GetSha256;
    /// the DNS names of the subject alternative name extension
    property SanDns: TArray<string> read GetSanDns;
    /// the URI names of the subject alternative name extension
    property SanUri: TArray<string> read GetSanUri;
    /// the e-mail names of the subject alternative name extension
    property SanEmail: TArray<string> read GetSanEmail;
    /// the start of the validity period, in UTC
    property NotBefore: TDateTime read GetNotBefore;
    /// the end of the validity period, in UTC
    property NotAfter: TDateTime read GetNotAfter;
    /// the leaf certificate in PEM form
    property Pem: string read GetPem;
    /// the text that the principal setting made of this certificate
    property PrincipalText: string read GetPrincipalText;
  end;

  /// what the connection events use to give an exchange its client certificate
  IClientCertificateSink = interface
    ['{7E1F0C11-00E2-4A11-9C72-000000002002}']
    procedure SetClientCertificate(const AValue: IClientCertificate);
  end;

  /// the plain values of a client certificate
  TClientCertificateData = record
    SubjectDn, IssuerDn, CommonName, SerialHex, Sha256, Pem: string;
    SanDns, SanUri, SanEmail: TArray<string>;
    NotBefore, NotAfter: TDateTime;
    PrincipalText: string;
  end;

/// the identity object of plain values
function NewClientCertificate(
  const AData: TClientCertificateData): IClientCertificate;

/// the identity of a verified peer certificate summary
function ClientCertificateFromPeer(const APeer: ITLSPeerCertificate;
  const APrincipal: TClientCertPrincipal): IClientCertificate;

implementation

type
  TClientCertificateImpl = class(TInterfacedObject, IClientCertificate)
  private
    FData: TClientCertificateData;
  public
    constructor Create(const AData: TClientCertificateData);
    function GetSubjectDn: string;
    function GetIssuerDn: string;
    function GetCommonName: string;
    function GetSerialHex: string;
    function GetSha256: string;
    function GetSanDns: TArray<string>;
    function GetSanUri: TArray<string>;
    function GetSanEmail: TArray<string>;
    function GetNotBefore: TDateTime;
    function GetNotAfter: TDateTime;
    function GetPem: string;
    function GetPrincipalText: string;
  end;

constructor TClientCertificateImpl.Create(const AData: TClientCertificateData);
begin
  inherited Create;
  FData := AData;
end;

function TClientCertificateImpl.GetSubjectDn: string;
begin
  Result := FData.SubjectDn;
end;

function TClientCertificateImpl.GetIssuerDn: string;
begin
  Result := FData.IssuerDn;
end;

function TClientCertificateImpl.GetCommonName: string;
begin
  Result := FData.CommonName;
end;

function TClientCertificateImpl.GetSerialHex: string;
begin
  Result := FData.SerialHex;
end;

function TClientCertificateImpl.GetSha256: string;
begin
  Result := FData.Sha256;
end;

function TClientCertificateImpl.GetSanDns: TArray<string>;
begin
  Result := Copy(FData.SanDns);
end;

function TClientCertificateImpl.GetSanUri: TArray<string>;
begin
  Result := Copy(FData.SanUri);
end;

function TClientCertificateImpl.GetSanEmail: TArray<string>;
begin
  Result := Copy(FData.SanEmail);
end;

function TClientCertificateImpl.GetNotBefore: TDateTime;
begin
  Result := FData.NotBefore;
end;

function TClientCertificateImpl.GetNotAfter: TDateTime;
begin
  Result := FData.NotAfter;
end;

function TClientCertificateImpl.GetPem: string;
begin
  Result := FData.Pem;
end;

function TClientCertificateImpl.GetPrincipalText: string;
begin
  Result := FData.PrincipalText;
end;

function NewClientCertificate(
  const AData: TClientCertificateData): IClientCertificate;
begin
  Result := TClientCertificateImpl.Create(AData);
end;

function ClientCertificateFromPeer(const APeer: ITLSPeerCertificate;
  const APrincipal: TClientCertPrincipal): IClientCertificate;
var
  D: TClientCertificateData;
  Leaf: TTlsCertificateSummary;
begin
  Result := nil;
  if (APeer = nil) or not APeer.Verified then
    Exit;
  Leaf := APeer.Leaf;
  D.SubjectDn := Leaf.Subject;
  D.IssuerDn := Leaf.Issuer;
  D.CommonName := Leaf.CommonName;
  D.SerialHex := Leaf.Serial;
  D.Sha256 := Leaf.FingerprintSha256;
  D.Pem := Leaf.Pem;
  D.NotBefore := Leaf.NotBeforeUtc;
  D.NotAfter := Leaf.NotAfterUtc;
  D.SanDns := APeer.DnsNames;
  D.SanUri := APeer.UriNames;
  D.SanEmail := APeer.EmailAddresses;
  D.PrincipalText := PrincipalTextFor(APrincipal, D.SubjectDn, D.CommonName);
  Result := NewClientCertificate(D);
end;

end.
