{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, tlslib, tests
notes:
  - This program checks TlsLib policy and buffer sessions.
---
}
program Http2TlsLibTests;

{$mode delphi}{$H+}{$interfaces com}

uses
  cthreads, SysUtils, Classes, SyncObjs,
  Http2.Common.Tls.Types, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Identity, Http2.Common.Tls.Context,
  Http2.Common.Tls.Session, Http2.TlsLib,
  Http2.TlsLib.Diagnostics,
  Http2.Test.Tls.SessionContract;

type
  TForeignTlsIdentity = class(TInterfacedObject, ITLSIdentity)
  public
    function BackendName: string;
    function Leaf: TTlsCertificateSummary;
    function Formats: TTlsIdentityFormats;
  end;

  TTlsLibSessionCreateThread = class(TThread)
  private
    FContext: ITLSContext;
    FGate: TEvent;
    FClientOptions: TTlsClientSessionOptions;
    FServerOptions: TTlsServerSessionOptions;
    FClient: Boolean;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AContext: ITLSContext; const AGate: TEvent;
      const AClientOptions: TTlsClientSessionOptions;
      const AServerOptions: TTlsServerSessionOptions; const AClient: Boolean);
    property Error: string read FError;
  end;

var TestStartMs: QWord;

function TForeignTlsIdentity.BackendName: string; begin Result := 'TlsLib'; end;
function TForeignTlsIdentity.Leaf: TTlsCertificateSummary; begin Result := Default(TTlsCertificateSummary); end;
function TForeignTlsIdentity.Formats: TTlsIdentityFormats; begin Result := [tifPem]; end;

constructor TTlsLibSessionCreateThread.Create(const AContext: ITLSContext;
  const AGate: TEvent; const AClientOptions: TTlsClientSessionOptions;
  const AServerOptions: TTlsServerSessionOptions; const AClient: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FContext := AContext;
  FGate := AGate;
  FClientOptions := AClientOptions;
  FServerOptions := AServerOptions;
  FClient := AClient;
end;

procedure TTlsLibSessionCreateThread.Execute;
var I: Integer; Session: ITLSSession;
begin
  try
    if FGate.WaitFor(5000) <> wrSignaled then
      raise Exception.Create('start gate timed out');
    for I := 1 to 5 do
    begin
      if FClient then Session := FContext.CreateClientSession(FClientOptions)
      else Session := FContext.CreateServerSession(FServerOptions);
      if Session.State <> tssHandshaking then
        raise Exception.Create('new session has an invalid initial state');
      Session.Abort;
      Session := nil;
    end;
  except
    on E: Exception do FError := E.ClassName + ': ' + E.Message;
  end;
end;

function ProjectPath(const ARelative: string): string;
begin
  Result := ExpandFileName(ExtractFileDir(ParamStr(0)) +
    '/../../../../../' + ARelative);
end;

procedure Check(const ACondition: Boolean; const AName: string);
begin
  if not ACondition then raise Exception.Create('failed: ' + AName);
  WriteLn('PASS ', AName, ' +', GetTickCount64 - TestStartMs, ' ms');
  Flush(Output);
end;

function MakeContext(const AClient: TTlsClientPolicy;
  const AServer: TTlsServerPolicy): ITLSContext;
var F: TTlsLibContextFactory;
begin
  F := TTlsLibContextFactory.Create.WithClientPolicy(AClient)
    .WithServerPolicy(AServer).WithHandshakeTimeoutMs(4000);
  Result := F.Build;
end;

procedure MoveCipher(const AFrom, ATo: ITLSSession; var ABuffered: TBytes);
var N, Fed: SizeInt;
begin
  if Length(ABuffered) = 0 then
  begin
    SetLength(ABuffered, 7);
    N := AFrom.DrainEncrypted(ABuffered, 0, Length(ABuffered));
    if N <= 0 then begin ABuffered := nil; Exit; end;
    SetLength(ABuffered, N);
  end;
  Fed := ATo.FeedEncrypted(ABuffered, 0, Length(ABuffered));
  if Fed > 0 then Delete(ABuffered, 0, Fed);
end;

function TryHandshake(const AContext: ITLSContext;
  const AClientOptions: TTlsClientSessionOptions;
  const AServerOptions: TTlsServerSessionOptions;
  out APeer: ITLSPeerCertificate; out AVersion: TTlsVersion;
  out ACipherName: string): Boolean;
var C, S: ITLSSession; ClientOptions, ServerOptions: TTlsClientSessionOptions;
  ServerCopy: TTlsServerSessionOptions; StartMs: Int64; I: Integer;
  P: TTlsProgress; CToS, SToC: TBytes;
begin
  APeer := nil;
  ClientOptions := AClientOptions;
  ServerCopy := AServerOptions;
  StartMs := GetTickCount64;
  ClientOptions.HandshakeStartMs := StartMs;
  ClientOptions.HandshakeDeadlineMs := StartMs + 4000;
  ServerCopy.HandshakeStartMs := StartMs;
  ServerCopy.HandshakeDeadlineMs := StartMs + 4000;
  C := AContext.CreateClientSession(ClientOptions);
  S := AContext.CreateServerSession(ServerCopy);
  Result := False;
  try
    try
      for I := 1 to 10000 do
      begin
        MoveCipher(C, S, CToS);
        MoveCipher(S, C, SToC);
        P := C.Advance(GetTickCount64);
        P := S.Advance(GetTickCount64);
        if (C.State = tssOpen) and (S.State = tssOpen) then
        begin
          APeer := C.NegotiatedInfo.PeerCertificate;
          AVersion := C.NegotiatedInfo.Version;
          ACipherName := C.NegotiatedInfo.CipherName;
          Exit(True);
        end;
        if (C.State in [tssFailed, tssClosed]) or (S.State in [tssFailed, tssClosed]) then
          Exit(False);
        if GetTickCount64 >= StartMs + 4000 then Exit(False);
      end;
    except
      on E: ETlsSessionError do Exit(False);
    end;
  finally
    C.Abort;
    S.Abort;
  end;
end;

procedure Run;
var
  Root, Cert, Key: string;
  Identity: ITLSIdentity;
  EscapedIdentity: ITLSIdentity;
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  Factory: TTlsLibContextFactory;
  Context: ITLSContext;
  ClientOptions: TTlsClientSessionOptions;
  InvalidClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  Cap: TTlsCapabilities;
  Leaf: TTlsCertificateSummary;
  Peer: ITLSPeerCertificate;
  Version: TTlsVersion;
  CipherName: string;
  ClientIdentity, OtherClientIdentity,
    ExpiredServerIdentity: ITLSIdentity;
  PartialServerIdentity: ITLSIdentity;
  FullChainServerIdentity: ITLSIdentity;
  OtherRoot, InvalidAnchor: string;
  Ok: Boolean;
  LoaderFailed: Boolean;
  ForeignIdentity: ITLSIdentity;
  Failed: Boolean;
  Count: Integer;
  BeforeCounts, LiveCounts: TTlsLibResourceCounts;
  TemporaryIdentity: ITLSIdentity;
  TemporaryContext: ITLSContext;
  TemporaryClient, TemporaryServer: ITLSSession;
  LifecycleIndex: Integer;
  AlpnIndex: Integer;
  OversizedAlpn: TArray<string>;
  FailureInput, FailureOutput: TBytes;
  FailureCount: SizeInt;
  FailureSession: ITLSSession;
  StartGate: TEvent;
  ClientCreateThread, ServerCreateThread: TTlsLibSessionCreateThread;
begin
  TestStartMs := GetTickCount64;
  Root := ProjectPath('test/fixtures/client/certs/mtls');
  Cert := Root + '/server.crt';
  Key := Root + '/server.key';
  Identity := TTlsLibIdentity.FromPemFiles(Cert, Key);
  Check((Identity.BackendName = 'TlsLib') and (Identity.Formats = [tifPem]),
    'PEM identity loader');
  EscapedIdentity := TTlsLibIdentity.FromPemFiles(
    ProjectPath('test/tls/tlslib/fixtures/escaped-name.crt'),
    ProjectPath('test/tls/tlslib/fixtures/escaped-name.key'));
  WriteLn('RFC4514 subject: ', EscapedIdentity.Leaf.Subject);
  Flush(Output);
  Check((EscapedIdentity.Leaf.Subject =
    'UID=svc+CN=Zo\C3\AB Example,O=TLS\, Inc.,OU=TLS\\,C=NL') and
    (EscapedIdentity.Leaf.Issuer = EscapedIdentity.Leaf.Subject) and
    (EscapedIdentity.Leaf.CommonName = 'Zoë Example'),
    'RFC 4514 metadata normalizes RDN order and UTF-8 escaping');
  Leaf := Identity.Leaf;
  Check((Leaf.Subject <> '') and (Leaf.Issuer <> '') and (Leaf.CommonName <> '') and
    (Leaf.Serial <> '') and (Length(Leaf.FingerprintSha256) = 64) and
    (Leaf.FingerprintSha256 = LowerCase(Leaf.FingerprintSha256)) and
    (Pos(':', Leaf.Serial) = 0) and (Leaf.Serial = UpperCase(Leaf.Serial)) and
    (Pos('-----BEGIN CERTIFICATE-----', Leaf.Pem) = 1) and
    (Leaf.NotBeforeUtc > 0) and (Leaf.NotAfterUtc > Leaf.NotBeforeUtc),
    'identity certificate metadata');
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Root + '/ca.crt']);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity);
  Factory := TTlsLibContextFactory.Create.WithClientPolicy(ClientPolicy)
    .WithServerPolicy(ServerPolicy);
  Context := Factory.Build;
  Cap := Context.Capabilities;
  Check((Cap.Roles = [trClient, trServer]) and (Cap.Versions = [tls12, tls13]) and
    Cap.PartialChain and not Cap.SystemTrust and not Cap.VerificationDepth and
    not Cap.SessionResumption and not Cap.EarlyData and
    not (tifDer in Cap.IdentityFormats), 'provider capability report');

  Failed := False;
  try
    Factory.WithClientPolicy(ClientPolicy.WithSystemTrust(True)).Build;
  except
    on E: ETlsContextError do Failed := Pos('system trust', LowerCase(E.Message)) > 0;
  end;
  Check(Failed, 'system trust rejected before session creation');
  Failed := False;
  try
    Factory.WithClientPolicy(ClientPolicy.WithVerificationDepth(4)).Build;
  except
    on E: ETlsContextError do Failed := Pos('depth', LowerCase(E.Message)) > 0;
  end;
  Check(Failed, 'verification depth rejected before session creation');
  Failed := False;
  try
    Factory.WithClientPolicy(ClientPolicy.WithVerificationDepth(0)).Build;
  except
    on E: ETlsContextError do Failed := Pos('depth', LowerCase(E.Message)) > 0;
  end;
  Check(Failed, 'explicit zero verification depth rejected');
  ClientPolicy.VerifyPeer := False;
  Failed := False;
  try
    Factory.WithClientPolicy(ClientPolicy).Build;
  except on E: ETlsContextError do
    Failed := Pos('hostname verification', LowerCase(E.Message)) > 0; end;
  Check(Failed, 'hostname verification without peer verification rejected at Build');
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Root + '/ca.crt']);

  InvalidAnchor := ProjectPath('test/tls/tlslib/fixtures/invalid-anchor.txt');
  Failed := False;
  try
    Factory.WithClientPolicy(TTlsClientPolicy.SecureDefault
      .WithTrustAnchors([InvalidAnchor])).Build;
  except on E: ETlsContextError do
    Failed := Pos('certificate bundle', LowerCase(E.Message)) > 0; end;
  Check(Failed, 'malformed strict trust anchor fails during Build');
  Failed := False;
  try
    Factory.WithClientPolicy(TTlsClientPolicy.SecureDefault
      .WithTrustAnchors([InvalidAnchor]).WithPartialChain(True)).Build;
  except on E: ETlsContextError do
    Failed := Pos('certificate bundle', LowerCase(E.Message)) > 0; end;
  Check(Failed, 'malformed partial-chain trust anchor fails during Build');
  Inc(Count, 2);

  LoaderFailed := True;
  try
    TTlsLibIdentity.FromPemFiles(Root + '/client.crt',
      Root + '/client-encrypted.key', 'mtls-test-pass');
    LoaderFailed := False;
  except on E: ETlsContextError do ; end;
  Check(not LoaderFailed, 'encrypted PEM identity accepts its passphrase');
  LoaderFailed := False;
  try
    TTlsLibIdentity.FromPemFiles(Root + '/client.crt',
      Root + '/client-encrypted.key', 'wrong-passphrase');
  except on E: ETlsContextError do LoaderFailed := True; end;
  Check(LoaderFailed, 'encrypted PEM identity rejects a wrong passphrase');
  LoaderFailed := True;
  try
    TTlsLibIdentity.FromPkcs12File(Root + '/client-chain.p12', 'mtls-test-pass');
    LoaderFailed := False;
  except on E: ETlsContextError do ; end;
  Check(not LoaderFailed, 'PKCS#12 identity loader');
  LoaderFailed := False;
  try
    TTlsLibIdentity.FromPkcs12File(Root + '/client-chain.p12', 'wrong-passphrase');
  except on E: ETlsContextError do LoaderFailed := True; end;
  Check(LoaderFailed, 'PKCS#12 rejects a wrong passphrase');
  LoaderFailed := False;
  try
    TTlsLibIdentity.FromPemFiles(Root + '/client.crt', Root + '/client2.key');
  except on E: ETlsContextError do LoaderFailed := True; end;
  Check(LoaderFailed, 'mismatched certificate and private key rejected');
  ForeignIdentity := TForeignTlsIdentity.Create;
  Failed := False;
  try
    Factory.WithClientPolicy(ClientPolicy.WithDefaultIdentity(ForeignIdentity)).Build;
  except on E: ETlsContextError do Failed := Pos('another provider', E.Message) > 0; end;
  Check(Failed, 'foreign-provider identity rejected during Build');
  ClientOptions := Default(TTlsClientSessionOptions);
  ClientOptions.HostName := 'localhost';
  ClientOptions := ClientOptions.WithAlpns(['h2']);
  ServerOptions := Default(TTlsServerSessionOptions);
  ServerOptions := ServerOptions.WithAlpns(['h2']);
  Count := RunTlsSessionContract(Context, ClientOptions, ServerOptions);
  Inc(Count, 10);

  FailureSession := Context.CreateServerSession(ServerOptions);
  SetLength(FailureInput, 6);
  FailureInput[0] := $FF; FailureInput[1] := $03; FailureInput[2] := $03;
  FailureInput[3] := $00; FailureInput[4] := $01; FailureInput[5] := $00;
  Failed := False;
  try FailureSession.FeedEncrypted(FailureInput, 0, Length(FailureInput));
  except on E: ETlsSessionError do Failed := E.Category = tecAlert; end;
  Check(Failed and (FailureSession.State = tssFailed),
    'fatal TLS record sets failed state and raises alert category');
  SetLength(FailureOutput, 1024);
  FailureCount := FailureSession.DrainEncrypted(FailureOutput, 0, Length(FailureOutput));
  Check(FailureCount > 0, 'fatal TLS alert remains drainable after failure');
  Failed := False;
  try FailureSession.Advance(GetTickCount64);
  except on E: ETlsSessionError do Failed := E.Category = tecAlert; end;
  Check(Failed, 'repeat Advance raises a fresh fatal session error');
  FailureSession.Abort;
  FailureSession := nil;
  Inc(Count, 3);

  InvalidClientOptions := ClientOptions;
  InvalidClientOptions.HandshakeStartMs := 0;
  InvalidClientOptions.HandshakeDeadlineMs := 1;
  FailureSession := Context.CreateClientSession(InvalidClientOptions);
  Failed := False;
  try FailureSession.Advance(1);
  except on E: ETlsSessionError do Failed := E.Category = tecTimeout; end;
  Check(Failed and (FailureSession.State = tssFailed),
    'absolute handshake deadline fails even when monotonic start is zero');
  FailureCount := FailureSession.DrainEncrypted(FailureOutput, 0, Length(FailureOutput));
  Check(FailureCount > 0, 'deadline failure preserves queued handshake output');
  Failed := False;
  try FailureSession.Advance(2);
  except on E: ETlsSessionError do Failed := E.Category = tecTimeout; end;
  Check(Failed, 'repeat deadline advancement raises a fresh error');
  FailureSession.Abort;
  FailureSession := nil;
  Inc(Count, 3);

  InvalidClientOptions := ClientOptions.WithAlpns(['']);
  Failed := False;
  try Context.CreateClientSession(InvalidClientOptions);
  except on E: ETlsContextError do Failed := Pos('empty', LowerCase(E.Message)) > 0; end;
  Check(Failed, 'empty ALPN value rejected before engine creation');
  InvalidClientOptions := ClientOptions.WithAlpns([StringOfChar('x', 256)]);
  Failed := False;
  try Context.CreateClientSession(InvalidClientOptions);
  except on E: ETlsContextError do Failed := Pos('255', E.Message) > 0; end;
  Check(Failed, 'ALPN protocol over 255 bytes rejected');
  SetLength(OversizedAlpn, 65);
  for AlpnIndex := 0 to High(OversizedAlpn) do
    OversizedAlpn[AlpnIndex] := StringOfChar('x', 255);
  InvalidClientOptions := ClientOptions.WithAlpns(OversizedAlpn);
  Failed := False;
  try Context.CreateClientSession(InvalidClientOptions);
  except on E: ETlsContextError do Failed := Pos('16 kib', LowerCase(E.Message)) > 0; end;
  Check(Failed, 'oversized aggregate ALPN rejected');
  Inc(Count, 3);

  BeforeCounts := TlsLibActiveResourceCounts;
  TemporaryIdentity := TTlsLibIdentity.FromPemFiles(Cert, Key);
  LiveCounts := TlsLibActiveResourceCounts;
  Check(LiveCounts.Credentials = BeforeCounts.Credentials + 1,
    'credential lifecycle increments provider count');
  TemporaryIdentity := nil;
  Check(TlsLibActiveResourceCounts.Credentials = BeforeCounts.Credentials,
    'credential lifecycle returns to baseline');
  Inc(Count, 2);
  BeforeCounts := TlsLibActiveResourceCounts;
  for LifecycleIndex := 1 to 10 do
  begin
    TemporaryContext := MakeContext(ClientPolicy, ServerPolicy);
    TemporaryClient := TemporaryContext.CreateClientSession(ClientOptions);
    TemporaryServer := TemporaryContext.CreateServerSession(ServerOptions);
    TemporaryContext := nil;
    LiveCounts := TlsLibActiveResourceCounts;
    Check((LiveCounts.Contexts = BeforeCounts.Contexts + 1) and
      (LiveCounts.Sessions = BeforeCounts.Sessions + 2) and
      (LiveCounts.Engines = BeforeCounts.Engines + 2),
      'sessions retain context and engine resources');
    TemporaryClient.Abort;
    TemporaryServer.Abort;
    TemporaryClient := nil;
    TemporaryServer := nil;
    LiveCounts := TlsLibActiveResourceCounts;
    Check((LiveCounts.Contexts = BeforeCounts.Contexts) and
      (LiveCounts.Sessions = BeforeCounts.Sessions) and
      (LiveCounts.Engines = BeforeCounts.Engines),
      'ten-cycle context and session counts return to baseline');
  end;
  Inc(Count, 20);
  BeforeCounts := TlsLibActiveResourceCounts;
  StartGate := TEvent.Create(nil, True, False, '');
  ClientCreateThread := TTlsLibSessionCreateThread.Create(Context, StartGate,
    ClientOptions, ServerOptions, True);
  ServerCreateThread := TTlsLibSessionCreateThread.Create(Context, StartGate,
    ClientOptions, ServerOptions, False);
  try
    ClientCreateThread.Start;
    ServerCreateThread.Start;
    StartGate.SetEvent;
    ClientCreateThread.WaitFor;
    ServerCreateThread.WaitFor;
    Check((ClientCreateThread.Error = '') and (ServerCreateThread.Error = ''),
      'concurrent client and server sessions share one context');
    LiveCounts := TlsLibActiveResourceCounts;
    Check((LiveCounts.Contexts = BeforeCounts.Contexts) and
      (LiveCounts.Sessions = BeforeCounts.Sessions) and
      (LiveCounts.Engines = BeforeCounts.Engines),
      'concurrent session lifecycle returns resource counts to baseline');
  finally
    ClientCreateThread.Free;
    ServerCreateThread.Free;
    StartGate.Free;
  end;
  Inc(Count, 2);

  Ok := TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName);
  Check(Ok and (Version = tls13), 'TLS 1.3 version and DNS SNI');
  Check(Pos('TLS_', CipherName) = 1, 'TLS 1.3 negotiated standard cipher name');
  Check((Peer <> nil) and Peer.Verified and (Length(Peer.Chain) >= 1) and
    (Length(Peer.DnsNames) > 0) and (Peer.DnsNames[0] = 'localhost') and
    (Length(Peer.IpAddresses) >= 1), 'peer SAN and chain metadata');
  Inc(Count, 3);

  ClientPolicy := ClientPolicy.WithVersions(tls12, tls12);
  ServerPolicy := ServerPolicy.WithVersions(tls12, tls12);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Ok := TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName);
  Check(Ok and (Version = tls12), 'TLS 1.2 explicit version');
  Check(Pos('TLS_', CipherName) = 1, 'TLS 1.2 negotiated standard cipher name');
  Inc(Count, 2);

  ClientPolicy := TTlsClientPolicy.SecureDefault;
  ClientPolicy.VerifyPeer := False;
  ClientPolicy.VerifyHostname := False;
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Ok := TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName);
  Check(Ok and (Peer <> nil) and not Peer.Verified,
    'insecure client keeps presented peer metadata marked unverified');
  Inc(Count);

  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([Root + '/ca.crt']);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity);
  ClientIdentity := TTlsLibIdentity.FromPemFiles(Root + '/client-chain.pem', Root + '/client.key');
  OtherClientIdentity := TTlsLibIdentity.FromPemFiles(Root + '/other-client.crt',
    Root + '/other-client.key');
  ExpiredServerIdentity := TTlsLibIdentity.FromPemFiles(
    ProjectPath('test/tls/tlslib/fixtures/expired-server.crt'),
    ProjectPath('test/tls/tlslib/fixtures/server-intermediate.key'));
  ClientPolicy := ClientPolicy.WithDefaultIdentity(ClientIdentity);
  ClientOptions.IdentitySelection := tisExplicit;
  ClientOptions.Identity := ClientIdentity;
  ServerPolicy := ServerPolicy.WithTrustAnchors([Root + '/ca.crt']);
  ServerPolicy := ServerPolicy.WithClientAuth(tlsAuthNone);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS none accepts valid configured identity');
  Inc(Count);
  ClientOptions.Identity := nil;
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS none accepts absent client identity');
  Inc(Count);
  ServerPolicy := ServerPolicy.WithClientAuth(tlsAuthRequest);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS request accepts absent client identity');
  Inc(Count);
  ClientOptions.Identity := ClientIdentity;
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS request accepts trusted client identity');
  ClientOptions.Identity := OtherClientIdentity;
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS request rejects invalid presented client identity');
  ClientOptions.Identity := nil;
  Inc(Count, 2);
  ServerPolicy := ServerPolicy.WithClientAuth(tlsAuthRequire);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS require rejects absent client identity');
  Inc(Count);
  ClientOptions.Identity := ClientIdentity;
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'mTLS require accepts trusted identity');
  Inc(Count);
  ClientOptions.Identity := nil;
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'explicit nil identity fails required mTLS');
  ClientOptions.Identity := OtherClientIdentity;
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'untrusted client identity fails required mTLS');
  Inc(Count, 2);
  ClientOptions.Identity := ClientIdentity;

  ClientOptions.HostName := 'wrong.example';
  Context := MakeContext(ClientPolicy, ServerPolicy.WithClientAuth(tlsAuthNone));
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'DNS identity mismatch fails');
  ClientOptions.HostName := '127.0.0.1';
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'IP SAN identity succeeds without SNI');
  ClientOptions.HostName := '127.0.0.2';
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'IP identity mismatch fails');
  ClientOptions.HostName := 'localhost';
  ClientOptions.ServerName := 'wrong.example';
  Ok := False;
  try
    TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName);
  except on E: ETlsContextError do Ok := Pos('SNI', E.Message) > 0; end;
  Check(Ok, 'unsupported separate SNI and hostname fails before transport');
  ClientOptions.ServerName := '';
  Inc(Count, 4);

  PartialServerIdentity := TTlsLibIdentity.FromPemFiles(
    ProjectPath('test/tls/tlslib/fixtures/server-intermediate.crt'),
    ProjectPath('test/tls/tlslib/fixtures/server-intermediate.key'));
  FullChainServerIdentity := TTlsLibIdentity.FromPemFiles(
    ProjectPath('test/tls/tlslib/fixtures/server-intermediate-chain.crt'),
    ProjectPath('test/tls/tlslib/fixtures/server-intermediate.key'));
  ClientOptions.Identity := ClientIdentity;
  ClientPolicy := TTlsClientPolicy.SecureDefault
    .WithTrustAnchors([Root + '/intermediate.crt'])
    .WithPartialChain(True).WithDefaultIdentity(ClientIdentity);
  ServerPolicy := TTlsServerPolicy.SecureDefault
    .WithServerIdentity(PartialServerIdentity)
    .WithTrustAnchors([Root + '/intermediate.crt'])
    .WithPartialChain(True).WithClientAuth(tlsAuthRequire);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Ok := TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName);
  Check(Ok and (Peer <> nil) and (Length(Peer.Chain) >= 1),
    'partial-chain trust on client and server roles');
  Check((Length(Peer.DnsNames) > 0) and (Length(Peer.IpAddresses) > 0) and
    (Length(Peer.UriNames) > 0) and (Length(Peer.EmailAddresses) > 0),
    'DNS, IP, URI, and email SAN metadata');
  Inc(Count, 2);
  ClientPolicy := ClientPolicy.WithTrustAnchors(
    [Root + '/intermediate.crt', Root + '/ca.crt']).WithPartialChain(False);
  ServerPolicy := ServerPolicy.WithTrustAnchors([Root + '/ca.crt'])
    .WithServerIdentity(FullChainServerIdentity).WithPartialChain(False)
    .WithClientAuth(tlsAuthRequire);
  Context := MakeContext(ClientPolicy, ServerPolicy);
  Check(TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'root trust succeeds with intermediate in strict trust bundle');
  Inc(Count);
  Ok := False;
  try
    MakeContext(ClientPolicy.WithTrustAnchors([Root + '/intermediate.crt'])
      .WithPartialChain(False), ServerPolicy);
  except on E: ETlsContextError do
    Ok := Pos('partial-chain', LowerCase(E.Message)) > 0; end;
  Check(Ok, 'intermediate anchor rejected without partial-chain policy');
  Inc(Count);

  OtherRoot := Root + '/other-ca.crt';
  Context := MakeContext(ClientPolicy.WithTrustAnchors([OtherRoot]),
    ServerPolicy.WithClientAuth(tlsAuthNone));
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'unknown server authority fails');
  Context := MakeContext(ClientPolicy, ServerPolicy.WithServerIdentity(ExpiredServerIdentity)
    .WithClientAuth(tlsAuthNone));
  Check(not TryHandshake(Context, ClientOptions, ServerOptions, Peer, Version, CipherName),
    'expired server certificate fails');
  Inc(Count, 2);

  WriteLn('PASS ', Count, ' cases');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
