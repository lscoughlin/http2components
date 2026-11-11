{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, factory, tlslib
notes:
  - This unit validates immutable TlsLib context policies before construction.
---
}
unit Http2.TlsLib.Factory;

{$mode delphi}{$H+}{$interfaces com}{$modeswitch advancedrecords}

interface

uses
  Http2.Common.Tls.Types, Http2.Common.Tls.Policy, Http2.Common.Tls.Context;

type
  TTlsLibContextFactory = record
  private
    FRoles: TTlsRoles;
    FClientPolicy: TTlsClientPolicy;
    FServerPolicy: TTlsServerPolicy;
    FTimeoutMs: Cardinal;
  public
    class function Create: TTlsLibContextFactory; static;
    function WithClientPolicy(const APolicy: TTlsClientPolicy): TTlsLibContextFactory;
    function WithServerPolicy(const APolicy: TTlsServerPolicy): TTlsLibContextFactory;
    function WithHandshakeTimeoutMs(const AValue: Cardinal): TTlsLibContextFactory;
    function Build: ITLSContext;
  end;

implementation

uses
  SysUtils, Http2.Common.Tls.Identity,
  Http2.TlsLib.Context, Http2.TlsLib.Identity, Http2.TlsLib.Trust;

class function TTlsLibContextFactory.Create: TTlsLibContextFactory;
begin
  Result := Default(TTlsLibContextFactory);
  Result.FClientPolicy := TTlsClientPolicy.SecureDefault;
  Result.FServerPolicy := TTlsServerPolicy.SecureDefault;
end;

function TTlsLibContextFactory.WithClientPolicy(const APolicy: TTlsClientPolicy): TTlsLibContextFactory;
begin Result := Self; Result.FClientPolicy := APolicy; Include(Result.FRoles, trClient); end;

function TTlsLibContextFactory.WithServerPolicy(const APolicy: TTlsServerPolicy): TTlsLibContextFactory;
begin Result := Self; Result.FServerPolicy := APolicy; Include(Result.FRoles, trServer); end;

function TTlsLibContextFactory.WithHandshakeTimeoutMs(const AValue: Cardinal): TTlsLibContextFactory;
begin Result := Self; Result.FTimeoutMs := AValue; end;

function TTlsLibContextFactory.Build: ITLSContext;
var I: ITLSIdentity; ClientTrust, ServerTrust: TBytes;
  Marker: ITlsLibIdentityMarker; ServerMaterialBytes: SizeInt;
begin
  if FRoles = [] then raise ETlsContextError.Create('TlsLib context requires at least one role');
  if FClientPolicy.UseSystemTrust or FServerPolicy.UseSystemTrust then
    raise ETlsContextError.Create('TlsLib system trust is unsupported');
  if FClientPolicy.HasVerificationDepth or FServerPolicy.HasVerificationDepth then
    raise ETlsContextError.Create('TlsLib verification depth is fixed at four');
  if FClientPolicy.VerifyPeer and not FClientPolicy.VerifyHostname then
    raise ETlsContextError.Create('TlsLib requires hostname verification with peer verification');
  if FClientPolicy.VerifyHostname and not FClientPolicy.VerifyPeer then
    raise ETlsContextError.Create('TlsLib hostname verification requires peer verification');
  if (FClientPolicy.MinVersion > FClientPolicy.MaxVersion) or
     (FServerPolicy.MinVersion > FServerPolicy.MaxVersion) then
    raise ETlsContextError.Create('TlsLib minimum TLS version exceeds maximum version');
  I := FClientPolicy.DefaultIdentity;
  if (I <> nil) and not Supports(I, ITlsLibIdentityMarker) then
    raise ETlsContextError.Create('TlsLib cannot use an identity from another provider');
  if (I <> nil) and Supports(I, ITlsLibIdentityMarker, Marker) and
     (Marker.CertificateBytes > 32 * 1024) then
    raise ETlsContextError.Create('TlsLib client certificate chain exceeds the 32 KiB handshake budget');
  I := FServerPolicy.ServerIdentity;
  if (I <> nil) and not Supports(I, ITlsLibIdentityMarker) then
    raise ETlsContextError.Create('TlsLib cannot use an identity from another provider');
  ServerMaterialBytes := 0;
  if (I <> nil) and Supports(I, ITlsLibIdentityMarker, Marker) then
    ServerMaterialBytes := Marker.CertificateBytes;
  ClientTrust := TlsLibLoadTrustAnchors(FClientPolicy.TrustAnchors,
    FClientPolicy.AllowPartialChain);
  ServerTrust := TlsLibLoadTrustAnchors(FServerPolicy.TrustAnchors,
    FServerPolicy.AllowPartialChain);
  if (trClient in FRoles) and FClientPolicy.VerifyPeer and (Length(ClientTrust) = 0) then
    raise ETlsContextError.Create('TlsLib verified client role requires trust anchors');
  if (trServer in FRoles) and (FServerPolicy.ServerIdentity = nil) then
    raise ETlsContextError.Create('TlsLib server role requires a server identity');
  if (trServer in FRoles) and (FServerPolicy.ClientAuth <> tlsAuthNone) and
     (Length(ServerTrust) = 0) then
    raise ETlsContextError.Create('TlsLib client authentication requires trust anchors');
  if (trServer in FRoles) and (ServerMaterialBytes > 32 * 1024) then
    raise ETlsContextError.Create('TlsLib server certificate chain exceeds the 32 KiB handshake budget');
  if (trServer in FRoles) and (FServerPolicy.ClientAuth <> tlsAuthNone) and
     (ServerMaterialBytes + Length(ServerTrust) > 32 * 1024) then
    raise ETlsContextError.Create(
      'TlsLib server certificate and advertised trust names exceed the 32 KiB handshake budget');
  Result := TTlsLibContext.Create(FRoles, FClientPolicy, FServerPolicy, FTimeoutMs,
    ClientTrust, ServerTrust);
end;

end.
