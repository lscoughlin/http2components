{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests in this unit check the client option and its validation at Build.
---
}
unit Http2.Client.UnixClient.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Proxy, Http2.Client;

type
  /// tests for THttpClientFactory.WithUnixSocket and its checks in Build
  TUnixClientTest = class(TTestCase)
  published
    procedure TestDefaultHasNoUnixPath;
    procedure TestWithUnixSocketIsCopyOnWrite;
    procedure TestEmptyPathClearsTheOption;
    procedure TestBuildAcceptsAnAbsolutePath;
    procedure TestBuildAcceptsAPathOf103Bytes;
    procedure TestBuildRaisesForRelativePath;
    procedure TestBuildRaisesForPathOver103Bytes;
    procedure TestBuildRaisesWithExplicitProxy;
    procedure TestBuildRaisesWithAllProxy;
    procedure TestBuildRaisesWithProxySelector;
    procedure TestBuildRaisesWithProxyEnvironmentVars;
    procedure TestBuildIgnoresProxyEnvironmentVarsWhenOff;
    procedure TestBuildAcceptsANoProxyList;
  end;

implementation

type
  /// a selector that answers direct for every URI
  TDirectSelector = class(TInterfacedObject, IProxySelector)
  public
    function SelectProxy(const AUri: string): IProxy;
  end;

function TDirectSelector.SelectProxy(const AUri: string): IProxy;
begin
  Result := nil;
end;

/// a lookup that holds one proxy value for http_proxy
function ProxyEnvLookup(const AName: string): string;
begin
  if AName = 'http_proxy' then
    Result := 'http://proxy.example:3128'
  else
    Result := '';
end;

/// the path of AChars bytes after the leading slash
function AbsolutePathOfLength(const ALength: Integer): string;
begin
  Result := '/' + StringOfChar('a', ALength - 1);
end;

/// true when Build raises EHttpUnixSocketConfigError
function BuildRaisesUnixConfigError(const AFactory: THttpClientFactory): Boolean;
begin
  Result := False;
  try
    AFactory.Build;
  except
    on EHttpUnixSocketConfigError do
      Result := True;
  end;
end;

{ TUnixClientTest }

procedure TUnixClientTest.TestDefaultHasNoUnixPath;
begin
  AssertEquals('', THttpClientFactory.Create.UnixPath);
end;

procedure TUnixClientTest.TestWithUnixSocketIsCopyOnWrite;
var
  A, B: THttpClientFactory;
begin
  A := THttpClientFactory.Create;
  B := A.WithUnixSocket('/tmp/h2-test.sock');
  AssertEquals('', A.UnixPath);
  AssertEquals('/tmp/h2-test.sock', B.UnixPath);
end;

procedure TUnixClientTest.TestEmptyPathClearsTheOption;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create.WithUnixSocket('relative.sock');
  F := F.WithUnixSocket('');
  AssertEquals('', F.UnixPath);
  AssertFalse('an empty path must not raise at Build',
    BuildRaisesUnixConfigError(F));
end;

procedure TUnixClientTest.TestBuildAcceptsAnAbsolutePath;
begin
  AssertFalse(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')));
end;

procedure TUnixClientTest.TestBuildAcceptsAPathOf103Bytes;
begin
  AssertFalse(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket(AbsolutePathOfLength(103))));
end;

procedure TUnixClientTest.TestBuildRaisesForRelativePath;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('h2.sock')));
end;

procedure TUnixClientTest.TestBuildRaisesForPathOver103Bytes;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket(AbsolutePathOfLength(104))));
end;

procedure TUnixClientTest.TestBuildRaisesWithExplicitProxy;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithProxy('proxy.corp', 3128)));
end;

procedure TUnixClientTest.TestBuildRaisesWithAllProxy;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithAllProxy('http://proxy.corp:3128')));
end;

procedure TUnixClientTest.TestBuildRaisesWithProxySelector;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithProxySelector(TDirectSelector.Create)));
end;

procedure TUnixClientTest.TestBuildRaisesWithProxyEnvironmentVars;
begin
  AssertTrue(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithProxyEnvironmentLookup(@ProxyEnvLookup)
      .WithProxyEnvironmentVars(True)));
end;

procedure TUnixClientTest.TestBuildIgnoresProxyEnvironmentVarsWhenOff;
begin
  AssertFalse(BuildRaisesUnixConfigError(
    THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
      .WithProxyEnvironmentLookup(@ProxyEnvLookup)));
end;

procedure TUnixClientTest.TestBuildAcceptsANoProxyList;
begin
  AssertFalse('a host in NoProxy is not a proxy source',
    BuildRaisesUnixConfigError(
      THttpClientFactory.Create.WithUnixSocket('/tmp/h2-test.sock')
        .WithNoProxy('localhost')));
end;

initialization
  RegisterTest(TUnixClientTest);
end.
