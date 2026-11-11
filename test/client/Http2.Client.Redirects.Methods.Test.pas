{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
/// Redirect tests (plan story S10, tasks 10.1-10.4) plus the reusable
/// scripted frame-level fake used by the timeout suite too.
// - NOTHING here opens a real socket or touches the network: an injected
//   IHttp2SocketFactory hands out in-memory frame-level peers that decode the
//   client's request HEADERS (with a persistent HPACK decoder, so dynamic
///   table state stays in sync) and answer with a scripted response per
///   request.
// - non-vacuous by construction: the method/body matrix is asserted from the
///   DECODED request HEADERS and DATA payloads the fake captured, so removing
//   the 303->GET rewrite, the 307 body preservation or the non-replayable
//   guard fails a test; cross-origin asserts the factory dialled twice.
unit Http2.Client.Redirects.Methods.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.Redirects.Test;
type
  TRedirectMethodTest = class(TTestCase)
  published
    procedure Test301WithGetPreservesMethod;
    procedure Test302WithPostRewritesToGetAndDropsBody;
    procedure Test303RewritesToGetAndDropsBody;
    procedure Test307PreservesMethodAndReplayableBody;
    procedure Test308PreservesMethodAndReplayableBody;
    procedure Test307WithBodyWriterRaisesNotReplayable;
  end;

implementation

procedure TRedirectMethodTest.Test301WithGetPreservesMethod;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('301', '/moved'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('hop 1 method', 'GET', Sock.RequestAt(0).Method);
  AssertEquals('hop 2 method stays GET', 'GET', Sock.RequestAt(1).Method);
  AssertEquals('hop 2 path resolved', '/moved', Sock.RequestAt(1).Path);
  Client.Close;
end;

procedure TRedirectMethodTest.Test302WithPostRewritesToGetAndDropsBody;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/next'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('payload')));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('hop 1 method', 'POST', Sock.RequestAt(0).Method);
  AssertEquals('hop 2 method rewritten to GET', 'GET', Sock.RequestAt(1).Method);
  AssertFalse('hop 2 body dropped', Sock.RequestAt(1).HasBody);
  Client.Close;
end;

procedure TRedirectMethodTest.Test303RewritesToGetAndDropsBody;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('303', '/see-other'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('payload')));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('hop 1 method', 'POST', Sock.RequestAt(0).Method);
  AssertTrue('hop 1 carried the body', Sock.RequestAt(0).HasBody);
  AssertEquals('hop 2 method becomes GET', 'GET', Sock.RequestAt(1).Method);
  AssertFalse('hop 2 body dropped', Sock.RequestAt(1).HasBody);
  Client.Close;
end;

procedure TRedirectMethodTest.Test307PreservesMethodAndReplayableBody;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('307', '/retry'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('payload')));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('hop 2 method preserved', 'POST', Sock.RequestAt(1).Method);
  AssertTrue('hop 2 body arrived', Sock.WaitForRequestBody(1, 7, 2000));
  AssertEquals('hop 2 body replayed', 'payload', StrOf(Sock.RequestAt(1).Body));
  Client.Close;
end;

procedure TRedirectMethodTest.Test308PreservesMethodAndReplayableBody;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('308', '/retry'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('payload')));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('hop 2 method preserved', 'POST', Sock.RequestAt(1).Method);
  AssertTrue('hop 2 body arrived', Sock.WaitForRequestBody(1, 7, 2000));
  AssertEquals('hop 2 body replayed', 'payload', StrOf(Sock.RequestAt(1).Body));
  Client.Close;
end;

type
  TTwoChunkWriter = class(TInterfacedObject, IBodyWriter)
  private
    FIssued: Boolean;
  public
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

function TTwoChunkWriter.NextChunk(out ABuffer: TBytes): Boolean;
begin
  if FIssued then
    Exit(False);
  FIssued := True;
  ABuffer := BytesOf('streamed');
  Result := True;
end;

procedure TRedirectMethodTest.Test307WithBodyWriterRaisesNotReplayable;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  Raised: Boolean;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('307', '/retry')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
      .WithBodyWriter(TTwoChunkWriter.Create));
  except
    on E: EHttpNotReplayable do Raised := True;
  end;
  AssertTrue('a body writer cannot be replayed on 307', Raised);
  Client.Close;
end;

initialization
  RegisterTest(TRedirectMethodTest);
end.
