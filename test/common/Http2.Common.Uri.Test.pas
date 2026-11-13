{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: uri, rfc3986, test
notes:
  - This test checks the URI parser, the reference resolution and the host rules.
---
}
unit Http2.Common.Uri.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Errors, Http2.Common.Uri;

type
  TUriTest = class(TTestCase)
  private
    procedure AssertRejected(const AUri: string);
    procedure AssertResolved(const ARef, AExpected: string);
  published
    procedure TestRfcNormalExamples;
    procedure TestRfcAbnormalExamples;
    procedure TestPathAndQueryWithoutAuthority;
    procedure TestFragmentHoldsAt;
    procedure TestBackslashIsRejected;
    procedure TestSpaceIsRejected;
    procedure TestDelIsRejected;
    procedure TestControlAndHighBytesAreRejected;
    procedure TestIPv6Literal;
    procedure TestIPv6ZoneIsRejected;
    procedure TestBadIPv6IsRejected;
    procedure TestEmptyPortMeansNoPort;
    procedure TestBadPortIsRejected;
    procedure TestSchemeAndHostLowerCase;
    procedure TestPercentEncodedUnreservedHost;
    procedure TestPercentEncodedSlashInHostIsRejected;
    procedure TestEmptyHostIsRejected;
    procedure TestUserInfoEndsAtLastAt;
    procedure TestMailto;
    procedure TestErrorCodeAndMessage;
    procedure TestTryParse;
    procedure TestAuthorityText;
    procedure TestSameHostAndOrigin;
    procedure TestHttpToHttpsUpgrade;
    procedure TestResolveNeedsAbsoluteBase;
  end;

implementation

const
  cBase = 'http://a/b/c/d;p?q';

procedure TUriTest.AssertRejected(const AUri: string);
var
  LRaised: Boolean;
  LUri: TURI;
begin
  LRaised := False;
  try
    LUri := ParseURI(AUri);
  except
    on EHttpProtocolError do
      LRaised := True;
  end;
  AssertTrue('rejects ' + AUri, LRaised);
  AssertFalse('TryParseURI ' + AUri, TryParseURI(AUri, LUri));
end;

procedure TUriTest.AssertResolved(const ARef, AExpected: string);
begin
  AssertEquals(ARef, AExpected,
    UriToString(ResolveReference(ParseURI(cBase), ParseURI(ARef))));
end;

procedure TUriTest.TestRfcNormalExamples;
begin
  AssertResolved('g:h', 'g:h');
  AssertResolved('g', 'http://a/b/c/g');
  AssertResolved('./g', 'http://a/b/c/g');
  AssertResolved('g/', 'http://a/b/c/g/');
  AssertResolved('/g', 'http://a/g');
  AssertResolved('//g', 'http://g');
  AssertResolved('?y', 'http://a/b/c/d;p?y');
  AssertResolved('g?y', 'http://a/b/c/g?y');
  AssertResolved('#s', 'http://a/b/c/d;p?q#s');
  AssertResolved('g#s', 'http://a/b/c/g#s');
  AssertResolved('g?y#s', 'http://a/b/c/g?y#s');
  AssertResolved(';x', 'http://a/b/c/;x');
  AssertResolved('g;x', 'http://a/b/c/g;x');
  AssertResolved('g;x?y#s', 'http://a/b/c/g;x?y#s');
  AssertResolved('', 'http://a/b/c/d;p?q');
  AssertResolved('.', 'http://a/b/c/');
  AssertResolved('./', 'http://a/b/c/');
  AssertResolved('..', 'http://a/b/');
  AssertResolved('../', 'http://a/b/');
  AssertResolved('../g', 'http://a/b/g');
  AssertResolved('../..', 'http://a/');
  AssertResolved('../../', 'http://a/');
  AssertResolved('../../g', 'http://a/g');
end;

procedure TUriTest.TestRfcAbnormalExamples;
begin
  AssertResolved('../../../g', 'http://a/g');
  AssertResolved('../../../../g', 'http://a/g');
  AssertResolved('/./g', 'http://a/g');
  AssertResolved('/../g', 'http://a/g');
  AssertResolved('g.', 'http://a/b/c/g.');
  AssertResolved('.g', 'http://a/b/c/.g');
  AssertResolved('g..', 'http://a/b/c/g..');
  AssertResolved('..g', 'http://a/b/c/..g');
  AssertResolved('./../g', 'http://a/b/g');
  AssertResolved('./g/.', 'http://a/b/c/g/');
  AssertResolved('g/./h', 'http://a/b/c/g/h');
  AssertResolved('g/../h', 'http://a/b/c/h');
  AssertResolved('g;x=1/./y', 'http://a/b/c/g;x=1/y');
  AssertResolved('g;x=1/../y', 'http://a/b/c/y');
  AssertResolved('g?y/./x', 'http://a/b/c/g?y/./x');
  AssertResolved('g?y/../x', 'http://a/b/c/g?y/../x');
  AssertResolved('g#s/./x', 'http://a/b/c/g#s/./x');
  AssertResolved('g#s/../x', 'http://a/b/c/g#s/../x');
  AssertResolved('http:g', 'http:g');
end;

procedure TUriTest.TestPathAndQueryWithoutAuthority;
var
  LUri: TURI;
begin
  LUri := ParseURI('/login?next=https://evil.com/x');
  AssertFalse('authority', LUri.HasAuthority);
  AssertFalse('absolute', LUri.IsAbsolute);
  AssertEquals('/login', LUri.Path);
  AssertTrue(LUri.HasQuery);
  AssertEquals('next=https://evil.com/x', LUri.Query);
  AssertEquals('', LUri.Host);
end;

procedure TUriTest.TestFragmentHoldsAt;
var
  LUri: TURI;
begin
  LUri := ParseURI('https://good.com#@evil.com/');
  AssertEquals('good.com', LUri.Host);
  AssertEquals('', LUri.UserInfo);
  AssertTrue(LUri.HasFragment);
  AssertEquals('@evil.com/', LUri.Fragment);
  AssertEquals('', LUri.Path);
end;

procedure TUriTest.TestBackslashIsRejected;
begin
  AssertRejected('https://good.com\@evil.com/');
  AssertRejected('/a\b');
end;

procedure TUriTest.TestSpaceIsRejected;
begin
  AssertRejected('http://a/b c');
  AssertRejected(' http://a/');
end;

procedure TUriTest.TestDelIsRejected;
begin
  AssertRejected('http://a/b' + #$7F);
end;

procedure TUriTest.TestControlAndHighBytesAreRejected;
begin
  AssertRejected('http://a/' + #0);
  AssertRejected('http://a/' + #13#10 + 'X: y');
  AssertRejected('http://a/' + #$80);
  AssertRejected('http://a/%zz');
  AssertRejected('http://a/%4');
end;

procedure TUriTest.TestIPv6Literal;
var
  LUri: TURI;
begin
  LUri := ParseURI('http://[::1]:8080/x');
  AssertEquals('::1', LUri.Host);
  AssertTrue(LUri.IsIPLiteral);
  AssertEquals(8080, LUri.Port);
  AssertEquals('[::1]:8080', LUri.Authority);
  AssertEquals('/x', LUri.Path);
  LUri := ParseURI('http://[2001:DB8::1]/');
  AssertEquals('2001:db8::1', LUri.Host);
  AssertEquals(-1, LUri.Port);
  AssertEquals('[2001:db8::1]', LUri.Authority);
  LUri := ParseURI('http://[::ffff:192.168.0.1]/');
  AssertEquals('::ffff:192.168.0.1', LUri.Host);
end;

procedure TUriTest.TestIPv6ZoneIsRejected;
begin
  AssertRejected('http://[fe80::1%25eth0]/');
  AssertRejected('http://[fe80::1%eth0]/');
end;

procedure TUriTest.TestBadIPv6IsRejected;
begin
  AssertRejected('http://[::1/');
  AssertRejected('http://[]/');
  AssertRejected('http://[1:2:3]/');
  AssertRejected('http://[1::2::3]/');
  AssertRejected('http://[::1]x/');
  AssertRejected('http://[v1.x]/');
end;

procedure TUriTest.TestEmptyPortMeansNoPort;
var
  LUri: TURI;
begin
  LUri := ParseURI('http://h:/');
  AssertFalse(LUri.HasPort);
  AssertEquals(-1, LUri.Port);
  AssertEquals('h', LUri.Host);
  AssertEquals('/', LUri.Path);
end;

procedure TUriTest.TestBadPortIsRejected;
begin
  AssertRejected('http://h:99999/');
  AssertRejected('http://h:65536/');
  AssertRejected('http://h:8x/');
  AssertRejected('http://h:1:2/');
  AssertEquals(65535, ParseURI('http://h:65535/').Port);
  AssertEquals(0, ParseURI('http://h:0/').Port);
end;

procedure TUriTest.TestSchemeAndHostLowerCase;
var
  LUri: TURI;
begin
  LUri := ParseURI('HTTP://GOOD.com./');
  AssertEquals('http', LUri.Scheme);
  AssertEquals('good.com', LUri.Host);
  AssertRejected('1http://a/');
  AssertRejected('ht_tp://a/');
  AssertRejected('://a/');
end;

procedure TUriTest.TestPercentEncodedUnreservedHost;
begin
  AssertEquals('good.com', ParseURI('http://good%2Ecom/').Host);
  AssertEquals('good.com', ParseURI('http://GOOD%2ecom/').Host);
end;

procedure TUriTest.TestPercentEncodedSlashInHostIsRejected;
begin
  AssertRejected('http://good%2Fcom/');
  AssertRejected('http://good%40evil/');
end;

procedure TUriTest.TestEmptyHostIsRejected;
begin
  AssertRejected('http:///x');
  AssertRejected('https:///x');
  AssertRejected('http://./x');
  AssertEquals('', ParseURI('file:///x').Host);
end;

procedure TUriTest.TestUserInfoEndsAtLastAt;
var
  LUri: TURI;
begin
  LUri := ParseURI('http://user:pw@a@evil.com/x');
  AssertEquals('user:pw@a', LUri.UserInfo);
  AssertTrue(LUri.HasUserInfo);
  AssertEquals('evil.com', LUri.Host);
  LUri := ParseURI('http://a.com?@evil.com/');
  AssertEquals('a.com', LUri.Host);
  AssertEquals('@evil.com/', LUri.Query);
  LUri := ParseURI('http://a.com/@evil.com/');
  AssertEquals('a.com', LUri.Host);
  AssertFalse(LUri.HasUserInfo);
end;

procedure TUriTest.TestMailto;
var
  LUri: TURI;
begin
  LUri := ParseURI('mailto:a@b');
  AssertEquals('mailto', LUri.Scheme);
  AssertFalse(LUri.HasAuthority);
  AssertEquals('a@b', LUri.Path);
end;

procedure TUriTest.TestErrorCodeAndMessage;
var
  LCode: THttp2ErrorCode;
  LMessage: string;
begin
  LCode := ecNoError;
  LMessage := '';
  try
    ParseURI('http://secret-host\x/');
  except
    on E: EHttpProtocolError do
    begin
      LCode := E.ErrorCode;
      LMessage := E.Message;
    end;
  end;
  AssertTrue(LCode = ecProtocolError);
  AssertEquals(0, Pos('secret-host', LMessage));
end;

procedure TUriTest.TestTryParse;
var
  LUri: TURI;
begin
  AssertTrue(TryParseURI('http://a/b', LUri));
  AssertEquals('a', LUri.Host);
  AssertTrue(TryParseURI('', LUri));
  AssertEquals('', LUri.Path);
end;

procedure TUriTest.TestAuthorityText;
begin
  AssertEquals('a.com:81', ParseURI('http://u@a.com:81/').Authority);
  AssertEquals('a.com', ParseURI('http://a.com/').Authority);
  AssertEquals('http://u@a.com:81/p?q#f',
    UriToString(ParseURI('HTTP://u@A.com:81/p?q#f')));
end;

procedure TUriTest.TestSameHostAndOrigin;
begin
  AssertTrue(SameHost(ParseURI('http://a.com/x'), ParseURI('https://A.COM./y')));
  AssertFalse(SameHost(ParseURI('http://a.com/'), ParseURI('http://b.com/')));
  AssertFalse(SameHost(ParseURI('/a'), ParseURI('/b')));
  AssertTrue(SameOrigin(ParseURI('http://a.com/'), ParseURI('http://a.com:80/x')));
  AssertTrue(SameOrigin(ParseURI('https://a.com/'),
    ParseURI('https://a.com:443/x')));
  AssertFalse(SameOrigin(ParseURI('http://a.com/'), ParseURI('https://a.com/')));
  AssertFalse(SameOrigin(ParseURI('http://a.com/'),
    ParseURI('http://a.com:8080/')));
end;

procedure TUriTest.TestHttpToHttpsUpgrade;
begin
  AssertTrue(IsHttpToHttpsUpgrade(ParseURI('http://a.com/'),
    ParseURI('https://a.com/x')));
  AssertFalse(IsHttpToHttpsUpgrade(ParseURI('https://a.com/'),
    ParseURI('http://a.com/')));
  AssertFalse(IsHttpToHttpsUpgrade(ParseURI('http://a.com/'),
    ParseURI('https://b.com/')));
  AssertFalse(IsHttpToHttpsUpgrade(ParseURI('http://a.com/'),
    ParseURI('http://a.com/')));
end;

procedure TUriTest.TestResolveNeedsAbsoluteBase;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ResolveReference(ParseURI('/a'), ParseURI('b'));
  except
    on EHttpProtocolError do
      LRaised := True;
  end;
  AssertTrue(LRaised);
end;

initialization
  RegisterTest(TUriTest);
end.
