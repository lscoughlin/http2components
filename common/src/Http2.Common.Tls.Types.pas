{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, types, capabilities
notes:
  - This unit defines provider-neutral TLS enums and context summaries.
---
}
unit Http2.Common.Tls.Types;
{$mode delphi}{$H+}{$interfaces com}
interface
uses SysUtils;
type
  TTlsVersion = (tls12, tls13);
  TTlsRole = (trClient, trServer);
  TTlsRoles = set of TTlsRole;
  TTlsClientAuthMode = (tlsAuthNone, tlsAuthRequest, tlsAuthRequire);
  TTlsIdentityFormat = (tifPem, tifDer, tifPkcs12);
  TTlsIdentityFormats = set of TTlsIdentityFormat;
  TTlsSessionState = (tssNew, tssHandshaking, tssOpen, tssClosing, tssClosed, tssFailed);
  TTlsErrorCategory = (tecConfiguration, tecVerification, tecProtocol,
    tecTransportEof, tecTimeout, tecAlert, tecInternal);
  TTlsCapabilities = record
    Roles: TTlsRoles;
    Versions: set of TTlsVersion;
    IdentityFormats: TTlsIdentityFormats;
    SystemTrust, PartialChain, VerificationDepth: Boolean;
    SessionResumption, EarlyData: Boolean;
  end;
  TTlsContextInfo = record
    Roles: TTlsRoles;
    ClientAuth: TTlsClientAuthMode;
    HandshakeTimeoutMs: Cardinal;
    function RequiresClientCertificate: Boolean;
  end;
  ETlsContextError = class(Exception)
  private FCategory: TTlsErrorCategory;
  public
    constructor Create(const AMessage: string; const ACategory: TTlsErrorCategory = tecConfiguration);
    property Category: TTlsErrorCategory read FCategory;
  end;
  ETlsSessionError = class(Exception)
  private FCategory: TTlsErrorCategory; FProviderDetail: string;
  public
    constructor Create(const AMessage: string; const ACategory: TTlsErrorCategory;
      const AProviderDetail: string = '');
    property Category: TTlsErrorCategory read FCategory;
    property ProviderDetail: string read FProviderDetail;
  end;
const
  TlsMaxEncryptedInput = 16384;
  TlsMaxEncryptedOutput = 65536;
  TlsMaxPlaintextBuffer = 65536;
implementation
function TTlsContextInfo.RequiresClientCertificate: Boolean;
begin
  Result := (trServer in Roles) and (ClientAuth = tlsAuthRequire);
end;
constructor ETlsContextError.Create(const AMessage: string; const ACategory: TTlsErrorCategory);
begin
  inherited Create(AMessage);
  FCategory := ACategory;
end;
constructor ETlsSessionError.Create(const AMessage: string; const ACategory: TTlsErrorCategory;
  const AProviderDetail: string);
begin
  inherited Create(AMessage);
  FCategory := ACategory;
  FProviderDetail := AProviderDetail;
end;
end.
