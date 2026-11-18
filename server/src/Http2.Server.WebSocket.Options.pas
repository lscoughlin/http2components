{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, options, limits, timers, origin policy, subprotocol
notes:
  - This unit holds the record TWsOptions of the server builder. Every default
    lives in Create. The record holds the message and frame limits, the queue cap
    of a session, the timers, the two token buckets, the origin policy and the
    subprotocols that the server accepts.
  - The limits protect the server. The ceilings are the choices of the project and
    are not taken from an RFC, which sets none for a server.
---
}
/// The settings of the WebSocket part of the server
unit Http2.Server.WebSocket.Options;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Http2.Server.Limits, Http2.Server.WebSocket.Origin;

type
  /// the settings of the WebSocket part of the server
  TWsOptions = record
  private
    FMaxMessageSize: Int64;
    FMaxFrameSize: Int64;
    FMaxFragments: Integer;
    FQueuedMessages: Integer;
    FFrameSize: Integer;
    FPingIntervalMs: Integer;
    FPongTimeoutMs: Integer;
    FCloseTimeoutMs: Integer;
    FInitTimeoutMs: Integer;
    FControlBucket: TTokenBucketOptions;
    FMessageBucket: TTokenBucketOptions;
    FOriginPolicy: TWsOriginPolicy;
    FAllowedOrigins: TArray<string>;
    FSubprotocols: TArray<string>;
    FWsEarlyBytes: Integer;
    FWsAllowedHosts: TArray<string>;
    FInlineLimit: Integer;
    FInboundPipeBytes: Integer;
    FInboundStallMs: Integer;
  public
    /// the defaults
    class function Create: TWsOptions; static;
    /// the greatest message, summed over its fragments, in octets that the server
    // receives; for a message that SendStream sends it is the greatest chunk
    function WithMaxMessageSize(const AValue: Int64): TWsOptions;
    /// the greatest payload of one frame that the server accepts, in octets
    function WithMaxFrameSize(const AValue: Int64): TWsOptions;
    /// the greatest number of frames of one message
    function WithMaxFragments(const AValue: Integer): TWsOptions;
    /// the greatest number of messages that wait for the application
    function WithQueuedMessages(const AValue: Integer): TWsOptions;
    /// the payload size of the frames that the server sends
    function WithFrameSize(const AValue: Integer): TWsOptions;
    /// the idle time after which the server sends a Ping; 0 turns the Ping off
    function WithPingIntervalMs(const AValue: Integer): TWsOptions;
    /// the wait for the Pong
    function WithPongTimeoutMs(const AValue: Integer): TWsOptions;
    /// the wait for the Close frame of the peer after ours
    function WithCloseTimeoutMs(const AValue: Integer): TWsOptions;
    /// the wait for IWsHandler.Init
    function WithInitTimeoutMs(const AValue: Integer): TWsOptions;
    /// the bucket of the Ping and Pong frames that arrive
    function WithControlBucket(const AValue: TTokenBucketOptions): TWsOptions;
    /// the bucket of the data messages that arrive
    function WithMessageBucket(const AValue: TTokenBucketOptions): TWsOptions;
    function WithOriginPolicy(const AValue: TWsOriginPolicy): TWsOptions;
    /// the origins of the allow-list, each as scheme://host[:port]
    function WithAllowedOrigins(const AValue: TArray<string>): TWsOptions;
    /// the subprotocols that the server picks from, in order of preference
    function WithSubprotocols(const AValue: TArray<string>): TWsOptions;
    /// the octets of a message that the server holds before the handler runs;
    /// valid from 4096 to 16777216
    function WithWsEarlyBytes(const AValue: Integer): TWsOptions;
    /// the host names that the allow-list accepts; an empty list turns the
    /// host check off
    function WithWsAllowedHosts(const AValue: TArray<string>): TWsOptions;
    /// the octets of a message that the server keeps in memory before it gives the
    /// message to the handler; a message that ends inside the limit goes to the handler
    /// whole, and a longer message goes to the handler at once and streams
    function WithInlineLimit(const AValue: Integer): TWsOptions;
    /// the octets of a streamed message that wait for the handler, at most; a push over
    /// the limit closes the session with 1009
    function WithInboundPipeBytes(const AValue: Integer): TWsOptions;
    /// the time that a read of a streamed message waits for an octet; on expiry the
    /// session closes with 1008
    function WithInboundStallMs(const AValue: Integer): TWsOptions;

    /// add one text to AProblems for each setting that is not usable
    procedure Problems(var AProblems: TArray<string>);

    property MaxMessageSize: Int64 read FMaxMessageSize;
    property MaxFrameSize: Int64 read FMaxFrameSize;
    property MaxFragments: Integer read FMaxFragments;
    property QueuedMessages: Integer read FQueuedMessages;
    property FrameSize: Integer read FFrameSize;
    property PingIntervalMs: Integer read FPingIntervalMs;
    property PongTimeoutMs: Integer read FPongTimeoutMs;
    property CloseTimeoutMs: Integer read FCloseTimeoutMs;
    property InitTimeoutMs: Integer read FInitTimeoutMs;
    property ControlBucket: TTokenBucketOptions read FControlBucket;
    property MessageBucket: TTokenBucketOptions read FMessageBucket;
    property OriginPolicy: TWsOriginPolicy read FOriginPolicy;
    property AllowedOrigins: TArray<string> read FAllowedOrigins;
    property Subprotocols: TArray<string> read FSubprotocols;
    property WsEarlyBytes: Integer read FWsEarlyBytes;
    property WsAllowedHosts: TArray<string> read FWsAllowedHosts;
    property InlineLimit: Integer read FInlineLimit;
    property InboundPipeBytes: Integer read FInboundPipeBytes;
    property InboundStallMs: Integer read FInboundStallMs;
  end;

implementation

class function TWsOptions.Create: TWsOptions;
begin
  Result.FMaxMessageSize := 1048576;
  Result.FMaxFrameSize := 65536;
  Result.FMaxFragments := 1024;
  Result.FQueuedMessages := 16;
  Result.FFrameSize := 16384;
  Result.FPingIntervalMs := 30000;
  Result.FPongTimeoutMs := 10000;
  Result.FCloseTimeoutMs := 5000;
  Result.FInitTimeoutMs := 10000;
  // a Ping or a Pong is cheap, and a client has no reason to send many
  Result.FControlBucket := TTokenBucketOptions.Create
    .WithCapacity(100)
    .WithRefillPerSecond(10);
  // a chat client can send many short messages, so the message bucket is large
  Result.FMessageBucket := TTokenBucketOptions.Create
    .WithCapacity(10000)
    .WithRefillPerSecond(10000);
  Result.FOriginPolicy := opSameOrAbsent;
  Result.FAllowedOrigins := nil;
  Result.FSubprotocols := nil;
  Result.FWsEarlyBytes := 262144;
  Result.FWsAllowedHosts := nil;
  Result.FInlineLimit := 65536;
  Result.FInboundPipeBytes := 1048576;
  Result.FInboundStallMs := 30000;
end;

function TWsOptions.WithMaxMessageSize(const AValue: Int64): TWsOptions;
begin
  Result := Self;
  Result.FMaxMessageSize := AValue;
end;

function TWsOptions.WithMaxFrameSize(const AValue: Int64): TWsOptions;
begin
  Result := Self;
  Result.FMaxFrameSize := AValue;
end;

function TWsOptions.WithMaxFragments(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FMaxFragments := AValue;
end;

function TWsOptions.WithQueuedMessages(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FQueuedMessages := AValue;
end;

function TWsOptions.WithFrameSize(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FFrameSize := AValue;
end;

function TWsOptions.WithPingIntervalMs(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FPingIntervalMs := AValue;
end;

function TWsOptions.WithPongTimeoutMs(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FPongTimeoutMs := AValue;
end;

function TWsOptions.WithCloseTimeoutMs(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FCloseTimeoutMs := AValue;
end;

function TWsOptions.WithInitTimeoutMs(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FInitTimeoutMs := AValue;
end;

function TWsOptions.WithControlBucket(const AValue: TTokenBucketOptions): TWsOptions;
begin
  Result := Self;
  Result.FControlBucket := AValue;
end;

function TWsOptions.WithMessageBucket(const AValue: TTokenBucketOptions): TWsOptions;
begin
  Result := Self;
  Result.FMessageBucket := AValue;
end;

function TWsOptions.WithOriginPolicy(const AValue: TWsOriginPolicy): TWsOptions;
begin
  Result := Self;
  Result.FOriginPolicy := AValue;
end;

function TWsOptions.WithAllowedOrigins(const AValue: TArray<string>): TWsOptions;
begin
  Result := Self;
  Result.FAllowedOrigins := Copy(AValue);
end;

function TWsOptions.WithSubprotocols(const AValue: TArray<string>): TWsOptions;
begin
  Result := Self;
  Result.FSubprotocols := Copy(AValue);
end;

function TWsOptions.WithWsEarlyBytes(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FWsEarlyBytes := AValue;
end;

function TWsOptions.WithWsAllowedHosts(const AValue: TArray<string>): TWsOptions;
begin
  Result := Self;
  Result.FWsAllowedHosts := Copy(AValue);
end;

function TWsOptions.WithInlineLimit(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FInlineLimit := AValue;
end;

function TWsOptions.WithInboundPipeBytes(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FInboundPipeBytes := AValue;
end;

function TWsOptions.WithInboundStallMs(const AValue: Integer): TWsOptions;
begin
  Result := Self;
  Result.FInboundStallMs := AValue;
end;

procedure TWsOptions.Problems(var AProblems: TArray<string>);
var
  I, J: Integer;
  Origin: TWsOrigin;

  procedure Add(const AText: string);
  begin
    SetLength(AProblems, Length(AProblems) + 1);
    AProblems[High(AProblems)] := AText;
  end;

begin
  if FMaxMessageSize < 1 then
    Add('the WebSocket message size limit is below 1');
  if FMaxFrameSize < 1 then
    Add('the WebSocket frame size limit is below 1');
  // the message is built in memory with a 32-bit length
  if FMaxMessageSize > MaxInt then
    Add('the WebSocket message size limit is above 2147483647');
  if (FMaxMessageSize >= 1) and (FMaxFrameSize > FMaxMessageSize) then
    Add('the WebSocket frame size limit is above the message size limit');
  if FMaxFragments < 1 then
    Add('the WebSocket fragment limit is below 1');
  if FQueuedMessages < 1 then
    Add('the WebSocket queued message limit is below 1');
  if FFrameSize < 1 then
    Add('the WebSocket send frame size is below 1');
  if FPingIntervalMs < 0 then
    Add('the WebSocket ping interval is below 0');
  if (FPingIntervalMs > 0) and (FPongTimeoutMs < 1) then
    Add('the WebSocket pong timeout is below 1 while the ping is on');
  if FCloseTimeoutMs < 1 then
    Add('the WebSocket close timeout is below 1');
  if FInitTimeoutMs < 1 then
    Add('the WebSocket init timeout is below 1');
  if FControlBucket.Capacity < 1 then
    Add('the WebSocket control bucket capacity is below 1');
  if FMessageBucket.Capacity < 1 then
    Add('the WebSocket message bucket capacity is below 1');
  for I := 0 to High(FAllowedOrigins) do
    if not WsParseOrigin(FAllowedOrigins[I], Origin) then
      Add('the WebSocket allowed origin "' + FAllowedOrigins[I] + '" is not scheme://host[:port]');
  if (FWsEarlyBytes < 4096) or (FWsEarlyBytes > 16777216) then
    Add('the WebSocket early bytes is outside the range 4096 to 16777216');
  if (FInlineLimit < 1) or (FInlineLimit > 16777216) then
    Add('the WebSocket inline limit is outside the range 1 to 16777216');
  if FInboundPipeBytes < 1 then
    Add('the WebSocket inbound pipe size is below 1');
  // the octets that the reader kept move into the pipe when a message streams
  if (FInlineLimit >= 1) and (FInboundPipeBytes >= 1) and (FInlineLimit > FInboundPipeBytes) then
    Add('the WebSocket inline limit is above the inbound pipe size');
  if FInboundStallMs < 1 then
    Add('the WebSocket inbound stall time is below 1');
  if (FOriginPolicy = opAllowListOnly) and (Length(FAllowedOrigins) = 0) then
    Add('the origin policy allow-list only needs at least one allowed origin');
  for I := 0 to High(FSubprotocols) do
  begin
    if FSubprotocols[I] = '' then
      Add('a WebSocket subprotocol is empty');
    for J := 1 to Length(FSubprotocols[I]) do
      if (FSubprotocols[I][J] <= ' ') or (FSubprotocols[I][J] >= #127) or
         (FSubprotocols[I][J] in ['(', ')', '<', '>', '@', ',', ';', ':', '\', '"', '/', '[', ']', '?', '=', '{', '}']) then
      begin
        Add('the WebSocket subprotocol "' + FSubprotocols[I] + '" is not a token');
        Break;
      end;
  end;
end;

end.
