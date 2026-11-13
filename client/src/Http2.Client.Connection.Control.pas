{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, connection, control, rate_limit
notes:
  - This unit holds the control frame queue and the token buckets of the client reader.
  - The control queue never blocks the reader. A full queue is a connection error.
---
}
unit Http2.Client.Connection.Control;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Generics.Collections, Http2.Common.Frames,
  Http2.Common.Hpack;

const
  /// the most control frames that wait for the writer (as the server OutboundBudget)
  cControlQueueLimit = 1000;
  /// the burst and the refill of the peer PING frames the reader accepts
  cPingBurst = 100;
  cPingRefillPerSecond = 10;
  /// the burst and the refill of the peer SETTINGS frames the reader accepts
  cSettingsBurst = 100;
  cSettingsRefillPerSecond = 10;
  /// the burst and the refill of the peer RST_STREAM frames the reader accepts
  cRstStreamBurst = 1000;
  cRstStreamRefillPerSecond = 100;

type
  /// a bounded queue of control frames. TryPost never blocks.
  // - the writer drains it before the data queue
  TControlFrameQueue = class
  private
    FLock: TCriticalSection;
    FItems: TQueue<TFrame>;
    FOverflowed: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    /// queue AFrame; False when cControlQueueLimit frames already wait
    function TryPost(const AFrame: TFrame): Boolean;
    /// take the oldest frame, if any (never blocks)
    function TryPop(out AFrame: TFrame): Boolean;
    /// frames currently waiting
    function Count: Integer;
    /// True after TryPost has refused a frame (sticky)
    function Overflowed: Boolean;
  end;

  /// a token bucket with a clock passed in by the caller
  // - a take costs ACost tokens; the bucket holds at most Capacity tokens
  // - the bucket starts full
  TTokenBucket = record
  private
    FCapacity: Integer;
    FRefillPerSecond: Integer;
    /// tokens times 1000, so that a refill in whole milliseconds is exact
    FMilliTokens: Int64;
    FLastMs: Int64;
  public
    procedure Init(const ACapacity, ARefillPerSecond: Integer; const ANowMs: Int64);
    /// take ACost tokens at time ANowMs (milliseconds); False when too few tokens
    function TryTake(const ACost: Integer; const ANowMs: Int64): Boolean;
  end;

  /// the token buckets that limit the frames a peer sends to the reader
  // - a PING or SETTINGS acknowledgement is never limited
  TPeerRateLimits = record
  private
    FPing: TTokenBucket;
    FSettings: TTokenBucket;
    FRstStream: TTokenBucket;
  public
    procedure Init(const ANowMs: Int64);
    /// False when AFrame is over the rate limit of its type at time ANowMs
    function Allow(const AFrame: TFrame; const ANowMs: Int64): Boolean;
  end;

  /// the SETTINGS_HEADER_TABLE_SIZE of the peer, on its way to the header encoder
  // - the reader never waits for the encoder lock: it leaves the value here
  //   when the lock is busy, and the thread that holds the lock applies it
  //   before the next header block
  THeaderTableHandoff = class
  private
    FLock: TCriticalSection;
    FPending: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    /// record AValue as the size that the encoder has not applied yet
    procedure Defer(const AValue: LongWord);
    /// apply the recorded size, if any, to AEncoder (nil: drop it); the caller holds the encoder lock
    procedure Apply(const AEncoder: THpackCodec);
  end;

implementation

{ TControlFrameQueue }

constructor TControlFrameQueue.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TQueue<TFrame>.Create;
  FOverflowed := False;
end;

destructor TControlFrameQueue.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

function TControlFrameQueue.TryPost(const AFrame: TFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FItems.Count < cControlQueueLimit;
    if Result then
      FItems.Enqueue(AFrame)
    else
      FOverflowed := True;
  finally
    FLock.Release;
  end;
end;

function TControlFrameQueue.TryPop(out AFrame: TFrame): Boolean;
begin
  FLock.Acquire;
  try
    Result := FItems.Count > 0;
    if Result then
      AFrame := FItems.Dequeue;
  finally
    FLock.Release;
  end;
end;

function TControlFrameQueue.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FItems.Count;
  finally
    FLock.Release;
  end;
end;

function TControlFrameQueue.Overflowed: Boolean;
begin
  FLock.Acquire;
  try
    Result := FOverflowed;
  finally
    FLock.Release;
  end;
end;

{ THeaderTableHandoff }

constructor THeaderTableHandoff.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FPending := -1;
end;

destructor THeaderTableHandoff.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure THeaderTableHandoff.Defer(const AValue: LongWord);
begin
  FLock.Acquire;
  try
    FPending := AValue;
  finally
    FLock.Release;
  end;
end;

procedure THeaderTableHandoff.Apply(const AEncoder: THpackCodec);
var
  Value: Int64;
begin
  FLock.Acquire;
  try
    Value := FPending;
    FPending := -1;
  finally
    FLock.Release;
  end;
  if (Value >= 0) and (AEncoder <> nil) then
    AEncoder.SetPeerTableSize(LongWord(Value));
end;

{ TTokenBucket }

procedure TTokenBucket.Init(const ACapacity, ARefillPerSecond: Integer;
  const ANowMs: Int64);
begin
  FCapacity := ACapacity;
  FRefillPerSecond := ARefillPerSecond;
  FMilliTokens := Int64(ACapacity) * 1000;
  FLastMs := ANowMs;
end;

function TTokenBucket.TryTake(const ACost: Integer;
  const ANowMs: Int64): Boolean;
var
  Cost, Full: Int64;
begin
  // a refill of R tokens a second is R milli-tokens a millisecond
  if ANowMs > FLastMs then
  begin
    Inc(FMilliTokens, (ANowMs - FLastMs) * FRefillPerSecond);
    Full := Int64(FCapacity) * 1000;
    if FMilliTokens > Full then
      FMilliTokens := Full;
    FLastMs := ANowMs;
  end;
  Cost := Int64(ACost) * 1000;
  Result := FMilliTokens >= Cost;
  if Result then
    Dec(FMilliTokens, Cost);
end;

{ TPeerRateLimits }

procedure TPeerRateLimits.Init(const ANowMs: Int64);
begin
  FPing.Init(cPingBurst, cPingRefillPerSecond, ANowMs);
  FSettings.Init(cSettingsBurst, cSettingsRefillPerSecond, ANowMs);
  FRstStream.Init(cRstStreamBurst, cRstStreamRefillPerSecond, ANowMs);
end;

function TPeerRateLimits.Allow(const AFrame: TFrame;
  const ANowMs: Int64): Boolean;
begin
  Result := True;
  case AFrame.Header.FrameType of
    ftPing:
      if not AFrame.IsAck then
        Result := FPing.TryTake(1, ANowMs);
    ftSettings:
      if not AFrame.IsAck then
        Result := FSettings.TryTake(1, ANowMs);
    ftRstStream:
      Result := FRstStream.TryTake(1, ANowMs);
  end;
end;

end.
