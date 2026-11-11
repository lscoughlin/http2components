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
unit Http2.Client.Redirects.Policy.Test;

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
  TRedirectPolicyTest = class(TTestCase)
  published
    procedure TestMaxRedirectsLimit;
    procedure TestCrossOriginUsesSeparateConnection;
    procedure Test301WithoutLocationReturnedAsIs;
    procedure TestFollowRedirectsFalseReturns3xxUntouched;
    procedure TestHeadersPreservedAcrossHop;
    procedure TestRelativeLocationIsResolved;
  end;

implementation

procedure TRedirectPolicyTest.TestMaxRedirectsLimit;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  Raised: Boolean;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', '/loop')]));
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithMaxRedirects(2)
    .Build;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  except
    on E: EHttpTooManyRedirects do Raised := True;
  end;
  AssertTrue('exceeding MaxRedirects raises', Raised);
  Sock := Factory.SocketAt(0);
  // MaxRedirects=2 allows the initial request plus two hops = 3 requests
  AssertTrue('exactly MaxRedirects+1 requests were issued',
    Sock.WaitForRequests(3, 2000));
  AssertEquals('no fourth request', 3, Sock.RequestCount);
  Client.Close;
end;

procedure TRedirectPolicyTest.TestCrossOriginUsesSeparateConnection;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Pool: TConnectionPool;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('301', 'https://b.example/y')]));
  Factory.SetDialScript(1, SpecArray([HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('final status', 200, R.StatusCode);
  Pool := (Client as THttpClient).Pool;
  AssertEquals('a second connection was dialled', 2, Factory.Dials);
  AssertEquals('dial 1 host', 'a.example', Factory.HostAt(0));
  AssertEquals('dial 2 host is the new authority', 'b.example', Factory.HostAt(1));
  AssertEquals('two pooled connections', 2, Pool.ConnectionCount);
  Client.Close;
end;

procedure TRedirectPolicyTest.Test301WithoutLocationReturnedAsIs;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('301')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the 301 is returned unchanged', 301, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('one request issued', Sock.WaitForRequests(1, 2000));
  AssertEquals('no follow-up request', 1, Sock.RequestCount);
  Client.Close;
end;

procedure TRedirectPolicyTest.TestFollowRedirectsFalseReturns3xxUntouched;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', '/elsewhere')]));
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithFollowRedirects(False)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the 302 is returned untouched', 302, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('one request issued', Sock.WaitForRequests(1, 2000));
  AssertEquals('no follow-up request', 1, Sock.RequestCount);
  Client.Close;
end;

procedure TRedirectPolicyTest.TestHeadersPreservedAcrossHop;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('307', '/again'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithHeader('x-hop', 'kept')
    .WithBody(THttpBody.FromString('b')));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertTrue('header carried to hop 2',
    Pos('x-hop', Sock.RequestAt(1).HeaderNames) > 0);
  Client.Close;
end;

procedure TRedirectPolicyTest.TestRelativeLocationIsResolved;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', 'child'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/dir/page'));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('relative location resolved against the base path',
    '/dir/child', Sock.RequestAt(1).Path);
  Client.Close;
end;

initialization
  RegisterTest(TRedirectPolicyTest);
end.
