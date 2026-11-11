{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, trust, tlslib
notes:
  - This unit loads immutable trust anchors and enforces root-only trust.
---
}
unit Http2.TlsLib.Trust;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils;

function TlsLibLoadTrustAnchors(const APaths: TArray<string>;
  const AAllowPartialChain: Boolean): TBytes;

implementation

uses
  Classes, TlpDefaultPkixProvider, TlpIPkixProvider, TlpPkixDomainTypes,
  ClpEncoders, Http2.Common.Tls.Types;

function AddBytes(const A, B: TBytes): TBytes;
var N: Integer;
begin
  N := Length(A);
  SetLength(Result, N + Length(B));
  if N > 0 then Move(A[0], Result[0], N);
  if Length(B) > 0 then Move(B[0], Result[N], Length(B));
end;

function ReadTrustFile(const APath: string): TBytes;
var S: TFileStream;
begin
  try
    S := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
      raise ETlsContextError.Create('TlsLib trust anchor file could not be opened');
  end;
  try
    if S.Size > 4 * 1024 * 1024 then
      raise ETlsContextError.Create('TlsLib trust anchor input exceeds the 4 MiB limit');
    SetLength(Result, S.Size);
    if Length(Result) > 0 then S.ReadBuffer(Result[0], Length(Result));
  finally
    S.Free;
  end;
end;

function EncodeCertificatePem(const ADer: TBytes): TBytes;
var S: string;
begin
  S := '-----BEGIN CERTIFICATE-----' + #10 +
    TBase64Encoder.Encode(ADer) + #10 + '-----END CERTIFICATE-----' + #10;
  Result := TEncoding.ASCII.GetBytes(S);
end;

function TlsLibLoadTrustAnchors(const APaths: TArray<string>;
  const AAllowPartialChain: Boolean): TBytes;
var
  I, RootCount: Integer;
  Data, CertData, Filtered: TBytes;
  Chain: TArray<TBytes>;
  Cert: IInspectedCertificate;
begin
  Data := nil;
  for I := 0 to High(APaths) do
  begin
    CertData := ReadTrustFile(APaths[I]);
    if Length(CertData) = 0 then
      raise ETlsContextError.Create('TlsLib trust anchor file is empty');
    if Length(CertData) > 4 * 1024 * 1024 - Length(Data) - 1 then
      raise ETlsContextError.Create('TlsLib trust anchors exceed the 4 MiB limit');
    Data := AddBytes(Data, CertData);
    Data := AddBytes(Data, TEncoding.ASCII.GetBytes(#10));
  end;
  if Length(Data) = 0 then Exit(Data);
  try
    Chain := TDefaultPkixProvider.Shared.Certificates.LoadChain(Data);
  except
    on E: ETlsContextError do raise;
    on E: Exception do
      raise ETlsContextError.Create('TlsLib trust anchor data is not a valid certificate bundle');
  end;
  if Length(Chain) = 0 then
    raise ETlsContextError.Create('TlsLib trust anchor data contains no certificates');
  if AAllowPartialChain then Exit(Data);
  RootCount := 0;
  Filtered := nil;
  for I := 0 to High(Chain) do
  begin
    Cert := TDefaultPkixProvider.Shared.Certificates.Parse(Chain[I]);
    if Cert.IsSelfSigned = TCertAnswer.Yes then
    begin
      Inc(RootCount);
      Filtered := AddBytes(Filtered, EncodeCertificatePem(Chain[I]));
    end;
  end;
  if RootCount = 0 then
    raise ETlsContextError.Create(
      'TlsLib requires a root trust anchor unless partial-chain policy is true');
  Result := Filtered;
end;

end.
