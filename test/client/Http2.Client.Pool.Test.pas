{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves client tests from the source project
---
}
unit Http2.Client.Pool.Test;

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
  TClientPoolTest = class(TTestCase)
  published
    procedure TestPoolNeverExceedsMaxConnections;
    procedure TestMaxConnectionsPerHostAndTotalAreIndependent;
    procedure TestPoolNeverExceedsMaxConnectionsPerHost;
    procedure TestPoolNeverExceedsMaxTotalConnections;
    procedure TestConcurrentSendAcrossOneConnection;
    procedure TestIdleBodyReadDoesNotBlockSecondStream;
    procedure TestWaitingHeadersDoNotBlockSecondStream;
    procedure TestCancelledHeaderWaitLeavesConnectionUsable;
    procedure TestLeastLoadedSelection;
    procedure TestPerConnectionStreamCap;
    procedure TestCloseRejectsNewSends;
    procedure TestCloseKeepsOutstandingBodyReadable;
  end;

implementation

procedure TClientPoolTest.TestPoolNeverExceedsMaxConnections;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Pool: TConnectionPool;
  Workers: array[0..5] of TSendWorker;
  I, Succeeded, TimedOut, Timeouts: Integer;
begin
  Factory := TFakeSocketFactory.Create;
  // answer with HEADERS only (no END_STREAM): each acquired lease keeps its
  // slot, so the pool can never wave more than MaxConnections*cap through
  Factory.SetResponse('200', nil, False);
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithMaxConnections(2)
    .WithMaxStreamsPerConnection(1)
    .WithHeaderTimeout(600)
    .Build;
  Pool := (Client as THttpClient).Pool;
  for I := 0 to High(Workers) do
  begin
    Workers[I] := TSendWorker.Create(Client, 'https://api.example/x');
    Workers[I].Start;
  end;
  Succeeded := 0;
  TimedOut := 0;
  Timeouts := 0;
  // wait for every worker BEFORE releasing any response, so the two holders
  // keep their slots occupied for the whole deadline and the rest time out
  for I := 0 to High(Workers) do
    AssertTrue('worker finished', Workers[I].WaitDone(5000));
  for I := 0 to High(Workers) do
  begin
    if (not Workers[I].Raised) and (Workers[I].Status = 200) then
      Inc(Succeeded)
    else
    begin
      if Pos('timed out', Workers[I].Error) > 0 then
        Inc(Timeouts);
      Inc(TimedOut);
    end;
  end;
  AssertEquals('exactly MaxConnections connections dialled', 2,
    Factory.Dials);
  AssertEquals('pool reports MaxConnections connections', 2,
    Pool.ConnectionCount);
  AssertEquals('two streams fit the two slots', 2, Succeeded);
  AssertEquals('the rest wait and time out at the slot deadline', 4, TimedOut);
  AssertEquals('the waits time out with EHttpTimeout', 4, Timeouts);
  for I := 0 to High(Workers) do
    Workers[I].Free;
  Client.Close;
end;

procedure TClientPoolTest.TestMaxConnectionsPerHostAndTotalAreIndependent;
var
  Base, PerHost, Total, Legacy: THttpClientFactory;
begin
  Base := THttpClientFactory.Create;
  // the two caps are set independently, so a high-concurrency caller can keep
  // a large total while tightly bounding each authority
  PerHost := Base.WithMaxConnectionsPerHost(1)
    .WithMaxTotalConnections(64)
    .WithMaxStreamsPerConnection(20);
  AssertEquals('per-host cap set', 1, PerHost.MaxConnectionsPerHost);
  AssertEquals('total cap set', 64, PerHost.MaxTotalConnections);
  AssertEquals('stream cap set', 20, PerHost.MaxStreamsPerConnection);
  // MaxConnectionsPerHost leaves the total alone
  AssertEquals('the base total is unchanged', 32, Base.MaxTotalConnections);

  Total := Base.WithMaxTotalConnections(8);
  AssertEquals('total cap set', 8, Total.MaxTotalConnections);
  AssertEquals('per-host cap untouched', 4, Total.MaxConnectionsPerHost);

  // the legacy single setter pins both, which is right for a single authority
  Legacy := Base.WithMaxConnections(6);
  AssertEquals('WithMaxConnections sets the per-host cap', 6,
    Legacy.MaxConnectionsPerHost);
  AssertEquals('WithMaxConnections also sets the total', 6,
    Legacy.MaxTotalConnections);
end;

procedure TClientPoolTest.TestPoolNeverExceedsMaxConnectionsPerHost;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Pool: TConnectionPool;
  Workers: array[0..3] of TSendWorker;
  I, Succeeded, TimedOut, Timeouts: Integer;
begin
  Factory := TFakeSocketFactory.Create;
  // hold every lease open (HEADERS only) so a slot occupied stays occupied
  Factory.SetResponse('200', nil, False);
  // one connection per host, but room for all four pool-wide: if the per-host
  // cap were ignored, each host would open its second connection and the
  // per-origin counts below would read 2
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithMaxConnectionsPerHost(1)
    .WithMaxTotalConnections(4)
    .WithMaxStreamsPerConnection(1)
    .WithHeaderTimeout(600)
    .Build;
  Pool := (Client as THttpClient).Pool;
  Workers[0] := TSendWorker.Create(Client, 'https://a.example/x');
  Workers[1] := TSendWorker.Create(Client, 'https://a.example/x');
  Workers[2] := TSendWorker.Create(Client, 'https://b.example/x');
  Workers[3] := TSendWorker.Create(Client, 'https://b.example/x');
  for I := 0 to High(Workers) do
    Workers[I].Start;
  Succeeded := 0;
  TimedOut := 0;
  Timeouts := 0;
  for I := 0 to High(Workers) do
    AssertTrue('worker finished', Workers[I].WaitDone(5000));
  for I := 0 to High(Workers) do
  begin
    if (not Workers[I].Raised) and (Workers[I].Status = 200) then
      Inc(Succeeded)
    else
    begin
      if Pos('timed out', Workers[I].Error) > 0 then
        Inc(Timeouts);
      Inc(TimedOut);
    end;
  end;
  // one connection per host (2 total), each capped at a single stream
  AssertEquals('one connection dialled per host', 2, Factory.Dials);
  AssertEquals('the pool holds per-host + total connections', 2,
    Pool.ConnectionCount);
  AssertEquals('a.example opened exactly one connection', 1,
    Pool.ConnectionCountForOrigin('a.example'));
  AssertEquals('b.example opened exactly one connection', 1,
    Pool.ConnectionCountForOrigin('b.example'));
  AssertEquals('one stream fits each host slot', 2, Succeeded);
  AssertEquals('the extra request per host waits and times out', 2, TimedOut);
  AssertEquals('the waits time out with EHttpTimeout', 2, Timeouts);
  for I := 0 to High(Workers) do
    Workers[I].Free;
  Client.Close;
end;

procedure TClientPoolTest.TestPoolNeverExceedsMaxTotalConnections;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Pool: TConnectionPool;
  Workers: array[0..1] of TSendWorker;
  I, Succeeded, TimedOut: Integer;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', nil, False);
  // a generous per-host cap but a total of one: the global resource budget
  // must bind below the per-host cap
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithMaxConnectionsPerHost(4)
    .WithMaxTotalConnections(1)
    .WithMaxStreamsPerConnection(1)
    .WithHeaderTimeout(600)
    .Build;
  Pool := (Client as THttpClient).Pool;
  Workers[0] := TSendWorker.Create(Client, 'https://a.example/x');
  Workers[1] := TSendWorker.Create(Client, 'https://b.example/x');
  for I := 0 to High(Workers) do
    Workers[I].Start;
  Succeeded := 0;
  TimedOut := 0;
  for I := 0 to High(Workers) do
    AssertTrue('worker finished', Workers[I].WaitDone(5000));
  for I := 0 to High(Workers) do
    if (not Workers[I].Raised) and (Workers[I].Status = 200) then
      Inc(Succeeded)
    else
      Inc(TimedOut);
  AssertEquals('only one connection may exist pool-wide', 1, Factory.Dials);
  AssertEquals('the pool reports its one connection', 1, Pool.ConnectionCount);
  AssertEquals('one stream proceeds', 1, Succeeded);
  AssertEquals('the second host waits and times out', 1, TimedOut);
  for I := 0 to High(Workers) do
    Workers[I].Free;
  Client.Close;
end;

procedure TClientPoolTest.TestConcurrentSendAcrossOneConnection;
const
  N = 8;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Pool: TConnectionPool;
  Workers: array[0..N - 1] of TSendWorker;
  I, Ok: Integer;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.AddResponseHeader('x-test-concurrent', 'dynamic-value');
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithMaxConnections(1)
    .WithMaxStreamsPerConnection(100)
    .Build;
  Pool := (Client as THttpClient).Pool;
  for I := 0 to N - 1 do
  begin
    Workers[I] := TSendWorker.Create(Client, 'https://api.example/x');
    Workers[I].Start;
  end;
  Ok := 0;
  for I := 0 to N - 1 do
  begin
    AssertTrue('worker finished', Workers[I].WaitDone(10000));
    AssertFalse('no error under concurrency: ' + Workers[I].Error,
      Workers[I].Raised);
    AssertEquals('shared dynamic header is decoded', 'dynamic-value',
      Workers[I].Response.Headers.GetFirst('x-test-concurrent'));
    if Workers[I].Status = 200 then
      Inc(Ok);
    Workers[I].Free;
  end;
  AssertEquals('all concurrent sends succeed', N, Ok);
  AssertEquals('all streams share one connection', 1, Factory.Dials);
  AssertEquals('pool still reports one connection', 1, Pool.ConnectionCount);
  Client.Close;
end;

procedure TClientPoolTest.TestIdleBodyReadDoesNotBlockSecondStream;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  First, Second: TSendWorker;
  Reader: TBodyReadWorker;
  B: array[0..15] of Byte;
  N: Integer;
  FirstBodyCount: Integer;
  SecondBody: string;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', BytesOf('body'), True);
  Factory.AddResponseHeader('x-test-hpack', 'shared-table-value');
  Factory.SetResponseGate(frgFirstBody);
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithMaxConnections(1).WithMaxStreamsPerConnection(8)
    .WithHeaderTimeout(5000).Build;
  First := TSendWorker.Create(Client, 'https://api.example/first');
  Second := nil;
  Reader := nil;
  SecondBody := '';
  FirstBodyCount := 0;
  try
    First.Start;
    AssertTrue('first response headers arrive', First.WaitDone(2000));
    AssertFalse('first send succeeds', First.Raised);
    Reader := TBodyReadWorker.Create(First.Response);
    Reader.Start;
    AssertTrue('first body reader starts', Reader.WaitStarted(1000));
    Second := TSendWorker.Create(Client, 'https://api.example/second');
    Second.Start;
    AssertTrue('second response arrives while first body is idle',
      Second.WaitDone(1500));
    AssertFalse('second send succeeds', Second.Raised);
    AssertEquals('dynamic HPACK response header decodes',
      'shared-table-value',
      Second.Response.Headers.GetFirst('x-test-hpack'));
    N := Second.Response.Body.Read(B[0], SizeOf(B));
    SetLength(SecondBody, N);
    if N > 0 then Move(B[0], SecondBody[1], N);
    Factory.ReleaseGate;
    AssertTrue('first body read finishes after release', Reader.WaitDone(2000));
    FirstBodyCount := Reader.ByteCount;
  finally
    Factory.ReleaseGate;
    if Reader <> nil then Reader.WaitDone(2000);
    if Second <> nil then Second.Free;
    if Reader <> nil then Reader.Free;
    First.Free;
    Client.Close;
  end;
  AssertEquals('second stream body is readable', 'body', SecondBody);
  AssertTrue('first stream body is readable', FirstBodyCount > 0);
end;

procedure TClientPoolTest.TestWaitingHeadersDoNotBlockSecondStream;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  First, Second: TSendWorker;
  SecondDone: Boolean;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', BytesOf('body'), True);
  Factory.AddResponseHeader('x-test-hpack', 'shared-table-value');
  Factory.SetResponseGate(frgFirstHeaders);
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithMaxConnections(1).WithMaxStreamsPerConnection(8)
    .WithHeaderTimeout(5000).Build;
  First := TSendWorker.Create(Client, 'https://api.example/first');
  Second := nil;
  try
    First.Start;
    AssertTrue('first request reaches server; dials=' + IntToStr(Factory.Dials),
      Factory.WaitForRequests(1, 2000));
    Second := TSendWorker.Create(Client, 'https://api.example/second');
    Second.Start;
    SecondDone := Second.WaitDone(1500);
    Factory.ReleaseGate;
    AssertTrue('first response finishes during cleanup', First.WaitDone(2500));
    AssertTrue('second stream finishes while first headers are pending', SecondDone);
    AssertFalse('second stream succeeds', Second.Raised);
    AssertEquals('dynamic HPACK response header decodes',
      'shared-table-value',
      Second.Response.Headers.GetFirst('x-test-hpack'));
    AssertFalse('released first stream succeeds', First.Raised);
  finally
    Factory.ReleaseGate;
    if Second <> nil then Second.Free;
    First.Free;
    Client.Close;
  end;
end;

procedure TClientPoolTest.TestCancelledHeaderWaitLeavesConnectionUsable;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Token: ICancellationToken;
  First: TCancellableSendWorker;
  Second: TSendWorker;
begin
  Factory := TFakeSocketFactory.Create;
  Factory.SetResponse('200', BytesOf('body'), True);
  Factory.AddResponseHeader('x-test-hpack', 'shared-table-value');
  Factory.SetResponseGate(frgFirstHeaders);
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithMaxConnections(1).WithMaxStreamsPerConnection(8)
    .WithHeaderTimeout(5000).Build;
  Token := TCancellationToken.Create;
  First := TCancellableSendWorker.Create(Client, Token);
  Second := nil;
  try
    First.Start;
    AssertTrue('first request reaches server; dials=' + IntToStr(Factory.Dials),
      Factory.WaitForRequests(1, 2000));
    (Token as TCancellationToken).Cancel;
    AssertTrue('cancelled header wait ends', First.WaitDone(2000));
    AssertTrue('first send observes cancellation', First.Raised);
    Second := TSendWorker.Create(Client, 'https://api.example/second');
    Second.Start;
    AssertTrue('connection accepts a request after cancellation',
      Second.WaitDone(2000));
    AssertFalse('request after cancellation succeeds', Second.Raised);
    AssertEquals('connection HPACK state remains valid after cancellation',
      'shared-table-value',
      Second.Response.Headers.GetFirst('x-test-hpack'));
  finally
    Factory.ReleaseGate;
    if Second <> nil then Second.Free;
    First.Free;
    Client.Close;
  end;
end;

procedure TClientPoolTest.TestLeastLoadedSelection;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Pool: TConnectionPool;
  Origin: string;
  Picked: IPooledConnection;
begin
  Factory := TFakeSocketFactory.Create;
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  Pool := (Client as THttpClient).Pool;
  Origin := 'api.example';
  Pool.AddForTest(Origin, TFakePooledConnection.Create(Origin, 3, True));
  Pool.AddForTest(Origin, TFakePooledConnection.Create(Origin, 1, True));
  Pool.AddForTest(Origin, TFakePooledConnection.Create(Origin, 0, False));
  Picked := Pool.PickForTest(Origin);
  AssertTrue('a connection was picked', Picked <> nil);
  AssertEquals('least-loaded eligible connection chosen', 1,
    Picked.ActiveStreams);
  Client.Close;
end;

procedure TClientPoolTest.TestPerConnectionStreamCap;
var
  Sock: IHttp2Socket;
  Conn: TConnection;
  Pooled: THttpConnection;
  Settings: TConnectionSettings;
begin
  Sock := TFakeServerSocket.Create;
  Conn := TConnection.Create(Sock);
  Pooled := THttpConnection.Create(Conn, 'api.example', 1);
  try
    AssertTrue('idle connection is eligible', Pooled.Eligible);
    Conn.RegisterStream(1, TFakeConnStream.Create);
    AssertFalse('local cap reached -> ineligible', Pooled.Eligible);
    Conn.UnregisterStream(1);
    AssertTrue('slot freed -> eligible again', Pooled.Eligible);
    // peer SETTINGS_MAX_CONCURRENT_STREAMS also caps eligibility
    Settings := TConnectionSettings.Defaults;
    Settings.MaxConcurrentStreams := 1;
    Conn.ApplyPeerSettingsValue(Settings);
    AssertTrue('peer cap 1, no streams -> eligible', Pooled.Eligible);
    Conn.RegisterStream(3, TFakeConnStream.Create);
    AssertFalse('peer cap 1 reached -> ineligible', Pooled.Eligible);
    Conn.UnregisterStream(3);
  finally
    // Pooled owns the TConnection and frees it in its destructor
    Pooled.Free;
  end;
end;

procedure TClientPoolTest.TestCloseRejectsNewSends;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  Raised: Boolean;
begin
  Factory := TFakeSocketFactory.Create;
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  Client.Close;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'https://api.example/x'));
  except
    on E: EHttpConnectionClosed do Raised := True;
  end;
  AssertTrue('Send after Close raises EHttpConnectionClosed', Raised);
end;

procedure TClientPoolTest.TestCloseKeepsOutstandingBodyReadable;
var
  Factory: TFakeSocketFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  First: array[0..0] of Byte;
  Rest: array[0..15] of Byte;
  N: LongInt;
  Total: Integer;
begin
  Factory := TFakeSocketFactory.Create;
  // answer with a body that does not end the stream, so the response body
  // stays readable after Close
  Factory.SetResponse('200', BytesOf('hello-world'), False);
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/x'));
  AssertEquals('response headers', 200, R.StatusCode);

  N := R.Body.Read(First[0], 1);
  AssertEquals('one buffered byte before Close', 1, N);
  Client.Close;
  Total := N;
  while Total < 11 do
  begin
    N := R.Body.Read(Rest[0], SizeOf(Rest));
    AssertTrue('buffered body readable after Close', N > 0);
    Inc(Total, N);
  end;
  AssertEquals('the whole buffered body stayed readable after Close', 11,
    Total);
end;

initialization
  RegisterTest(TClientPoolTest);
end.
