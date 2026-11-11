{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Identity;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  DateUtils,
  Http2.Client.Errors,
  Http2.Client.ClientCert,
  Http2.Client.Tls,
  Http2.Client.SocketFactory.Types;


function ChooseClientIdentity(const ASelector: IClientIdentitySelector;
  const AHost: string; const APort: Word): IClientIdentity;

procedure RequireIdentityFactory(const AFactory: IHttp2SocketFactory;
  const AWhat: string);

procedure CheckRequestIdentity(const AIdentity: IClientIdentity);

implementation

function ChooseClientIdentity(const ASelector: IClientIdentitySelector;
  const AHost: string; const APort: Word): IClientIdentity;
begin
  try
    Result := ASelector.Select(AHost, APort);
  except
    on E: Exception do
      raise EHttpTlsConfigError.CreateFmt(
        'the client identity selector failed for %s:%d: %s',
        [AHost, APort, E.Message]);
  end;
  // an expired answer is refused before anything is dialled; the message
  // names the expiry, never key material
  if (Result <> nil) and (Result.NotAfter < LocalTimeToUniversal(Now)) then
    raise EHttpTlsConfigError.CreateFmt(
      'the client identity selector returned a certificate for %s:%d that ' +
      'expired on %s UTC',
      [AHost, APort, FormatDateTime('yyyy-mm-dd hh:nn:ss', Result.NotAfter)]);
end;

/// raise EHttpTlsConfigError when an identity (or selector) is configured but
/// AFactory, an injected socket factory, cannot present identities

procedure RequireIdentityFactory(const AFactory: IHttp2SocketFactory;
  const AWhat: string);
begin
  if not Supports(AFactory, IIdentitySocketFactory) then
    raise EHttpTlsConfigError.CreateFmt(
      '%s, but the injected socket factory cannot present a client identity ' +
      '(it does not implement IIdentitySocketFactory)', [AWhat]);
end;

/// raise EHttpTlsConfigError when a request's own identity has expired, before
/// anything is dialled

procedure CheckRequestIdentity(const AIdentity: IClientIdentity);
begin
  if AIdentity = nil then
    Exit;
  if AIdentity.NotAfter < LocalTimeToUniversal(Now) then
    raise EHttpTlsConfigError.CreateFmt(
      'the request client certificate expired on %s UTC',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', AIdentity.NotAfter)]);
end;

end.
