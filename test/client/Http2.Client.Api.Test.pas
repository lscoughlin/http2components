{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves client tests from the source project
---
}
unit Http2.Client.Api.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client,
  Http2.Client.Observer, Http2.Client.Encoding, Http2.Client.Test.Support;

type
  TClientApiTest = class(TTestCase)
  published
    procedure TestFactoryDefaults;
    procedure TestFactoryIsImmutable;
    procedure TestDocumentedFluentChainBuilds;
    procedure TestSendReturnsStatusHeadersAndBody;
    procedure TestSendDecodesAGzipBody;
    procedure TestSendLeavesAnUncodedBodyAlone;
    procedure TestSendKeepsAnUnknownCodingRaw;
    procedure TestResponseReaderDecodesBytes;
    procedure TestResponseReaderDecodesString;
    procedure TestResponseReaderDecodesUTF8String;
    procedure TestResponseReaderDecodesRecord;
    procedure TestWithTextBodySetsBodyAndContentType;
    procedure TestWithTextBodyKeepsExplicitContentType;
    procedure TestReadTextReturnsBody;
  end;

implementation

procedure TClientApiTest.TestFactoryDefaults;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create;
  AssertEquals('MaxConnectionsPerHost default', 4, F.MaxConnectionsPerHost);
  AssertEquals('MaxTotalConnections default', 32, F.MaxTotalConnections);
  AssertEquals('MaxConnections alias', 4, F.MaxConnections);
  AssertEquals('MaxStreamsPerConnection default', 100,
    F.MaxStreamsPerConnection);
  AssertTrue('FollowRedirects default', F.FollowRedirects);
  AssertEquals('MaxRedirects default', 10, F.MaxRedirects);
  AssertEquals('ConnectTimeoutMs default', 10000, F.ConnectTimeoutMs);
  AssertEquals('HeaderTimeoutMs default', 30000, F.HeaderTimeoutMs);
  AssertEquals('IdleTimeoutMs default', 60000, F.IdleTimeoutMs);
  AssertEquals('ProxyHost default', '', F.ProxyHost);
  AssertEquals('ProxyPort default', 0, Ord(F.ProxyPort));
end;

procedure TClientApiTest.TestFactoryIsImmutable;
var
  Base, Forked: THttpClientFactory;
begin
  Base := THttpClientFactory.Create;
  Forked := Base.WithMaxConnections(8).WithFollowRedirects(False);
  AssertEquals('fork changed MaxConnections', 8, Forked.MaxConnections);
  AssertEquals('fork changed MaxConnectionsPerHost', 8,
    Forked.MaxConnectionsPerHost);
  AssertEquals('fork changed MaxTotalConnections', 8,
    Forked.MaxTotalConnections);
  AssertFalse('fork changed FollowRedirects', Forked.FollowRedirects);
  // the original is untouched
  AssertEquals('base MaxConnections unchanged', 4, Base.MaxConnections);
  AssertEquals('base MaxTotalConnections unchanged', 32,
    Base.MaxTotalConnections);
  AssertTrue('base FollowRedirects unchanged', Base.FollowRedirects);
  // chaining twice from one base yields independent records
  AssertEquals('base MaxStreams unchanged', 100, Base.MaxStreamsPerConnection);
  AssertEquals('fork MaxStreams unchanged', 100, Forked.MaxStreamsPerConnection);
end;

procedure TClientApiTest.TestDocumentedFluentChainBuilds;
var
  Client: IHttpClient;
begin
  Client := THttpClientFactory.Create
    .WithMaxConnections(8)
    .WithMaxStreamsPerConnection(50)
    .WithFollowRedirects(False)
    .Build;
  AssertTrue('the documented chain builds a client', Client <> nil);
  Client.Close;
end;

procedure TClientApiTest.TestSendReturnsStatusHeadersAndBody;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeSocketFactory.Create;
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/thing'));
  AssertEquals('status decoded from the wire', 200, R.StatusCode);
  AssertEquals('body streamed', '', ReadWholeBody(R.Body));
  AssertEquals('exactly one connection dialled', 1, Factory.Dials);
  Client.Close;
end;

procedure TClientApiTest.TestSendDecodesAGzipBody;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', GzipCompress(BytesOf('a gzipped body')), True);
  Factory.AddResponseHeader('content-encoding', 'gzip');
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/thing')
    .WithAcceptEncoding('gzip'));
  AssertEquals('status decoded from the wire', 200, R.StatusCode);
  // the decode happens below ReadText, so a plain read yields plain bytes
  AssertEquals('the gzip body is decoded transparently', 'a gzipped body',
    ReadText(R));
  AssertEquals('the coding header is removed', '',
    R.Headers.GetFirst('content-encoding'));
  Client.Close;
end;

procedure TClientApiTest.TestSendLeavesAnUncodedBodyAlone;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', BytesOf('plain text'), True);
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/thing'));
  AssertEquals('an uncoded body is returned as it arrived', 'plain text',
    ReadText(R));
  Client.Close;
end;

procedure TClientApiTest.TestSendKeepsAnUnknownCodingRaw;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', BytesOf('brotli bytes'), True);
  Factory.AddResponseHeader('content-encoding', 'br');
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/thing'));
  // an unsupported coding is not decoded, and the header still names it
  AssertEquals('an unknown coding reaches the caller raw', 'brotli bytes',
    ReadText(R));
  AssertEquals('the unknown coding header is kept', 'br',
    R.Headers.GetFirst('content-encoding'));
  Client.Close;
end;

procedure TClientApiTest.TestResponseReaderDecodesBytes;
var
  Resp: IHttpResponse;
  V: TBytes;
begin
  Resp := TFakeResponse.Create(200, TFakeBody.Create(BytesOf('abcd')));
  TResponseReader<TBytes>.Read(Resp, V);
  AssertEquals('byte count', 4, Length(V));
  AssertEquals('byte content', 'abcd', StrOf(V));
end;

procedure TClientApiTest.TestResponseReaderDecodesString;
var
  Resp: IHttpResponse;
  V: AnsiString;
begin
  Resp := TFakeResponse.Create(200, TFakeBody.Create(BytesOf('hello')));
  TResponseReader<AnsiString>.Read(Resp, V);
  AssertEquals('string content', 'hello', string(V));
end;

type
  TSmallDto = record
    A, B: LongWord;
  end;

procedure TClientApiTest.TestResponseReaderDecodesUTF8String;
var
  Resp: IHttpResponse;
  V: UTF8String;
begin
  // UTF8String is an AnsiString on FPC 3.2.4; the base reader copies the body
  // bytes verbatim into it (no code-page conversion)
  Resp := TFakeResponse.Create(200, TFakeBody.Create(BytesOf('h'#195#169'llo')));
  TResponseReader<UTF8String>.Read(Resp, V);
  AssertEquals('utf8 byte count', 6, Length(V));
  AssertEquals('utf8 text', 'h'#195#169'llo', string(V));
end;

procedure TClientApiTest.TestResponseReaderDecodesRecord;
var
  Resp: IHttpResponse;
  V: TSmallDto;
  Raw: TBytes;
begin
  SetLength(Raw, SizeOf(TSmallDto));
  LongWord(Pointer(@Raw[0])^) := $11223344;
  LongWord(Pointer(@Raw[4])^) := $55667788;
  Resp := TFakeResponse.Create(200, TFakeBody.Create(Raw));
  TResponseReader<TSmallDto>.Read(Resp, V);
  AssertEquals('first field', LongWord($11223344), V.A);
  AssertEquals('second field', LongWord($55667788), V.B);
end;

procedure TClientApiTest.TestWithTextBodySetsBodyAndContentType;
var
  Req: THttpRequest;
begin
  Req := WithTextBody(
    THttpRequest.Create(hmPost, 'https://api.example/echo'), 'hello');
  AssertTrue('body is set', Req.Body.IsSet);
  AssertEquals('body bytes', 'hello', StrOf(Req.Body.Data));
  AssertEquals('content-type defaulted', 'text/plain',
    Req.Headers.GetFirst('content-type'));
end;

procedure TClientApiTest.TestWithTextBodyKeepsExplicitContentType;
var
  Req: THttpRequest;
begin
  Req := WithTextBody(
    THttpRequest.Create(hmPost, 'https://api.example/echo')
      .WithHeader('content-type', 'text/csv'), 'a,b');
  AssertEquals('explicit content-type preserved', 'text/csv',
    Req.Headers.GetFirst('content-type'));
end;

procedure TClientApiTest.TestReadTextReturnsBody;
var
  Resp: IHttpResponse;
begin
  Resp := TFakeResponse.Create(200, TFakeBody.Create(BytesOf('plain text')));
  AssertEquals('body as text', 'plain text', ReadText(Resp));
end;

initialization
  RegisterTest(TClientApiTest);
end.
