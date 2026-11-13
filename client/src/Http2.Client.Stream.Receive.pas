{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, receive queue, flow control
notes:
  - This unit holds the receive queue of one stream. Its byte cap bounds the DATA that a stream holds.
  - Push never blocks. A push that passes the cap raises EHttpStreamError with ecFlowControlError.
---
}
unit Http2.Client.Stream.Receive;

{$mode delphi}{$H+}

interface

uses
  SysUtils, SyncObjs, Http2.Common.Frames, Http2.Common.Errors,
  Http2.Client.Connection.Queue;

type
  /// a blocking queue of received frames with a byte cap on the DATA it holds
  // - the byte count is the sum of DataLength of the DATA frames in the queue
  // - the other frame types never count against the cap
  TByteBoundedFrameQueue = class
  private
    FLock: TCriticalSection;
    FItems: TBlockingQueueState<TFrame>;
    FMaxBytes: Int64;
    FQueuedBytes: Int64;
  public
    constructor Create(const AMaxBytes: Int64);
    destructor Destroy; override;
    /// add a frame; raises EHttpStreamError when the DATA would pass MaxBytes
    // - a frame pushed after Shutdown is dropped without a raise
    procedure Push(const AItem: TFrame);
    /// return a frame only if one is already queued (never blocks)
    function TryPop(out AItem: TFrame): Boolean;
    /// block until a frame is queued, the queue shuts down or the time runs out
    function WaitForItem(const ATimeoutMs: Integer): Boolean;
    /// wake every blocked waiter; a later Push is dropped
    procedure Shutdown;
    function IsShutdown: Boolean;
    /// the sum of DataLength of the DATA frames in the queue
    property QueuedBytes: Int64 read FQueuedBytes;
    property MaxBytes: Int64 read FMaxBytes;
  end;

implementation

{ TByteBoundedFrameQueue }

constructor TByteBoundedFrameQueue.Create(const AMaxBytes: Int64);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  // capacity 0: the queue never blocks a push, the byte cap does the bounding
  FItems := TBlockingQueueState<TFrame>.Create(0);
  FMaxBytes := AMaxBytes;
  FQueuedBytes := 0;
end;

destructor TByteBoundedFrameQueue.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TByteBoundedFrameQueue.Push(const AItem: TFrame);
var
  Size: Int64;
begin
  if AItem.Header.FrameType = ftData then
    Size := Int64(AItem.DataLength)
  else
    Size := 0;
  FLock.Acquire;
  try
    if FItems.IsShutdown then
      Exit;
    if FQueuedBytes + Size > FMaxBytes then
      raise EHttpStreamError.Create('receive queue of the stream is full',
        0, ecFlowControlError);
    FItems.Push(AItem);
    Inc(FQueuedBytes, Size);
  finally
    FLock.Release;
  end;
end;

function TByteBoundedFrameQueue.TryPop(out AItem: TFrame): Boolean;
var
  Size: Int64;
begin
  FLock.Acquire;
  try
    Result := FItems.TryPop(AItem);
    if Result then
    begin
      if AItem.Header.FrameType = ftData then
        Size := Int64(AItem.DataLength)
      else
        Size := 0;
      Dec(FQueuedBytes, Size);
    end;
  finally
    FLock.Release;
  end;
end;

function TByteBoundedFrameQueue.WaitForItem(const ATimeoutMs: Integer): Boolean;
begin
  Result := FItems.WaitForItem(ATimeoutMs);
end;

procedure TByteBoundedFrameQueue.Shutdown;
begin
  FItems.Shutdown;
end;

function TByteBoundedFrameQueue.IsShutdown: Boolean;
begin
  Result := FItems.IsShutdown;
end;

end.
