{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, tests
notes:
  - this runner creates short-lived test credentials under the binary output directory
---
}
program Http2TlsOpenSSLTests;
{$mode delphi}{$H+}
uses cthreads, SysUtils, Classes, Process, Http2.Common.Tls.Types,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Context,
  Http2.Common.Tls.Session, Http2.Common.Tls.Identity,
  Http2.OpenSSL, Http2.OpenSSL.Identity, Http2.OpenSSL.Live.Resources,
  Http2.Test.Tls.SessionContract;

type
  TCreateRole = (crClient, crServer);
  TSessionCreateThread = class(TThread)
  private
    FContext: ITLSContext;
    FRole: TCreateRole;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AContext: ITLSContext; const ARole: TCreateRole);
    property ErrorText: string read FError;
  end;

var
  Cases: Integer;
  FixtureDir, RootCert, RootKey, ServerCert, ServerKey, ClientCert,
  ClientKey, EncryptedClientKey, ClientP12, ExpiredServerCert,
  ExpiredServerKey: string;
  RootPem, ServerPem, ClientPem, ClientKeyPem, EncryptedPem, P12Data: TBytes;
  ClientIdentity, ServerIdentity, P12Identity: ITLSIdentity;
  Context: ITLSContext;

procedure Check(const AValue: Boolean; const AMessage: string);
begin
  if not AValue then raise Exception.Create(AMessage);
  Inc(Cases);
end;

constructor TSessionCreateThread.Create(const AContext: ITLSContext; const ARole: TCreateRole);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FContext := AContext; FRole := ARole;
  Start;
end;

procedure TSessionCreateThread.Execute;
var I: Integer; Session: ITLSSession; C: TTlsClientSessionOptions; S: TTlsServerSessionOptions;
begin
  try
    C := Default(TTlsClientSessionOptions); C.HostName := 'localhost'; C := C.WithAlpns(['h2']);
    S := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
    for I := 1 to 10 do
    begin
      if FRole = crClient then Session := FContext.CreateClientSession(C)
      else Session := FContext.CreateServerSession(S);
      Session.Abort; Session := nil;
    end;
  except on E: Exception do FError := E.ClassName + ': ' + E.Message; end;
end;

procedure DebugStep(const AMessage: string);
begin
  if GetEnvironmentVariable('TLS_DEBUG') <> '' then
  begin
    WriteLn(StdErr, 'STEP: ', AMessage);
    Flush(StdErr);
  end;
end;

procedure CheckWrongPassword;
var Raised: Boolean;
begin
  Raised := False;
  try TOpenSSLIdentity.FromPem(ClientPem, EncryptedPem, 'wrongpass');
  except on ETlsContextError do Raised := True; end;
  Check(Raised, 'encrypted PEM rejects an incorrect passphrase');
end;

procedure CheckMismatchedKey;
var Raised: Boolean;
begin
  Raised := False;
  try TOpenSSLIdentity.FromPem(ServerPem, ClientKeyPem);
  except on ETlsContextError do Raised := True; end;
  Check(Raised, 'PEM rejects a mismatched key');
end;

function ExistingFixture(const AName: string): string;
var P: string;
begin
  P := ExpandFileName('test/fixtures/client/certs/mtls/' + AName);
  if FileExists(P) then Exit(P);
  P := ExpandFileName(ExtractFilePath(ParamStr(0)) +
    '../../../../../test/fixtures/client/certs/mtls/' + AName);
  if FileExists(P) then Exit(P);
  raise Exception.Create('TLS identity fixture is missing: ' + AName);
end;

function ReadBytes(const AFile: string): TBytes; forward;

function ExistingBytes(const AName: string): TBytes;
begin
  Result := ReadBytes(ExistingFixture(AName));
end;

function LoadFailure(const ACertificate, AKey, APassphrase: string): string;
begin
  Result := '';
  try
    TOpenSSLIdentity.FromPemFiles(ACertificate, AKey, APassphrase);
  except
    on E: ETlsContextError do Result := E.Message;
  end;
end;

procedure CheckLegacyIdentityInputs;
var Id: ITLSIdentity; Cert, Key, Bad: TBytes; Msg, TextInput: string; I: Integer;
  Chain: TArray<TTlsCertificateSummary>;
  Secret: string;
begin
  Secret := 'S3cr3t-Wr0ng-Pass-Phrase';
  Id := TOpenSSLIdentity.FromPemFiles(ExistingFixture('client.crt'),
    ExistingFixture('client.key'));
  Check((Pos('mtls client', Id.Leaf.Subject) > 0) and
    (Length(Id.Leaf.FingerprintSha256) = 64) and
    (Id.Leaf.NotAfterUtc > Now), 'legacy PEM subject, fingerprint, and expiry');
  Id := TOpenSSLIdentity.FromPemFiles(ExistingFixture('client-chain.pem'),
    ExistingFixture('client.key'));
  Chain := OpenSSLIdentityChainMetadata(Id);
  Check((Length(Chain) = 1) and (Pos('mtls test intermediate', Chain[0].Subject) > 0),
    'PEM chain preserves intermediate order');
  Id := TOpenSSLIdentity.FromPem(ExistingBytes('client-chain.pem'),
    ExistingBytes('client.key'));
  Check(Id.Leaf.CommonName <> '', 'PEM memory loading');
  Id := TOpenSSLIdentity.FromPemFiles(ExistingFixture('client.crt'),
    ExistingFixture('client-encrypted.key'), 'mtls-test-pass');
  Check(Id.Leaf.CommonName <> '', 'encrypted PEM key accepts its passphrase');
  Check(LoadFailure(ExistingFixture('client.crt'),
    ExistingFixture('client-encrypted.key'), Secret) <> '',
    'encrypted PEM key rejects a wrong passphrase');
  Check(LoadFailure(ExistingFixture('client.crt'),
    ExistingFixture('client-encrypted.key'), '') <> '',
    'encrypted PEM key rejects a missing passphrase without prompting');
  Check(Pos('does not match', LoadFailure(ExistingFixture('client.crt'),
    ExistingFixture('other-client.key'), '')) > 0, 'PEM rejects a mismatched key');
  Cert := ExistingBytes('client.crt');
  Key := ExistingBytes('client.key');
  Bad := Copy(Cert, 0, Length(Cert) div 2);
  Msg := '';
  try TOpenSSLIdentity.FromPem(Bad, Key); except on E: ETlsContextError do Msg := E.Message; end;
  Check(Msg <> '', 'PEM rejects a truncated certificate');
  Bad := Copy(Key, 0, Length(Key) div 2);
  Msg := '';
  try TOpenSSLIdentity.FromPem(Cert, Bad); except on E: ETlsContextError do Msg := E.Message; end;
  Check(Msg <> '', 'PEM rejects a truncated private key');
  Msg := '';
  try TOpenSSLIdentity.FromPem(nil, Key); except on E: ETlsContextError do Msg := E.Message; end;
  Check(Pos('empty', Msg) > 0, 'PEM rejects empty certificate input');
  Msg := '';
  TextInput := 'not a certificate';
  SetLength(Bad, Length(TextInput));
  Move(TextInput[1], Bad[0], Length(Bad));
  try TOpenSSLIdentity.FromPem(Bad, Key); except on E: ETlsContextError do Msg := E.Message; end;
  Check(Msg <> '', 'PEM rejects text without a PEM block');
  Msg := LoadFailure(ExtractFileDir(ExistingFixture('client.crt')) + '/missing.crt', ExistingFixture('client.key'), '');
  Check((Msg <> '') and (Pos('missing.crt', Msg) > 0), 'PEM file error names the missing file');
  Id := TOpenSSLIdentity.FromPemFiles(ExistingFixture('expired.crt'),
    ExistingFixture('expired.key'));
  Check(Id.Leaf.NotAfterUtc < Now, 'expired PEM loads and reports its past expiry');
  Id := TOpenSSLIdentity.FromPkcs12File(ExistingFixture('client.p12'), 'mtls-test-pass');
  Chain := OpenSSLIdentityChainMetadata(Id);
  Check((Id.Leaf.CommonName <> '') and (Length(Chain) = 0),
    'PKCS#12 without a chain loads');
  Id := TOpenSSLIdentity.FromPkcs12File(ExistingFixture('client-chain.p12'), 'mtls-test-pass');
  Chain := OpenSSLIdentityChainMetadata(Id);
  Check((Id.Leaf.CommonName <> '') and (Length(Chain) = 1) and
    (Pos('mtls test intermediate', Chain[0].Subject) > 0), 'PKCS#12 chain is preserved');
  Check(TOpenSSLIdentity.FromPkcs12(ExistingBytes('client-chain.p12'), 'mtls-test-pass') <> nil,
    'PKCS#12 memory loading');
  Msg := '';
  try TOpenSSLIdentity.FromPkcs12File(ExistingFixture('client.p12'), Secret); except on E: ETlsContextError do Msg := E.Message; end;
  Check((Msg <> '') and (Pos(Secret, Msg) = 0), 'PKCS#12 rejects wrong password without exposing it');
  Msg := '';
  SetLength(Bad, 3); Bad[0] := 1; Bad[1] := 2; Bad[2] := 3;
  try TOpenSSLIdentity.FromPkcs12(Bad, ''); except on E: ETlsContextError do Msg := E.Message; end;
  Check(Msg <> '', 'PKCS#12 rejects malformed data');
  for I := 0 to 2 do
  begin
    case I of
      0: Msg := LoadFailure(ExistingFixture('client.crt'), ExistingFixture('client-encrypted.key'), Secret);
      1: Msg := LoadFailure(ExistingFixture('client.crt'), ExistingFixture('other-client.key'), Secret);
      2: Msg := LoadFailure(ExtractFileDir(ExistingFixture('client.crt')) + '/missing.crt', ExistingFixture('client.key'), Secret);
    end;
    Check((Msg <> '') and (Pos(Secret, Msg) = 0), 'PEM loader error excludes passphrase');
  end;
end;

function ReadBytes(const AFile: string): TBytes;
var S: TFileStream;
begin
  Result := nil;
  S := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try SetLength(Result, S.Size); if Length(Result) > 0 then S.ReadBuffer(Result[0], Length(Result));
  finally S.Free; end;
end;

procedure RunOpenSsl(const AArgs: array of string);
var P: TProcess; I, N: Integer; OutputText, ArgText, LogText: string;
  L: TextFile; RedactNext: Boolean;
begin
  P := TProcess.Create(nil);
  ArgText := ''; RedactNext := False;
  try
    P.Executable := 'openssl';
    for I := 0 to High(AArgs) do
    begin
      P.Parameters.Add(AArgs[I]);
      if ArgText <> '' then ArgText := ArgText + ' ';
      if RedactNext then ArgText := ArgText + '<redacted>'
      else ArgText := ArgText + AArgs[I];
      RedactNext := AArgs[I] = '-passout';
    end;
    P.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut, poNoConsole];
    P.Execute;
    N := P.Output.NumBytesAvailable;
    SetLength(OutputText, N);
    if N > 0 then P.Output.ReadBuffer(OutputText[1], N);
    LogText := 'args: openssl ' + ArgText + LineEnding +
      'exit: ' + IntToStr(P.ExitStatus) + LineEnding +
      'output: ' + Trim(OutputText) + LineEnding;
    AssignFile(L, FixtureDir + '/setup.log');
    if FileExists(FixtureDir + '/setup.log') then Append(L) else Rewrite(L);
    try Write(L, LogText); finally CloseFile(L); end;
    if P.ExitStatus <> 0 then
      raise Exception.CreateFmt('openssl fixture command failed (%d): %s',
        [P.ExitStatus, Trim(OutputText)]);
  finally P.Free; end;
end;

procedure MakeFixtures;
var F: TextFile; SR: TSearchRec; CaConfig, CaDir, CaIndex, CaSerial: string;
begin
  DebugStep('fixture creation');
  FixtureDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'fixtures';
  ForceDirectories(FixtureDir);
  if FindFirst(FixtureDir + '/*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') and
        ((SR.Attr and faDirectory) = 0) then DeleteFile(FixtureDir + '/' + SR.Name);
    until FindNext(SR) <> 0;
  finally FindClose(SR); end;
  RootCert := FixtureDir + '/root.pem'; RootKey := FixtureDir + '/root.key';
  ServerCert := FixtureDir + '/server.pem'; ServerKey := FixtureDir + '/server.key';
  ClientCert := FixtureDir + '/client.pem'; ClientKey := FixtureDir + '/client.key';
  ExpiredServerCert := FixtureDir + '/expired-server.pem';
  ExpiredServerKey := FixtureDir + '/expired-server.key';
  EncryptedClientKey := FixtureDir + '/client-encrypted.key';
  ClientP12 := FixtureDir + '/client.p12';
  RunOpenSsl(['req','-quiet','-x509','-newkey','rsa:2048','-nodes','-days','2',
    '-subj','/CN=TLS05-root','-addext','basicConstraints=critical,CA:TRUE',
    '-addext','keyUsage=critical,keyCertSign,cRLSign','-keyout',RootKey,'-out',RootCert]);
  AssignFile(F, FixtureDir + '/server.ext'); Rewrite(F);
  WriteLn(F, 'basicConstraints=critical,CA:FALSE');
  WriteLn(F, 'keyUsage=critical,digitalSignature,keyEncipherment');
  WriteLn(F, 'extendedKeyUsage=serverAuth');
  WriteLn(F, 'subjectAltName=DNS:localhost,IP:127.0.0.1'); CloseFile(F);
  AssignFile(F, FixtureDir + '/client.ext'); Rewrite(F);
  WriteLn(F, 'basicConstraints=critical,CA:FALSE');
  WriteLn(F, 'keyUsage=critical,digitalSignature,keyEncipherment');
  WriteLn(F, 'extendedKeyUsage=clientAuth');
  WriteLn(F, 'subjectAltName=DNS:client.local'); CloseFile(F);
  RunOpenSsl(['req','-quiet','-new','-newkey','rsa:2048','-nodes','-subj','/CN=localhost',
    '-keyout',ServerKey,'-out',FixtureDir + '/server.csr']);
  RunOpenSsl(['x509','-req','-in',FixtureDir + '/server.csr','-CA',RootCert,
    '-CAkey',RootKey,'-CAcreateserial','-days','2','-sha256','-extfile',FixtureDir + '/server.ext',
    '-out',ServerCert]);
  RunOpenSsl(['req','-quiet','-new','-newkey','rsa:2048','-nodes','-subj','/CN=client.local',
    '-keyout',ClientKey,'-out',FixtureDir + '/client.csr']);
  RunOpenSsl(['x509','-req','-in',FixtureDir + '/client.csr','-CA',RootCert,
    '-CAkey',RootKey,'-CAserial',FixtureDir + '/root.srl','-days','2','-sha256','-extfile',FixtureDir + '/client.ext',
    '-out',ClientCert]);
  RunOpenSsl(['pkcs8','-topk8','-in',ClientKey,'-out',EncryptedClientKey,
    '-passout','pass:fixturepass']);
  RunOpenSsl(['pkcs12','-export','-in',ClientCert,'-inkey',ClientKey,'-certfile',RootCert,
    '-out',ClientP12,'-passout','pass:fixturepass']);
  ExpiredServerKey := ServerKey;
  RunOpenSsl(['req','-quiet','-new','-key',ServerKey,'-subj','/CN=localhost',
    '-out',FixtureDir + '/expired-server.csr']);
  CaDir := FixtureDir + '/newcerts'; ForceDirectories(CaDir);
  CaIndex := FixtureDir + '/index.txt'; AssignFile(F, CaIndex); Rewrite(F); CloseFile(F);
  CaSerial := FixtureDir + '/serial'; AssignFile(F, CaSerial); Rewrite(F);
  WriteLn(F, '01'); CloseFile(F);
  CaConfig := FixtureDir + '/ca.cnf'; AssignFile(F, CaConfig); Rewrite(F);
  WriteLn(F, '[ca]'); WriteLn(F, 'default_ca=CA_default');
  WriteLn(F, '[CA_default]'); WriteLn(F, 'database=', CaIndex);
  WriteLn(F, 'serial=', CaSerial); WriteLn(F, 'new_certs_dir=', CaDir);
  WriteLn(F, 'certificate=', RootCert); WriteLn(F, 'private_key=', RootKey);
  WriteLn(F, 'default_md=sha256'); WriteLn(F, 'policy=policy');
  WriteLn(F, 'x509_extensions=server_cert'); WriteLn(F, 'unique_subject=no');
  WriteLn(F, '[policy]'); WriteLn(F, 'commonName=supplied');
  WriteLn(F, '[server_cert]'); WriteLn(F, 'basicConstraints=critical,CA:FALSE');
  WriteLn(F, 'keyUsage=critical,digitalSignature,keyEncipherment');
  WriteLn(F, 'extendedKeyUsage=serverAuth');
  WriteLn(F, 'subjectAltName=DNS:localhost,IP:127.0.0.1'); CloseFile(F);
  RunOpenSsl(['ca','-batch','-config',CaConfig,'-in',FixtureDir + '/expired-server.csr',
    '-out',ExpiredServerCert,'-notext','-startdate','20150101000000Z',
    '-enddate','20160101000000Z']);
  RootPem := ReadBytes(RootCert); ServerPem := ReadBytes(ServerCert);
  ClientPem := ReadBytes(ClientCert); ClientKeyPem := ReadBytes(ClientKey);
  EncryptedPem := ReadBytes(EncryptedClientKey); P12Data := ReadBytes(ClientP12);
end;

procedure LoadIdentities;
begin
  DebugStep('identity loader tests');
  ServerIdentity := TOpenSSLIdentity.FromPemFiles(ServerCert, ServerKey);
  DebugStep('server PEM loaded');
  ClientIdentity := TOpenSSLIdentity.FromPemFiles(ClientCert, ClientKey);
  DebugStep('client PEM loaded');
  P12Identity := TOpenSSLIdentity.FromPkcs12File(ClientP12, 'fixturepass');
  DebugStep('PKCS12 loaded');
  Check(ServerIdentity.BackendName = 'OpenSSL', 'server identity backend');
  Check(ClientIdentity.Leaf.CommonName = 'client.local', 'client identity common name');
  Check(Length(ClientIdentity.Leaf.Pem) > 0, 'client identity PEM summary');
  Check(ClientIdentity.Leaf.FingerprintSha256 <> '', 'client identity fingerprint');
  Check(ClientIdentity.Leaf.Serial <> '', 'client identity serial');
  Check(P12Identity.Leaf.CommonName = 'client.local', 'PKCS#12 identity');
  ClientIdentity := TOpenSSLIdentity.FromPem(ClientPem, EncryptedPem, 'fixturepass');
  Check(ClientIdentity.Leaf.CommonName = 'client.local', 'encrypted PEM key');
  CheckWrongPassword;
  CheckMismatchedKey;
  Check(TOpenSSLIdentity.FromPkcs12(P12Data, 'fixturepass').Leaf.CommonName = 'client.local',
    'in-memory PKCS#12 identity');
end;

procedure BuildContext;
var ClientPolicy: TTlsClientPolicy; ServerPolicy: TTlsServerPolicy;
begin
  DebugStep('context build');
  ClientIdentity := TOpenSSLIdentity.FromPemFiles(ClientCert, ClientKey);
  ServerIdentity := TOpenSSLIdentity.FromPemFiles(ServerCert, ServerKey);
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert])
    .WithDefaultIdentity(ClientIdentity);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithTrustAnchors([RootCert])
    .WithClientAuth(tlsAuthRequire).WithServerIdentity(ServerIdentity);
  Context := TOpenSSLTlsContextFactory.Create.WithClientPolicy(ClientPolicy)
    .WithServerPolicy(ServerPolicy).Build;
  DebugStep('context built');
  Check(Context.BackendName = 'OpenSSL', 'context backend');
  Check(Context.Info.Roles = [trClient, trServer], 'dual-role context');
  Check(not Context.Capabilities.SessionResumption, 'session resumption disabled');
  Check(not Context.Capabilities.EarlyData, 'early data disabled');
end;

procedure CheckConcurrentCreation;
var ClientThread, ServerThread: TSessionCreateThread;
begin
  ClientThread := TSessionCreateThread.Create(Context, crClient);
  ServerThread := TSessionCreateThread.Create(Context, crServer);
  try
    ClientThread.WaitFor; ServerThread.WaitFor;
    Check((ClientThread.ErrorText = '') and (ServerThread.ErrorText = ''),
      'concurrent client and server session creation failed');
  finally
    ClientThread.Free; ServerThread.Free;
  end;
end;

procedure CheckInsecurePeerIsUnverified;
var
  InsecureContext: ITLSContext;
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  ClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  Client, Server: ITLSSession;
  ToClient, ToServer: TBytes;
  I, N: Integer;
  Info: TTlsNegotiatedInfo;
begin
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithInsecure(True);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity);
  InsecureContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  ClientOptions := Default(TTlsClientSessionOptions).WithAlpns(['h2']);
  ServerOptions := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
  Client := InsecureContext.CreateClientSession(ClientOptions);
  Server := InsecureContext.CreateServerSession(ServerOptions);
  SetLength(ToClient, 16384);
  SetLength(ToServer, 16384);
  try
    for I := 1 to 10000 do
    begin
      Client.Advance(GetTickCount64);
      Server.Advance(GetTickCount64);
      N := Client.DrainEncrypted(ToServer, 0, Length(ToServer));
      if N > 0 then Server.FeedEncrypted(ToServer, 0, N);
      N := Server.DrainEncrypted(ToClient, 0, Length(ToClient));
      if N > 0 then Client.FeedEncrypted(ToClient, 0, N);
      if (Client.State = tssOpen) and (Server.State = tssOpen) then Break;
    end;
    Check((Client.State = tssOpen) and (Server.State = tssOpen),
      'insecure client handshake did not finish');
    Info := Client.NegotiatedInfo;
    Check((Info.PeerCertificate <> nil) and not Info.PeerCertificate.Verified,
      'insecure client marked the server certificate as verified');
  finally
    Client.Abort;
    Server.Abort;
  end;
end;

function VerificationFailureFor(const AContext: ITLSContext;
  const AClientIdentity: ITLSIdentity; const AServerTrustsClients: Boolean;
  const AHost: string = 'localhost'; const ARequiredClientAuth: Boolean = False): Boolean;
var
  ClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  Client, Server: ITLSSession;
  ToClient, ToServer: TBytes;
  Info: TTlsNegotiatedInfo;
  I, N, AlertBytes: Integer;
  ClientCategory, ServerCategory: TTlsErrorCategory;
  ClientFailed, ServerFailed, MetadataHidden: Boolean;
begin
  ClientOptions := Default(TTlsClientSessionOptions).WithAlpns(['h2']);
  ClientOptions.HostName := AHost;
  ClientOptions.Identity := AClientIdentity;
  ClientOptions.IdentitySelection := tisExplicit;
  ServerOptions := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
  Client := AContext.CreateClientSession(ClientOptions);
  Server := AContext.CreateServerSession(ServerOptions);
  SetLength(ToClient, 16384); SetLength(ToServer, 16384);
  ClientFailed := False; ServerFailed := False;
  MetadataHidden := False;
  ClientCategory := tecProtocol; ServerCategory := tecProtocol;
  AlertBytes := 0;
  try
    for I := 1 to 256 do
    begin
      try Client.Advance(GetTickCount64);
      except on E: ETlsSessionError do begin ClientCategory := E.Category; ClientFailed := True; end; end;
      try Server.Advance(GetTickCount64);
      except on E: ETlsSessionError do begin ServerCategory := E.Category; ServerFailed := True; end; end;
      N := Client.DrainEncrypted(ToServer, 0, Length(ToServer));
      if ClientFailed and (N > 0) then Inc(AlertBytes, N);
      if N > 0 then Server.FeedEncrypted(ToServer, 0, N);
      N := Server.DrainEncrypted(ToClient, 0, Length(ToClient));
      if ServerFailed and (N > 0) then Inc(AlertBytes, N);
      if N > 0 then Client.FeedEncrypted(ToClient, 0, N);
      if (ClientFailed and ServerFailed) or
        (AServerTrustsClients and ServerFailed) or
        (not AServerTrustsClients and ClientFailed) then Break;
    end;
    if AServerTrustsClients then
    begin
      try Info := Server.NegotiatedInfo;
      except on ETlsSessionError do MetadataHidden := True; end;
      Result := ServerFailed and
        ((ServerCategory = tecVerification) or
         (ARequiredClientAuth and (ServerCategory = tecAlert))) and
        (AlertBytes > 0) and MetadataHidden;
    end
    else
    begin
      Result := ClientFailed and (ClientCategory = tecVerification) and
        (AlertBytes > 0);
    end;
    if not Result then
      WriteLn(StdErr, Format('VERIFY-DIAG client-state=%d client-category=%d server-state=%d server-category=%d drained-alert=%d',
        [Ord(Client.State), Ord(ClientCategory), Ord(Server.State),
         Ord(ServerCategory), AlertBytes]));
  finally
    Client.Abort; Server.Abort;
  end;
end;

procedure OpenSessions(const AContext: ITLSContext; const AHost, AServerName: string;
  out AClientInfo, AServerInfo: TTlsNegotiatedInfo;
  const ACheckPendingPlaintext: Boolean = False);
var
  ClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  Client, Server: ITLSSession;
  ToClient, ToServer: TBytes;
  I, N, Accepted: Integer;
  Payload: TBytes;
  Progress: TTlsProgress;
begin
  ClientOptions := Default(TTlsClientSessionOptions).WithAlpns(['h2']);
  ClientOptions.HostName := AHost;
  ClientOptions.ServerName := AServerName;
  ServerOptions := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
  Client := AContext.CreateClientSession(ClientOptions);
  Server := AContext.CreateServerSession(ServerOptions);
  SetLength(ToClient, 16384); SetLength(ToServer, 16384);
  try
    for I := 1 to 512 do
    begin
      Client.Advance(GetTickCount64); Server.Advance(GetTickCount64);
      N := Client.DrainEncrypted(ToServer, 0, Length(ToServer));
      if N > 0 then Server.FeedEncrypted(ToServer, 0, N);
      N := Server.DrainEncrypted(ToClient, 0, Length(ToClient));
      if N > 0 then Client.FeedEncrypted(ToClient, 0, N);
      if (Client.State = tssOpen) and (Server.State = tssOpen) then Break;
    end;
    Check((Client.State = tssOpen) and (Server.State = tssOpen),
      'TLS session pair did not open');
    AClientInfo := Client.NegotiatedInfo;
    AServerInfo := Server.NegotiatedInfo;
    if ACheckPendingPlaintext then
    begin
      SetLength(Payload, TlsMaxPlaintextBuffer);
      FillChar(Payload[0], Length(Payload), 42);
      Accepted := 0;
      repeat
        N := Client.WritePlaintext(Payload, Accepted, Length(Payload) - Accepted);
        Inc(Accepted, N);
      until (N = 0) or (Accepted = Length(Payload));
      Progress := Client.Advance(GetTickCount64);
      Check((Accepted = Length(Payload)) and
        (Progress.PendingPlaintextOutput > 0) and
        (Progress.PendingPlaintextOutput < Accepted),
        'queued plaintext is absent from TLS progress');
      Client.Abort;
      Check(Client.Advance(0).PendingPlaintextOutput = 0,
        'abort retained pending plaintext credit');
    end;
  finally
    Client.Abort; Server.Abort;
  end;
end;

procedure CheckVersionsAndNames;
var
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  PairContext: ITLSContext;
  ClientInfo, ServerInfo: TTlsNegotiatedInfo;
  Version: TTlsVersion;
begin
  for Version := Low(TTlsVersion) to High(TTlsVersion) do
  begin
    ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert])
      .WithVersions(Version, Version);
    ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity)
      .WithVersions(Version, Version);
    PairContext := TOpenSSLTlsContextFactory.Create
      .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
    OpenSessions(PairContext, 'localhost', 'localhost', ClientInfo, ServerInfo);
    Check((ClientInfo.Version = Version) and (ServerInfo.Version = Version),
      'explicit TLS version was not negotiated');
    Check((ClientInfo.SelectedAlpn = 'h2') and (ServerInfo.SelectedAlpn = 'h2'),
      'DNS SNI session did not negotiate ALPN');
    Check((Pos('GCM', ClientInfo.CipherName) > 0) or
      (Pos('CHACHA20', ClientInfo.CipherName) > 0),
      'negotiated cipher is outside the HTTP/2 AEAD policy');
  end;
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity);
  PairContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  OpenSessions(PairContext, '127.0.0.1', '', ClientInfo, ServerInfo);
  Check(ClientInfo.PeerCertificate.Verified,
    'IP address certificate verification failed');
end;

procedure CheckRequestWithoutIdentity;
var
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  PairContext: ITLSContext;
  ClientInfo, ServerInfo: TTlsNegotiatedInfo;
begin
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithTrustAnchors([RootCert])
    .WithClientAuth(tlsAuthRequest).WithServerIdentity(ServerIdentity);
  PairContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  OpenSessions(PairContext, 'localhost', 'localhost', ClientInfo, ServerInfo);
  Check((ClientInfo.PeerCertificate <> nil) and
    (ServerInfo.PeerCertificate = nil),
    'request mode without a client identity returned the wrong peer metadata');
end;

procedure CheckTrustDepthAndDeadline;
var
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  PairContext: ITLSContext;
  ClientInfo, ServerInfo: TTlsNegotiatedInfo;
  Client: ITLSSession;
  Options: TTlsClientSessionOptions;
  Failed: Boolean;
begin
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([ServerCert])
    .WithPartialChain(True);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity);
  PairContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  OpenSessions(PairContext, 'localhost', 'localhost', ClientInfo, ServerInfo);
  Check(ClientInfo.PeerCertificate.Verified,
    'partial-chain trust of a configured leaf anchor failed');

  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert])
    .WithVerificationDepth(0);
  PairContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  OpenSessions(PairContext, 'localhost', 'localhost', ClientInfo, ServerInfo);
  Check(ClientInfo.PeerCertificate.Verified,
    'explicit verification depth zero was not applied');

  PairContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy)
    .WithHandshakeTimeoutMs(1).Build;
  Options := Default(TTlsClientSessionOptions);
  Options.HostName := 'localhost';
  Options.HandshakeStartMs := 0;
  Client := PairContext.CreateClientSession(Options);
  Failed := False;
  try Client.Advance(1);
  except on E: ETlsSessionError do Failed := E.Category = tecTimeout; end;
  Check(Failed and (Client.State = tssFailed),
    'context handshake timeout ignored a zero monotonic start');
  Client.Abort;
end;

procedure CheckRepeatedLifecycle;
var I: Integer; Ctx: ITLSContext; C: ITLSSession; S: ITLSSession;
  CP: TTlsClientPolicy; SP: TTlsServerPolicy;
  CO: TTlsClientSessionOptions; SO: TTlsServerSessionOptions;
  ClientInfo, ServerInfo: TTlsNegotiatedInfo;
  BaseX509, BaseSsl, BaseCtx: Integer;
begin
  OpenSessions(Context, 'localhost', 'localhost', ClientInfo, ServerInfo);
  BaseX509 := LiveX509Count; BaseSsl := LiveSSLCount;
  BaseCtx := LiveSSLContextCount;
  CP := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  SP := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity);
  CO := Default(TTlsClientSessionOptions).WithAlpns(['h2']);
  CO.HostName := 'localhost'; SO := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
  for I := 1 to 10 do
  begin
    Ctx := TOpenSSLTlsContextFactory.Create.WithClientPolicy(CP)
      .WithServerPolicy(SP).Build;
    C := Ctx.CreateClientSession(CO); S := Ctx.CreateServerSession(SO);
    C.Abort; S.Abort; C := nil; S := nil;
    OpenSessions(Ctx, 'localhost', 'localhost', ClientInfo, ServerInfo);
    Ctx := nil;
  end;
  Check((LiveX509Count = BaseX509) and (LiveSSLCount = BaseSsl) and
    (LiveSSLContextCount = BaseCtx),
    'native OpenSSL object counts did not return to baseline after ten handshakes');
  WriteLn(Format('RESOURCE BASELINE X509=%d SSL=%d SSL_CTX=%d; repetitions=10',
    [BaseX509, BaseSsl, BaseCtx]));
end;

procedure CheckHandshakeMaterialBounds;
var
  LargePem, CertBytes, KeyBytes: TBytes;
  LargeIdentity: ITLSIdentity;
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  PairContext: ITLSContext;
  Alpns: TArray<string>;
  Options: TTlsServerSessionOptions;
  I, Count: Integer;
  Raised: Boolean;
begin
  CertBytes := ReadBytes(ServerCert);
  KeyBytes := ReadBytes(ServerKey);
  Count := (32768 div Length(CertBytes)) + 2;
  SetLength(LargePem, Length(CertBytes) * Count);
  for I := 0 to Count - 1 do
    Move(CertBytes[0], LargePem[I * Length(CertBytes)], Length(CertBytes));
  LargeIdentity := TOpenSSLIdentity.FromPem(LargePem, KeyBytes);
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(LargeIdentity);
  Raised := False;
  try TOpenSSLTlsContextFactory.Create.WithClientPolicy(ClientPolicy)
      .WithServerPolicy(ServerPolicy).Build;
  except on ETlsContextError do Raised := True; end;
  Check(Raised, 'oversized local certificate chain was not rejected at Build');

  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity);
  PairContext := TOpenSSLTlsContextFactory.Create.WithClientPolicy(ClientPolicy)
    .WithServerPolicy(ServerPolicy).Build;
  SetLength(Alpns, 70);
  for I := 0 to High(Alpns) do Alpns[I] := StringOfChar('a', 240);
  Options := Default(TTlsServerSessionOptions).WithAlpns(Alpns);
  Raised := False;
  try PairContext.CreateServerSession(Options);
  except on ETlsContextError do Raised := True; end;
  Check(Raised, 'oversized ALPN handshake vector was not rejected');
end;

procedure CheckVerificationFailures;
var
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  BadIdentity: ITLSIdentity;
  UntrustedContext, RequestContext, NameContext, ExpiredContext,
  RequireContext: ITLSContext;
  ExpiredIdentity: ITLSIdentity;
begin
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([
    ExistingFixture('other-ca.crt')]);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ServerIdentity);
  UntrustedContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  Check(VerificationFailureFor(UntrustedContext, nil, False),
    'untrusted server certificate returns verification category');
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  NameContext := TOpenSSLTlsContextFactory.Create.WithClientPolicy(ClientPolicy)
    .WithServerPolicy(ServerPolicy).Build;
  Check(VerificationFailureFor(NameContext, nil, False, '127.0.0.2'),
    'wrong IP address fails certificate verification');

  ExpiredIdentity := TOpenSSLIdentity.FromPemFiles(ExpiredServerCert, ExpiredServerKey);
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithServerIdentity(ExpiredIdentity);
  ExpiredContext := TOpenSSLTlsContextFactory.Create.WithClientPolicy(ClientPolicy)
    .WithServerPolicy(ServerPolicy).Build;
  Check(VerificationFailureFor(ExpiredContext, nil, False),
    'expired trusted server certificate fails verification');

  BadIdentity := TOpenSSLIdentity.FromPemFiles(ExistingFixture('other-client.crt'),
    ExistingFixture('other-client.key'));
  ClientPolicy := TTlsClientPolicy.SecureDefault.WithTrustAnchors([RootCert]);
  ServerPolicy := TTlsServerPolicy.SecureDefault.WithTrustAnchors([RootCert])
    .WithClientAuth(tlsAuthRequest).WithServerIdentity(ServerIdentity);
  RequestContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  Check(VerificationFailureFor(RequestContext, BadIdentity, True),
    'request mode rejects an invalid presented certificate');

  ServerPolicy := TTlsServerPolicy.SecureDefault.WithTrustAnchors([RootCert])
    .WithClientAuth(tlsAuthRequire).WithServerIdentity(ServerIdentity);
  RequireContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy).Build;
  Check(VerificationFailureFor(RequireContext, nil, True, 'localhost', True),
    'require mode rejects a missing client certificate');
  Check(VerificationFailureFor(RequireContext, BadIdentity, True),
    'require mode rejects an invalid client certificate');
end;

procedure Run;
var ClientOptions: TTlsClientSessionOptions; ServerOptions: TTlsServerSessionOptions;
  N: Integer;
  ClientInfo, ServerInfo: TTlsNegotiatedInfo;
begin
  Cases := 0;
  MakeFixtures;
  Check(InstallOpenSSLResourceCounters,
    'OpenSSL native object counters are unavailable');
  LoadIdentities;
  CheckLegacyIdentityInputs;
  BuildContext;
  OpenSessions(Context, 'localhost', 'localhost', ClientInfo, ServerInfo, True);
  ClientOptions := Default(TTlsClientSessionOptions);
  ClientOptions.HostName := 'localhost';
  ClientOptions.ServerName := 'localhost';
  ClientOptions := ClientOptions.WithAlpns(['h2']);
  ServerOptions := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
  DebugStep('shared session contract');
  N := RunTlsSessionContract(Context, ClientOptions, ServerOptions);
  Inc(Cases, N);
  CheckInsecurePeerIsUnverified;
  CheckVerificationFailures;
  CheckVersionsAndNames;
  CheckRequestWithoutIdentity;
  CheckTrustDepthAndDeadline;
  CheckRepeatedLifecycle;
  CheckHandshakeMaterialBounds;
  CheckConcurrentCreation;
  WriteLn('PASS ', Cases, ' cases');
end;

begin
  try Run;
  except on E: Exception do begin WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message); Halt(1); end; end;
end.
