{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, context
notes:
  - This unit owns immutable OpenSSL role contexts.
---
}
unit Http2.OpenSSL.Context;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session,
  Http2.Common.Tls.Context, mormot.lib.openssl11;
const
  TlsMaxHandshakeIdentityBytes = 32768;
type
  TOpenSSLTlsContext = class(TInterfacedObject, ITLSContext)
  private
    FClient: TTlsClientPolicy;
    FServer: TTlsServerPolicy;
    FInfo: TTlsContextInfo;
    FClientCtx, FServerCtx: PSSL_CTX;
  public
    constructor Create(const AClient: TTlsClientPolicy;
      const AServer: TTlsServerPolicy; const ATimeout: Cardinal;
      const AHasClient, AHasServer: Boolean);
    destructor Destroy; override;
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
    procedure RequireAvailable;
  end;

  OpenSSLTlsContext = TOpenSSLTlsContext;
implementation
uses Http2.OpenSSL.Identity, Http2.OpenSSL.Session, Http2.OpenSSL.Trust,
  mormot.core.base, mormot.core.os;
function NativeVersion(const AVersion: TTlsVersion): Integer;
begin
  if AVersion = tls12 then Result := TLS1_2_VERSION else Result := TLS1_3_VERSION;
end;
constructor TOpenSSLTlsContext.Create(const AClient: TTlsClientPolicy;
  const AServer: TTlsServerPolicy; const ATimeout: Cardinal;
  const AHasClient, AHasServer: Boolean);
var Anchors: TArray<string>; I: Integer;
  procedure Configure(const ACtx: PSSL_CTX; const AMin, AMax: TTlsVersion;
    const AAnchors: TArray<string>; const ASystem, APartial: Boolean;
    const AVerifyMode: Integer; const AHasDepth: Boolean; const ADepth: Integer);
  begin
    if ACtx = nil then raise ETlsContextError.Create('SSL_CTX_new failed');
    SSL_CTX_set_options(ACtx, SSL_OP_NO_TICKET or SSL_OP_NO_COMPRESSION or
      SSL_OP_NO_RENEGOTIATION);
    SSL_CTX_set_session_cache_mode(ACtx, 0);
    if not OpenSSLDisableResumption(ACtx) then
      raise ETlsContextError.Create('OpenSSL ticket and early-data disablement failed');
    if SSL_CTX_set_cipher_list(ACtx,
      'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:' +
      'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:' +
      'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305') <> 1 then
      raise ETlsContextError.Create('OpenSSL TLS 1.2 AEAD cipher policy setup failed');
    if SSL_CTX_set_ciphersuites(ACtx,
      'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256') <> 1 then
      raise ETlsContextError.Create('OpenSSL TLS 1.3 AEAD cipher policy setup failed');
    if (SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_MIN_PROTO_VERSION, NativeVersion(AMin), nil) <= 0) or
       (SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_MAX_PROTO_VERSION, NativeVersion(AMax), nil) <= 0) then
      raise ETlsContextError.Create('OpenSSL TLS version policy setup failed');
    SSL_CTX_set_verify(ACtx, AVerifyMode, nil);
    OpenSSLConfigureTrust(ACtx, AAnchors, ASystem, APartial, AHasDepth, ADepth);
  end;
begin
  inherited Create;
  FClient := AClient; FServer := AServer;
  FInfo.Roles := [];
  if AHasClient then Include(FInfo.Roles, trClient);
  if AHasServer then Include(FInfo.Roles, trServer);
  FInfo.ClientAuth := AServer.ClientAuth;
  FInfo.HandshakeTimeoutMs := ATimeout;
  if not OpenSslInitialize then
    raise EOpenSSLProviderUnavailable.Create('OpenSSL provider library is not available');
  try
    if AHasClient then
    begin
      FClientCtx := SSL_CTX_new(TLS_client_method());
      Anchors := AClient.TrustAnchors;
      if AClient.VerifyPeer then I := SSL_VERIFY_PEER else I := 0;
      Configure(FClientCtx, AClient.MinVersion, AClient.MaxVersion, Anchors,
        AClient.UseSystemTrust, AClient.AllowPartialChain, I,
        AClient.HasVerificationDepth, AClient.VerificationDepth);
    end;
    if AHasServer then
    begin
      FServerCtx := SSL_CTX_new(TLS_server_method());
      Anchors := AServer.TrustAnchors;
      case AServer.ClientAuth of
        tlsAuthNone: I := 0;
        tlsAuthRequest: I := SSL_VERIFY_PEER;
      else I := SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
      end;
      Configure(FServerCtx, AServer.MinVersion, AServer.MaxVersion, Anchors,
        AServer.UseSystemTrust, AServer.AllowPartialChain, I,
        AServer.HasVerificationDepth, AServer.VerificationDepth);
      OpenSSLIdentityInstallContext(FServerCtx, AServer.ServerIdentity);
      if not OpenSSLInstallServerAlpn(FServerCtx) then
        raise ETlsContextError.Create('OpenSSL ALPN functions are not available');
    end;
  except
    if FClientCtx <> nil then SSL_CTX_free(FClientCtx);
    if FServerCtx <> nil then SSL_CTX_free(FServerCtx);
    FClientCtx := nil; FServerCtx := nil;
    raise;
  end;
end;

destructor TOpenSSLTlsContext.Destroy;
begin
  if FClientCtx <> nil then SSL_CTX_free(FClientCtx);
  if FServerCtx <> nil then SSL_CTX_free(FServerCtx);
  inherited Destroy;
end;
function TOpenSSLTlsContext.BackendName: string; begin Result := 'OpenSSL'; end;
function TOpenSSLTlsContext.Info: TTlsContextInfo; begin Result := FInfo; end;
function TOpenSSLTlsContext.Capabilities: TTlsCapabilities;
begin
  Result := Default(TTlsCapabilities); Result.Roles := FInfo.Roles;
  Result.Versions := [tls12, tls13]; Result.IdentityFormats := [tifPem, tifPkcs12];
  Result.SystemTrust := True; Result.PartialChain := True;
  Result.VerificationDepth := True;
end;
procedure TOpenSSLTlsContext.RequireAvailable;
begin
  if not OpenSslIsAvailable then
    raise EOpenSSLProviderUnavailable.Create('OpenSSL provider library is not available');
end;
function TOpenSSLTlsContext.CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
var Selected: ITLSIdentity;
begin
  if not (trClient in FInfo.Roles) then raise ETlsContextError.Create('client role is not enabled');
  if AOptions.IdentitySelection = tisExplicit then Selected := AOptions.Identity
  else Selected := FClient.DefaultIdentity;
  if (Selected <> nil) and not OpenSSLIdentityIsNative(Selected) then
    raise ETlsContextError.Create('client identity belongs to another TLS provider');
  if (Selected <> nil) and (OpenSSLIdentityMaterialSize(Selected) >
    TlsMaxHandshakeIdentityBytes) then
    raise ETlsContextError.Create('client certificate chain exceeds the TLS handshake bound');
  Result := TOpenSSLSession.Create(Self as ITLSContext, FClientCtx, trClient,
    AOptions.HostName, AOptions.ServerName, AOptions.AlpnValues,
    AOptions.HandshakeStartMs, AOptions.HandshakeDeadlineMs,
    FClient.VerifyHostname, FClient.VerifyPeer, Selected);
end;
function TOpenSSLTlsContext.CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
begin
  if not (trServer in FInfo.Roles) then raise ETlsContextError.Create('server role is not enabled');
  Result := TOpenSSLSession.Create(Self as ITLSContext, FServerCtx, trServer,
    '', '', AOptions.AlpnValues, AOptions.HandshakeStartMs,
    AOptions.HandshakeDeadlineMs, False, FServer.ClientAuth <> tlsAuthNone, nil);
end;


end.
