{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves client tests from the source project
---
}
unit Http2.Client.Lifecycle.Test;

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
  TClientLifecycleTest = class(TTestCase)
  published
    procedure TestLiveGetAgainstNghttpd;
    procedure TestLivePostEchoAgainstNghttpd;
    procedure TestFactoryObserverReceivesConnectionAndFrameEvents;
  end;

implementation

procedure TClientLifecycleTest.TestLiveGetAgainstNghttpd;
var
  Client: IHttpClient;
  R: IHttpResponse;
  Url: string;
begin
  // opt-in: requires nghttpd on 127.0.0.1:8080 and the matching TLS cert; the
  // default suite stays hermetic with this test skipped
  if GetEnvironmentVariable('HTTP2_LIVE_ITEST') <> '1' then
    Exit;
  Url := GetEnvironmentVariable('HTTP2_LIVE_ITEST_URL');
  if Url = '' then
    Url := 'https://127.0.0.1:8080/';
  Client := THttpClientFactory.Create
    .WithCACertFile(GetEnvironmentVariable('HTTP2_LIVE_ITEST_CA'))
    .Build;
  try
    R := Client.Send(THttpRequest.Create(hmGet, Url));
    AssertEquals('live GET returns 200', 200, R.StatusCode);
  finally
    Client.Close;
  end;
end;

procedure TClientLifecycleTest.TestLivePostEchoAgainstNghttpd;
var
  Client: IHttpClient;
  R: IHttpResponse;
  Url, Echoed, Sent: string;
begin
  // nghttpd must be started with --echo-upload so a POST is echoed back
  if GetEnvironmentVariable('HTTP2_LIVE_ITEST') <> '1' then
    Exit;
  Url := GetEnvironmentVariable('HTTP2_LIVE_ITEST_URL');
  if Url = '' then
    Url := 'https://127.0.0.1:8080/';
  Sent := 'http2client-echo-body';
  Client := THttpClientFactory.Create
    .WithCACertFile(GetEnvironmentVariable('HTTP2_LIVE_ITEST_CA'))
    .Build;
  try
    R := Client.Send(THttpRequest.Create(hmPost, Url)
      .WithHeader('content-type', 'text/plain')
      .WithBody(THttpBody.FromString(Sent)));
    AssertEquals('live POST returns 200', 200, R.StatusCode);
    Echoed := string(AnsiString(PAnsiChar(ReadAllBodyBytes(R.Body))));
    AssertEquals('nghttpd echoed the uploaded POST body', Sent, Echoed);
  finally
    Client.Close;
  end;
end;

procedure TClientLifecycleTest.TestFactoryObserverReceivesConnectionAndFrameEvents;
var
  Fact: TFakeSocketFactory;
  Obs: TRecordingObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Fact := TFakeSocketFactory.Create;
  Obs := TRecordingObserver.Create;
  Client := THttpClientFactory.Create
    .WithSocketFactory(Fact)
    .WithObserver(Obs)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/thing'));
  AssertEquals('status decoded', 200, R.StatusCode);
  AssertTrue('connection open was observed',
    Obs.WaitForCount(oekConnectionOpen, 1, 3000));
  AssertTrue('the request HEADERS frame was observed outbound',
    Obs.WaitForCount(oekFrameOut, 1, 3000));
  AssertTrue('the server SETTINGS frame was observed inbound',
    Obs.WaitForCount(oekFrameIn, 1, 3000));
  AssertTrue('the stream lease was observed open',
    Obs.WaitForCount(oekStreamOpen, 1, 3000));
  // non-vacuous: a factory that dropped the observer would record nothing
  AssertTrue('events were actually delivered', Obs.Count > 0);
  Client.Close;
  AssertTrue('connection close was observed',
    Obs.WaitForCount(oekConnectionClose, 1, 3000));
end;

initialization
  RegisterTest(TClientLifecycleTest);
end.
