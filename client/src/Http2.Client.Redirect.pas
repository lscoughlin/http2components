{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, redirect
notes:
  - this decides whether the client follows a redirect and whether it drops the credentials
---
}
unit Http2.Client.Redirect;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  Http2.Common.Uri, Http2.Client.Config.Security;

type
  /// the outcome of the redirect decision for one hop
  TRedirectDecision = (rdFollow, rdRefuse);

/// decide whether a redirect from ABase to ATarget is followed under APolicy
// - a scheme other than http and https is refused under every policy
// - a scheme change is refused, except the http to https upgrade under
//   rpSameOriginUpgrade
function DecideRedirect(APolicy: TRedirectPolicy;
  const ABase, ATarget: TURI): TRedirectDecision;

/// True when the next request drops authorization, cookie and
/// proxy-authorization.  The request keeps them only for the same origin, and
/// for the http to https upgrade under rpSameOriginUpgrade.
function StripOnOriginChange(const ABase, ATarget: TURI;
  APolicy: TRedirectPolicy): Boolean;

implementation

function IsHttpOrHttps(const AScheme: string): Boolean;
begin
  Result := (AScheme = 'http') or (AScheme = 'https');
end;

function DecideRedirect(APolicy: TRedirectPolicy;
  const ABase, ATarget: TURI): TRedirectDecision;
begin
  Result := rdRefuse;
  if not IsHttpOrHttps(ATarget.Scheme) then
    Exit;
  if ABase.Scheme = ATarget.Scheme then
  begin
    case APolicy of
      rpAnyHost:
        Result := rdFollow;
      rpSameHostOnly:
        if SameHost(ABase, ATarget) then
          Result := rdFollow;
      rpSameOriginOnly, rpSameOriginUpgrade:
        if SameOrigin(ABase, ATarget) then
          Result := rdFollow;
    end;
  end
  else if (APolicy = rpSameOriginUpgrade) and
    IsHttpToHttpsUpgrade(ABase, ATarget) then
    Result := rdFollow;
end;

function StripOnOriginChange(const ABase, ATarget: TURI;
  APolicy: TRedirectPolicy): Boolean;
begin
  if (APolicy = rpSameOriginUpgrade) and IsHttpToHttpsUpgrade(ABase, ATarget) then
    Exit(False);
  Result := not SameOrigin(ABase, ATarget);
end;

end.
