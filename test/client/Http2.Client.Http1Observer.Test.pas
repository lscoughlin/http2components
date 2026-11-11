{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.Http1Observer.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Redirects.Test,
  Http2.Client.ClearText.Support, Http2.Client.Http1, Http2.Client.Http1.Test, Http2.Client.Sse, Http2.Client.RequestObserver.Support;

type
  THttp1ObserverTest = class(TTestCase)
  private
    function Send(const AFactory: IHttp2SocketFactory;
      const AObserver: IHttpClientObserver; const AUrl: string;
      const APolicy: TClearTextPolicy; out AClient: IHttpClient): IHttpResponse;
  published
    // 18.11
    procedure TestContentLengthBodyEndsAtEof;
    procedure TestChunkedBodyEndsAtEof;
    procedure TestUntilCloseBodyEndsAtEof;
    procedure TestDroppedHttp1ResponseIsAbandoned;
    procedure TestEmptyHttp1BodyEndsAtOnce;
    procedure TestBodyStreamReportsOnceForEofAndRelease;
    // 18.16
    procedure TestHttp1TlsFallbackProducesStartAndEnd;
    procedure TestPriorKnowledgeH2cProducesStartAndEnd;
    procedure TestDeclinedUpgradeProducesStartAndEnd;
    procedure TestDeclinedUpgradeKeepsTheRealWriteStamp;
    procedure TestCleartextHttp1ProducesStartAndEnd;
    procedure TestHttp1RequestBodySizeIsReported;
  end;


implementation

{ THttp1ObserverTest }

function THttp1ObserverTest.Send(const AFactory: IHttp2SocketFactory;
  const AObserver: IHttpClientObserver; const AUrl: string;
  const APolicy: TClearTextPolicy; out AClient: IHttpClient): IHttpResponse;
begin
  AClient := THttpClientFactory.Create
    .WithSocketFactory(AFactory)
    .WithHttp1Fallback
    .WithClearText(APolicy)
    .WithConnectTimeout(2000).WithHeaderTimeout(2000)
    .WithRequestObserver(AObserver)
    .Build;
  Result := AClient.Send(THttpRequest.Create(hmGet, AUrl));
end;

function ReadAll(const AResponse: IHttpResponse): Integer;
var
  Buf: array[0..63] of Byte;
  N: LongInt;
begin
  Result := 0;
  repeat
    N := AResponse.Body.Read(Buf, SizeOf(Buf));
    if N > 0 then
      Inc(Result, N);
  until N <= 0;
end;
procedure THttp1ObserverTest.TestContentLengthBodyEndsAtEof;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Tls,
    'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello'), ObsRef,
    'https://secure.example/x', ctReject, Client);
  AssertEquals('open until read', 0, Obs.EndCount);
  AssertEquals('five bytes', 5, ReadAll(R));
  AssertEquals('one end at EOF', 1, Obs.EndCount);
  AssertEquals('order', 'S0 H0 E0', Obs.Order);
  AssertEquals('bytes in', 5, Obs.Outcome(0).O.BytesIn);
  AssertEquals('status', 200, Obs.Outcome(0).O.StatusCode);
  AssertFalse('not abandoned', Obs.Outcome(0).O.Abandoned);
  AssertTrue('HTTP/1.1 over TLS', Obs.Outcome(0).O.Protocol = npHttp1Tls);
  AssertFalse('a fresh connection', Obs.Outcome(0).O.ConnectionReused);
  R := nil;
  AssertEquals('release adds nothing', 1, Obs.EndCount);
  Client.Close;
end;

procedure THttp1ObserverTest.TestChunkedBodyEndsAtEof;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Tls,
    'HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '5'#13#10'hello'#13#10'0'#13#10#13#10), ObsRef,
    'https://secure.example/x', ctReject, Client);
  AssertEquals('open until read', 0, Obs.EndCount);
  AssertEquals('five decoded bytes', 5, ReadAll(R));
  AssertEquals('one end at EOF', 1, Obs.EndCount);
  AssertEquals('bytes in', 5, Obs.Outcome(0).O.BytesIn);
  AssertFalse('not abandoned', Obs.Outcome(0).O.Abandoned);
  Client.Close;
end;

procedure THttp1ObserverTest.TestUntilCloseBodyEndsAtEof;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Tls,
    'HTTP/1.1 200 OK'#13#10#13#10'hello'), ObsRef,
    'https://secure.example/x', ctReject, Client);
  AssertEquals('open until read', 0, Obs.EndCount);
  AssertEquals('five bytes', 5, ReadAll(R));
  AssertEquals('one end at EOF', 1, Obs.EndCount);
  AssertEquals('bytes in', 5, Obs.Outcome(0).O.BytesIn);
  AssertFalse('not abandoned', Obs.Outcome(0).O.Abandoned);
  Client.Close;
end;

procedure THttp1ObserverTest.TestDroppedHttp1ResponseIsAbandoned;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Tls,
    'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello'), ObsRef,
    'https://secure.example/x', ctReject, Client);
  AssertEquals('open while held', 0, Obs.EndCount);
  R := nil;
  AssertEquals('release ends it', 1, Obs.EndCount);
  AssertTrue('abandoned', Obs.Outcome(0).O.Abandoned);
  Client.Close;
end;

procedure THttp1ObserverTest.TestEmptyHttp1BodyEndsAtOnce;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Tls,
    'HTTP/1.1 204 No Content'#13#10#13#10), ObsRef,
    'https://secure.example/x', ctReject, Client);
  AssertEquals('nothing to read: ended', 1, Obs.EndCount);
  AssertEquals('headers precede the end', 'S0 H0 E0', Obs.Order);
  AssertFalse('not abandoned', Obs.Outcome(0).O.Abandoned);
  R := nil;
  AssertEquals('release adds nothing', 1, Obs.EndCount);
  Client.Close;
end;

procedure THttp1ObserverTest.TestBodyStreamReportsOnceForEofAndRelease;
var
  Exch: TCountingExchange;
  ExchRef: IExchangeObserver;
  Conn: THttp1Connection;
  Script: TSocketScript;
  ScriptRef: IHttp2Socket;
  R: IHttpResponse;
  Req: TStreamRequest;
begin
  // the codec-level latch: EOF and a later release report one end between them
  Exch := TCountingExchange.Create;
  ExchRef := Exch;
  Script := TSocketScript.Create;
  ScriptRef := Script;
  Script.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 3'#13#10#13#10'abc');
  Conn := THttp1Connection.Create(ScriptRef);
  try
    Req := TStreamRequest.Create('GET', 'h.example').WithExchange(ExchRef);
    R := Conn.Send(Req);
    AssertEquals('three bytes', 3, ReadAll(R));
    AssertEquals('EOF reported once', 1, Exch.Ends);
    R := nil;
    AssertEquals('release adds none', 1, Exch.Ends);
    AssertEquals('and was not abandoned', 0, Exch.Abandoned);
  finally
    Conn.Free;
  end;
end;

procedure THttp1ObserverTest.TestHttp1TlsFallbackProducesStartAndEnd;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Tls,
    'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok'), ObsRef,
    'https://secure.example/x', ctReject, Client);
  ReadAll(R);
  AssertEquals('start, headers, end', 'S0 H0 E0', Obs.Order);
  AssertTrue('HTTP/1.1 over TLS', Obs.Outcome(0).O.Protocol = npHttp1Tls);
  Client.Close;
end;

procedure THttp1ObserverTest.TestPriorKnowledgeH2cProducesStartAndEnd;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TFramePeerPlainFactory.Create('200', BytesOf('0123456789')), ObsRef,
    'http://127.0.0.1:28080/small.txt', ctPriorKnowledge, Client);
  AssertEquals('ten bytes', 10, ReadAll(R));
  AssertEquals('start, headers, end', 'S0 H0 E0', Obs.Order);
  AssertTrue('HTTP/2 over cleartext',
    Obs.Outcome(0).O.Protocol = npHttp2Cleartext);
  AssertEquals('bytes in', 10, Obs.Outcome(0).O.BytesIn);
  Client.Close;
end;

procedure THttp1ObserverTest.TestDeclinedUpgradeProducesStartAndEnd;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Cleartext,
    'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello'), ObsRef,
    'http://plain.example/x', ctUpgrade, Client);
  AssertEquals('five bytes', 5, ReadAll(R));
  AssertEquals('start, headers, end', 'S0 H0 E0', Obs.Order);
  AssertTrue('the declined upgrade is HTTP/1.1',
    Obs.Outcome(0).O.Protocol = npHttp1Cleartext);
  AssertEquals('bytes in', 5, Obs.Outcome(0).O.BytesIn);
  AssertFalse('not abandoned', Obs.Outcome(0).O.Abandoned);
  Client.Close;
end;

var
  GTickUs: Int64;

function TickingClock: Int64;
begin
  Result := InterlockedExchangeAdd64(GTickUs, 100) + 100;
end;

procedure THttp1ObserverTest.TestDeclinedUpgradeKeepsTheRealWriteStamp;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  O: THttpOutcome;
begin
  // the probe carries the request, and the pool reports "request written"
  // again once the declined response head was read; the stamp must stay at
  // the real write, which precedes the read that delivered the response
  GTickUs := 0;
  SetNowUsHook(TickingClock);
  try
    Obs := TRecordingRequestObserver.Create;
    ObsRef := Obs;
    R := Send(TScriptProtocolFactory.Create(npHttp1Cleartext,
      'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello'), ObsRef,
      'http://plain.example/x', ctUpgrade, Client);
    AssertEquals('five bytes', 5, ReadAll(R));
    O := Obs.Outcome(0).O;
    AssertTrue('the first message arrived', O.FirstMessageUs > 0);
    AssertTrue('request written before the first byte arrived: ' +
      IntToStr(O.RequestSentUs) + ' vs ' + IntToStr(O.FirstMessageUs),
      O.RequestSentUs < O.FirstMessageUs);
    AssertTrue('request written before headers',
      O.RequestSentUs <= O.HeadersUs);
  finally
    ResetNowUsHook;
  end;
  Client.Close;
end;

procedure THttp1ObserverTest.TestCleartextHttp1ProducesStartAndEnd;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  R := Send(TScriptProtocolFactory.Create(npHttp1Cleartext,
    'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello'), ObsRef,
    'http://plain.example/x', ctHttp1, Client);
  AssertEquals('five bytes', 5, ReadAll(R));
  AssertEquals('start, headers, end', 'S0 H0 E0', Obs.Order);
  AssertTrue('cleartext HTTP/1.1', Obs.Outcome(0).O.Protocol = npHttp1Cleartext);
  Client.Close;
end;

procedure THttp1ObserverTest.TestHttp1RequestBodySizeIsReported;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  Client := THttpClientFactory.Create
    .WithSocketFactory(TScriptProtocolFactory.Create(npHttp1Tls,
      'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok'))
    .WithHttp1Fallback.WithRequestObserver(ObsRef).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://secure.example/x')
    .WithBody(THttpBody.FromString('payload')));
  ReadAll(R);
  AssertEquals('the body, not the head, is counted', 7,
    Obs.Outcome(0).O.BytesOut);
  Client.Close;
end;

{ arrival stamping }


initialization
  RegisterTest(THttp1ObserverTest);
end.
