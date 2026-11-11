{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls_engine_study
notes:
  - This study uses local generated certificate fixtures.
---
}
program TlsLibEngineStudy;

{$mode delphi}

uses
  SysUtils, Classes,
  TlpTlsEngineFactory, TlpITlsEngine, TlpTlsAlert, TlpITlsConfig,
  TlpITlsConfigBuilder,
  TlpTlsCredential, TlpTlsVersion, TlpTlsPresets,
  TlpDefaultCryptoProvider, TlpDefaultPkixProvider,
  TlpCertificateVerifierSource, TlpTlsConnectionInfo;

function ReadBytes(const APath: string): TBytes;
var
  LStream: TFileStream;
begin
  Result := nil;
  LStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, LStream.Size);
    if Length(Result) > 0 then
      LStream.ReadBuffer(Result[0], Length(Result));
  finally
    LStream.Free;
  end;
end;

function Transfer(const AFrom, ATo: ITlsEngine; ACapacity, AFragment: Integer): Integer;
var
  LBytes: TBytes;
  LOffset, LCount, LPart: Integer;
begin
  SetLength(LBytes, ACapacity);
  LCount := AFrom.TakeOutgoing(LBytes, 0);
  Result := LCount;
  LOffset := 0;
  while LOffset < LCount do
  begin
    LPart := AFragment;
    if LPart > LCount - LOffset then
      LPart := LCount - LOffset;
    ATo.ProcessInput(LBytes, LOffset, LPart);
    Inc(LOffset, LPart);
  end;
end;

procedure PumpHandshake(const AClient, AServer: ITlsEngine);
var
  LRound, LMoved: Integer;
begin
  AClient.StartHandshake;
  for LRound := 1 to 20000 do
  begin
    LMoved := Transfer(AClient, AServer, 7, 1);
    Inc(LMoved, Transfer(AServer, AClient, 7, 1));
    if not AClient.IsHandshaking and not AServer.IsHandshaking then
    begin
      if AClient.IsTerminal or AServer.IsTerminal then
        raise Exception.Create('TLS handshake ended in a terminal engine state');
      Exit;
    end;
    if LMoved = 0 then
      raise Exception.CreateFmt('handshake stopped without progress at round %d', [LRound]);
  end;
  raise Exception.Create('handshake exceeded the bounded pump rounds');
end;

procedure ExpectClientReject(const AClient, AServer: ITlsEngine; const ACaseName: string);
var
  LRound, LMoved: Integer;
begin
  AClient.StartHandshake;
  for LRound := 1 to 20000 do
  begin
    LMoved := Transfer(AClient, AServer, 7, 1);
    Inc(LMoved, Transfer(AServer, AClient, 7, 1));
    if AClient.IsTerminal then
    begin
      WriteLn('PASS: TlsLib rejected ', ACaseName);
      Exit;
    end;
    if LMoved = 0 then
      raise Exception.Create('reject handshake stopped without progress: ' + ACaseName);
  end;
  raise Exception.Create('invalid peer completed TLS handshake: ' + ACaseName);
end;

function ClientConfig(const ARoot, AClientCert, AClientKey: TBytes;
  AVersion: UInt16; AWithCredential: Boolean): ITlsClientConfig;
var
  LBuilder: ITlsClientConfigBuilder;
begin
  LBuilder := TTlsPresets.Compatible(TDefaultCryptoProvider.Shared,
    TDefaultPkixProvider.Shared).Client
    .WithServerVerification(TServerVerification.WebPki(ARoot).Build)
    .WithSupportedVersions(TArray<UInt16>.Create(AVersion))
    .WithAlpnProtocols(TArray<TBytes>.Create(TEncoding.ASCII.GetBytes('h2')));
  if AWithCredential then
    LBuilder := LBuilder.WithCredential(TTlsCredential.Load(
      TDefaultCryptoProvider.Shared, TDefaultPkixProvider.Shared,
      AClientCert, AClientKey));
  Result := LBuilder.Build;
end;

function ServerConfig(const ARoot, AServerCert, AServerKey: TBytes;
  AVersion: UInt16; ARequireClient: Boolean): ITlsServerConfig;
var
  LBuilder: ITlsServerConfigBuilder;
begin
  LBuilder := TTlsPresets.Compatible(TDefaultCryptoProvider.Shared,
    TDefaultPkixProvider.Shared).Server
    .WithCredential(TTlsCredential.Load(TDefaultCryptoProvider.Shared,
      TDefaultPkixProvider.Shared, AServerCert, AServerKey))
    .WithSupportedVersions(TArray<UInt16>.Create(AVersion))
    .WithAlpnProtocols(TArray<TBytes>.Create(TEncoding.ASCII.GetBytes('h2')));
  if ARequireClient then
    LBuilder := LBuilder.WithPeerAuth(TClientAuthMode.Required)
      .WithClientVerification(TClientVerification.WebPki(ARoot).Build);
  Result := LBuilder.Build;
end;

procedure CheckAlpn(const AInfo: TTlsConnectionInfo; const AExpected: string);
begin
  if TEncoding.ASCII.GetString(AInfo.AlpnProtocol) <> AExpected then
    raise Exception.Create('ALPN did not select ' + AExpected);
end;

procedure ProveVersion(const ARoot, AServerCert, AServerKey, AClientCert,
  AClientKey: TBytes; AVersion: UInt16);
var
  LServerConfig: ITlsServerConfig;
  LClientConfig: ITlsClientConfig;
  LClient, LServer: ITlsEngine;
  LWire, LApp, LRead: TBytes;
  LReadCount: Integer;
begin
  LServerConfig := ServerConfig(ARoot, AServerCert, AServerKey, AVersion, False);
  LClientConfig := ClientConfig(ARoot, AClientCert, AClientKey, AVersion, False);
  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'localhost');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  PumpHandshake(LClient, LServer);
  if not LClient.ConnectionInfo.NegotiatedVersion.Equals(TTlsVersion.Create(AVersion)) then
    raise Exception.CreateFmt('client selected unexpected TLS version 0x%.4x', [AVersion]);
  if not LServer.ConnectionInfo.NegotiatedVersion.Equals(TTlsVersion.Create(AVersion)) then
    raise Exception.CreateFmt('server selected unexpected TLS version 0x%.4x', [AVersion]);
  CheckAlpn(LClient.ConnectionInfo, 'h2');
  CheckAlpn(LServer.ConnectionInfo, 'h2');
  if Length(LClient.ConnectionInfo.ValidatedPath) < 2 then
    raise Exception.Create('client did not retain a validated certificate path');
  if LClient.ConnectionInfo.CipherSuite = 0 then
    raise Exception.Create('TLS cipher suite was not selected');
  if LServer.ConnectionInfo.ServerName <> 'localhost' then
    raise Exception.Create('server did not receive the DNS SNI name');

  LApp := TEncoding.ASCII.GetBytes('engine application payload');
  LClient.Write(LApp, 0, Length(LApp));
  while LClient.WantsWrite do
    Transfer(LClient, LServer, 7, 1);
  SetLength(LRead, Length(LApp));
  LReadCount := LServer.ReadAppData(LRead, 0, Length(LApp));
  if (LReadCount <> Length(LApp)) or not CompareMem(@LApp[0], @LRead[0], Length(LApp)) then
    raise Exception.Create('fragmented application payload did not arrive intact');
  WriteLn(Format('PASS: TlsLib client/server TLS 0x%.4x, cipher 0x%.4x, verified DNS chain, SNI, ALPN, payload',
    [AVersion, LClient.ConnectionInfo.CipherSuite]));

  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, '127.0.0.1');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  PumpHandshake(LClient, LServer);
  if LServer.ConnectionInfo.ServerName <> '' then
    raise Exception.Create('client sent SNI for an IP literal');
  WriteLn(Format('PASS: TlsLib IP SAN verification and IP SNI omission, TLS 0x%.4x', [AVersion]));
end;

procedure ProveVerificationFailures(const ARoot, ABadRoot, AServerCert,
  AServerKey, AClientCert, AClientKey: TBytes);
var
  LServerConfig: ITlsServerConfig;
  LClientConfig: ITlsClientConfig;
  LClient, LServer: ITlsEngine;
begin
  LServerConfig := ServerConfig(ARoot, AServerCert, AServerKey, TlsWireVersionTls13, False);
  LClientConfig := ClientConfig(ARoot, AClientCert, AClientKey, TlsWireVersionTls13, False);
  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'wrong.example');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  ExpectClientReject(LClient, LServer, 'a trusted certificate with a wrong DNS name');

  LClientConfig := ClientConfig(ABadRoot, AClientCert, AClientKey, TlsWireVersionTls13, False);
  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'localhost');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  ExpectClientReject(LClient, LServer, 'an untrusted certificate chain');
end;

procedure ProveMutualTls(const ARoot, AServerCert, AServerKey, AClientCert,
  AClientKey: TBytes; AVersion: UInt16; AWithCredential: Boolean);
var
  LServerConfig: ITlsServerConfig;
  LClientConfig: ITlsClientConfig;
  LClient, LServer: ITlsEngine;
begin
  LServerConfig := ServerConfig(ARoot, AServerCert, AServerKey, AVersion, True);
  LClientConfig := ClientConfig(ARoot, AClientCert, AClientKey, AVersion, AWithCredential);
  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'localhost');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  if AWithCredential then
  begin
    PumpHandshake(LClient, LServer);
    if Length(LServer.ConnectionInfo.PeerCertificates) = 0 then
      raise Exception.Create('server completed required mTLS without a peer certificate');
    if Length(LServer.ConnectionInfo.ValidatedPath) < 2 then
      raise Exception.Create('server did not retain a validated client-certificate path');
    WriteLn(Format('PASS: TlsLib required mTLS, client certificate, TLS 0x%.4x', [AVersion]));
  end
  else
    ExpectClientReject(LClient, LServer, 'required mTLS without a client certificate');
end;

procedure ProvePartialChain(const AIntermediate, AServerCert, AServerKey,
  AClientCert, AClientKey: TBytes);
var
  LServerConfig: ITlsServerConfig;
  LClientConfig: ITlsClientConfig;
  LClient, LServer: ITlsEngine;
begin
  LServerConfig := ServerConfig(AIntermediate, AServerCert, AServerKey,
    TlsWireVersionTls13, True);
  LClientConfig := ClientConfig(AIntermediate, AClientCert, AClientKey,
    TlsWireVersionTls13, True);
  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'localhost');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  PumpHandshake(LClient, LServer);
  if (Length(LClient.ConnectionInfo.ValidatedPath) < 2) or
     (Length(LServer.ConnectionInfo.ValidatedPath) < 2) then
    raise Exception.Create('intermediate trust anchor did not validate the partial chains');
  WriteLn('PASS: TlsLib TLS 1.3 server and client accept partial chains at trusted intermediate');
end;

procedure Run;
var
  LRoot, LBadRoot, LIntermediate, LServerCert, LServerKey, LClientCert, LClientKey: TBytes;
  LServerConfig: ITlsServerConfig;
  LClientConfig: ITlsClientConfig;
  LClient, LServer: ITlsEngine;
  LRound, LMoved: Integer;
  LEvent: ITlsEvent;
  LSeenAlert: Boolean;
begin
  LRoot := ReadBytes(ParamStr(1));
  LBadRoot := ReadBytes(ParamStr(2));
  LServerCert := ReadBytes(ParamStr(3));
  LServerKey := ReadBytes(ParamStr(4));
  LClientCert := ReadBytes(ParamStr(5));
  LClientKey := ReadBytes(ParamStr(6));
  LIntermediate := ReadBytes(ParamStr(7));
  ProveVersion(LRoot, LServerCert, LServerKey, LClientCert, LClientKey, TlsWireVersionTls12);
  ProveVersion(LRoot, LServerCert, LServerKey, LClientCert, LClientKey, TlsWireVersionTls13);
  ProveVerificationFailures(LRoot, LBadRoot, LServerCert, LServerKey, LClientCert, LClientKey);
  ProveMutualTls(LRoot, LServerCert, LServerKey, LClientCert, LClientKey,
    TlsWireVersionTls12, True);
  ProveMutualTls(LRoot, LServerCert, LServerKey, LClientCert, LClientKey,
    TlsWireVersionTls13, True);
  ProveMutualTls(LRoot, LServerCert, LServerKey, LClientCert, LClientKey,
    TlsWireVersionTls13, False);
  ProvePartialChain(LIntermediate, LServerCert, LServerKey, LClientCert, LClientKey);

  LServerConfig := ServerConfig(LRoot, LServerCert, LServerKey, TlsWireVersionTls13, False);
  LClientConfig := ClientConfig(LRoot, LClientCert, LClientKey, TlsWireVersionTls13, False);
  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'localhost');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  PumpHandshake(LClient, LServer);
  LServer.SendAlert(TTlsAlertDescription.HandshakeFailure);
  for LRound := 1 to 100 do
  begin
    if not LServer.WantsWrite then
      Break;
    LMoved := Transfer(LServer, LClient, 7, 1);
    if LMoved = 0 then
      raise Exception.Create('alert output stalled before the alert record was drained');
  end;
  if LServer.WantsWrite then
    raise Exception.Create('alert output exceeded the bounded drain rounds');
  LSeenAlert := False;
  while LClient.NextEvent(LEvent) do
    if LEvent.Kind = TTlsEventKind.PeerAlert then
      LSeenAlert := True;
  if not LSeenAlert then
    raise Exception.Create('peer fatal alert did not produce an alert event');

  LClient := TTlsEngineFactory.CreateClientEngine(LClientConfig, 'localhost');
  LServer := TTlsEngineFactory.CreateServerEngine(LServerConfig);
  PumpHandshake(LClient, LServer);
  LClient.LatchTransportFailure('study EOF');
  if not LClient.IsTerminal then
    raise Exception.Create('transport EOF did not terminate the engine');
  WriteLn('PASS: TlsLib fatal alert and transport EOF. All engine input is split to 1 byte; ' +
    'each output drain is capped at 7 bytes.');
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
