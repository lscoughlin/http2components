{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
unit Http2.Client.ProxyClient.Builder.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Client.Stream, Http2.Client.Messages, Http2.Client.Proxy, Http2.Client,
  Http2.Client.Redirects.Test, Http2.Client.ProxyClient.Test;

type
  TProxyBuilderTest = class(TTestCase)
  published
    procedure TestDefaults;
    procedure TestWithXReturnsANewRecordAndLeavesTheReceiverUnchanged;
    procedure TestWithNoProxyAppends;
    procedure TestWithNoProxyIgnoresEmpty;
    procedure TestWithAllProxyTrimsAndClears;
    procedure TestBuildRejectsABadAllProxy;
    procedure TestBuildRejectsABadEnvironmentValueOnlyWhenEnabled;
    procedure TestBuildNeverReadsTheEnvironmentWhenOff;
    procedure TestWithProxyKeepsTheProxyHostAndPortProperties;
  end;

  /// a transport with no raw handle (like a TLS socket) on a keep-alive
  /// connection: Read for more than what is buffered would wait for the
  /// server to give up, ReadSome returns at once

implementation

var
  GLookupValues: TStringList;
  GLookupCalls: Integer;

function ScriptedLookup(const AName: string): string;
var
  I: Integer;
begin
  Inc(GLookupCalls);
  Result := '';
  if GLookupValues = nil then
    Exit;
  for I := 0 to GLookupValues.Count - 1 do
    if GLookupValues.Names[I] = AName then
      Exit(GLookupValues.ValueFromIndex[I]);
end;


{ TProxyBuilderTest }

procedure TProxyBuilderTest.TestDefaults;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create;
  AssertEquals('', F.ProxyHost);
  AssertEquals(0, Integer(F.ProxyPort));
  AssertTrue(F.ProxySelector = nil);
  AssertEquals('', F.AllProxy);
  AssertFalse(F.ProxyEnvironmentVars);
  AssertEquals('', F.NoProxy);
end;

procedure TProxyBuilderTest.TestWithXReturnsANewRecordAndLeavesTheReceiverUnchanged;
var
  A, B: THttpClientFactory;
begin
  A := THttpClientFactory.Create;
  B := A.WithAllProxy('socks5://p:1').WithProxyEnvironmentVars.WithNoProxy('x')
    .WithProxySelector(TRecordingSelector.Create);
  AssertEquals('', A.AllProxy);
  AssertFalse(A.ProxyEnvironmentVars);
  AssertEquals('', A.NoProxy);
  AssertTrue(A.ProxySelector = nil);
  AssertEquals('socks5://p:1', B.AllProxy);
  AssertTrue(B.ProxyEnvironmentVars);
  AssertEquals('x', B.NoProxy);
  AssertTrue(B.ProxySelector <> nil);
  AssertFalse('switch can be turned off again',
    B.WithProxyEnvironmentVars(False).ProxyEnvironmentVars);
end;

procedure TProxyBuilderTest.TestWithNoProxyAppends;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create.WithNoProxy('a.example').WithNoProxy('b.example,c');
  AssertEquals('a.example,b.example,c', F.NoProxy);
end;

procedure TProxyBuilderTest.TestWithNoProxyIgnoresEmpty;
begin
  AssertEquals('', THttpClientFactory.Create.WithNoProxy('').NoProxy);
  AssertEquals('', THttpClientFactory.Create.WithNoProxy('   ').NoProxy);
  AssertEquals('a', THttpClientFactory.Create.WithNoProxy('a').WithNoProxy('').NoProxy);
end;

procedure TProxyBuilderTest.TestWithAllProxyTrimsAndClears;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create.WithAllProxy('  http://p:1  ');
  AssertEquals('http://p:1', F.AllProxy);
  AssertEquals('', F.WithAllProxy('').AllProxy);
end;

procedure TProxyBuilderTest.TestBuildRejectsABadAllProxy;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpClientFactory.Create.WithAllProxy('socks4://p:1').Build;
  except
    on EHttpProxyConfigError do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

procedure TProxyBuilderTest.TestBuildRejectsABadEnvironmentValueOnlyWhenEnabled;
var
  Raised: Boolean;
begin
  GLookupValues := TStringList.Create;
  try
    GLookupValues.CaseSensitive := True;
    GLookupValues.Add('https_proxy=ftp://nope:1');
    // switch off: the value is never read
    THttpClientFactory.Create.WithProxyEnvironmentLookup(ScriptedLookup).Build.Close;
    Raised := False;
    try
      THttpClientFactory.Create.WithProxyEnvironmentLookup(ScriptedLookup)
        .WithProxyEnvironmentVars.Build;
    except
      on EHttpProxyConfigError do
        Raised := True;
    end;
    AssertTrue('switch on: raised at Build', Raised);
  finally
    FreeAndNil(GLookupValues);
  end;
end;

procedure TProxyBuilderTest.TestBuildNeverReadsTheEnvironmentWhenOff;
begin
  GLookupValues := TStringList.Create;
  try
    GLookupValues.Add('http_proxy=http://x:1');
    GLookupCalls := 0;
    THttpClientFactory.Create.WithProxyEnvironmentLookup(ScriptedLookup)
      .Build.Close;
    AssertEquals('switch off: the environment is never read', 0, GLookupCalls);
    THttpClientFactory.Create.WithProxyEnvironmentLookup(ScriptedLookup)
      .WithProxyEnvironmentVars.Build.Close;
    AssertTrue('switch on: it is read once at Build', GLookupCalls > 0);
  finally
    FreeAndNil(GLookupValues);
  end;
end;

procedure TProxyBuilderTest.TestWithProxyKeepsTheProxyHostAndPortProperties;
var
  F: THttpClientFactory;
begin
  F := THttpClientFactory.Create.WithProxy('proxy.corp', 3128);
  AssertEquals('proxy.corp', F.ProxyHost);
  AssertEquals(3128, Integer(F.ProxyPort));
end;


initialization
  RegisterTest(TProxyBuilderTest);
end.
