{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, request smuggling, obs-fold, websocket handshake, transfer-encoding, test, fpcunit
notes:
  - This unit pins the strict request field rules: no white space before the colon,
    no obsolete line fold and a Transfer-Encoding that ends in chunked.
  - The WebSocket handshake fields are framing or hop-by-hop fields. The same
    strict rules apply to them.
---
}
/// Strict request field rules of the HTTP/1.1 server
unit Http2.Server.Http1.Fields.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server.Http1.Limits, Http2.Server.Http1.Guard, Http2.Server.Http1.TestKit;

type
  THttp1FieldsTest = class(TTestCase)
  private
    FLimits: THttp11Limits;
    procedure Reject400(const AName, AInput: string);
  protected
    procedure SetUp; override;
  published
    procedure TestSpaceBeforeColonIsRefused;
    procedure TestObsFoldInARequestIsRefused;
    procedure TestTransferEncodingMustEndInChunked;
    procedure TestWebSocketHandshakeFieldsStayStrict;
    procedure TestPlainChunkedStillWorks;
  end;

implementation

const
  CRLF = #13#10;
  Second = 'GET /second HTTP/1.1' + CRLF + 'Host: a' + CRLF + CRLF;
  Base = 'POST / HTTP/1.1' + CRLF + 'Host: a' + CRLF;
  WsBase = 'GET /ws HTTP/1.1' + CRLF + 'Host: a' + CRLF;

procedure THttp1FieldsTest.SetUp;
begin
  FLimits := THttp11Limits.Create;
end;

procedure THttp1FieldsTest.Reject400(const AName, AInput: string);
var
  T: string;
begin
  T := H1RunAll(AInput + Second, FLimits);
  AssertTrue(AName + ': refused with 400; got: ' + T, H1Rejected(T, 400));
  AssertEquals(AName + ': the second request is not processed', 0, Pos('/second', T));
end;

procedure THttp1FieldsTest.TestSpaceBeforeColonIsRefused;
var
  N: string;
begin
  for N in ['X-A ', 'Host ', 'Content-Length ', 'Transfer-Encoding ', 'X-A'#9] do
    Reject400('a space before the colon in "' + N + '"',
      Base + N + ': 5' + CRLF + CRLF + 'hello');
end;

procedure THttp1FieldsTest.TestObsFoldInARequestIsRefused;
begin
  Reject400('a folded custom field', Base + 'X-A: b' + CRLF + ' c' + CRLF + CRLF);
  Reject400('a tab fold', Base + 'X-A: b' + CRLF + #9'c' + CRLF + CRLF);
  Reject400('a folded Content-Length', Base + 'Content-Length: 1' + CRLF + ' 0' + CRLF +
    CRLF + 'hello');
  Reject400('a fold before the first field', 'POST / HTTP/1.1' + CRLF + ' Host: a' + CRLF + CRLF);
end;

procedure THttp1FieldsTest.TestTransferEncodingMustEndInChunked;
var
  V: string;
begin
  for V in ['gzip', 'identity', 'gzip, chunked', 'chunked, gzip', 'chunked, identity',
            'xchunked', 'compress'] do
    Reject400('Transfer-Encoding: ' + V, Base + 'Transfer-Encoding: ' + V + CRLF + CRLF +
      '0' + CRLF + CRLF);
end;

procedure THttp1FieldsTest.TestWebSocketHandshakeFieldsStayStrict;
var
  N: string;
begin
  for N in ['Upgrade ', 'Connection ', 'Sec-WebSocket-Key ', 'Sec-WebSocket-Version ',
            'Sec-WebSocket-Protocol '] do
    Reject400('a space before the colon in "' + N + '"',
      WsBase + 'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
      N + ': 13' + CRLF + CRLF);
  Reject400('a folded Upgrade', WsBase + 'Upgrade: web' + CRLF + ' socket' + CRLF +
    'Connection: Upgrade' + CRLF + CRLF);
  Reject400('a folded Connection', WsBase + 'Upgrade: websocket' + CRLF +
    'Connection: keep-alive,' + CRLF + ' Upgrade' + CRLF + CRLF);
  Reject400('a folded Sec-WebSocket-Key', WsBase + 'Upgrade: websocket' + CRLF +
    'Connection: Upgrade' + CRLF + 'Sec-WebSocket-Key: dGhlIHNhbXBsZQ' + CRLF + ' ==' +
    CRLF + CRLF);
end;

procedure THttp1FieldsTest.TestPlainChunkedStillWorks;
var
  T: string;
begin
  T := H1RunAll(Base + 'Transfer-Encoding: chunked' + CRLF + CRLF + '0' + CRLF + CRLF, FLimits);
  AssertEquals('chunked is accepted: ' + T, 1, Pos('H POST / auth=a fr=chunked', T));
end;

initialization
  RegisterTest(THttp1FieldsTest);
end.
