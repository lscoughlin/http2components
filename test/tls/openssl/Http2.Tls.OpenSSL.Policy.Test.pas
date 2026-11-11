{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, policy, regression
notes:
  - this checks OpenSSL role policy validation and copy behavior
---
}
unit Http2.Tls.OpenSSL.Policy.Test;
{$mode delphi}{$H+}
interface
uses Http2.Common.Tls.Identity;
function RunOpenSSLPolicyRegressionTests(const AServerIdentity: ITLSIdentity;
  const AServerCertificate, AServerKey, AWrongKey: string): Integer;
implementation
uses SysUtils, Classes, Http2.Common.Tls.Types, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Context, Http2.OpenSSL, Http2.OpenSSL.Identity;

procedure AssertCase(const AId: string; const ACondition: Boolean;
  var ACount: Integer);
begin
  if not ACondition then
    raise Exception.Create('FAIL ' + AId);
  Inc(ACount);
  WriteLn('PASS ', AId);
end;

function BuildClient(const APolicy: TTlsClientPolicy): ITLSContext;
begin
  Result := TOpenSSLTlsContextFactory.Create.WithClientPolicy(APolicy).Build;
end;

function BuildServer(const APolicy: TTlsServerPolicy): ITLSContext;
begin
  Result := TOpenSSLTlsContextFactory.Create.WithServerPolicy(APolicy).Build;
end;

function ReadFileBytes(const APath: string): TBytes;
var Stream: TFileStream;
begin
  Result := nil;
  Stream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Length(Result) > 0 then Stream.ReadBuffer(Result[0], Length(Result));
  finally
    Stream.Free;
  end;
end;

function RunOpenSSLPolicyRegressionTests(const AServerIdentity: ITLSIdentity;
  const AServerCertificate, AServerKey, AWrongKey: string): Integer;
var
  ClientPolicy, ClientCopy: TTlsClientPolicy;
  ServerPolicy, ServerCopy: TTlsServerPolicy;
  Anchors, ReturnedAnchors: TArray<string>;
  Raised: Boolean;
  MissingPath: string;
  MessageText: string;
  Context: ITLSContext;
  CertificateBytes, KeyBytes: TBytes;
  CombinedPath: string;
  CombinedStream: TFileStream;
  CombinedIdentity: ITLSIdentity;
begin
  Result := 0;
  ClientPolicy := TTlsClientPolicy.SecureDefault;
  ServerPolicy := TTlsServerPolicy.SecureDefault;
  AssertCase('openssl.policy.client_default_verifies_peer_and_name',
    ClientPolicy.VerifyPeer and ClientPolicy.VerifyHostname, Result);
  AssertCase('openssl.policy.client_system_trust_off_by_default',
    not ClientPolicy.UseSystemTrust, Result);
  AssertCase('openssl.policy.server_default_client_auth_none',
    ServerPolicy.ClientAuth = tlsAuthNone, Result);
  AssertCase('openssl.policy.server_default_tls12_tls13',
    (ServerPolicy.MinVersion = tls12) and (ServerPolicy.MaxVersion = tls13), Result);
  ServerPolicy := ServerPolicy.WithServerIdentity(AServerIdentity);
  ServerCopy := ServerPolicy.WithClientAuth(tlsAuthRequire);
  AssertCase('openssl.policy.server_policy_copy_isolated',
    (ServerPolicy.ClientAuth = tlsAuthNone) and
    (ServerCopy.ClientAuth = tlsAuthRequire), Result);

  SetLength(Anchors, 1);
  Anchors[0] := AServerCertificate;
  ClientPolicy := ClientPolicy.WithTrustAnchors(Anchors);
  Anchors[0] := 'changed-input.pem';
  ReturnedAnchors := ClientPolicy.TrustAnchors;
  AssertCase('openssl.policy.trust_anchor_input_is_copied',
    (Length(ReturnedAnchors) = 1) and (ReturnedAnchors[0] = AServerCertificate), Result);
  ReturnedAnchors[0] := 'changed-output.pem';
  AssertCase('openssl.policy.trust_anchor_output_is_copied',
    ClientPolicy.TrustAnchors[0] = AServerCertificate, Result);
  ClientCopy := ClientPolicy.WithVersions(tls13, tls13);
  AssertCase('openssl.policy.client_policy_copy_isolated',
    (ClientPolicy.MinVersion = tls12) and (ClientPolicy.MaxVersion = tls13) and
    (ClientCopy.MinVersion = tls13) and (ClientCopy.MaxVersion = tls13), Result);
  ServerCopy := ServerPolicy.WithVersions(tls13, tls13);
  AssertCase('openssl.policy.server_version_copy_isolated',
    (ServerPolicy.MinVersion = tls12) and (ServerPolicy.MaxVersion = tls13) and
    (ServerCopy.MinVersion = tls13) and (ServerCopy.MaxVersion = tls13), Result);

  Raised := False;
  try
    TOpenSSLTlsContextFactory.Create.WithServerPolicy(
      TTlsServerPolicy.SecureDefault).Build;
  except on ETlsContextError do Raised := True; end;
  AssertCase('openssl.policy.rejects_missing_server_identity', Raised, Result);

  Raised := False;
  try BuildClient(TTlsClientPolicy.SecureDefault.WithVersions(tls13, tls12));
  except on ETlsContextError do Raised := True; end;
  AssertCase('openssl.policy.rejects_reversed_client_version_range', Raised, Result);
  Raised := False;
  try BuildServer(TTlsServerPolicy.SecureDefault.WithServerIdentity(AServerIdentity)
    .WithVersions(tls13, tls12));
  except on ETlsContextError do Raised := True; end;
  AssertCase('openssl.policy.rejects_reversed_server_version_range', Raised, Result);

  Raised := False;
  try TTlsClientPolicy.SecureDefault.WithVerificationDepth(-1);
  except on ETlsContextError do Raised := True; end;
  AssertCase('openssl.policy.rejects_negative_verification_depth', Raised, Result);
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithVerificationDepth(0);
  AssertCase('openssl.policy.zero_verification_depth_is_explicit',
    ClientPolicy.HasVerificationDepth and (ClientPolicy.VerificationDepth = 0), Result);
  Context := BuildClient(ClientPolicy);
  AssertCase('openssl.policy.zero_verification_depth_builds', Context <> nil, Result);
  Context := nil;

  Context := BuildClient(TTlsClientPolicy.SecureDefault.WithSystemTrust(True));
  AssertCase('openssl.policy.system_trust_alone_builds_client', Context <> nil, Result);
  Context := nil;
  Context := BuildServer(TTlsServerPolicy.SecureDefault.WithServerIdentity(AServerIdentity)
    .WithClientAuth(tlsAuthRequest).WithSystemTrust(True));
  AssertCase('openssl.policy.system_trust_alone_builds_server', Context <> nil, Result);
  Context := nil;

  MissingPath := AServerCertificate + '.missing-ca.pem';
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([MissingPath]);
  Raised := False;
  MessageText := '';
  try BuildClient(ClientPolicy);
  except on E: ETlsContextError do begin Raised := True; MessageText := E.Message; end; end;
  AssertCase('openssl.policy.missing_ca_file_fails_build', Raised, Result);
  AssertCase('openssl.policy.missing_ca_file_is_reported',
    Pos(MissingPath, MessageText) > 0, Result);

  MissingPath := AServerCertificate + '.missing-server-ca.pem';
  Raised := False;
  MessageText := '';
  try BuildServer(TTlsServerPolicy.SecureDefault
      .WithServerIdentity(AServerIdentity).WithClientAuth(tlsAuthRequest)
      .WithTrustAnchors([MissingPath]));
  except on E: ETlsContextError do begin Raised := True; MessageText := E.Message; end; end;
  AssertCase('openssl.policy.missing_ca_file_fails_server_build', Raised, Result);
  AssertCase('openssl.policy.missing_server_ca_file_is_reported',
    Pos(MissingPath, MessageText) > 0, Result);

  MissingPath := AServerCertificate + '.missing-certificate.pem';
  Raised := False;
  MessageText := '';
  try TOpenSSLIdentity.FromPemFiles(MissingPath, AServerCertificate);
  except on E: ETlsContextError do begin Raised := True; MessageText := E.Message; end; end;
  AssertCase('openssl.policy.rejects_missing_certificate_file',
    Raised and (Pos(MissingPath, MessageText) > 0), Result);
  MissingPath := AServerCertificate + '.missing-key.pem';
  Raised := False;
  MessageText := '';
  try TOpenSSLIdentity.FromPemFiles(AServerCertificate, MissingPath);
  except on E: ETlsContextError do begin Raised := True; MessageText := E.Message; end; end;
  AssertCase('openssl.policy.rejects_missing_private_key_file',
    Raised and (Pos(MissingPath, MessageText) > 0), Result);
  Raised := False;
  try TOpenSSLIdentity.FromPemFiles(AServerCertificate, AWrongKey);
  except on ETlsContextError do Raised := True; end;
  AssertCase('openssl.identity.rejects_mismatched_key', Raised, Result);

  CertificateBytes := ReadFileBytes(AServerCertificate);
  KeyBytes := ReadFileBytes(AServerKey);
  CombinedPath := AServerCertificate + '.combined.pem';
  CombinedStream := TFileStream.Create(CombinedPath, fmCreate);
  try
    if Length(CertificateBytes) > 0 then
      CombinedStream.WriteBuffer(CertificateBytes[0], Length(CertificateBytes));
    if Length(KeyBytes) > 0 then
      CombinedStream.WriteBuffer(KeyBytes[0], Length(KeyBytes));
  finally
    CombinedStream.Free;
  end;
  try
    CombinedIdentity := TOpenSSLIdentity.FromPemFiles(CombinedPath, CombinedPath);
    Context := BuildServer(TTlsServerPolicy.SecureDefault
      .WithServerIdentity(CombinedIdentity));
    AssertCase('openssl.identity.combined_pem_file_succeeds',
      (Context <> nil) and (CombinedIdentity.Leaf.CommonName <> ''), Result);
  finally
    Context := nil;
    CombinedIdentity := nil;
    DeleteFile(CombinedPath);
  end;
end;

end.
