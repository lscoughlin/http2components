{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, obs-fold, transfer-encoding, websocket handshake
notes:
  - This unit pins the response field rules of the HTTP/1.1 client: one transfer
    coding rule, a restricted obsolete line fold and a strict field name.
  - A response that needed a fold is delivered, and its connection is not reused.
  - The WebSocket client reads the handshake with the same field parser.
---
}
unit Http2.Client.Http1Fields.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1, Http2.Client.ClearText.Support;

type
  THttp1FieldsTest = class(TTestCase)
  private
    function Exchange(const AWire: string; out ABody: string;
      out AReusable: Boolean): IHttpResponse;
    function ExchangeRaises(const AWire: string): Boolean;
    function Parses(const ALines: array of string): Boolean;
  published
    procedure TestTransferCodingTableIsRefused;
    procedure TestPlainChunkedIsAccepted;
    procedure TestFoldedCustomFieldIsAcceptedAndNotReused;
    procedure TestFoldedFramingFieldsAreRefused;
    procedure TestFoldInTheFirstFieldLineIsRefused;
    procedure TestSpaceBeforeColonAndInsideNameAreRefused;
    procedure TestBadFieldNamesAreRefused;
    procedure TestDifferentContentLengthsAreRefused;
    procedure TestFoldedTrailerIsNotReused;
    procedure TestUnfoldedResponseIsStillReused;
    procedure TestWebSocketHandshakeFieldsStayStrict;
  end;

implementation

function THttp1FieldsTest.Exchange(const AWire: string; out ABody: string;
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

function THttp1FieldsTest.ExchangeRaises(const AWire: string): Boolean;
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

function THttp1FieldsTest.Parses(const ALines: array of string): Boolean;
var
  Lines: TArray<string>;
  I: Integer;
  F: TArray<THttp1HeaderField>;
begin
  SetLength(Lines, Length(ALines));
  for I := 0 to High(ALines) do
    Lines[I] := ALines[I];
  Result := True;
  try
    F := ParseHeaders(Lines);
  except
    on E: EHttpProtocolError do
      Result := False;
  end;
end;

procedure THttp1FieldsTest.TestTransferCodingTableIsRefused;
var
  V: string;
begin
  // Go refuses every transfer coding except a single chunked: so does the client
  for V in ['gzip, chunked', 'gzip', 'identity', '', 'chunked, gzip', 'chunked, chunked',
            'xchunked', 'compress, chunked'] do
    AssertTrue('Transfer-Encoding "' + V + '" is refused',
      ExchangeRaises('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: ' + V + #13#10#13#10 +
        '0'#13#10#13#10));
end;

procedure THttp1FieldsTest.TestPlainChunkedIsAccepted;
var
  Body: string;
  Reusable: Boolean;
begin
  Exchange('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '2'#13#10'ok'#13#10'0'#13#10#13#10, Body, Reusable);
  AssertEquals('body', 'ok', Body);
  AssertTrue('reusable', Reusable);
end;

procedure THttp1FieldsTest.TestFoldedCustomFieldIsAcceptedAndNotReused;
var
  Body: string;
  Reusable: Boolean;
  R: IHttpResponse;
begin
  R := Exchange('HTTP/1.1 200 OK'#13#10'X-Custom: one'#13#10#9'two'#13#10 +
    'Content-Length: 2'#13#10#13#10'ok', Body, Reusable);
  AssertEquals('one space replaces the fold', 'one two', R.Headers.GetFirst('X-Custom'));
  AssertEquals('body delivered', 'ok', Body);
  AssertFalse('a response that needed a fold is not reused', Reusable);
end;

procedure THttp1FieldsTest.TestFoldedFramingFieldsAreRefused;
var
  N, V: string;
begin
  AssertTrue('folded Content-Length', ExchangeRaises('HTTP/1.1 200 OK'#13#10 +
    'Content-Length: 1'#13#10' 0'#13#10#13#10'0123456789'));
  AssertTrue('folded Content-Length value on the fold line', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Content-Length:'#13#10' 2'#13#10#13#10'ok'));
  AssertTrue('folded Transfer-Encoding', ExchangeRaises('HTTP/1.1 200 OK'#13#10 +
    'Transfer-Encoding: chunked,'#13#10' gzip'#13#10#13#10'0'#13#10#13#10));
  AssertTrue('folded Transfer-Encoding hides chunked', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Transfer-Encoding:'#13#10' chunked'#13#10#13#10'0'#13#10#13#10));
  for N in ['Connection', 'Upgrade', 'Keep-Alive'] do
  begin
    V := 'HTTP/1.1 200 OK'#13#10 + N + ': a'#13#10' b'#13#10'Content-Length: 0'#13#10#13#10;
    AssertTrue('folded ' + N, ExchangeRaises(V));
  end;
end;

procedure THttp1FieldsTest.TestFoldInTheFirstFieldLineIsRefused;
begin
  AssertTrue('a fold in the first field line', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10' X-A: b'#13#10'Content-Length: 0'#13#10#13#10));
  AssertTrue('a tab fold in the first field line', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10#9'X-A: b'#13#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1FieldsTest.TestSpaceBeforeColonAndInsideNameAreRefused;
begin
  AssertTrue('Content-Length : 2', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Content-Length : 2'#13#10#13#10'ok'));
  AssertTrue('Transfer-Encoding : chunked', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Transfer-Encoding : chunked'#13#10#13#10'0'#13#10#13#10));
  AssertTrue('a tab before the colon', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'X-A'#9': b'#13#10'Content-Length: 0'#13#10#13#10));
  AssertTrue('a space inside a name', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'X A: b'#13#10'Content-Length: 0'#13#10#13#10));
  AssertTrue('a space inside Content-Length', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Content Length: 2'#13#10#13#10'ok'));
end;

procedure THttp1FieldsTest.TestBadFieldNamesAreRefused;
begin
  AssertTrue('an empty name', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10': b'#13#10'Content-Length: 0'#13#10#13#10));
  AssertTrue('a control byte in a name', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'X'#1'A: b'#13#10'Content-Length: 0'#13#10#13#10));
  AssertTrue('a DEL byte in a name', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'X'#127'A: b'#13#10'Content-Length: 0'#13#10#13#10));
  AssertTrue('a high byte in a name', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'X'#200'A: b'#13#10'Content-Length: 0'#13#10#13#10));
end;

procedure THttp1FieldsTest.TestDifferentContentLengthsAreRefused;
begin
  AssertTrue('two different Content-Length fields', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10'Content-Length: 3'#13#10#13#10'ok!'));
end;

procedure THttp1FieldsTest.TestFoldedTrailerIsNotReused;
var
  Body: string;
  Reusable: Boolean;
begin
  Exchange('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '2'#13#10'ok'#13#10'0'#13#10'X-T: a'#13#10' b'#13#10#13#10, Body, Reusable);
  AssertEquals('body', 'ok', Body);
  AssertFalse('a folded trailer block: not reused', Reusable);
  AssertTrue('a folded Content-Length trailer is refused', ExchangeRaises(
    'HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '2'#13#10'ok'#13#10'0'#13#10'Content-Length: 1'#13#10' 0'#13#10#13#10));
end;

procedure THttp1FieldsTest.TestUnfoldedResponseIsStillReused;
var
  Body: string;
  Reusable: Boolean;
begin
  Exchange('HTTP/1.1 200 OK'#13#10'X-Custom: one'#13#10'Content-Length: 2'#13#10#13#10'ok',
    Body, Reusable);
  AssertTrue('no fold: the connection is reused', Reusable);
end;

procedure THttp1FieldsTest.TestWebSocketHandshakeFieldsStayStrict;
var
  N: string;
begin
  // the client reads the handshake with ParseHeaders
  for N in ['Upgrade', 'Connection', 'Sec-WebSocket-Accept', 'Sec-WebSocket-Protocol',
            'Content-Length', 'Transfer-Encoding'] do
  begin
    AssertFalse('a space before the colon in ' + N, Parses([N + ' : x']));
    AssertFalse('a fold of ' + N, Parses([N + ': a', ' b']));
  end;
  AssertFalse('a fold before the first field', Parses([' Upgrade: websocket']));
  AssertTrue('plain handshake fields', Parses(['Upgrade: websocket', 'Connection: Upgrade',
    'Sec-WebSocket-Accept: abc=']));
end;

initialization
  RegisterTest(THttp1FieldsTest);
end.
