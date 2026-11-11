{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, policy, options
notes:
  - This unit defines immutable-by-copy role policy and session options.
---
}
unit Http2.Common.Tls.Policy;
{$mode delphi}{$H+}{$modeswitch advancedrecords}{$interfaces com}
interface
uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Identity;
type
  TTlsClientPolicy = record
  private FTrustAnchors: TArray<string>;
  public
    MinVersion, MaxVersion: TTlsVersion;
    VerifyPeer, VerifyHostname, UseSystemTrust: Boolean;
    AllowPartialChain, HasVerificationDepth: Boolean;
    VerificationDepth: Integer;
    DefaultIdentity: ITLSIdentity;
    class function SecureDefault: TTlsClientPolicy; static;
    { Trust anchor values are filesystem paths to PEM certificate files. }
    function WithTrustAnchors(const AValues: array of string): TTlsClientPolicy;
    function TrustAnchors: TArray<string>;
    function WithVersions(const AMin, AMax: TTlsVersion): TTlsClientPolicy;
    function WithInsecure(const AValue: Boolean): TTlsClientPolicy;
    function WithDefaultIdentity(const AValue: ITLSIdentity): TTlsClientPolicy;
    function WithSystemTrust(const AValue: Boolean): TTlsClientPolicy;
    function WithPartialChain(const AValue: Boolean): TTlsClientPolicy;
    function WithVerificationDepth(const AValue: Integer): TTlsClientPolicy;
  end;
  TTlsServerPolicy = record
  private FTrustAnchors: TArray<string>;
  public
    MinVersion, MaxVersion: TTlsVersion;
    ClientAuth: TTlsClientAuthMode;
    UseSystemTrust, AllowPartialChain, HasVerificationDepth: Boolean;
    VerificationDepth: Integer;
    ServerIdentity: ITLSIdentity;
    class function SecureDefault: TTlsServerPolicy; static;
    { Trust anchor values are filesystem paths to PEM certificate files. }
    function WithTrustAnchors(const AValues: array of string): TTlsServerPolicy;
    function TrustAnchors: TArray<string>;
    function WithVersions(const AMin, AMax: TTlsVersion): TTlsServerPolicy;
    function WithClientAuth(const AMode: TTlsClientAuthMode): TTlsServerPolicy;
    function WithServerIdentity(const AValue: ITLSIdentity): TTlsServerPolicy;
    function WithSystemTrust(const AValue: Boolean): TTlsServerPolicy;
    function WithPartialChain(const AValue: Boolean): TTlsServerPolicy;
    function WithVerificationDepth(const AValue: Integer): TTlsServerPolicy;
  end;
  TTlsIdentitySelection = (tisUseDefault, tisExplicit);
  TTlsClientSessionOptions = record
  private FAlpns: TArray<string>;
  public
    HostName, ServerName: string;
    IdentitySelection: TTlsIdentitySelection;
    Identity: ITLSIdentity;
    { Monotonic time sampled when the adapter creates the session. }
    HandshakeStartMs: Int64;
    { Zero means no additional role deadline. }
    HandshakeDeadlineMs: Int64;
    function WithAlpns(const AValues: array of string): TTlsClientSessionOptions;
    function AlpnValues: TArray<string>;
  end;
  TTlsServerSessionOptions = record
  private FAlpns: TArray<string>;
  public
    { Monotonic time sampled when the adapter creates the session. }
    HandshakeStartMs: Int64;
    { Zero means no additional role deadline. }
    HandshakeDeadlineMs: Int64;
    function WithAlpns(const AValues: array of string): TTlsServerSessionOptions;
    function AlpnValues: TArray<string>;
  end;
implementation
function CopyStrings(const AValues: array of string): TArray<string>;
var I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do Result[I] := AValues[I];
end;
class function TTlsClientPolicy.SecureDefault: TTlsClientPolicy;
begin
  Result := Default(TTlsClientPolicy);
  Result.MinVersion := tls12; Result.MaxVersion := tls13;
  Result.VerifyPeer := True; Result.VerifyHostname := True;
end;
function TTlsClientPolicy.WithTrustAnchors(const AValues: array of string): TTlsClientPolicy;
begin
  Result := Self;
  Result.FTrustAnchors := CopyStrings(AValues);
end;
function TTlsClientPolicy.TrustAnchors: TArray<string>;
begin
  Result := Copy(FTrustAnchors);
end;
function TTlsClientPolicy.WithVersions(const AMin, AMax: TTlsVersion): TTlsClientPolicy;
begin
  Result := Self;
  Result.MinVersion := AMin;
  Result.MaxVersion := AMax;
end;
function TTlsClientPolicy.WithInsecure(const AValue: Boolean): TTlsClientPolicy;
begin
  Result := Self;
  Result.VerifyPeer := not AValue;
  Result.VerifyHostname := not AValue;
end;
function TTlsClientPolicy.WithDefaultIdentity(const AValue: ITLSIdentity): TTlsClientPolicy;
begin
  Result := Self;
  Result.DefaultIdentity := AValue;
end;
function TTlsClientPolicy.WithSystemTrust(const AValue: Boolean): TTlsClientPolicy;
begin
  Result := Self;
  Result.UseSystemTrust := AValue;
end;
function TTlsClientPolicy.WithPartialChain(const AValue: Boolean): TTlsClientPolicy;
begin
  Result := Self;
  Result.AllowPartialChain := AValue;
end;
function TTlsClientPolicy.WithVerificationDepth(const AValue: Integer): TTlsClientPolicy;
begin
  if AValue < 0 then
    raise ETlsContextError.Create('Verification depth cannot be negative');
  Result := Self;
  Result.HasVerificationDepth := True;
  Result.VerificationDepth := AValue;
end;
class function TTlsServerPolicy.SecureDefault: TTlsServerPolicy;
begin Result := Default(TTlsServerPolicy); Result.MinVersion := tls12; Result.MaxVersion := tls13; end;
function TTlsServerPolicy.WithTrustAnchors(const AValues: array of string): TTlsServerPolicy;
begin
  Result := Self;
  Result.FTrustAnchors := CopyStrings(AValues);
end;
function TTlsServerPolicy.TrustAnchors: TArray<string>;
begin
  Result := Copy(FTrustAnchors);
end;
function TTlsServerPolicy.WithVersions(const AMin, AMax: TTlsVersion): TTlsServerPolicy;
begin
  Result := Self;
  Result.MinVersion := AMin;
  Result.MaxVersion := AMax;
end;
function TTlsServerPolicy.WithClientAuth(const AMode: TTlsClientAuthMode): TTlsServerPolicy;
begin
  Result := Self;
  Result.ClientAuth := AMode;
end;
function TTlsServerPolicy.WithServerIdentity(const AValue: ITLSIdentity): TTlsServerPolicy;
begin
  Result := Self;
  Result.ServerIdentity := AValue;
end;
function TTlsServerPolicy.WithSystemTrust(const AValue: Boolean): TTlsServerPolicy;
begin
  Result := Self;
  Result.UseSystemTrust := AValue;
end;
function TTlsServerPolicy.WithPartialChain(const AValue: Boolean): TTlsServerPolicy;
begin
  Result := Self;
  Result.AllowPartialChain := AValue;
end;
function TTlsServerPolicy.WithVerificationDepth(const AValue: Integer): TTlsServerPolicy;
begin
  if AValue < 0 then
    raise ETlsContextError.Create('Verification depth cannot be negative');
  Result := Self;
  Result.HasVerificationDepth := True;
  Result.VerificationDepth := AValue;
end;
function TTlsClientSessionOptions.WithAlpns(const AValues: array of string): TTlsClientSessionOptions;
begin
  Result := Self;
  Result.FAlpns := CopyStrings(AValues);
end;
function TTlsClientSessionOptions.AlpnValues: TArray<string>;
begin
  Result := Copy(FAlpns);
end;
function TTlsServerSessionOptions.WithAlpns(const AValues: array of string): TTlsServerSessionOptions;
begin
  Result := Self;
  Result.FAlpns := CopyStrings(AValues);
end;
function TTlsServerSessionOptions.AlpnValues: TArray<string>;
begin
  Result := Copy(FAlpns);
end;
end.
