{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: cookie, test
notes:
  - This test checks the cookie record, the HTTP-date formats and the cookie field helpers.
  - The tests check that a name or a value with a forbidden octet raises EBodyFormatError.
---
}
unit Http2.Common.Cookie.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Body, Http2.Common.Headers,
  Http2.Common.Parameters, Http2.Common.Cookie;

type
  TCookieTest = class(TTestCase)
  private
    function CreateRaises(const AName, AValue: string): Boolean;
    function ParseRaises(const AText: string): Boolean;
    function WithValueRaises(const AValue: string): Boolean;
    function WithPathRaises(const APath: string): Boolean;
    function WithDomainRaises(const ADomain: string): Boolean;
    function HeaderParseRaises(const AHeaders: IHttpHeaders): Boolean;
    function CookieValueRaises(const AValue: string): Boolean;
    procedure AssertSameInstant(const AMessage: string; const AExpected, AActual: TDateTime);
  published
    procedure TestParseNameAndValue;
    procedure TestParseEachAttribute;
    procedure TestAttributeNamesAreCaseInsensitive;
    procedure TestSameSiteValues;
    procedure TestValueKeepsEquals;
    procedure TestQuotedValue;
    procedure TestMalformedAttributesAreIgnored;
    procedure TestExpiresInImfFixdate;
    procedure TestExpiresInObsoleteFormats;
    procedure TestTwoDigitYears;
    procedure TestRefusedHttpDates;
    procedure TestFormatHttpDate;
    procedure TestToStringExactText;
    procedure TestToStringRoundTrip;
    procedure TestWithReturnsAChangedCopy;
    procedure TestBadNameRaises;
    procedure TestBadValueRaises;
    procedure TestBadAttributeRaises;
    procedure TestParseCookiesPairs;
    procedure TestParseCookiesSpacesAndQuotes;
    procedure TestParseCookiesCaseIsSignificant;
    procedure TestGetCookiesReadsTwoFields;
    procedure TestGetSetCookiesIsNotJoined;
    procedure TestGetSetCookiesRefusesBadField;
    procedure TestCookieHeaderValue;
    procedure TestCookieHeaderValueRefusesBadValue;
    procedure TestAddSetCookie;
  end;

implementation

function TCookieTest.CreateRaises(const AName, AValue: string): Boolean;
begin
  Result := False;
  try
    THttpCookie.Create(AName, AValue);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

function TCookieTest.ParseRaises(const AText: string): Boolean;
begin
  Result := False;
  try
    THttpCookie.Parse(AText);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

function TCookieTest.WithValueRaises(const AValue: string): Boolean;
var
  LCookie: THttpCookie;
begin
  Result := False;
  LCookie := THttpCookie.Create('a', 'b');
  try
    LCookie.WithValue(AValue);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

function TCookieTest.WithPathRaises(const APath: string): Boolean;
var
  LCookie: THttpCookie;
begin
  Result := False;
  LCookie := THttpCookie.Create('a', 'b');
  try
    LCookie.WithPath(APath);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

function TCookieTest.WithDomainRaises(const ADomain: string): Boolean;
var
  LCookie: THttpCookie;
begin
  Result := False;
  LCookie := THttpCookie.Create('a', 'b');
  try
    LCookie.WithDomain(ADomain);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

function TCookieTest.HeaderParseRaises(const AHeaders: IHttpHeaders): Boolean;
var
  LCookies: TArray<THttpCookie>;
begin
  Result := False;
  try
    LCookies := GetSetCookies(AHeaders);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

function TCookieTest.CookieValueRaises(const AValue: string): Boolean;
var
  LParams: TParameters;
begin
  Result := False;
  LParams := TParameters.Create;
  LParams.Add('a', AValue);
  try
    CookieHeaderValue(LParams);
  except
    on EBodyFormatError do
      Result := True;
  end;
end;

procedure TCookieTest.AssertSameInstant(const AMessage: string; const AExpected, AActual: TDateTime);
begin
  AssertTrue(AMessage + ' (expected ' + DateTimeToStr(AExpected) + ', got ' +
    DateTimeToStr(AActual) + ')', Abs(AExpected - AActual) < 1e-7);
end;

procedure TCookieTest.TestParseNameAndValue;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Parse('sid=abc');
  AssertEquals('name', 'sid', LCookie.Name);
  AssertEquals('value', 'abc', LCookie.Value);
  AssertFalse('no Expires', LCookie.HasExpires);
  AssertFalse('no Max-Age', LCookie.HasMaxAge);
  AssertEquals('no Domain', '', LCookie.Domain);
  AssertEquals('no Path', '', LCookie.Path);
  AssertFalse('no Secure', LCookie.Secure);
  AssertFalse('no HttpOnly', LCookie.HttpOnly);
  AssertTrue('no SameSite', LCookie.SameSite = ssUnset);
  AssertFalse('no Partitioned', LCookie.Partitioned);
  AssertEquals('an empty value is allowed', '', THttpCookie.Parse('x=').Value);
end;

procedure TCookieTest.TestParseEachAttribute;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Parse('a=b; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=60; ' +
    'Domain=example.com; Path=/x; Secure; HttpOnly; SameSite=Lax; Partitioned');
  AssertEquals('name', 'a', LCookie.Name);
  AssertEquals('value', 'b', LCookie.Value);
  AssertTrue('HasExpires', LCookie.HasExpires);
  AssertSameInstant('Expires', EncodeDate(1994, 11, 6) + EncodeTime(8, 49, 37, 0), LCookie.Expires);
  AssertTrue('HasMaxAge', LCookie.HasMaxAge);
  AssertEquals('Max-Age', 60, LCookie.MaxAge);
  AssertEquals('Domain', 'example.com', LCookie.Domain);
  AssertEquals('Path', '/x', LCookie.Path);
  AssertTrue('Secure', LCookie.Secure);
  AssertTrue('HttpOnly', LCookie.HttpOnly);
  AssertTrue('SameSite Lax', LCookie.SameSite = ssLax);
  AssertTrue('Partitioned', LCookie.Partitioned);
end;

procedure TCookieTest.TestAttributeNamesAreCaseInsensitive;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Parse('a=b; max-age=-5; SECURE; samesite=STRICT; PATH=/; httponly; domain=d.test');
  AssertTrue('a negative Max-Age is kept', LCookie.HasMaxAge);
  AssertEquals('Max-Age -5', -5, LCookie.MaxAge);
  AssertTrue('SECURE', LCookie.Secure);
  AssertTrue('httponly', LCookie.HttpOnly);
  AssertTrue('samesite=STRICT', LCookie.SameSite = ssStrict);
  AssertEquals('PATH', '/', LCookie.Path);
  AssertEquals('domain', 'd.test', LCookie.Domain);
end;

procedure TCookieTest.TestSameSiteValues;
begin
  AssertTrue('None', THttpCookie.Parse('a=b; SameSite=None').SameSite = ssNone);
  AssertTrue('Lax', THttpCookie.Parse('a=b; SameSite=Lax').SameSite = ssLax);
  AssertTrue('Strict', THttpCookie.Parse('a=b; SameSite=Strict').SameSite = ssStrict);
  AssertTrue('an unknown value is ignored', THttpCookie.Parse('a=b; SameSite=Sideways').SameSite = ssUnset);
end;

procedure TCookieTest.TestValueKeepsEquals;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Parse('token=a=b=c; Path=/');
  AssertEquals('the name ends at the first =', 'token', LCookie.Name);
  AssertEquals('the value keeps the other =', 'a=b=c', LCookie.Value);
  AssertEquals('the attribute after it is read', '/', LCookie.Path);
end;

procedure TCookieTest.TestQuotedValue;
begin
  AssertEquals('the quotes are removed', 'xyz', THttpCookie.Parse('q="xyz"').Value);
  AssertTrue('a quoted value with a space is refused', ParseRaises('q="a b"'));
  AssertTrue('a quoted value with a comma is refused', ParseRaises('q="a,b"'));
end;

procedure TCookieTest.TestMalformedAttributesAreIgnored;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Parse('a=b; Expires=garbage; Max-Age=x; Max-Age=1.5; SameSite=');
  AssertFalse('a malformed Expires is ignored', LCookie.HasExpires);
  AssertFalse('a malformed Max-Age is ignored', LCookie.HasMaxAge);
  AssertTrue('the value is kept', LCookie.Value = 'b');
end;

procedure TCookieTest.TestExpiresInImfFixdate;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Parse('a=b; Expires=Sun, 06 Nov 1994 08:49:37 GMT');
  AssertTrue('HasExpires', LCookie.HasExpires);
  AssertSameInstant('IMF-fixdate', EncodeDate(1994, 11, 6) + EncodeTime(8, 49, 37, 0), LCookie.Expires);
end;

procedure TCookieTest.TestExpiresInObsoleteFormats;
var
  LExpected: TDateTime;
begin
  LExpected := EncodeDate(1994, 11, 6) + EncodeTime(8, 49, 37, 0);
  AssertSameInstant('RFC 850 format',
    LExpected, THttpCookie.Parse('a=b; Expires=Sunday, 06-Nov-94 08:49:37 GMT').Expires);
  AssertSameInstant('asctime format',
    LExpected, THttpCookie.Parse('a=b; Expires=Sun Nov  6 08:49:37 1994').Expires);
  AssertSameInstant('asctime format, two digits of the day',
    EncodeDate(1994, 11, 16) + EncodeTime(8, 49, 37, 0),
    THttpCookie.Parse('a=b; Expires=Sun Nov 16 08:49:37 1994').Expires);
end;

procedure TCookieTest.TestTwoDigitYears;
begin
  AssertSameInstant('a year of 70 is 1970',
    EncodeDate(1970, 1, 1), THttpCookie.Parse('a=b; Expires=Thu, 01 Jan 70 00:00:00 GMT').Expires);
  AssertSameInstant('a year of 99 is 1999',
    EncodeDate(1999, 12, 31) + EncodeTime(23, 59, 59, 0),
    THttpCookie.Parse('a=b; Expires=Fri, 31 Dec 99 23:59:59 GMT').Expires);
  AssertSameInstant('a year of 00 is 2000',
    EncodeDate(2000, 1, 1), THttpCookie.Parse('a=b; Expires=Sat, 01 Jan 00 00:00:00 GMT').Expires);
  AssertSameInstant('a year of 69 is 2069',
    EncodeDate(2069, 1, 1), THttpCookie.Parse('a=b; Expires=Sun, 01 Jan 69 00:00:00 GMT').Expires);
end;

procedure TCookieTest.TestRefusedHttpDates;
var
  LDate: TDateTime;
begin
  AssertFalse('a day 31 of February is refused',
    TryParseHttpDate('Sun, 31 Feb 1994 08:49:37 GMT', LDate));
  AssertFalse('a leap second is refused',
    TryParseHttpDate('Sun, 06 Nov 1994 08:49:60 GMT', LDate));
  AssertFalse('a zone other than GMT is refused',
    TryParseHttpDate('Sun, 06 Nov 1994 08:49:37 PST', LDate));
  AssertFalse('a month name that is unknown is refused',
    TryParseHttpDate('Sun, 06 Nax 1994 08:49:37 GMT', LDate));
  AssertFalse('a text that is not a date is refused', TryParseHttpDate('yesterday', LDate));
  AssertFalse('a date with a time that has no seconds is refused',
    TryParseHttpDate('Sun, 06 Nov 1994 08:49 GMT', LDate));
end;

procedure TCookieTest.TestFormatHttpDate;
begin
  AssertEquals('the IMF-fixdate text',
    'Sun, 06 Nov 1994 08:49:37 GMT', FormatHttpDate(EncodeDate(1994, 11, 6) + EncodeTime(8, 49, 37, 0)));
  AssertEquals('a Monday in the IMF-fixdate text',
    'Mon, 07 Nov 1994 00:00:00 GMT', FormatHttpDate(EncodeDate(1994, 11, 7)));
end;

procedure TCookieTest.TestToStringExactText;
var
  LCookie: THttpCookie;
begin
  LCookie := THttpCookie.Create('sid', 'abc')
    .WithExpires(EncodeDate(1994, 11, 6) + EncodeTime(8, 49, 37, 0))
    .WithMaxAge(60)
    .WithPath('/')
    .WithSecure
    .WithSameSite(ssLax);
  AssertEquals('the Set-Cookie text',
    'sid=abc; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=60; Path=/; Secure; SameSite=Lax',
    LCookie.ToString);
  AssertEquals('no attribute by default', 'a=b', THttpCookie.Create('a', 'b').ToString);
  AssertEquals('a value with = is written as it is', 'a=x=y', THttpCookie.Create('a', 'x=y').ToString);
end;

procedure TCookieTest.TestToStringRoundTrip;
var
  LCookie: THttpCookie;
  LParsed: THttpCookie;
  LText: string;
begin
  LCookie := THttpCookie.Create('sid', 'a=b')
    .WithExpires(EncodeDate(2032, 2, 29) + EncodeTime(23, 0, 5, 0))
    .WithMaxAge(3600)
    .WithDomain('example.com')
    .WithPath('/app')
    .WithSecure
    .WithHttpOnly
    .WithSameSite(ssStrict)
    .WithPartitioned;
  LText := LCookie.ToString;
  LParsed := THttpCookie.Parse(LText);
  AssertEquals('name survives', 'sid', LParsed.Name);
  AssertEquals('value survives', 'a=b', LParsed.Value);
  AssertSameInstant('Expires survives', LCookie.Expires, LParsed.Expires);
  AssertEquals('Max-Age survives', 3600, LParsed.MaxAge);
  AssertEquals('Domain survives', 'example.com', LParsed.Domain);
  AssertEquals('Path survives', '/app', LParsed.Path);
  AssertTrue('Secure survives', LParsed.Secure);
  AssertTrue('HttpOnly survives', LParsed.HttpOnly);
  AssertTrue('SameSite survives', LParsed.SameSite = ssStrict);
  AssertTrue('Partitioned survives', LParsed.Partitioned);
  AssertEquals('the second text is the same', LText, LParsed.ToString);
end;

procedure TCookieTest.TestWithReturnsAChangedCopy;
var
  LFirst: THttpCookie;
  LSecond: THttpCookie;
begin
  LFirst := THttpCookie.Create('a', 'b');
  LSecond := LFirst.WithValue('c').WithSecure;
  AssertEquals('the original keeps its value', 'b', LFirst.Value);
  AssertFalse('the original keeps its flags', LFirst.Secure);
  AssertEquals('the copy has the new value', 'c', LSecond.Value);
  AssertTrue('the copy has the new flag', LSecond.Secure);
  AssertFalse('WithoutMaxAge clears the Max-Age', LSecond.WithMaxAge(5).WithoutMaxAge.HasMaxAge);
  AssertFalse('WithoutExpires clears the Expires', LSecond.WithExpires(Now).WithoutExpires.HasExpires);
end;

procedure TCookieTest.TestBadNameRaises;
begin
  AssertTrue('a name with a space raises', CreateRaises('a b', 'v'));
  AssertTrue('a name with ; raises', CreateRaises('a;b', 'v'));
  AssertTrue('a name with , raises', CreateRaises('a,b', 'v'));
  AssertTrue('a name with a double quote raises', CreateRaises('a"b', 'v'));
  AssertTrue('a name with = raises', CreateRaises('a=b', 'v'));
  AssertTrue('a name with a tab raises', CreateRaises('a' + #9 + 'b', 'v'));
  AssertTrue('a name with a control octet raises', CreateRaises('a' + #1, 'v'));
  AssertTrue('an empty name raises', CreateRaises('', 'v'));
  AssertTrue('a Set-Cookie with an empty name raises', ParseRaises('=x'));
  AssertTrue('a Set-Cookie with no = raises', ParseRaises('novalue'));
  AssertTrue('a Set-Cookie with a space in the name raises', ParseRaises('a b=c'));
  AssertFalse('a name that is a token is accepted', CreateRaises('a-b_c.d', 'v'));
end;

procedure TCookieTest.TestBadValueRaises;
begin
  AssertTrue('a value with a space raises', CreateRaises('a', 'x y'));
  AssertTrue('a value with ; raises', CreateRaises('a', 'x;y'));
  AssertTrue('a value with , raises', CreateRaises('a', 'x,y'));
  AssertTrue('a value with " raises', CreateRaises('a', 'x"y'));
  AssertTrue('a value with a backslash raises', CreateRaises('a', 'x\y'));
  AssertTrue('a value with a control octet raises', CreateRaises('a', 'x' + #10));
  AssertTrue('WithValue refuses a bad value', WithValueRaises('x y'));
  AssertFalse('the cookie-octet range is accepted', CreateRaises('a', 'AZaz09!#$%&''()*+-./:<=>?@[]^_`{|}~'));
  AssertTrue('a Set-Cookie value with a space raises', ParseRaises('a=b c; Path=/'));
  AssertTrue('the cookie header refuses a bad value', CookieValueRaises('x;y'));
end;

procedure TCookieTest.TestBadAttributeRaises;
begin
  AssertTrue('WithPath refuses a semicolon', WithPathRaises('/a;b'));
  AssertTrue('WithPath refuses a space', WithPathRaises('/a b'));
  AssertTrue('WithDomain refuses a control octet', WithDomainRaises('a' + #13 + 'b'));
  AssertFalse('a plain path is accepted', WithPathRaises('/a/b'));
end;

procedure TCookieTest.TestParseCookiesPairs;
var
  LParams: TParameters;
begin
  LParams := ParseCookies('a=1; b=2; a=3');
  AssertEquals('two names', 2, LParams.Count);
  AssertEquals('the first value of a', '1', LParams.GetFirst('a'));
  AssertEquals('two values of a', 2, Length(LParams['a']));
  AssertEquals('the second value of a', '3', LParams['a'][1]);
  AssertEquals('the value of b', '2', LParams.GetFirst('b'));
  AssertEquals('the names keep their order', 'a', LParams.Names[0]);
end;

procedure TCookieTest.TestParseCookiesSpacesAndQuotes;
var
  LParams: TParameters;
begin
  LParams := ParseCookies('  a = 1 ;b="2";  c ; =x; d=');
  AssertEquals('a is trimmed', '1', LParams.GetFirst('a'));
  AssertEquals('the quotes of b are removed', '2', LParams.GetFirst('b'));
  AssertFalse('a pair without = is skipped', LParams.Contains('c'));
  AssertFalse('a pair with an empty name is skipped', LParams.Contains(''));
  AssertTrue('an empty value is kept', LParams.Contains('d'));
  AssertEquals('three names', 3, LParams.Count);
end;

procedure TCookieTest.TestParseCookiesCaseIsSignificant;
var
  LParams: TParameters;
begin
  LParams := ParseCookies('A=1; a=2');
  AssertEquals('two names', 2, LParams.Count);
  AssertEquals('upper case', '1', LParams.GetFirst('A'));
  AssertEquals('lower case', '2', LParams.GetFirst('a'));
end;

procedure TCookieTest.TestGetCookiesReadsTwoFields;
var
  LHeaders: IHttpHeaders;
  LParams: TParameters;
begin
  LHeaders := NewHttpHeaders;
  LHeaders.Add('cookie', 'a=1; b=2');
  LHeaders.Add('cookie', 'c=3;   a=4');
  LParams := GetCookies(LHeaders);
  AssertEquals('three names over two fields', 3, LParams.Count);
  AssertEquals('two values of a over two fields', 2, Length(LParams['a']));
  AssertEquals('the second value of a is from the second field', '4', LParams['a'][1]);
  AssertEquals('the value of c', '3', LParams.GetFirst('c'));
  AssertEquals('no headers give no cookies', 0, GetCookies(NewHttpHeaders).Count);
end;

procedure TCookieTest.TestGetSetCookiesIsNotJoined;
var
  LHeaders: IHttpHeaders;
  LCookies: TArray<THttpCookie>;
begin
  LHeaders := NewHttpHeaders;
  LHeaders.Add('set-cookie', 'a=1; Path=/');
  LHeaders.Add('set-cookie', 'b=2; HttpOnly');
  LCookies := GetSetCookies(LHeaders);
  AssertEquals('two cookies from two fields', 2, Length(LCookies));
  AssertEquals('the first name', 'a', LCookies[0].Name);
  AssertEquals('the first path', '/', LCookies[0].Path);
  AssertEquals('the second name', 'b', LCookies[1].Name);
  AssertTrue('the second HttpOnly', LCookies[1].HttpOnly);
  AssertEquals('no set-cookie gives an empty array', 0, Length(GetSetCookies(NewHttpHeaders)));
end;

procedure TCookieTest.TestGetSetCookiesRefusesBadField;
var
  LHeaders: IHttpHeaders;
begin
  LHeaders := NewHttpHeaders;
  LHeaders.Add('set-cookie', 'a=1');
  LHeaders.Add('set-cookie', 'no pair here');
  AssertTrue('a bad set-cookie field raises', HeaderParseRaises(LHeaders));
end;

procedure TCookieTest.TestCookieHeaderValue;
var
  LParams: TParameters;
begin
  LParams := ParseCookies('a=1; b=2; a=3');
  AssertEquals('the pairs in map order', 'a=1; a=3; b=2', CookieHeaderValue(LParams));
  AssertEquals('an empty map gives an empty text', '', CookieHeaderValue(TParameters.Create));
end;

procedure TCookieTest.TestCookieHeaderValueRefusesBadValue;
begin
  AssertTrue('a value with a space is refused', CookieValueRaises('x y'));
end;

procedure TCookieTest.TestAddSetCookie;
var
  LHeaders: IHttpHeaders;
begin
  LHeaders := NewHttpHeaders;
  AddSetCookie(LHeaders, THttpCookie.Create('a', 'b').WithPath('/'));
  AssertEquals('one set-cookie field', 1, Length(LHeaders.GetValues('set-cookie')));
  AssertEquals('the field value', 'a=b; Path=/', LHeaders.GetFirst('set-cookie'));
end;

initialization
  RegisterTest(TCookieTest);
end.
