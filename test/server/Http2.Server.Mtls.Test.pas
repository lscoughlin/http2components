{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, peer identity, tls context, test
notes:
  - This unit checks common-context policy and copied verified peer identity.
---
}
unit Http2.Server.Mtls.Test;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, fpcunit, testregistry, Http2.Server.Config,
  Http2.Server.Seam,
  Http2.Server.Mtls.Types, Http2.Server.ClientCert,
  Http2.Common.Tls.Types, Http2.Common.Tls.Context,
  Http2.Common.Tls.Identity, Http2.Test.Tls.Fake;
type
  TUnusedHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;
  TMtlsContextTest = class(TTestCase)
  published
    procedure RequiredAuthenticationRejectsCleartext;
    procedure RequestedAuthenticationAllowsCleartext;
    procedure ClientOnlyContextIsRejected;
    procedure VerifiedPeerIdentityIsCopied;
    procedure UnverifiedPeerIdentityIsDropped;
  end;
implementation
function ProblemsText(const AProblems: TArray<string>): string;
var I: Integer;
begin
  Result := '';
  for I := 0 to High(AProblems) do
  begin
    if I > 0 then Result := Result + '; ';
    Result := Result + AProblems[I];
  end;
end;
procedure TUnusedHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
end;
procedure TMtlsContextTest.RequiredAuthenticationRejectsCleartext;
var C: ITLSContext; F: THttp2ServerFactory; P: TArray<string>; I: Integer;
    Found: Boolean;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthRequire, 2500);
  F := THttp2ServerFactory.Create.WithHandler(TUnusedHandler.Create)
    .WithTlsContext(C).WithClearTextAllowed(True);
  AssertFalse('required client authentication rejects cleartext', F.Validate(P));
  Found := False;
  for I := 0 to High(P) do
    if Pos('required client certificate mode needs cleartext off', P[I]) > 0 then
      Found := True;
  AssertTrue('the policy error is reported', Found);
end;

procedure TMtlsContextTest.RequestedAuthenticationAllowsCleartext;
var C: ITLSContext; F: THttp2ServerFactory; P: TArray<string>; Valid: Boolean;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthRequest, 2500);
  F := THttp2ServerFactory.Create.WithHandler(TUnusedHandler.Create)
    .WithTlsContext(C).WithClearTextAllowed(True);
  Valid := F.Validate(P);
  AssertTrue('requested client authentication allows cleartext: ' +
    ProblemsText(P), Valid);
end;

procedure TMtlsContextTest.ClientOnlyContextIsRejected;
var C: ITLSContext; F: THttp2ServerFactory; P: TArray<string>; I: Integer;
    Found: Boolean;
begin
  C := TTlsFakeContext.Create([trClient], tlsAuthNone, 2500);
  F := THttp2ServerFactory.Create.WithTlsContext(C);
  AssertFalse('a client-only context cannot serve', F.Validate(P));
  Found := False;
  for I := 0 to High(P) do
    if Pos('no server role', P[I]) > 0 then Found := True;
  AssertTrue('the missing server role is reported', Found);
end;

procedure TMtlsContextTest.VerifiedPeerIdentityIsCopied;
var Leaf: TTlsCertificateSummary; Peer: ITLSPeerCertificate;
    Identity, SubjectIdentity, PlainIdentity: IClientCertificate;
    Dns: TArray<string>;
begin
  Leaf.Subject := 'CN=alice,O=Example';
  Leaf.Issuer := 'CN=Test Root CA';
  Leaf.CommonName := 'alice';
  Leaf.Serial := 'A1';
  Leaf.FingerprintSha256 := StringOfChar('a', 64);
  Leaf.Pem := '-----BEGIN CERTIFICATE-----';
  Leaf.NotBeforeUtc := EncodeDate(2026, 1, 1);
  Leaf.NotAfterUtc := EncodeDate(2027, 1, 1);
  Peer := NewTlsPeerCertificate(True, Leaf, [], ['alice.example'], [],
    ['spiffe://example.org/alice'], ['alice@example.org']);
  Identity := ClientCertificateFromPeer(Peer, ccpCommonName);
  SubjectIdentity := ClientCertificateFromPeer(Peer, ccpSubjectDn);
  PlainIdentity := ClientCertificateFromPeer(Peer, ccpNone);
  Peer := nil;
  AssertTrue('the verified identity remains available', Identity <> nil);
  AssertEquals('the subject is copied', Leaf.Subject, Identity.SubjectDn);
  AssertEquals('the issuer is copied', Leaf.Issuer, Identity.IssuerDn);
  AssertEquals('the principal follows the server setting', 'alice',
    Identity.PrincipalText);
  AssertEquals('subject principal selection is preserved', Leaf.Subject,
    SubjectIdentity.PrincipalText);
  AssertEquals('no principal selection stays empty', '',
    PlainIdentity.PrincipalText);
  AssertEquals('the fingerprint is copied', Leaf.FingerprintSha256,
    Identity.Sha256);
  Dns := Identity.SanDns;
  AssertEquals(1, Length(Dns));
  AssertEquals('alice.example', Dns[0]);
  AssertEquals('the URI identity is copied', 'spiffe://example.org/alice',
    Identity.SanUri[0]);
  AssertEquals('the email identity is copied', 'alice@example.org',
    Identity.SanEmail[0]);
  AssertEquals('the leaf PEM is copied', Leaf.Pem, Identity.Pem);
end;

procedure TMtlsContextTest.UnverifiedPeerIdentityIsDropped;
var Leaf: TTlsCertificateSummary; Peer: ITLSPeerCertificate;
begin
  Leaf := Default(TTlsCertificateSummary);
  Peer := NewTlsPeerCertificate(False, Leaf, [], [], [], [], []);
  AssertTrue('unverified metadata does not become an identity',
    ClientCertificateFromPeer(Peer, ccpCommonName) = nil);
end;

initialization
  RegisterTest(TMtlsContextTest);
end.
