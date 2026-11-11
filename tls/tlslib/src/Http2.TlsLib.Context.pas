{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, context, factory, tlslib
notes:
  - This unit builds immutable role-specific TlsLib contexts and engines.
---
}
unit Http2.TlsLib.Context;

{$mode delphi}{$H+}{$interfaces com}{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session, Http2.Common.Tls.Context;

type
  TTlsLibContext = class(TInterfacedObject, ITLSContext)
  private
    FRoles: TTlsRoles;
    FClientPolicy: TTlsClientPolicy;
    FServerPolicy: TTlsServerPolicy;
    FHandshakeTimeoutMs: Cardinal;
    FClientTrustData, FServerTrustData: TBytes;
  public
    constructor Create(const ARoles: TTlsRoles; const AClient: TTlsClientPolicy;
      const AServer: TTlsServerPolicy; const ATimeoutMs: Cardinal;
      const AClientTrust, AServerTrust: TBytes);
    destructor Destroy; override;
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function HandshakeTimeoutMs: Cardinal;
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
  end;
  TlsLibContext = TTlsLibContext;



implementation

uses
  Http2.TlsLib.Diagnostics, Http2.TlsLib.Trust, Http2.TlsLib.Session,
  Http2.TlsLib.Identity,
  TlpTlsAlert, TlpTlsCredential, TlpTlsVersion, TlpTlsPresets,
  TlpDefaultCryptoProvider, TlpDefaultPkixProvider, TlpTlsEngineFactory,
  TlpITlsEngine, TlpITlsConfig, TlpITlsConfigBuilder,
  TlpCertificateVerifierSource, TlpPkixDomainTypes;

function AddVersion(const A: TArray<UInt16>; const V: UInt16): TArray<UInt16>;
begin Result := Copy(A); SetLength(Result, Length(A) + 1); Result[High(Result)] := V; end;

function AddAlpn(const A: TArray<TBytes>; const V: TBytes): TArray<TBytes>;
begin Result := Copy(A); SetLength(Result, Length(A) + 1); Result[High(Result)] := Copy(V); end;

function EncodeAlpn(const AValues: TArray<string>): TArray<TBytes>;
var I, Total: Integer; V: TBytes;
begin
  Result := nil;
  Total := 0;
  for I := 0 to High(AValues) do
  begin
    V := TEncoding.UTF8.GetBytes(AValues[I]);
    if Length(V) = 0 then raise ETlsContextError.Create('TlsLib ALPN values must not be empty');
    if Length(V) > 255 then raise ETlsContextError.Create('TlsLib ALPN values exceed 255 bytes');
    Inc(Total, Length(V) + 1);
    if Total > 16384 then raise ETlsContextError.Create('TlsLib ALPN list exceeds the 16 KiB limit');
    Result := AddAlpn(Result, V);
  end;
end;

constructor TTlsLibContext.Create(const ARoles: TTlsRoles; const AClient: TTlsClientPolicy;
  const AServer: TTlsServerPolicy; const ATimeoutMs: Cardinal;
  const AClientTrust, AServerTrust: TBytes);
begin
  inherited Create;
  FRoles := ARoles;
  FClientPolicy := AClient;
  FServerPolicy := AServer;
  FClientPolicy := FClientPolicy.WithTrustAnchors(AClient.TrustAnchors);
  FServerPolicy := FServerPolicy.WithTrustAnchors(AServer.TrustAnchors);
  FHandshakeTimeoutMs := ATimeoutMs;
  FClientTrustData := Copy(AClientTrust);
  FServerTrustData := Copy(AServerTrust);
  TlsLibCountContext(1);
end;

destructor TTlsLibContext.Destroy;
begin
  TlsLibCountContext(-1);
  FClientTrustData := nil;
  FServerTrustData := nil;
  inherited Destroy;
end;

function TTlsLibContext.BackendName: string; begin Result := 'TlsLib'; end;

function TTlsLibContext.Capabilities: TTlsCapabilities;
begin
  Result := Default(TTlsCapabilities);
  Result.Roles := FRoles;
  Result.Versions := [tls12, tls13];
  Result.IdentityFormats := [tifPem, tifPkcs12];
  Result.PartialChain := True;
end;

function TTlsLibContext.HandshakeTimeoutMs: Cardinal;
begin
  Result := FHandshakeTimeoutMs;
end;

function TTlsLibContext.Info: TTlsContextInfo;
begin
  Result := Default(TTlsContextInfo);
  Result.Roles := FRoles;
  Result.ClientAuth := FServerPolicy.ClientAuth;
  Result.HandshakeTimeoutMs := FHandshakeTimeoutMs;
end;

function TTlsLibContext.CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
var
  B: ITlsClientConfigBuilder;
  C: ITlsClientConfig;
  V: TArray<UInt16>;
  A: TArray<TBytes>;
  T: TBytes;
  I, N: Integer;
  Id: ITLSIdentity;
  Marker: ITlsLibIdentityMarker;
  E: ITlsEngine;
  Host: string;
begin
  if not (trClient in FRoles) then
    raise ETlsContextError.Create('TlsLib context does not enable the client role');
  if (AOptions.HandshakeStartMs < 0) or (AOptions.HandshakeDeadlineMs < 0) then
    raise ETlsContextError.Create('TlsLib handshake times must be non-negative');
  Id := FClientPolicy.DefaultIdentity;
  if AOptions.IdentitySelection = tisExplicit then Id := AOptions.Identity;
  if Id <> nil then
  begin
    if not Supports(Id, ITlsLibIdentityMarker, Marker) then
      raise ETlsContextError.Create('TlsLib cannot use an identity from another provider');
    if Marker.CertificateBytes > 32 * 1024 then
      raise ETlsContextError.Create('TlsLib client certificate chain exceeds the 32 KiB handshake budget');
  end;
  T := Copy(FClientTrustData);
  B := TTlsPresets.Compatible(TDefaultCryptoProvider.Shared,
    TDefaultPkixProvider.Shared).Client;
  V := nil;
  if FClientPolicy.MinVersion = tls12 then V := AddVersion(V, TlsWireVersionTls12);
  if FClientPolicy.MaxVersion = tls13 then V := AddVersion(V, TlsWireVersionTls13);
  if Length(V) = 0 then raise ETlsContextError.Create('TlsLib requires TLS 1.2 or TLS 1.3');
  B := B.WithSupportedVersions(V).WithResumption(False);
  if FClientPolicy.VerifyPeer then
  begin
    if Length(T) = 0 then
      raise ETlsContextError.Create('TlsLib client verification requires explicit trust anchors');
    B := B.WithServerVerification(TServerVerification.WebPki(T).Build);
  end
  else
    B := B.WithServerVerification(TServerVerification.DangerousSkip);
  A := EncodeAlpn(AOptions.AlpnValues);
  if Length(A) > 0 then B := B.WithAlpnProtocols(A);
  if Id <> nil then
  begin
    B := (Id as ITlsLibIdentityMarker).ApplyClientCredential(B) as ITlsClientConfigBuilder;
  end;
  C := B.Build;
  Host := AOptions.HostName;
  if (AOptions.ServerName <> '') and (AOptions.ServerName <> AOptions.HostName) then
    raise ETlsContextError.Create('TlsLib does not support separate SNI and verification names');
  if Host = '' then raise ETlsContextError.Create('TlsLib client session requires a host name');
  E := TTlsEngineFactory.CreateClientEngine(C, Host);
  try E.StartHandshake;
  except on X: Exception do
    raise ETlsContextError.Create('TlsLib could not start the client handshake'); end;
  Result := TTlsLibSession.Create(Self as ITLSContext, trClient, E,
    FHandshakeTimeoutMs, AOptions.HandshakeStartMs,
    AOptions.HandshakeDeadlineMs);
end;

function TTlsLibContext.CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
var
  B: ITlsServerConfigBuilder;
  C: ITlsServerConfig;
  V: TArray<UInt16>;
  A: TArray<TBytes>;
  T: TBytes;
  I: Integer;
  E: ITlsEngine;
begin
  if not (trServer in FRoles) then
    raise ETlsContextError.Create('TlsLib context does not enable the server role');
  if (AOptions.HandshakeStartMs < 0) or (AOptions.HandshakeDeadlineMs < 0) then
    raise ETlsContextError.Create('TlsLib handshake times must be non-negative');
  if FServerPolicy.ServerIdentity = nil then
    raise ETlsContextError.Create('TlsLib server role requires an explicit server identity');
  T := Copy(FServerTrustData);
  B := TTlsPresets.Compatible(TDefaultCryptoProvider.Shared,
    TDefaultPkixProvider.Shared).Server;
  V := nil;
  if FServerPolicy.MinVersion = tls12 then V := AddVersion(V, TlsWireVersionTls12);
  if FServerPolicy.MaxVersion = tls13 then V := AddVersion(V, TlsWireVersionTls13);
  if Length(V) = 0 then raise ETlsContextError.Create('TlsLib requires TLS 1.2 or TLS 1.3');
  B := B.WithSupportedVersions(V).WithResumption(False);
  B := (FServerPolicy.ServerIdentity as ITlsLibIdentityMarker)
    .ApplyServerCredential(B) as ITlsServerConfigBuilder;
  if FServerPolicy.ClientAuth <> tlsAuthNone then
  begin
    if Length(T) = 0 then
      raise ETlsContextError.Create('TlsLib client authentication requires explicit trust anchors');
    case FServerPolicy.ClientAuth of
      tlsAuthRequest: B := B.WithPeerAuth(TClientAuthMode.Requested);
      tlsAuthRequire: B := B.WithPeerAuth(TClientAuthMode.Required);
    end;
    B := B.WithClientVerification(TClientVerification.WebPki(T).Build);
  end;
  A := EncodeAlpn(AOptions.AlpnValues);
  if Length(A) > 0 then B := B.WithAlpnProtocols(A);
  C := B.Build;
  E := TTlsEngineFactory.CreateServerEngine(C);
  Result := TTlsLibSession.Create(Self as ITLSContext, trServer, E,
    FHandshakeTimeoutMs, AOptions.HandshakeStartMs,
    AOptions.HandshakeDeadlineMs);
end;

end.
