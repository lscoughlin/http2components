{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, cookie
notes:
  - This test checks WithCookies, which adds one cookie field to a client request.
---
}
unit Http2.Client.Cookies.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client, Http2.Common.Parameters,
  Http2.Client.Request, Http2.Client.Cookies;

type
  TClientCookiesTest = class(TTestCase)
  published
    procedure TestWithCookiesWritesOneField;
    procedure TestEmptyMapAddsNoField;
    procedure TestSecondCallAddsASecondField;
  end;

implementation

procedure TClientCookiesTest.TestWithCookiesWritesOneField;
var
  LParams: TParameters;
  LRequest: THttpRequest;
begin
  LParams := TParameters.Create;
  LParams.Add('a', '1').Add('b', '2').Add('a', '3');
  LRequest := WithCookies(THttpRequest.Create(hmGet, 'https://example.test/x'), LParams);
  AssertEquals('one cookie field', 1, Length(LRequest.Headers.GetValues('cookie')));
  AssertEquals('the pairs of the map', 'a=1; a=3; b=2', LRequest.Headers.GetFirst('cookie'));
end;

procedure TClientCookiesTest.TestEmptyMapAddsNoField;
var
  LRequest: THttpRequest;
begin
  LRequest := WithCookies(THttpRequest.Create(hmGet, 'https://example.test/x'), TParameters.Create);
  AssertTrue('no header is added for an empty map', (LRequest.Headers = nil) or
    (not LRequest.Headers.Contains('cookie')));
end;

procedure TClientCookiesTest.TestSecondCallAddsASecondField;
var
  LFirst: TParameters;
  LSecond: TParameters;
  LRequest: THttpRequest;
begin
  LFirst := TParameters.Create;
  LFirst.Add('a', '1');
  LSecond := TParameters.Create;
  LSecond.Add('b', '2');
  LRequest := WithCookies(THttpRequest.Create(hmGet, 'https://example.test/x'), LFirst);
  LRequest := WithCookies(LRequest, LSecond);
  AssertEquals('two cookie fields', 2, Length(LRequest.Headers.GetValues('cookie')));
end;

initialization
  RegisterTest(TClientCookiesTest);
end.
