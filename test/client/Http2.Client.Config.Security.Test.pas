{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, security options
notes:
  - this holds the tests for the client security options record
---
}
unit Http2.Client.Config.Security.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Client.Config.Security, Http2.Client.Factory, Http2.Client.Api,
  Http2.Client.Errors, Http2.Client.Core, Http2.Client.Pool;

type
  TClientSecurityOptionsTest = class(TTestCase)
  published
    procedure TestDefaultsMatchTable;
    procedure TestDefaultProblemsIsEmpty;
    procedure TestWithMethodsReturnChangedCopy;
    procedure TestRedirectPolicyRoundTrip;
    procedure TestReceiveQueueRangeChecked;
    procedure TestResponseBytesRangeChecked;
    procedure TestDecodeLimitsRangeChecked;
    procedure TestHeaderListRangeChecked;
    procedure TestSseLimitsRangeChecked;
    procedure TestProblemsReportsEachFault;
    procedure TestFactoryBuildRejectsBadValue;
    procedure TestFactoryWrappersReachClient;
  end;

implementation

procedure TClientSecurityOptionsTest.TestDefaultsMatchTable;
var
  O: TClientSecurityOptions;
begin
  O := TClientSecurityOptions.Default;
  AssertTrue('redirect policy', O.RedirectPolicy = rpAnyHost);
  AssertEquals('receive queue', Int64(1048576), O.MaxReceiveQueueBytes);
  AssertEquals('response bytes', Int64(0), O.MaxResponseBytes);
  AssertEquals('decoded bytes', Int64(0), O.MaxDecodedResponseBytes);
  AssertEquals('decode ratio', 1000, O.MaxDecodeRatio);
  AssertEquals('header list', 131072, O.MaxHeaderListSize);
  AssertEquals('sse line', 33554432, O.SseMaxLineBytes);
  AssertEquals('sse event', 67108864, O.SseMaxEventBytes);
  AssertEquals('sse idle', 600000, O.SseMaxIdleTimeMs);
  AssertEquals('sse retry', 600000, O.SseMaxRetryMs);
end;

procedure TClientSecurityOptionsTest.TestDefaultProblemsIsEmpty;
begin
  AssertEquals('', TClientSecurityOptions.Default.Problems);
end;

procedure TClientSecurityOptionsTest.TestWithMethodsReturnChangedCopy;
var
  O, Base: TClientSecurityOptions;
begin
  Base := TClientSecurityOptions.Default;
  O := Base.WithRedirectPolicy(rpSameOriginUpgrade)
    .WithMaxReceiveQueueBytes(65536)
    .WithMaxResponseBytes(1024)
    .WithMaxDecodedResponseBytes(2048)
    .WithMaxDecodeRatio(0)
    .WithMaxHeaderListSize(2048)
    .WithSseMaxLineBytes(0)
    .WithSseMaxEventBytes(4096)
    .WithSseMaxIdleTimeMs(0)
    .WithSseMaxRetryMs(250);
  AssertTrue('redirect policy', O.RedirectPolicy = rpSameOriginUpgrade);
  AssertEquals('receive queue', Int64(65536), O.MaxReceiveQueueBytes);
  AssertEquals('response bytes', Int64(1024), O.MaxResponseBytes);
  AssertEquals('decoded bytes', Int64(2048), O.MaxDecodedResponseBytes);
  AssertEquals('decode ratio', 0, O.MaxDecodeRatio);
  AssertEquals('header list', 2048, O.MaxHeaderListSize);
  AssertEquals('sse line', 0, O.SseMaxLineBytes);
  AssertEquals('sse event', 4096, O.SseMaxEventBytes);
  AssertEquals('sse idle', 0, O.SseMaxIdleTimeMs);
  AssertEquals('sse retry', 250, O.SseMaxRetryMs);
  AssertEquals('problems', '', O.Problems);
  // the receiver of the With call is not changed
  AssertTrue('base redirect policy', Base.RedirectPolicy = rpAnyHost);
  AssertEquals('base receive queue', Int64(1048576), Base.MaxReceiveQueueBytes);
end;

procedure TClientSecurityOptionsTest.TestRedirectPolicyRoundTrip;
var
  Policy: TRedirectPolicy;
  O: TClientSecurityOptions;
begin
  for Policy := Low(TRedirectPolicy) to High(TRedirectPolicy) do
  begin
    O := TClientSecurityOptions.Default.WithRedirectPolicy(Policy);
    AssertTrue('policy kept', O.RedirectPolicy = Policy);
    AssertEquals('policy has no problem', '', O.Problems);
  end;
end;

procedure TClientSecurityOptionsTest.TestReceiveQueueRangeChecked;
var
  O: TClientSecurityOptions;
begin
  O := TClientSecurityOptions.Default.WithMaxReceiveQueueBytes(16383);
  AssertTrue('below 16 KiB', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithMaxReceiveQueueBytes(16384);
  AssertEquals('16 KiB is valid', '', O.Problems);
  O := TClientSecurityOptions.Default.WithMaxReceiveQueueBytes(1073741824);
  AssertEquals('1 GiB is valid', '', O.Problems);
  O := TClientSecurityOptions.Default.WithMaxReceiveQueueBytes(1073741825);
  AssertTrue('above 1 GiB', O.Problems <> '');
end;

procedure TClientSecurityOptionsTest.TestResponseBytesRangeChecked;
var
  O: TClientSecurityOptions;
begin
  O := TClientSecurityOptions.Default.WithMaxResponseBytes(-1);
  AssertTrue('negative response cap', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithMaxResponseBytes(0);
  AssertEquals('zero is unlimited', '', O.Problems);
  O := TClientSecurityOptions.Default.WithMaxDecodedResponseBytes(-1);
  AssertTrue('negative decoded cap', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithMaxDecodedResponseBytes(0);
  AssertEquals('zero is unlimited', '', O.Problems);
end;

procedure TClientSecurityOptionsTest.TestDecodeLimitsRangeChecked;
var
  O: TClientSecurityOptions;
begin
  O := TClientSecurityOptions.Default.WithMaxDecodeRatio(-1);
  AssertTrue('negative ratio', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithMaxDecodeRatio(0);
  AssertEquals('zero is off', '', O.Problems);
end;

procedure TClientSecurityOptionsTest.TestHeaderListRangeChecked;
var
  O: TClientSecurityOptions;
begin
  O := TClientSecurityOptions.Default.WithMaxHeaderListSize(1023);
  AssertTrue('below 1 KiB', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithMaxHeaderListSize(1024);
  AssertEquals('1 KiB is valid', '', O.Problems);
  O := TClientSecurityOptions.Default.WithMaxHeaderListSize(16777216);
  AssertEquals('16 MiB is valid', '', O.Problems);
  O := TClientSecurityOptions.Default.WithMaxHeaderListSize(16777217);
  AssertTrue('above 16 MiB', O.Problems <> '');
end;

procedure TClientSecurityOptionsTest.TestSseLimitsRangeChecked;
var
  O: TClientSecurityOptions;
begin
  O := TClientSecurityOptions.Default.WithSseMaxLineBytes(1023);
  AssertTrue('line below 1 KiB', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithSseMaxLineBytes(0);
  AssertEquals('line 0 is no cap', '', O.Problems);
  O := TClientSecurityOptions.Default.WithSseMaxLineBytes(1073741825);
  AssertTrue('line above 1 GiB', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithSseMaxEventBytes(1023);
  AssertTrue('event below 1 KiB', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithSseMaxEventBytes(0);
  AssertEquals('event 0 is no cap', '', O.Problems);
  O := TClientSecurityOptions.Default.WithSseMaxEventBytes(1073741825);
  AssertTrue('event above 1 GiB', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithSseMaxIdleTimeMs(-1);
  AssertTrue('negative idle time', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithSseMaxIdleTimeMs(0);
  AssertEquals('idle 0 is off', '', O.Problems);
  O := TClientSecurityOptions.Default.WithSseMaxRetryMs(0);
  AssertTrue('retry 0', O.Problems <> '');
  O := TClientSecurityOptions.Default.WithSseMaxRetryMs(1);
  AssertEquals('retry 1 is valid', '', O.Problems);
end;

procedure TClientSecurityOptionsTest.TestProblemsReportsEachFault;
var
  O: TClientSecurityOptions;
  P: string;
begin
  O := TClientSecurityOptions.Default.WithMaxResponseBytes(-1)
    .WithSseMaxRetryMs(0);
  P := O.Problems;
  AssertTrue('names the response cap', Pos('MaxResponseBytes', P) > 0);
  AssertTrue('names the retry time', Pos('SseMaxRetryMs', P) > 0);
end;

procedure TClientSecurityOptionsTest.TestFactoryBuildRejectsBadValue;
var
  Factory: THttpClientFactory;
  Raised: Boolean;
begin
  Factory := THttpClientFactory.Create.WithSseMaxRetryMs(0);
  Raised := False;
  try
    Factory.Build;
  except
    on E: EHttpError do
      Raised := True;
  end;
  AssertTrue('Build raises for an invalid security option', Raised);
end;

procedure TClientSecurityOptionsTest.TestFactoryWrappersReachClient;
var
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Opts: IHttpClientOptions;
begin
  Factory := THttpClientFactory.Create
    .WithRedirectPolicy(rpSameHostOnly)
    .WithMaxReceiveQueueBytes(32768)
    .WithSseMaxRetryMs(5000);
  Client := Factory.Build;
  AssertTrue('client exposes the options', Supports(Client, IHttpClientOptions, Opts));
  AssertTrue('redirect policy', Opts.Options.RedirectPolicy = rpSameHostOnly);
  AssertEquals('receive queue', Int64(32768), Opts.Options.MaxReceiveQueueBytes);
  AssertEquals('sse retry', 5000, Opts.Options.SseMaxRetryMs);
  AssertEquals('pool receives the options', Int64(32768),
    (Client as THttpClient).Pool.Security.MaxReceiveQueueBytes);
end;

initialization
  RegisterTest(TClientSecurityOptionsTest);
end.
