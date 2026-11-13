{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, strict
notes:
  - This unit tests the strict HTTP/1.1 response parsing rules of RFC 9112 sections 5.1, 5.2, 6.1, 6.3 and 7.1.
  - The live tests feed scripted bytes to THttp1Connection through TScriptSocket.
---
}
unit Http2.Client.Http1Strict.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1, Http2.Client.Http1.Parse, Http2.Client.ClearText.Support;

type
  /// unit tests of the pure parsers (no socket)
  THttp1ParseTest = class(TTestCase)
  published
    procedure TestContentLengthDigits;
    procedure TestContentLengthEqualListAccepted;
    procedure TestContentLengthDifferentListRejected;
    procedure TestContentLengthRejectsSignsAndPrefixes;
    procedure TestContentLengthOverflowRejected;
    procedure TestTransferEncodingChunked;
  end;

  /// live tests: one scripted response read by THttp1Connection
  THttp1StrictLiveTest = class(TTestCase)
  private
    /// send one GET over a scripted socket and read the whole body;
    /// returns the response and its body text, or raises
    function Exchange(const AWire: string; out ABody: string;
      out AReusable: Boolean): IHttpResponse;
    /// True when the exchange raises EHttpProtocolError (head or body)
    function ExchangeRaises(const AWire: string): Boolean;
  published
    procedure TestBareLfInStatusLineRaises;
    procedure TestBareLfInFieldLineRaises;
    procedure TestBareCrInFieldLineRaises;
    procedure TestBareLfInChunkSizeRaises;
    procedure TestBareLfInChunkTerminatorRaises;
    procedure TestSpaceBeforeColonRaises;
    procedure TestObsFoldJoinsWithSpace;
    procedure TestFoldBeforeFirstFieldRaises;
    procedure TestInterimResponseIsSkipped;
    procedure TestTooManyInterimResponsesRaises;
    procedure TestTransferEncodingWinsOverContentLength;
    procedure TestUnknownTransferCodingRaises;
    procedure TestTransferEncodingNotFinalRaises;
    procedure TestInvalidContentLengthRaises;
    procedure TestNormalChunkedBodyStillDecodes;
  end;

implementation

{ THttp1ParseTest }

procedure THttp1ParseTest.TestContentLengthDigits;
var
  L: Int64;
begin
  AssertTrue('5 is valid', TryParseContentLength('5', L));
  AssertEquals('value of 5', 5, L);
  AssertTrue('0 is valid', TryParseContentLength('0', L));
  AssertEquals('value of 0', 0, L);
  AssertTrue('surrounding spaces are trimmed', TryParseContentLength(' 12 ', L));
  AssertEquals('value of 12', 12, L);
end;

procedure THttp1ParseTest.TestContentLengthEqualListAccepted;
var
  L: Int64;
begin
  // RFC 9110 section 8.6: a list of equal values is one value
  AssertTrue('equal list is valid', TryParseContentLength('5, 5', L));
  AssertEquals('equal list value', 5, L);
end;

procedure THttp1ParseTest.TestContentLengthDifferentListRejected;
var
  L: Int64;
begin
  AssertFalse('different values are refused', TryParseContentLength('5, 6', L));
end;

procedure THttp1ParseTest.TestContentLengthRejectsSignsAndPrefixes;
var
  L: Int64;
begin
  // RFC 9110 section 8.6: 1*DIGIT only
  AssertFalse('plus sign', TryParseContentLength('+5', L));
  AssertFalse('dollar sign', TryParseContentLength('$10', L));
  AssertFalse('hex prefix', TryParseContentLength('0x10', L));
  AssertFalse('ampersand', TryParseContentLength('&17', L));
  AssertFalse('percent', TryParseContentLength('%101', L));
  AssertFalse('space inside a number', TryParseContentLength('5 5', L));
  AssertFalse('empty value', TryParseContentLength('', L));
  AssertFalse('empty list element', TryParseContentLength('5,,5', L));
  AssertFalse('minus sign', TryParseContentLength('-1', L));
end;

procedure THttp1ParseTest.TestContentLengthOverflowRejected;
var
  L: Int64;
begin
  AssertTrue('High(Int64) is valid',
    TryParseContentLength('9223372036854775807', L));
  AssertEquals('High(Int64) value', High(Int64), L);
  AssertFalse('one above High(Int64) overflows',
    TryParseContentLength('9223372036854775808', L));
  AssertFalse('19 digits above High(Int64) overflow',
    TryParseContentLength('9999999999999999999', L));
  AssertFalse('a long run of digits overflows',
    TryParseContentLength('99999999999999999999999999', L));
end;

procedure THttp1ParseTest.TestTransferEncodingChunked;
var
  Known: Boolean;
begin
  AssertTrue('chunked', TransferEncodingIsChunked('chunked', Known));
  AssertTrue('chunked is known', Known);
  AssertTrue('CHUNKED in capitals', TransferEncodingIsChunked('CHUNKED', Known));
  AssertTrue('CHUNKED is known', Known);
  AssertTrue('gzip, chunked: chunked is last', TransferEncodingIsChunked('gzip, chunked', Known));
  AssertFalse('gzip, chunked: gzip is not known', Known);
  AssertFalse('chunked, gzip: chunked is not last',
    TransferEncodingIsChunked('chunked, gzip', Known));
  AssertFalse('chunked, gzip: not known', Known);
  AssertFalse('xchunked is not chunked',
    TransferEncodingIsChunked('xchunked', Known));
  AssertFalse('xchunked is not known', Known);
  AssertFalse('chunked-foo is not chunked',
    TransferEncodingIsChunked('chunked-foo', Known));
end;

{ THttp1StrictLiveTest }

function THttp1StrictLiveTest.Exchange(const AWire: string; out ABody: string;
  out AReusable: Boolean): IHttpResponse;
var
  Sock: TScriptSocket;
  H1: THttp1Connection;
  Req: TStreamRequest;
  Buf: array[0..255] of Byte;
  N: Integer;
  Chunk: string;
begin
  Sock := TScriptSocket.Create;
  Sock.Feed(AWire);
  H1 := THttp1Connection.Create(Sock, 500);
  try
    Req := TStreamRequest.Create('GET', 'a.example');
    Req := Req.WithScheme('http').WithPath('/x');
    Result := H1.Send(Req);
    ABody := '';
    repeat
      N := Result.Body.Read(Buf[0], SizeOf(Buf));
      if N > 0 then
      begin
        SetString(Chunk, PAnsiChar(@Buf[0]), N);
        ABody := ABody + Chunk;
      end;
    until N <= 0;
    AReusable := H1.Reusable;
  finally
    H1.Free;
  end;
end;

function THttp1StrictLiveTest.ExchangeRaises(const AWire: string): Boolean;
var
  Body: string;
  Reusable: Boolean;
  R: IHttpResponse;
begin
  Result := False;
  try
    R := Exchange(AWire, Body, Reusable);
  except
    on E: EHttpProtocolError do
      Result := True;
  end;
end;

procedure THttp1StrictLiveTest.TestBareLfInStatusLineRaises;
begin
  AssertTrue('a bare LF ends the status line: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestBareLfInFieldLineRaises;
begin
  AssertTrue('a bare LF ends a field line: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'X-A: b'#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestBareCrInFieldLineRaises;
begin
  AssertTrue('a bare CR inside a field line: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'X-A: b'#13'c'#13#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestBareLfInChunkSizeRaises;
begin
  AssertTrue('a bare LF ends the chunk-size line: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
      '2'#10'ok'#13#10'0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestBareLfInChunkTerminatorRaises;
begin
  AssertTrue('a bare LF ends the chunk terminator: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
      '2'#13#10'ok'#10'0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestSpaceBeforeColonRaises;
begin
  // RFC 9112 section 5.1: a server must reject it, so a client must not accept it
  AssertTrue('a space before the colon: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'X-Name : v'#13#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestObsFoldJoinsWithSpace;
var
  Body: string;
  Reusable: Boolean;
  R: IHttpResponse;
begin
  // RFC 9112 section 5.2: a user agent replaces obs-fold with one SP
  R := Exchange('HTTP/1.1 200 OK'#13#10'X-Long: first'#13#10' second'#13#10 +
    'Content-Length: 2'#13#10#13#10'ok', Body, Reusable);
  AssertEquals('folded value joined with one space', 'first second',
    R.Headers.GetFirst('X-Long'));
  AssertEquals('body after the folded field', 'ok', Body);
end;

procedure THttp1StrictLiveTest.TestFoldBeforeFirstFieldRaises;
begin
  AssertTrue('a fold before any field: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10' bad'#13#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestInterimResponseIsSkipped;
var
  Body: string;
  Reusable: Boolean;
  R: IHttpResponse;
begin
  // RFC 9110 section 15.2: a 1xx response is not the final response
  R := Exchange('HTTP/1.1 103 Early Hints'#13#10'Link: </a.css>'#13#10#13#10 +
    'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok', Body, Reusable);
  AssertEquals('the final status is 200', 200, R.StatusCode);
  AssertEquals('the body of the final response', 'ok', Body);
  AssertEquals('the 1xx fields are not in the final headers', '',
    R.Headers.GetFirst('Link'));
end;

procedure THttp1StrictLiveTest.TestTooManyInterimResponsesRaises;
var
  Wire: string;
  I: Integer;
begin
  Wire := '';
  for I := 1 to 17 do
    Wire := Wire + 'HTTP/1.1 103 Early Hints'#13#10#13#10;
  Wire := Wire + 'HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10#13#10;
  AssertTrue('more than 16 interim responses: refused', ExchangeRaises(Wire));
end;

procedure THttp1StrictLiveTest.TestTransferEncodingWinsOverContentLength;
var
  Body: string;
  Reusable: Boolean;
  R: IHttpResponse;
begin
  // RFC 9112 section 6.3, item 3: Transfer-Encoding wins; the connection is not reused
  R := Exchange('HTTP/1.1 200 OK'#13#10'Content-Length: 99'#13#10 +
    'Transfer-Encoding: chunked'#13#10#13#10 +
    '2'#13#10'ok'#13#10'0'#13#10#13#10, Body, Reusable);
  AssertEquals('status 200', 200, R.StatusCode);
  AssertEquals('the chunked body is read', 'ok', Body);
  AssertFalse('the connection is not reusable', Reusable);
end;

procedure THttp1StrictLiveTest.TestUnknownTransferCodingRaises;
begin
  AssertTrue('a transfer coding the client does not know: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: gzip, chunked'#13#10#13#10 +
      '0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestTransferEncodingNotFinalRaises;
begin
  AssertTrue('chunked is not the last coding: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked, gzip'#13#10#13#10 +
      '0'#13#10#13#10));
end;

procedure THttp1StrictLiveTest.TestInvalidContentLengthRaises;
begin
  AssertTrue('a signed Content-Length: refused',
    ExchangeRaises('HTTP/1.1 200 OK'#13#10'Content-Length: +2'#13#10#13#10'ok'));
end;

procedure THttp1StrictLiveTest.TestNormalChunkedBodyStillDecodes;
var
  Body: string;
  Reusable: Boolean;
  R: IHttpResponse;
begin
  R := Exchange('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '5;ext=1'#13#10'hello'#13#10'6'#13#10' world'#13#10'0'#13#10'X-Trailer: t'#13#10#13#10,
    Body, Reusable);
  AssertEquals('chunks decoded', 'hello world', Body);
  AssertTrue('a normal exchange keeps the connection reusable', Reusable);
end;

initialization
  RegisterTest(THttp1ParseTest);
  RegisterTest(THttp1StrictLiveTest);
end.
