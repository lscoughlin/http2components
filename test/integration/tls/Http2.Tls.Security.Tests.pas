{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, security, integration
notes:
  - This program checks shared security behavior across TLS provider pairs.
---
}
program Http2TlsSecurityTests;
{$mode delphi}{$H+}{$interfaces com}

uses
  cthreads, SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Context, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Session, Http2.OpenSSL, Http2.OpenSSL.Identity,
  Http2.TlsLib, Http2.TlsLib.Identity;

type
  TProvider = (prOpenSSL, prTlsLib);
  THandshakeResult = record
    ClientInfo, ServerInfo: TTlsNegotiatedInfo;
  end;

const
  FixtureRoot = 'test/fixtures/client/certs/mtls';
  MaxPumpSteps = 12000;
  HandshakeMs = 4000;

var
  CaseCount: Integer;

function ProviderName(const AProvider: TProvider): string;
begin
  if AProvider = prOpenSSL then Result := 'O' else Result := 'T';
end;

function VersionName(const AVersion: TTlsVersion): string;
begin
  if AVersion = tls12 then Result := 'TLS12' else Result := 'TLS13';
end;

function AuthName(const AMode: TTlsClientAuthMode): string;
begin
  case AMode of
    tlsAuthNone: Result := 'none';
    tlsAuthRequest: Result := 'request';
    tlsAuthRequire: Result := 'require';
  else
    Result := 'unknown';
  end;
end;

function IdentityName(const AIdentityCase: Integer): string;
begin
  case AIdentityCase of
    0: Result := 'missing';
    1: Result := 'valid';
  else
    Result := 'invalid';
  end;
end;

function Fixture(const AName: string): string;
begin
  Result := ExpandFileName(FixtureRoot + '/' + AName);
  if not FileExists(Result) then
    Result := ExpandFileName(ExtractFilePath(ParamStr(0)) +
      '../../../../../' + FixtureRoot + '/' + AName);
  if not FileExists(Result) then
    raise Exception.Create('missing TLS fixture: ' + AName);
end;

function TlsFixture(const AName: string): string;
begin
  Result := ExpandFileName('test/tls/tlslib/fixtures/' + AName);
  if not FileExists(Result) then
    Result := ExpandFileName(ExtractFilePath(ParamStr(0)) +
      '../../../../../test/tls/tlslib/fixtures/' + AName);
  if not FileExists(Result) then
    raise Exception.Create('missing TLS fixture: ' + AName);
end;

function LoadIdentity(const AProvider: TProvider; const ACert, AKey: string): ITLSIdentity;
var CertPath, KeyPath: string;
begin
  if Copy(ACert, 1, 4) = 'tls:' then
  begin
    CertPath := TlsFixture(Copy(ACert, 5, MaxInt));
    KeyPath := TlsFixture(Copy(AKey, 5, MaxInt));
  end
  else
  begin
    CertPath := Fixture(ACert);
    KeyPath := Fixture(AKey);
  end;
  if AProvider = prOpenSSL then
    Result := TOpenSSLIdentity.FromPemFiles(CertPath, KeyPath)
  else
    Result := TTlsLibIdentity.FromPemFiles(CertPath, KeyPath);
end;

function ClientContext(const AProvider: TProvider;
  const APolicy: TTlsClientPolicy): ITLSContext;
begin
  if AProvider = prOpenSSL then
    Result := TOpenSSLTlsContextFactory.Create.WithClientPolicy(APolicy)
      .WithHandshakeTimeoutMs(HandshakeMs).Build
  else
    Result := TTlsLibContextFactory.Create.WithClientPolicy(APolicy)
      .WithHandshakeTimeoutMs(HandshakeMs).Build;
end;

function ServerContext(const AProvider: TProvider;
  const APolicy: TTlsServerPolicy): ITLSContext;
begin
  if AProvider = prOpenSSL then
    Result := TOpenSSLTlsContextFactory.Create.WithServerPolicy(APolicy)
      .WithHandshakeTimeoutMs(HandshakeMs).Build
  else
    Result := TTlsLibContextFactory.Create.WithServerPolicy(APolicy)
      .WithHandshakeTimeoutMs(HandshakeMs).Build;
end;

procedure Transfer(const AFrom, ATo: ITLSSession; var AQueue: TBytes);
var N, Fed: SizeInt;
begin
  if Length(AQueue) = 0 then
  begin
    SetLength(AQueue, 13);
    N := AFrom.DrainEncrypted(AQueue, 0, Length(AQueue));
    if N <= 0 then begin AQueue := nil; Exit; end;
    SetLength(AQueue, N);
  end;
  Fed := ATo.FeedEncrypted(AQueue, 0, Length(AQueue));
  if Fed > 0 then Delete(AQueue, 0, Fed);
end;

function Handshake(const AClientContext, AServerContext: ITLSContext;
  const AClientOptions: TTlsClientSessionOptions;
  const AServerOptions: TTlsServerSessionOptions;
  out AResult: THandshakeResult): Boolean;
var C, S: ITLSSession; CO: TTlsClientSessionOptions;
  SO: TTlsServerSessionOptions; StartMs: Int64; I: Integer;
  CQ, SQ: TBytes;
begin
  AResult := Default(THandshakeResult);
  StartMs := GetTickCount64;
  CO := AClientOptions; SO := AServerOptions;
  CO.HandshakeStartMs := StartMs; SO.HandshakeStartMs := StartMs;
  CO.HandshakeDeadlineMs := StartMs + HandshakeMs;
  SO.HandshakeDeadlineMs := StartMs + HandshakeMs;
  C := AClientContext.CreateClientSession(CO);
  S := AServerContext.CreateServerSession(SO);
  Result := False;
  try
    for I := 1 to MaxPumpSteps do
    begin
      Transfer(C, S, CQ); Transfer(S, C, SQ);
      C.Advance(GetTickCount64); S.Advance(GetTickCount64);
      if (C.State = tssOpen) and (S.State = tssOpen) then
      begin
        AResult.ClientInfo := C.NegotiatedInfo;
        AResult.ServerInfo := S.NegotiatedInfo;
        Exit(True);
      end;
      if (C.State in [tssFailed, tssClosed]) or
         (S.State in [tssFailed, tssClosed]) or
         (GetTickCount64 >= StartMs + HandshakeMs) then Exit(False);
    end;
  finally
    C.Abort; S.Abort;
  end;
end;

procedure Verify(const AValue: Boolean; const ACaseId: string);
begin
  if not AValue then raise Exception.Create('failed case ' + ACaseId);
  Inc(CaseCount);
  WriteLn('PASS ', ACaseId);
  Flush(Output);
end;

procedure RunPair(const AClientProvider, AServerProvider: TProvider);
var Pair, Name: string; ClientIdentity, ServerIdentity, InvalidIdentity,
  ExpiredIdentity: ITLSIdentity; CP: TTlsClientPolicy; SP: TTlsServerPolicy;
  CC, SC: ITLSContext; CO: TTlsClientSessionOptions;
  SO: TTlsServerSessionOptions; H: THandshakeResult; V: TTlsVersion;
  Mode: TTlsClientAuthMode; IdentityCase: Integer; Ok: Boolean;
  ClientPeer, ServerPeer: ITLSPeerCertificate;
begin
  Pair := ProviderName(AClientProvider) + '/' + ProviderName(AServerProvider);
  ClientIdentity := LoadIdentity(AClientProvider, 'client-chain.pem', 'client.key');
  ServerIdentity := LoadIdentity(AServerProvider, 'server.crt', 'server.key');
  InvalidIdentity := LoadIdentity(AClientProvider, 'other-client.crt', 'other-client.key');
  ExpiredIdentity := LoadIdentity(AServerProvider, 'tls:expired-server.crt',
    'tls:server-intermediate.key');

  for V := Low(TTlsVersion) to High(TTlsVersion) do
  begin
    Name := Pair + '/A05/trusted/' + VersionName(V);
    CP := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Fixture('ca.crt')])
      .WithVersions(V, V);
    SP := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity)
      .WithVersions(V, V);
    CC := ClientContext(AClientProvider, CP);
    SC := ServerContext(AServerProvider, SP);
    CO := Default(TTlsClientSessionOptions); CO.HostName := 'localhost';
    CO := CO.WithAlpns(['h2', 'http/1.1']);
    SO := Default(TTlsServerSessionOptions).WithAlpns(['h2', 'http/1.1']);
    Ok := Handshake(CC, SC, CO, SO, H);
    ClientPeer := H.ClientInfo.PeerCertificate;
    Verify(Ok and (H.ClientInfo.Version = V) and (H.ServerInfo.Version = V) and
      (H.ClientInfo.CipherName <> '') and (H.ServerInfo.CipherName <> '') and
      (H.ClientInfo.SelectedAlpn = 'h2') and (H.ServerInfo.SelectedAlpn = 'h2') and
      (ClientPeer <> nil) and ClientPeer.Verified and
      (Length(ClientPeer.Chain) > 0), Name + '/metadata-alpn-h2');

    CP := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Fixture('other-ca.crt')])
      .WithVersions(V, V);
    SP := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity)
      .WithTrustAnchors([Fixture('ca.crt')]).WithVersions(V, V);
    CC := ClientContext(AClientProvider, CP);
    SC := ServerContext(AServerProvider, SP);
    Verify(not Handshake(CC, SC, CO, SO, H), Pair + '/A05/unknown-ca/' + VersionName(V));
    CP := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Fixture('ca.crt')])
      .WithVersions(V, V);
    SC := ServerContext(AServerProvider,
      TTlsServerPolicy.SecureDefault.WithServerIdentity(ExpiredIdentity).WithVersions(V, V));
    CC := ClientContext(AClientProvider, CP);
    Verify(not Handshake(CC, SC, CO, SO, H), Pair + '/A05/expired/' + VersionName(V));
    SC := ServerContext(AServerProvider,
      TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity).WithVersions(V, V));
    CO.HostName := 'wrong.example';
    Verify(not Handshake(CC, SC, CO, SO, H), Pair + '/A05/dns-mismatch/' + VersionName(V));
    CO.HostName := '127.0.0.1';
    Verify(Handshake(CC, SC, CO, SO, H) and
      (H.ClientInfo.PeerCertificate <> nil) and
      H.ClientInfo.PeerCertificate.Verified,
      Pair + '/A05/ip-san/' + VersionName(V));
    CO.HostName := '127.0.0.2';
    Verify(not Handshake(CC, SC, CO, SO, H), Pair + '/A05/ip-mismatch/' + VersionName(V));
    CO.HostName := 'localhost';
    CO := CO.WithAlpns(['h2', 'http/1.1']);
    SO := Default(TTlsServerSessionOptions).WithAlpns(['http/1.1', 'h2']);
    Verify(Handshake(CC, SC, CO, SO, H) and (H.ClientInfo.SelectedAlpn = 'h2'),
      Pair + '/A07/preference-h2/' + VersionName(V));
    SO := Default(TTlsServerSessionOptions).WithAlpns(['http/1.1']);
    Verify(Handshake(CC, SC, CO, SO, H) and
      (H.ClientInfo.SelectedAlpn = 'http/1.1'),
      Pair + '/A07/http11/' + VersionName(V));
    SO := Default(TTlsServerSessionOptions);
    Verify(Handshake(CC, SC, CO, SO, H) and
      (H.ClientInfo.SelectedAlpn = ''), Pair + '/A07/no-alpn/' + VersionName(V));

    for Mode := Low(TTlsClientAuthMode) to High(TTlsClientAuthMode) do
    begin
      SP := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity)
        .WithTrustAnchors([Fixture('ca.crt')]).WithClientAuth(Mode).WithVersions(V, V);
      SC := ServerContext(AServerProvider, SP);
      CP := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Fixture('ca.crt')]
        ).WithDefaultIdentity(ClientIdentity).WithVersions(V, V);
      CC := ClientContext(AClientProvider, CP);
      CO := Default(TTlsClientSessionOptions); CO.HostName := 'localhost';
      SO := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
      for IdentityCase := 0 to 2 do
      begin
        CO.IdentitySelection := tisExplicit;
        if IdentityCase = 0 then CO.Identity := nil
        else if IdentityCase = 1 then CO.Identity := ClientIdentity
        else CO.Identity := InvalidIdentity;
        Ok := Handshake(CC, SC, CO, SO, H);
        ClientPeer := H.ClientInfo.PeerCertificate;
        ServerPeer := H.ServerInfo.PeerCertificate;
        Name := Pair + '/A06/' + VersionName(V) + '/' + AuthName(Mode) + '/' +
          IdentityName(IdentityCase);
        case Mode of
          tlsAuthNone:
            Verify(Ok and (ServerPeer = nil), Name + '/none');
          tlsAuthRequest:
            if IdentityCase = 0 then
              Verify(Ok and (ServerPeer = nil), Name + '/optional-missing')
            else if IdentityCase = 1 then
              Verify(Ok and (ServerPeer <> nil) and ServerPeer.Verified and
                (ServerPeer.Leaf.CommonName <> ''), Name + '/optional-verified')
            else
              Verify(not Ok or (ServerPeer = nil) or not ServerPeer.Verified,
                Name + '/optional-invalid-untrusted');
          tlsAuthRequire:
            if IdentityCase = 1 then
              Verify(Ok and (ServerPeer <> nil) and ServerPeer.Verified and
                (ServerPeer.Leaf.CommonName <> ''), Name + '/required-verified')
            else
              Verify(not Ok, Name + '/required-rejected');
        end;
        { The client always verifies the server in this matrix. }
        if Ok then
          Verify((ClientPeer <> nil) and ClientPeer.Verified,
            Name + '/client-server-peer-verified');
      end;
    end;
  end;
end;

begin
  try
    RunPair(prOpenSSL, prOpenSSL);
    RunPair(prOpenSSL, prTlsLib);
    RunPair(prTlsLib, prOpenSSL);
    RunPair(prTlsLib, prTlsLib);
    WriteLn('PASS total ', CaseCount, ' TLS security assertions');
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
