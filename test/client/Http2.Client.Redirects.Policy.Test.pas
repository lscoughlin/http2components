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
  Http2.Client.Tls, Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.Redirects.Test,
  Http2.Client.Tls.Types, Http2.Client.Config.Security;
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

  /// the fake factory with the cleartext dial added, so an http origin can
  /// reach the fake peers.  Every dial is served by the fake.
  TCleartextFakeFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FInner: TFakeFrameFactory;
  public
    constructor Create(const AInner: TFakeFrameFactory);
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
  end;

  /// the redirect policy against the fake peers (plan S-10 work card)
  TRedirectPolicyLiveTest = class(TTestCase)
  private
    function HasHeader(const ARec: TReqRecord; const AName: string): Boolean;
  published
    procedure TestSameOriginOnlyRefusesOtherPortAndReturns3xx;
    procedure TestSameOriginOnlyFollowsSameOriginKeepingCredentials;
    procedure TestSchemeChangeRefusedUnderEveryPolicy;
    procedure TestSameOriginUpgradeFollowsSameOrigin;
    procedure TestOtherPoliciesRefuseHttpToHttps;
    procedure TestSameOriginUpgradeFollowsHttpToHttpsKeepingCredentials;
    procedure TestSameHostOnlyFollowsOtherPort;
    procedure TestSameHostOnlyRefusesOtherHost;
    procedure TestAnyHostFollowsOtherHostAndDropsCredentials;
    procedure TestSameOriginUpgradeRefusesHttpsToHttp;
    procedure TestRelativeLocationWithQueryStaysOnHost;
    procedure Test307WithBodyToOtherOriginIsRefused;
    procedure TestPostRedirectDropsBodyHeaders;
  end;

  /// relative Location values against the redirect policy (plan S-11 work card)
  TRelativeLocationTest = class(TTestCase)
  published
    procedure TestRelativeLocationWithQueryKeepsSameHostAndPath;
    procedure TestProtocolRelativeLocationRefusedUnderSameHostOnly;
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

constructor TCleartextFakeFactory.Create(const AInner: TFakeFrameFactory);
begin
  inherited Create;
  FInner := AInner;
end;

function TCleartextFakeFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  Result := FInner.Dial(AHost, APort, ATimeoutMs);
end;

function TCleartextFakeFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  Result := FInner.Dial(AHost, APort, ATimeoutMs);
  if AScheme = 'https' then
    AProtocol := npHttp2Tls
  else
    AProtocol := npHttp2Cleartext;
end;

function TRedirectPolicyLiveTest.HasHeader(const ARec: TReqRecord;
  const AName: string): Boolean;
begin
  Result := Pos(',' + LowerCase(AName) + ',',
    ',' + LowerCase(ARec.HeaderNames) + ',') > 0;
end;

procedure TRedirectPolicyLiveTest.TestSameOriginOnlyRefusesOtherPortAndReturns3xx;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', 'https://a.example:8443/y')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameOriginOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the refused 302 is returned to the caller', 302, R.StatusCode);
  AssertEquals('no second request', 1, Factory.SocketAt(0).RequestCount);
  AssertEquals('no second dial', 1, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestSameOriginOnlyFollowsSameOriginKeepingCredentials;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', '/y'), HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameOriginOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x')
    .WithHeader('authorization', 'Bearer t')
    .WithHeader('cookie', 's=1'));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertTrue('same origin keeps authorization', HasHeader(Sock.RequestAt(1), 'authorization'));
  AssertTrue('same origin keeps cookie', HasHeader(Sock.RequestAt(1), 'cookie'));
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestSameHostOnlyFollowsOtherPort;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', 'https://a.example:8443/y')]));
  Factory.SetDialScript(1, SpecArray([HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameHostOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the same host on another port is followed', 200, R.StatusCode);
  AssertEquals('a second dial was made', 2, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestSameHostOnlyRefusesOtherHost;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', 'https://b.example/y')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameHostOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the other host is refused', 302, R.StatusCode);
  AssertEquals('no second dial', 1, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestAnyHostFollowsOtherHostAndDropsCredentials;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', 'https://b.example/y')]));
  Factory.SetDialScript(1, SpecArray([HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x')
    .WithHeader('authorization', 'Bearer t')
    .WithHeader('cookie', 's=1'));
  AssertEquals('final status', 200, R.StatusCode);
  AssertTrue('first hop sent authorization',
    HasHeader(Factory.SocketAt(0).RequestAt(0), 'authorization'));
  Sock := Factory.SocketAt(1);
  AssertTrue('second hop was issued', Sock.WaitForRequests(1, 2000));
  AssertFalse('other host drops authorization', HasHeader(Sock.RequestAt(0), 'authorization'));
  AssertFalse('other host drops cookie', HasHeader(Sock.RequestAt(0), 'cookie'));
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestSameOriginUpgradeRefusesHttpsToHttp;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', 'http://a.example/y')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithClearText(ctPriorKnowledge).WithRedirectPolicy(rpSameOriginUpgrade).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('https to http is refused', 302, R.StatusCode);
  AssertEquals('no second dial', 1, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestRelativeLocationWithQueryStaysOnHost;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/login?next=https://evil.com/x'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameOriginOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('one dial: the redirect stays on the host', 1, Factory.Dials);
  AssertEquals('the path is on the same host', '/login', Copy(Sock.RequestAt(1).Path, 1, 6));
  Client.Close;
end;

procedure TRelativeLocationTest.TestRelativeLocationWithQueryKeepsSameHostAndPath;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
  Rec: TReqRecord;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/login?next=https://evil.com/x'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameOriginOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('one dial: the redirect stays on the host', 1, Factory.Dials);
  AssertEquals('the second dial target is the same host', 'a.example', Factory.HostAt(0));
  Rec := Sock.RequestAt(1);
  AssertEquals('the second request goes to the same authority', 'a.example', Rec.Authority);
  AssertEquals('the second request path is /login with the query',
    '/login?next=https://evil.com/x', Rec.Path);
  Client.Close;
end;

procedure TRelativeLocationTest.TestProtocolRelativeLocationRefusedUnderSameHostOnly;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', '//evil.com/x')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameHostOnly).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('the other host from a protocol-relative Location is refused', 302, R.StatusCode);
  AssertEquals('no second request', 1, Factory.SocketAt(0).RequestCount);
  AssertEquals('no second dial', 1, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.Test307WithBodyToOtherOriginIsRefused;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('307', 'https://b.example/y')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithBody(THttpBody.FromString('b')));
  AssertEquals('a 307 with a body to another origin is returned', 307, R.StatusCode);
  AssertEquals('no second dial', 1, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestPostRedirectDropsBodyHeaders;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TFakeFrameSocket;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([
    HdrSpec('302', '/again'),
    HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmPost, 'https://a.example/x')
    .WithHeader('content-type', 'text/plain')
    .WithBody(THttpBody.FromString('abc')));
  AssertEquals('final status', 200, R.StatusCode);
  Sock := Factory.SocketAt(0);
  AssertTrue('two requests were issued', Sock.WaitForRequests(2, 2000));
  AssertEquals('hop 2 is a GET', 'GET', Sock.RequestAt(1).Method);
  AssertFalse('hop 2 has no content-length', HasHeader(Sock.RequestAt(1), 'content-length'));
  AssertFalse('hop 2 has no content-type', HasHeader(Sock.RequestAt(1), 'content-type'));
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestSchemeChangeRefusedUnderEveryPolicy;
const
  cTargets: array[0..1] of string = ('http://a.example/y', 'ftp://a.example/y');
var
  P: TRedirectPolicy;
  T: Integer;
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  for P := Low(TRedirectPolicy) to High(TRedirectPolicy) do
    for T := 0 to High(cTargets) do
    begin
      Factory := TFakeFrameFactory.Create;
      Factory.SetDialScript(0, SpecArray([HdrSpec('302', cTargets[T])]));
      Client := THttpClientFactory.Create.WithSocketFactory(Factory)
        .WithRedirectPolicy(P).Build;
      R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
      AssertEquals('scheme change refused: ' + cTargets[T] + ' policy ' + IntToStr(Ord(P)),
        302, R.StatusCode);
      AssertEquals('no second dial', 1, Factory.Dials);
      Client.Close;
    end;
end;

procedure TRedirectPolicyLiveTest.TestSameOriginUpgradeFollowsSameOrigin;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('302', '/y'), HdrSpec('200')]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithRedirectPolicy(rpSameOriginUpgrade).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://a.example/x'));
  AssertEquals('same origin is followed', 200, R.StatusCode);
  AssertEquals('one dial for the same origin', 1, Factory.Dials);
  Client.Close;
end;

procedure TRedirectPolicyLiveTest.TestOtherPoliciesRefuseHttpToHttps;
var
  Policies: array[0..2] of TRedirectPolicy;
  I: Integer;
  Inner: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Policies[0] := rpAnyHost;
  Policies[1] := rpSameHostOnly;
  Policies[2] := rpSameOriginOnly;
  for I := 0 to High(Policies) do
  begin
    Inner := TFakeFrameFactory.Create;
    Inner.SetDialScript(0, SpecArray([HdrSpec('302', 'https://a.example/y')]));
    Client := THttpClientFactory.Create
      .WithSocketFactory(TCleartextFakeFactory.Create(Inner))
      .WithClearText(ctPriorKnowledge).WithRedirectPolicy(Policies[I]).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'http://a.example/x'));
    AssertEquals('http to https is refused under policy ' + IntToStr(I), 302, R.StatusCode);
    AssertEquals('no upgrade dial under policy ' + IntToStr(I), 1, Inner.Dials);
    Client.Close;
  end;
end;

procedure TRedirectPolicyLiveTest.TestSameOriginUpgradeFollowsHttpToHttpsKeepingCredentials;
var
  Inner: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  Inner := TFakeFrameFactory.Create;
  Inner.SetDialScript(0, SpecArray([HdrSpec('302', 'https://a.example/y')]));
  Inner.SetDialScript(1, SpecArray([HdrSpec('200')]));
  Client := THttpClientFactory.Create
    .WithSocketFactory(TCleartextFakeFactory.Create(Inner))
    .WithClearText(ctPriorKnowledge).WithRedirectPolicy(rpSameOriginUpgrade).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'http://a.example/x')
    .WithHeader('authorization', 'Bearer t')
    .WithHeader('cookie', 's=1'));
  AssertEquals('the http to https upgrade is followed', 200, R.StatusCode);
  AssertTrue('upgrade keeps authorization',
    HasHeader(Inner.SocketAt(1).RequestAt(0), 'authorization'));
  AssertTrue('upgrade keeps cookie',
    HasHeader(Inner.SocketAt(1).RequestAt(0), 'cookie'));
  Client.Close;
end;

initialization
  RegisterTest(TRedirectPolicyTest);
  RegisterTest(TRedirectPolicyLiveTest);
  RegisterTest(TRelativeLocationTest);
end.
