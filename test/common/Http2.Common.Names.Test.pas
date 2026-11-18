{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: header names, status codes, constants, test
notes:
  - This test checks the header-name constants and the status-code constants.
  - A header name is lower case and a token, so the HTTP/2 wire form and the header map accept it.
---
}
unit Http2.Common.Names.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common, Http2.Common.Status;

type
  TNamesTest = class(TTestCase)
  private
    procedure CheckName(const AExpected, AActual: string);
  published
    procedure TestNewHeaderNamesHaveTheWireText;
    procedure TestEveryHeaderNameIsLowerCaseToken;
    procedure TestWebSocketHandshakeNames;
    procedure TestStatusCodesHaveTheirNumbers;
    procedure TestStatusCodesAreInTheirClass;
  end;

implementation

procedure TNamesTest.CheckName(const AExpected, AActual: string);
begin
  AssertEquals('the constant for ' + AExpected, AExpected, AActual);
  AssertEquals('the name is lower case', LowerCase(AActual), AActual);
end;

procedure TNamesTest.TestNewHeaderNamesHaveTheWireText;
begin
  CheckName('accept-language', HeaderAcceptLanguage);
  CheckName('accept-ranges', HeaderAcceptRanges);
  CheckName('allow', HeaderAllow);
  CheckName('connection', HeaderConnection);
  CheckName('content-disposition', HeaderContentDisposition);
  CheckName('content-language', HeaderContentLanguage);
  CheckName('content-range', HeaderContentRange);
  CheckName('date', HeaderDate);
  CheckName('etag', HeaderEtag);
  CheckName('expect', HeaderExpect);
  CheckName('if-match', HeaderIfMatch);
  CheckName('if-modified-since', HeaderIfModifiedSince);
  CheckName('if-none-match', HeaderIfNoneMatch);
  CheckName('if-range', HeaderIfRange);
  CheckName('if-unmodified-since', HeaderIfUnmodifiedSince);
  CheckName('last-modified', HeaderLastModified);
  CheckName('origin', HeaderOrigin);
  CheckName('range', HeaderRange);
  CheckName('referer', HeaderReferer);
  CheckName('retry-after', HeaderRetryAfter);
  CheckName('server', HeaderServer);
  CheckName('transfer-encoding', HeaderTransferEncoding);
  CheckName('upgrade', HeaderUpgrade);
  CheckName('vary', HeaderVary);
end;

procedure TNamesTest.TestEveryHeaderNameIsLowerCaseToken;
const
  cNames: array[0..28] of string = (
    HeaderAcceptLanguage, HeaderAcceptRanges, HeaderAllow, HeaderConnection,
    HeaderContentDisposition, HeaderContentLanguage, HeaderContentRange, HeaderDate,
    HeaderEtag, HeaderExpect, HeaderIfMatch, HeaderIfModifiedSince, HeaderIfNoneMatch,
    HeaderIfRange, HeaderIfUnmodifiedSince, HeaderLastModified, HeaderOrigin,
    HeaderRange, HeaderReferer, HeaderRetryAfter, HeaderServer,
    HeaderTransferEncoding, HeaderUpgrade, HeaderVary, HeaderSecWebSocketAccept,
    HeaderSecWebSocketExtensions, HeaderSecWebSocketKey, HeaderSecWebSocketProtocol,
    HeaderSecWebSocketVersion);
var
  I, J: Integer;
begin
  for I := Low(cNames) to High(cNames) do
  begin
    AssertTrue('the name is not empty', cNames[I] <> '');
    for J := 1 to Length(cNames[I]) do
      AssertTrue('only a to z, 0 to 9 and "-" in ' + cNames[I],
        cNames[I][J] in ['a'..'z', '0'..'9', '-']);
  end;
end;

procedure TNamesTest.TestWebSocketHandshakeNames;
begin
  CheckName('sec-websocket-accept', HeaderSecWebSocketAccept);
  CheckName('sec-websocket-extensions', HeaderSecWebSocketExtensions);
  CheckName('sec-websocket-key', HeaderSecWebSocketKey);
  CheckName('sec-websocket-protocol', HeaderSecWebSocketProtocol);
  CheckName('sec-websocket-version', HeaderSecWebSocketVersion);
end;

procedure TNamesTest.TestStatusCodesHaveTheirNumbers;
begin
  AssertEquals(100, HttpStatusContinue);
  AssertEquals(101, HttpStatusSwitchingProtocols);
  AssertEquals(200, HttpStatusOk);
  AssertEquals(201, HttpStatusCreated);
  AssertEquals(204, HttpStatusNoContent);
  AssertEquals(206, HttpStatusPartialContent);
  AssertEquals(301, HttpStatusMovedPermanently);
  AssertEquals(302, HttpStatusFound);
  AssertEquals(304, HttpStatusNotModified);
  AssertEquals(307, HttpStatusTemporaryRedirect);
  AssertEquals(308, HttpStatusPermanentRedirect);
  AssertEquals(400, HttpStatusBadRequest);
  AssertEquals(401, HttpStatusUnauthorized);
  AssertEquals(403, HttpStatusForbidden);
  AssertEquals(404, HttpStatusNotFound);
  AssertEquals(405, HttpStatusMethodNotAllowed);
  AssertEquals(408, HttpStatusRequestTimeout);
  AssertEquals(413, HttpStatusContentTooLarge);
  AssertEquals(416, HttpStatusRangeNotSatisfiable);
  AssertEquals(421, HttpStatusMisdirectedRequest);
  AssertEquals(426, HttpStatusUpgradeRequired);
  AssertEquals(429, HttpStatusTooManyRequests);
  AssertEquals(431, HttpStatusRequestHeaderFieldsTooLarge);
  AssertEquals(500, HttpStatusInternalServerError);
  AssertEquals(501, HttpStatusNotImplemented);
  AssertEquals(502, HttpStatusBadGateway);
  AssertEquals(503, HttpStatusServiceUnavailable);
  AssertEquals(504, HttpStatusGatewayTimeout);
  AssertEquals(505, HttpStatusHttpVersionNotSupported);
end;

procedure TNamesTest.TestStatusCodesAreInTheirClass;
begin
  AssertTrue('1xx', (HttpStatusEarlyHints div 100) = 1);
  AssertTrue('2xx', (HttpStatusNonAuthoritativeInformation div 100) = 2);
  AssertTrue('3xx', (HttpStatusMultipleChoices div 100) = 3);
  AssertTrue('4xx', (HttpStatusUnavailableForLegalReasons div 100) = 4);
  AssertTrue('5xx', (HttpStatusNetworkAuthenticationRequired div 100) = 5);
end;

initialization
  RegisterTest(TNamesTest);

end.
