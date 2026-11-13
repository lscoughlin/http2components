{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, url, uri, redirect, proxy
notes:
  - this tests the client URL wrappers over the shared ParseURI parser
---
}
/// Client URL tests (doc/design/common/uri.md).
// - the wrappers of Http2.Client.Url and SplitProxyTarget use ParseURI, so the
//   client and the proxy match read one host from one string.
unit Http2.Client.Url.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client.Errors, Http2.Client.Url,
  Http2.Client.Proxy;

type
  TClientUrlTest = class(TTestCase)
  private
    function RaisesProtocolError(const AUrl: string): Boolean;
  published
    procedure TestLocationKeepsTheBaseHost;
    procedure TestRelativeLocationStaysOnTheHost;
    procedure TestEmptyLocationStaysEmpty;
    procedure TestIpv6BaseKeepsBracketsInResolvedUrl;
    procedure TestFragmentAfterHostIsNotUserinfo;
    procedure TestBackslashInAuthorityRaises;
    procedure TestPortOutOfRangeRaises;
    procedure TestNonDigitPortRaises;
    procedure TestDollarPortRaises;
    procedure TestPortZeroRaises;
    procedure TestSchemeLessInputGetsHttps;
    procedure TestSchemeLessLocalhostFragmentInBothParsers;
    procedure TestSplitProxyTargetRejectsBadPort;
    procedure TestPathAndQueryWithoutFragment;
    procedure TestPathIsNotDecoded;
    procedure TestOriginOfFragmentHostIsTheHost;
  end;

implementation

function TClientUrlTest.RaisesProtocolError(const AUrl: string): Boolean;
var
  H, P: string;
  N: Word;
begin
  Result := False;
  try
    ParseHttpUrl(AUrl, H, N, P);
  except
    on EHttpProtocolError do Result := True;
  end;
end;

procedure TClientUrlTest.TestLocationKeepsTheBaseHost;
begin
  // H2: a query that holds a URL does not make the Location absolute
  AssertEquals('https://good.com/login?next=https://evil.com/x',
    ResolveLocation('https://good.com/a/b', '/login?next=https://evil.com/x'));
end;

procedure TClientUrlTest.TestRelativeLocationStaysOnTheHost;
begin
  AssertEquals('https://good.com/a/c',
    ResolveLocation('https://good.com/a/b', 'c'));
  AssertEquals('https://good.com/x',
    ResolveLocation('https://good.com/a/b', '../x'));
end;

procedure TClientUrlTest.TestEmptyLocationStaysEmpty;
begin
  AssertEquals('', ResolveLocation('https://good.com/a', ''));
end;

procedure TClientUrlTest.TestIpv6BaseKeepsBracketsInResolvedUrl;
begin
  AssertEquals('https://[::1]:8443/b',
    ResolveLocation('https://[::1]:8443/a', 'b'));
end;

procedure TClientUrlTest.TestFragmentAfterHostIsNotUserinfo;
var
  H, P: string;
  N: Word;
begin
  // M2: the '@' sits in the fragment, so the host is good.com
  ParseHttpUrl('https://good.com#@evil.com/', H, N, P);
  AssertEquals('good.com', H);
  AssertEquals(443, Integer(N));
  AssertEquals('/', P);
  AssertEquals('good.com', OriginOfUrl('https://good.com#@evil.com/'));
end;

procedure TClientUrlTest.TestBackslashInAuthorityRaises;
begin
  // M2: a backslash is an error, so no parser reads it as a slash
  AssertTrue('backslash', RaisesProtocolError('https://good.com\@evil.com/'));
  AssertTrue('origin of backslash', RaisesProtocolError('https://good.com\x'));
end;

procedure TClientUrlTest.TestPortOutOfRangeRaises;
begin
  AssertTrue('99999', RaisesProtocolError('https://host:99999/'));
  AssertTrue('65536', RaisesProtocolError('https://host:65536/'));
end;

procedure TClientUrlTest.TestNonDigitPortRaises;
begin
  AssertTrue('abc', RaisesProtocolError('https://host:abc/'));
end;

procedure TClientUrlTest.TestDollarPortRaises;
begin
  AssertTrue('$50', RaisesProtocolError('https://host:$50/'));
end;

procedure TClientUrlTest.TestPortZeroRaises;
begin
  AssertTrue('0', RaisesProtocolError('https://host:0/'));
end;

procedure TClientUrlTest.TestSchemeLessInputGetsHttps;
var
  H, P: string;
  N: Word;
begin
  // the owner decision Q7: a URL with no scheme takes https
  ParseHttpUrl('host/path', H, N, P);
  AssertEquals('host', H);
  AssertEquals(443, Integer(N));
  AssertEquals('/path', P);
  AssertEquals('https', SchemeOfUrl('host/path'));
end;

procedure TClientUrlTest.TestSchemeLessLocalhostFragmentInBothParsers;
var
  H, P, Scheme, Host: string;
  N: Word;
  Port: Word;
begin
  ParseHttpUrl('localhost#@evil.com', H, N, P);
  AssertEquals('localhost', H);
  AssertTrue(SplitProxyTarget('localhost#@evil.com', Scheme, Host, Port));
  AssertEquals('localhost', Host);
  AssertEquals('https', Scheme);
end;

procedure TClientUrlTest.TestSplitProxyTargetRejectsBadPort;
var
  Scheme, Host: string;
  Port: Word;
begin
  AssertFalse(SplitProxyTarget('http://h:99999/', Scheme, Host, Port));
  AssertFalse(SplitProxyTarget('http://h:0/', Scheme, Host, Port));
  AssertFalse(SplitProxyTarget('http://h:$50/', Scheme, Host, Port));
end;

procedure TClientUrlTest.TestPathAndQueryWithoutFragment;
var
  H, P: string;
  N: Word;
begin
  ParseHttpUrl('https://h/a/b?x=1#frag', H, N, P);
  AssertEquals('/a/b?x=1', P);
  ParseHttpUrl('https://h', H, N, P);
  AssertEquals('/', P);
end;

procedure TClientUrlTest.TestPathIsNotDecoded;
var
  H, P: string;
  N: Word;
begin
  // the bytes on the wire stay as written
  ParseHttpUrl('https://h/a%2Fb', H, N, P);
  AssertEquals('/a%2Fb', P);
end;

procedure TClientUrlTest.TestOriginOfFragmentHostIsTheHost;
begin
  AssertEquals('http://good.com', OriginOfUrl('http://good.com#@evil.com/'));
end;

initialization
  RegisterTest(TClientUrlTest);

end.
