{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, rapid reset, configuration, bounds, window
notes:
  - These tests hold the gaps of story S-50. Each test shows a defect on the
    code before the fix.
  - The reset bucket has no cost check in Validate, so a cost of 0 disables
    the rapid-reset limit. The bounds of the header list, the header table,
    the CONTINUATION count and the stream limit are checked in Validate.
  - A refused stream and the other resets that the server sends for a fault
    of the peer charge the reset bucket.
  - An initial window of 1 must not make the server send a WINDOW_UPDATE with
    an increment of 0.
  - The tests drive the core in memory with the peer of Http2.Server.H2Peer.
---
}
/// Tests of the rapid-reset gaps and the configuration bounds of the server
unit Http2.Server.RapidResetGaps.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  Http2.Server, Http2.Server.Config, Http2.Server.Async.Options,
  Http2.Server.Limits, Http2.Server.Errors, Http2.Common.Frames,
  Http2.Server.H2Peer, Http2.Server.Http1.RawClient;

type
  /// tests of the reset bucket costs, the configuration bounds and the
  /// window of one octet
  TRapidResetGapTest = class(TTestCase)
  private
    FHandler: IHttp2Handler;
    function Base: THttp2ServerFactory;
    function Rejects(const AFactory: THttp2ServerFactory;
      const AWord: string): Boolean;
    function Accepts(const AFactory: THttp2ServerFactory): Boolean;
    function CountZeroWindowUpdates(const APeer: TH2Peer): Integer;
  protected
    procedure SetUp; override;
  published
    procedure TestResetBucketCostBeforeZeroIsRejected;
    procedure TestResetBucketCostAfterZeroIsRejected;
    procedure TestResetBucketCostsOfOneAreAccepted;
    procedure TestMaxHeaderListSizeBounds;
    procedure TestHeaderTableSizeBounds;
    procedure TestMaxContinuationFramesBounds;
    procedure TestMaxConcurrentStreamsBounds;
    procedure TestRefusedStreamFloodTripsResetBucket;
    procedure TestWindowOfOneSendsNoZeroIncrement;
  end;

implementation

{ TRapidResetGapTest }

procedure TRapidResetGapTest.SetUp;
begin
  inherited SetUp;
  FHandler := TTestHandler.Create;
end;

function TRapidResetGapTest.Base: THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithHandler(FHandler)
    .WithClearTextAllowed(True);
end;

function TRapidResetGapTest.Rejects(const AFactory: THttp2ServerFactory;
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

function TRapidResetGapTest.Accepts(
  const AFactory: THttp2ServerFactory): Boolean;
var
  Problems: TArray<string>;
begin
  Result := AFactory.Validate(Problems);
end;

function TRapidResetGapTest.CountZeroWindowUpdates(
  const APeer: TH2Peer): Integer;
var
  I: Integer;
  Entry: TPeerFrame;
begin
  Result := 0;
  for I := 0 to APeer.Received.Count - 1 do
  begin
    Entry := APeer.Received[I];
    if (Entry.Frame.Header.FrameType = ftWindowUpdate) and
       (ParseWindowUpdate(Entry.Frame) = 0) then
      Inc(Result);
  end;
end;

procedure TRapidResetGapTest.TestResetBucketCostBeforeZeroIsRejected;
var
  Bucket: TTokenBucketOptions;
begin
  AssertTrue('the base factory is valid', Accepts(Base));
  Bucket := TTokenBucketOptions.Create.WithCapacity(10).WithRefillPerSecond(1)
    .WithCostBeforeDispatch(0).WithCostAfterDispatch(5);
  AssertTrue('a reset cost before dispatch of 0 is refused',
    Rejects(Base.WithResetBucket(Bucket), 'reset bucket cost'));
end;

procedure TRapidResetGapTest.TestResetBucketCostAfterZeroIsRejected;
var
  Bucket: TTokenBucketOptions;
begin
  Bucket := TTokenBucketOptions.Create.WithCapacity(10).WithRefillPerSecond(1)
    .WithCostBeforeDispatch(1).WithCostAfterDispatch(0);
  AssertTrue('a reset cost after dispatch of 0 is refused',
    Rejects(Base.WithResetBucket(Bucket), 'reset bucket cost'));
end;

procedure TRapidResetGapTest.TestResetBucketCostsOfOneAreAccepted;
var
  Bucket: TTokenBucketOptions;
begin
  Bucket := TTokenBucketOptions.Create.WithCapacity(10).WithRefillPerSecond(1)
    .WithCostBeforeDispatch(1).WithCostAfterDispatch(1);
  AssertTrue('costs of 1 are accepted', Accepts(Base.WithResetBucket(Bucket)));
end;

procedure TRapidResetGapTest.TestMaxHeaderListSizeBounds;
begin
  AssertTrue('zero is refused',
    Rejects(Base.WithMaxHeaderListSize(0), 'maximum header list size'));
  AssertTrue('1023 is refused',
    Rejects(Base.WithMaxHeaderListSize(1023), 'maximum header list size'));
  AssertTrue('1024 is accepted', Accepts(Base.WithMaxHeaderListSize(1024)));
  AssertTrue('1073741823 is accepted',
    Accepts(Base.WithMaxHeaderListSize(1073741823)));
  AssertTrue('1073741824 is refused',
    Rejects(Base.WithMaxHeaderListSize(1073741824),
      'maximum header list size'));
end;

procedure TRapidResetGapTest.TestHeaderTableSizeBounds;
begin
  AssertTrue('16777216 is accepted',
    Accepts(Base.WithHeaderTableSize(16777216)));
  AssertTrue('16777217 is refused',
    Rejects(Base.WithHeaderTableSize(16777217), 'header table size'));
end;

procedure TRapidResetGapTest.TestMaxContinuationFramesBounds;
begin
  AssertTrue('zero is refused',
    Rejects(Base.WithMaxContinuationFrames(0), 'continuation frame'));
  AssertTrue('1 is accepted', Accepts(Base.WithMaxContinuationFrames(1)));
  AssertTrue('1024 is accepted', Accepts(Base.WithMaxContinuationFrames(1024)));
  AssertTrue('1025 is refused',
    Rejects(Base.WithMaxContinuationFrames(1025), 'continuation frame'));
end;

procedure TRapidResetGapTest.TestMaxConcurrentStreamsBounds;
begin
  AssertTrue('100000 is accepted',
    Accepts(Base.WithMaxConcurrentStreams(100000)));
  AssertTrue('100001 is refused',
    Rejects(Base.WithMaxConcurrentStreams(100001), 'concurrent stream'));
end;

procedure TRapidResetGapTest.TestRefusedStreamFloodTripsResetBucket;
var
  Options: TPeerOptions;
  Peer: TH2Peer;
  Code: THttp2ErrorCode;
  I: Integer;
begin
  // one open stream fills the limit of one stream, so each later HEADERS is
  // refused. Each refusal costs the after-dispatch cost 2 of the peer bucket,
  // so a bucket of 100 tokens trips after 50 refusals; 200 refusals are sent
  Options := TPeerOptions.Default;
  Options.Core.MaxConcurrentStreams := 1;
  Options.BucketCapacity := 100;
  Peer := TH2Peer.Create(Options);
  try
    Peer.SendPreface;
    Peer.SendSettings([], []);
    Peer.SendPostHead(1);
    for I := 0 to 199 do
      Peer.SendGet(LongWord(3 + I * 2));
    Peer.Pump;
    AssertTrue('the refusal flood ends in GOAWAY', Peer.GoAwayCode(Code));
    AssertEquals('the GOAWAY code is ENHANCE_YOUR_CALM',
      Integer(Ord(ecEnhanceYourCalm)), Integer(Ord(Code)));
  finally
    Peer.Free;
  end;
end;

procedure TRapidResetGapTest.TestWindowOfOneSendsNoZeroIncrement;
var
  Factory: THttp2ServerFactory;
  Options: TPeerOptions;
  Peer: TH2Peer;
  Code: THttp2ErrorCode;
begin
  // a window of 1 gives a threshold of 0 without the fix, so each flush sent
  // a WINDOW_UPDATE with an increment of 0, which is a PROTOCOL_ERROR
  Factory := Base.WithInitialStreamWindow(1).WithInitialConnectionWindow(1);
  Options := TPeerOptions.Default;
  Options.Core := BuildConnectionCoreOptions(Factory);
  Peer := TH2Peer.Create(Options);
  try
    Peer.SendPreface;
    Peer.SendSettings([], []);
    Peer.Pump;
    Peer.SendGet(1);
    Peer.Pump;
    Peer.SendPostHead(3);
    Peer.SendData(3, 1, True);
    Peer.Pump;
    AssertEquals('no WINDOW_UPDATE has an increment of 0', 0,
      CountZeroWindowUpdates(Peer));
    AssertFalse('the connection stays open', Peer.GoAwayCode(Code));
    AssertEquals('the peer saw no violation', 0, Peer.Violations.Count);
  finally
    Peer.Free;
  end;
end;

initialization
  RegisterTest(TRapidResetGapTest);

end.
