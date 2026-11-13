{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, redirect
notes:
  - this holds the table tests of the redirect decision for each policy
---
}
unit Http2.Client.Redirect.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Common.Uri, Http2.Client.Config.Security, Http2.Client.Redirect;

type
  TRedirectDecisionTest = class(TTestCase)
  private
    function Decide(APolicy: TRedirectPolicy; const ABase, ATarget: string):
      TRedirectDecision;
  published
    procedure TestAnyHostFollowsSameScheme;
    procedure TestAnyHostRefusesSchemeChange;
    procedure TestSameHostOnlyRows;
    procedure TestSameOriginOnlyRows;
    procedure TestSameOriginUpgradeRows;
    procedure TestOtherSchemeRefusedByEveryPolicy;
    procedure TestStripOnOriginChange;
  end;

implementation

function TRedirectDecisionTest.Decide(APolicy: TRedirectPolicy;
  const ABase, ATarget: string): TRedirectDecision;
begin
  Result := DecideRedirect(APolicy, ParseURI(ABase), ParseURI(ATarget));
end;

procedure TRedirectDecisionTest.TestAnyHostFollowsSameScheme;
begin
  AssertTrue('same origin', Decide(rpAnyHost,
    'https://a.example/x', 'https://a.example/y') = rdFollow);
  AssertTrue('other port', Decide(rpAnyHost,
    'https://a.example/x', 'https://a.example:8443/y') = rdFollow);
  AssertTrue('other host', Decide(rpAnyHost,
    'https://a.example/x', 'https://b.example/y') = rdFollow);
  AssertTrue('http to http, other host', Decide(rpAnyHost,
    'http://a.example/x', 'http://b.example/y') = rdFollow);
end;

procedure TRedirectDecisionTest.TestAnyHostRefusesSchemeChange;
begin
  AssertTrue('https to http', Decide(rpAnyHost,
    'https://a.example/x', 'http://a.example/x') = rdRefuse);
  AssertTrue('http to https, same host', Decide(rpAnyHost,
    'http://a.example/x', 'https://a.example/x') = rdRefuse);
end;

procedure TRedirectDecisionTest.TestSameHostOnlyRows;
begin
  AssertTrue('same origin', Decide(rpSameHostOnly,
    'https://a.example/x', 'https://a.example/y') = rdFollow);
  AssertTrue('other port, same host', Decide(rpSameHostOnly,
    'https://a.example/x', 'https://a.example:8443/y') = rdFollow);
  AssertTrue('other host', Decide(rpSameHostOnly,
    'https://a.example/x', 'https://b.example/y') = rdRefuse);
  AssertTrue('https to http', Decide(rpSameHostOnly,
    'https://a.example/x', 'http://a.example/x') = rdRefuse);
  AssertTrue('http to https', Decide(rpSameHostOnly,
    'http://a.example/x', 'https://a.example/x') = rdRefuse);
end;

procedure TRedirectDecisionTest.TestSameOriginOnlyRows;
begin
  AssertTrue('same origin', Decide(rpSameOriginOnly,
    'https://a.example/x', 'https://a.example/y') = rdFollow);
  AssertTrue('default port is the same origin', Decide(rpSameOriginOnly,
    'https://a.example/x', 'https://a.example:443/y') = rdFollow);
  AssertTrue('other port', Decide(rpSameOriginOnly,
    'https://a.example/x', 'https://a.example:8443/y') = rdRefuse);
  AssertTrue('other host', Decide(rpSameOriginOnly,
    'https://a.example/x', 'https://b.example/y') = rdRefuse);
  AssertTrue('https to http', Decide(rpSameOriginOnly,
    'https://a.example/x', 'http://a.example/x') = rdRefuse);
  AssertTrue('http to https', Decide(rpSameOriginOnly,
    'http://a.example/x', 'https://a.example/x') = rdRefuse);
end;

procedure TRedirectDecisionTest.TestSameOriginUpgradeRows;
begin
  AssertTrue('same origin', Decide(rpSameOriginUpgrade,
    'https://a.example/x', 'https://a.example/y') = rdFollow);
  AssertTrue('other port', Decide(rpSameOriginUpgrade,
    'https://a.example/x', 'https://a.example:8443/y') = rdRefuse);
  AssertTrue('other host', Decide(rpSameOriginUpgrade,
    'https://a.example/x', 'https://b.example/y') = rdRefuse);
  AssertTrue('https to http', Decide(rpSameOriginUpgrade,
    'https://a.example/x', 'http://a.example/x') = rdRefuse);
  AssertTrue('http to https, same host', Decide(rpSameOriginUpgrade,
    'http://a.example/x', 'https://a.example/x') = rdFollow);
  AssertTrue('http to https, port 80 to 443', Decide(rpSameOriginUpgrade,
    'http://a.example:80/x', 'https://a.example:443/x') = rdFollow);
  AssertTrue('http to https, other host', Decide(rpSameOriginUpgrade,
    'http://a.example/x', 'https://b.example/x') = rdRefuse);
end;

procedure TRedirectDecisionTest.TestOtherSchemeRefusedByEveryPolicy;
var
  P: TRedirectPolicy;
begin
  for P := Low(TRedirectPolicy) to High(TRedirectPolicy) do
  begin
    AssertTrue('ftp refused', Decide(P,
      'https://a.example/x', 'ftp://a.example/x') = rdRefuse);
    AssertTrue('ftp refused from http', Decide(P,
      'http://a.example/x', 'ftp://a.example/x') = rdRefuse);
  end;
end;

procedure TRedirectDecisionTest.TestStripOnOriginChange;
begin
  AssertFalse('same origin keeps credentials', StripOnOriginChange(
    ParseURI('https://a.example/x'), ParseURI('https://a.example/y'),
    rpAnyHost));
  AssertTrue('other port drops credentials', StripOnOriginChange(
    ParseURI('https://a.example/x'), ParseURI('https://a.example:8443/y'),
    rpAnyHost));
  AssertTrue('other host drops credentials', StripOnOriginChange(
    ParseURI('https://a.example/x'), ParseURI('https://b.example/y'),
    rpSameHostOnly));
  AssertFalse('upgrade keeps credentials under rpSameOriginUpgrade',
    StripOnOriginChange(ParseURI('http://a.example/x'),
    ParseURI('https://a.example/x'), rpSameOriginUpgrade));
  AssertTrue('upgrade drops credentials under rpSameOriginOnly',
    StripOnOriginChange(ParseURI('http://a.example/x'),
    ParseURI('https://a.example/x'), rpSameOriginOnly));
end;

initialization
  RegisterTest(TRedirectDecisionTest);
end.
