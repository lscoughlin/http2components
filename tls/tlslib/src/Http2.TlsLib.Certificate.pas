{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, certificate, metadata
notes:
  - This unit creates copied certificate metadata for the TlsLib provider.
---
}
unit Http2.TlsLib.Certificate;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity;

function TlsLibCertificateSummary(const ADer: TBytes): TTlsCertificateSummary;
procedure TlsLibCertificateNames(const ADer: TBytes; out ADns, AIp, AUri,
  AEmail: TArray<string>);

implementation

uses
  Rtti, TlpDefaultCryptoProvider, TlpDefaultPkixProvider,
  TlpIPkixProvider, TlpICryptoProvider, TlpCryptoDomainTypes,
  ClpIX509Certificate, ClpX509CertificateParser, ClpX509Asn1Objects,
  ClpCryptoLibTypes, ClpEncoders;

procedure AddString(var A: TArray<string>; const V: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := V;
end;

function NormalizeDistinguishedName(const AValue: string): string;
const HexDigits = '0123456789ABCDEF';
var Input, Part: TBytes; Parts: TArray<TBytes>; I, StartAt, SlashRun, J: Integer;
begin
  Input := TEncoding.UTF8.GetBytes(AValue);
  Parts := nil;
  StartAt := 0;
  SlashRun := 0;
  for I := 0 to Length(Input) do
  begin
    if (I = Length(Input)) or ((Input[I] = Ord(',')) and ((SlashRun mod 2) = 0)) then
    begin
      SetLength(Part, I - StartAt);
      if Length(Part) > 0 then Move(Input[StartAt], Part[0], Length(Part));
      SetLength(Parts, Length(Parts) + 1);
      Parts[High(Parts)] := Part;
      StartAt := I + 1;
    end;
    if (I < Length(Input)) and (Input[I] = Ord('\')) then Inc(SlashRun)
    else SlashRun := 0;
  end;
  Result := '';
  for I := High(Parts) downto 0 do
  begin
    if I < High(Parts) then Result := Result + ',';
    for J := 0 to High(Parts[I]) do
      if Parts[I][J] >= $80 then
        Result := Result + '\' + HexDigits[(Parts[I][J] shr 4) + 1] +
          HexDigits[(Parts[I][J] and $0F) + 1]
      else Result := Result + Chr(Parts[I][J]);
  end;
end;

function HexBytes(const AData: TBytes; const AUpper: Boolean): string;
const Digits: array[Boolean] of string = ('0123456789abcdef', '0123456789ABCDEF');
var I: Integer;
begin
  Result := '';
  for I := 0 to High(AData) do
    Result := Result + Digits[AUpper][AData[I] shr 4 + 1] + Digits[AUpper][AData[I] and $0F + 1];
end;

function TlsLibCertificateSummary(const ADer: TBytes): TTlsCertificateSummary;
var
  Inspector: IInspectedCertificate;
  Parser: TX509CertificateParser;
  Cert: IX509Certificate;
  Hash: IHash;
  Digest: TBytes;
  Encoded: string;
  I: Integer;
begin
  Result := Default(TTlsCertificateSummary);
  Inspector := TDefaultPkixProvider.Shared.Certificates.Parse(ADer);
  if not Inspector.PeerInfo(Result.Subject, Result.Issuer, Result.CommonName,
    Result.Serial) then
    raise ETlsContextError.Create('TlsLib could not read certificate identity metadata');
  Result.Subject := NormalizeDistinguishedName(Result.Subject);
  Result.Issuer := NormalizeDistinguishedName(Result.Issuer);
  Result.Serial := UpperCase(Result.Serial);
  Hash := TDefaultCryptoProvider.Shared.Primitives.CreateHash(THashAlgorithm.SHA_256);
  Hash.Update(ADer, 0, Length(ADer));
  Digest := Hash.DoFinal;
  Result.FingerprintSha256 := HexBytes(Digest, False);
  Parser := TX509CertificateParser.Create;
  try
    Cert := Parser.ReadCertificate(ADer);
    Result.NotBeforeUtc := Cert.NotBefore;
    Result.NotAfterUtc := Cert.NotAfter;
  finally
    Parser.Free;
  end;
  Encoded := TBase64Encoder.Encode(ADer);
  Result.Pem := '-----BEGIN CERTIFICATE-----' + #10;
  I := 1;
  while I <= Length(Encoded) do
  begin
    Result.Pem := Result.Pem + Copy(Encoded, I, 64) + #10;
    Inc(I, 64);
  end;
  Result.Pem := Result.Pem + '-----END CERTIFICATE-----' + #10;
end;

procedure TlsLibCertificateNames(const ADer: TBytes; out ADns, AIp, AUri,
  AEmail: TArray<string>);
var Parser: TX509CertificateParser; Cert: IX509Certificate;
  Rows: TCryptoLibGenericArray<TCryptoLibGenericArray<TValue>>; I: Integer;
  Tag: Integer; Value: string;
begin
  ADns := nil; AIp := nil; AUri := nil; AEmail := nil;
  Parser := TX509CertificateParser.Create;
  try
    Cert := Parser.ReadCertificate(ADer);
    Rows := Cert.GetSubjectAlternativeNames;
  finally
    Parser.Free;
  end;
  for I := 0 to High(Rows) do
    if Length(Rows[I]) >= 2 then
    begin
      Tag := Rows[I][0].AsInteger;
      Value := Rows[I][1].AsString;
      case Tag of
        TGeneralName.DnsName: AddString(ADns, Value);
        TGeneralName.IPAddress: AddString(AIp, Value);
        TGeneralName.UniformResourceIdentifier: AddString(AUri, Value);
        TGeneralName.Rfc822Name: AddString(AEmail, Value);
      end;
    end;
end;

end.
