{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, request, pseudo-header, authority, host, path, method
notes:
  - This unit tests the RFC 9113 section 8.3.1 rules of the request
    pseudo-headers in the request validator.  The rules cover :method, :path,
    :authority and the host header field.
  - Each test builds one request header block and checks the verdict.
---
}
/// Tests of the request pseudo-header rules (RFC 9113 section 8.3.1)
unit Http2.Server.RequestPseudo.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Common.Hpack, Http2.Server.RequestValidation;

type
  /// tests of the :method, :path, :authority and host rules
  TRequestPseudoTest = class(TTestCase)
  private
    /// a request block with :scheme https; an empty AAuthority or AHost omits the field
    function Block(const AMethod, APath, AAuthority, AHost: string): THeaderBlock;
    function Valid(const AMethod, APath, AAuthority, AHost: string): Boolean;
  published
    procedure TestMethodMustBeAToken;
    procedure TestMethodWithSpaceIsRefused;
    procedure TestPathMustStartWithASlash;
    procedure TestPathWithControlOrSpaceIsRefused;
    procedure TestPathWithDeleteOrHighByteIsRefused;
    procedure TestAsteriskIsOnlyForOptions;
    procedure TestEmptyPathIsRefused;
    procedure TestAuthorityWithSpaceIsRefused;
    procedure TestAuthorityWithUserInfoIsRefused;
    procedure TestHostThatDiffersFromAuthorityIsRefused;
    procedure TestHostThatDiffersOnlyByCaseOrDefaultPortIsAccepted;
    procedure TestRequestWithoutHostIsAccepted;
    procedure TestOptionsAsteriskWithAuthorityIsAccepted;
    procedure TestIpv6LiteralAndExplicitPortAreAccepted;
  end;

implementation

function TRequestPseudoTest.Block(const AMethod, APath, AAuthority,
  AHost: string): THeaderBlock;
var
  N: Integer;

  procedure Add(const AName, AValue: string);
  begin
    SetLength(Result, N + 1);
    Result[N].Name := AName;
    Result[N].Value := AValue;
    Inc(N);
  end;

begin
  Result := nil;
  N := 0;
  Add(':method', AMethod);
  Add(':scheme', 'https');
  Add(':path', APath);
  if AAuthority <> '' then
    Add(':authority', AAuthority);
  if AHost <> '' then
    Add('host', AHost);
end;

function TRequestPseudoTest.Valid(const AMethod, APath, AAuthority,
  AHost: string): Boolean;
begin
  Result := ValidateRequestHeaders(Block(AMethod, APath, AAuthority, AHost),
    False).Valid;
end;

procedure TRequestPseudoTest.TestMethodMustBeAToken;
begin
  AssertTrue('GET', Valid('GET', '/', 'example.test', ''));
  AssertTrue('lowercase token', Valid('get', '/', 'example.test', ''));
  AssertTrue('token symbol', Valid('M-SEARCH', '/', 'example.test', ''));
end;

procedure TRequestPseudoTest.TestMethodWithSpaceIsRefused;
begin
  AssertFalse('GE T', Valid('GE T', '/', 'example.test', ''));
  AssertFalse('empty method', Valid('', '/', 'example.test', ''));
  AssertFalse('method with a slash', Valid('GET/1', '/', 'example.test', ''));
end;

procedure TRequestPseudoTest.TestPathMustStartWithASlash;
begin
  AssertFalse('no leading slash', Valid('GET', 'x', 'example.test', ''));
  AssertTrue('leading slash', Valid('GET', '/x', 'example.test', ''));
end;

procedure TRequestPseudoTest.TestPathWithControlOrSpaceIsRefused;
begin
  AssertFalse('space', Valid('GET', '/a b', 'example.test', ''));
  AssertFalse('control 0x01', Valid('GET', '/a' + #$01, 'example.test', ''));
  AssertFalse('nul', Valid('GET', '/a' + #0, 'example.test', ''));
  AssertTrue('a query is legal', Valid('GET', '/a?b=c&d=%20', 'example.test', ''));
end;

procedure TRequestPseudoTest.TestPathWithDeleteOrHighByteIsRefused;
begin
  AssertFalse('DEL 0x7F', Valid('GET', '/a' + #$7F, 'example.test', ''));
  AssertFalse('high byte 0x80', Valid('GET', '/a' + #$80, 'example.test', ''));
  AssertFalse('high byte 0xFF', Valid('GET', '/a' + #$FF, 'example.test', ''));
end;

procedure TRequestPseudoTest.TestAsteriskIsOnlyForOptions;
begin
  AssertTrue('OPTIONS *', Valid('OPTIONS', '*', 'example.test', ''));
  AssertFalse('GET *', Valid('GET', '*', 'example.test', ''));
  AssertFalse('POST *', Valid('POST', '*', 'example.test', ''));
end;

procedure TRequestPseudoTest.TestEmptyPathIsRefused;
begin
  AssertFalse('empty path', Valid('GET', '', 'example.test', ''));
end;

procedure TRequestPseudoTest.TestAuthorityWithSpaceIsRefused;
begin
  AssertFalse('space in authority', Valid('GET', '/', 'exa mple.test', ''));
end;

procedure TRequestPseudoTest.TestAuthorityWithUserInfoIsRefused;
begin
  AssertFalse('userinfo', Valid('GET', '/', 'user@example.test', ''));
  AssertFalse('userinfo with password', Valid('GET', '/', 'user:pw@example.test', ''));
end;

procedure TRequestPseudoTest.TestHostThatDiffersFromAuthorityIsRefused;
begin
  AssertFalse('other host', Valid('GET', '/', 'example.com', 'other.test'));
end;

procedure TRequestPseudoTest.TestHostThatDiffersOnlyByCaseOrDefaultPortIsAccepted;
begin
  AssertTrue('case and default port',
    Valid('GET', '/', 'example.com', 'EXAMPLE.com:443'));
end;

procedure TRequestPseudoTest.TestRequestWithoutHostIsAccepted;
begin
  AssertTrue('no host', Valid('GET', '/', 'example.com', ''));
end;

procedure TRequestPseudoTest.TestOptionsAsteriskWithAuthorityIsAccepted;
begin
  AssertTrue('OPTIONS * with host',
    Valid('OPTIONS', '*', 'example.com', 'example.com'));
end;

procedure TRequestPseudoTest.TestIpv6LiteralAndExplicitPortAreAccepted;
begin
  AssertTrue('IPv6 literal', Valid('GET', '/', '[::1]', '[::1]'));
  AssertTrue('IPv6 literal with port', Valid('GET', '/', '[::1]:8443', '[::1]:8443'));
  AssertTrue('explicit port', Valid('GET', '/', 'example.com:8443', 'example.com:8443'));
  AssertFalse('another host with the same port',
    Valid('GET', '/', 'example.com:8443', 'other.test:8443'));
end;

initialization
  RegisterTest(TRequestPseudoTest);

end.
