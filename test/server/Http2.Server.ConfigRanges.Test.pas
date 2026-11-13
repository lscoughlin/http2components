{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: configuration, validate, ranges, host, backlog
notes:
  - These tests hold the range checks of Validate and the effect of Host and
    Backlog.
  - Validate lists every problem in one call. A queue depth of 0 stays valid.
---
}
unit Http2.Server.ConfigRanges.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2.Server, Http2.Server.Config, Http2.Server.Async.Options, Http2.Server.Async,
  Http2.Server.Runtime.Test, Http2.Server.Http1.RawClient;

type
  TConfigRangesTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function Base: THttp2ServerFactory;
    function Rejects(const AFactory: THttp2ServerFactory;
      const AWord: string): Boolean;
  protected
    procedure SetUp; override;
  published
    procedure TestNegativeTimeoutsAreRejected;
    procedure TestNegativeLifetimeIsRejected;
    procedure TestZeroAndPositiveLifetimeIsAccepted;
    procedure TestBothLifetimeProblemsComeInOneCall;
    procedure TestBucketWithoutCapacityIsRejected;
    procedure TestZeroWindowsAreRejected;
    procedure TestZeroStreamLimitIsRejected;
    procedure TestHeaderTableAbove2To31IsRejected;
    procedure TestQueueDepthZeroStaysValid;
    procedure TestAllProblemsComeInOneMessage;
    procedure TestBindAddressTextUsesTheHost;
    procedure TestListenerBindsTheHost;
    procedure TestMaxHandlerTimeRange;
    procedure TestMaxBodyBytesInFlightRange;
    procedure TestMaxWsQueuedBytesRange;
    procedure TestMaxWsSessionsRange;
    procedure TestWsEarlyBytesRange;
    procedure TestWsAllowedHostsDefaultsEmpty;
  end;

implementation

procedure TConfigRangesTest.SetUp;
begin
  FHandler := TTestHandler.Create;
end;

function TConfigRangesTest.Base: THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True);
end;

function TConfigRangesTest.Rejects(const AFactory: THttp2ServerFactory;
  const AWord: string): Boolean;
var
  Problems: TArray<string>;
  I: Integer;
begin
  Result := False;
  if AFactory.Validate(Problems) then
    Exit;
  for I := 0 to High(Problems) do
    if Pos(AWord, Problems[I]) > 0 then
      Exit(True);
end;

procedure TConfigRangesTest.TestNegativeTimeoutsAreRejected;
begin
  AssertTrue('idle', Rejects(Base.WithIdleTimeout(-1), 'idle timeout'));
  AssertTrue('header', Rejects(Base.WithHeaderTimeout(-1), 'header timeout'));
  AssertTrue('graceful', Rejects(Base.WithGracefulStopTimeout(-1), 'graceful'));
end;

procedure TConfigRangesTest.TestNegativeLifetimeIsRejected;
begin
  AssertTrue('age', Rejects(Base.WithMaxConnectionAge(-1),
    'the maximum connection age is below 0'));
  AssertTrue('streams', Rejects(Base.WithMaxStreamsPerConnection(-1),
    'the maximum streams per connection is below 0'));
end;

procedure TConfigRangesTest.TestZeroAndPositiveLifetimeIsAccepted;
var
  Problems: TArray<string>;
begin
  AssertTrue('age 0', Base.WithMaxConnectionAge(0).Validate(Problems));
  AssertTrue('age positive',
    Base.WithMaxConnectionAge(60000).Validate(Problems));
  AssertTrue('streams 0',
    Base.WithMaxStreamsPerConnection(0).Validate(Problems));
  AssertTrue('streams positive',
    Base.WithMaxStreamsPerConnection(100).Validate(Problems));
end;

procedure TConfigRangesTest.TestBothLifetimeProblemsComeInOneCall;
var
  Problems: TArray<string>;
  Bad: THttp2ServerFactory;
begin
  Bad := Base.WithMaxConnectionAge(-1).WithMaxStreamsPerConnection(-1);
  AssertFalse('the bad factory fails validation', Bad.Validate(Problems));
  AssertTrue('both problems arrive at once: ' + IntToStr(Length(Problems)),
    Length(Problems) >= 2);
  AssertTrue('the age problem is in the list',
    Rejects(Bad, 'the maximum connection age is below 0'));
  AssertTrue('the stream problem is in the list',
    Rejects(Bad, 'the maximum streams per connection is below 0'));
end;

procedure TConfigRangesTest.TestBucketWithoutCapacityIsRejected;
begin
  AssertTrue(Rejects(Base.WithResetBucket(
    TTokenBucketOptions.Create.WithCapacity(0).WithRefillPerSecond(1)),
    'reset bucket'));
  AssertTrue(Rejects(Base.WithPingBucket(
    TTokenBucketOptions.Create.WithCapacity(0).WithRefillPerSecond(1)),
    'ping bucket'));
end;

procedure TConfigRangesTest.TestZeroWindowsAreRejected;
begin
  AssertTrue(Rejects(Base.WithInitialStreamWindow(0), 'initial stream window'));
  AssertTrue(Rejects(Base.WithInitialConnectionWindow(0),
    'initial connection window'));
end;

procedure TConfigRangesTest.TestZeroStreamLimitIsRejected;
begin
  AssertTrue(Rejects(Base.WithMaxConcurrentStreams(0), 'concurrent stream'));
end;

procedure TConfigRangesTest.TestHeaderTableAbove2To31IsRejected;
begin
  AssertTrue(Rejects(Base.WithHeaderTableSize(LongWord(2147483648)),
    'header table'));
  AssertFalse(Rejects(Base.WithHeaderTableSize(LongWord(2147483647)),
    'header table'));
end;

procedure TConfigRangesTest.TestQueueDepthZeroStaysValid;
var
  Problems: TArray<string>;
begin
  AssertTrue(Base.WithQueue(TQueueOptions.Create.WithDepth(0)).Validate(Problems));
end;

procedure TConfigRangesTest.TestAllProblemsComeInOneMessage;
var
  Problems: TArray<string>;
begin
  AssertFalse(Base.WithIdleTimeout(-1).WithMaxConcurrentStreams(0)
    .WithInitialStreamWindow(0).Validate(Problems));
  AssertTrue('three problems at least: ' + IntToStr(Length(Problems)),
    Length(Problems) >= 3);
end;

procedure TConfigRangesTest.TestBindAddressTextUsesTheHost;
begin
  AssertEquals('127.0.0.1:8080', string(BindAddressText('127.0.0.1', 8080)));
  AssertEquals('0.0.0.0:9', string(BindAddressText('', 9)));
  AssertEquals('::1:7', string(BindAddressText('::1', 7)));
end;

procedure TConfigRangesTest.TestListenerBindsTheHost;
var
  Server: THttp2AsyncServer;
  Addr: TNetAddr;
begin
  Server := THttp2AsyncServer.Create(Base.WithHost('127.0.0.1').WithPort(0));
  try
    Server.Start;
    AssertTrue('the socket has a name', Server.Server.Sock.GetName(Addr) = nrOk);
    AssertEquals('SRV-13: the listener holds the host of the factory',
      '127.0.0.1', string(Addr.IPShort));
  finally
    Server.Stop;
    Server.Free;
  end;
end;

procedure TConfigRangesTest.TestMaxHandlerTimeRange;
var
  Problems: TArray<string>;
begin
  AssertEquals('the default is off', 0, TServerLimits.Create.MaxHandlerTimeMs);
  AssertTrue('the default is valid', Base.Validate(Problems));
  AssertTrue('zero is valid', Base.WithServerLimits(
    TServerLimits.Create.WithMaxHandlerTimeMs(0)).Validate(Problems));
  AssertTrue('a positive value is valid', Base.WithServerLimits(
    TServerLimits.Create.WithMaxHandlerTimeMs(5000)).Validate(Problems));
  AssertTrue('a negative value is rejected', Rejects(Base.WithServerLimits(
    TServerLimits.Create.WithMaxHandlerTimeMs(-1)),
    'the maximum handler time is below 0'));
end;

procedure TConfigRangesTest.TestMaxBodyBytesInFlightRange;
var
  Problems: TArray<string>;
begin
  AssertEquals('the default is 256 MiB', Int64(268435456),
    TServerLimits.Create.MaxBodyBytesInFlight);
  AssertTrue('the default is valid', Base.Validate(Problems));
  AssertTrue('zero is valid', Base.WithServerLimits(
    TServerLimits.Create.WithMaxBodyBytesInFlight(0)).Validate(Problems));
  AssertTrue('1 MiB is valid', Base.WithServerLimits(
    TServerLimits.Create.WithMaxBodyBytesInFlight(1048576)).Validate(Problems));
  AssertTrue('below 1 MiB is rejected', Rejects(Base.WithServerLimits(
    TServerLimits.Create.WithMaxBodyBytesInFlight(1048575)),
    'the body bytes in flight limit is outside the range'));
end;

procedure TConfigRangesTest.TestMaxWsQueuedBytesRange;
var
  Problems: TArray<string>;
begin
  AssertEquals('the default is 128 MiB', Int64(134217728),
    TServerLimits.Create.MaxWsQueuedBytes);
  AssertTrue('the default is valid', Base.Validate(Problems));
  AssertTrue('1 MiB is valid', Base.WithServerLimits(
    TServerLimits.Create.WithMaxWsQueuedBytes(1048576)).Validate(Problems));
  AssertTrue('below 1 MiB is rejected', Rejects(Base.WithServerLimits(
    TServerLimits.Create.WithMaxWsQueuedBytes(1048575)),
    'the WebSocket queued bytes limit is below 1 MiB'));
end;

procedure TConfigRangesTest.TestMaxWsSessionsRange;
var
  Problems: TArray<string>;
begin
  AssertEquals('the default is 5000', 5000,
    TServerLimits.Create.MaxWsSessions);
  AssertTrue('the default is valid', Base.Validate(Problems));
  AssertTrue('zero is valid', Base.WithServerLimits(
    TServerLimits.Create.WithMaxWsSessions(0)).Validate(Problems));
  AssertTrue('a negative value is rejected', Rejects(Base.WithServerLimits(
    TServerLimits.Create.WithMaxWsSessions(-1)),
    'the WebSocket session limit is below 0'));
end;

procedure TConfigRangesTest.TestWsEarlyBytesRange;
var
  Problems: TArray<string>;
begin
  AssertEquals('the default is 256 KiB', 262144,
    TWsOptions.Create.WsEarlyBytes);
  AssertTrue('the default is valid', Base.Validate(Problems));
  AssertTrue('the minimum is valid', Base.WithWebSockets(
    TWsOptions.Create.WithWsEarlyBytes(4096)).Validate(Problems));
  AssertTrue('the maximum is valid', Base.WithWebSockets(
    TWsOptions.Create.WithWsEarlyBytes(16777216)).Validate(Problems));
  AssertTrue('below the minimum is rejected', Rejects(Base.WithWebSockets(
    TWsOptions.Create.WithWsEarlyBytes(4095)),
    'the WebSocket early bytes is outside the range'));
  AssertTrue('above the maximum is rejected', Rejects(Base.WithWebSockets(
    TWsOptions.Create.WithWsEarlyBytes(16777217)),
    'the WebSocket early bytes is outside the range'));
end;

procedure TConfigRangesTest.TestWsAllowedHostsDefaultsEmpty;
var
  Problems: TArray<string>;
begin
  AssertEquals('no host by default', 0,
    Length(TWsOptions.Create.WsAllowedHosts));
  AssertTrue('the default is valid', Base.Validate(Problems));
  AssertTrue('a host list is valid', Base.WithWebSockets(
    TWsOptions.Create.WithWsAllowedHosts(['example.com'])).Validate(Problems));
end;

initialization
  RegisterTest(TConfigRangesTest);

end.
