{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, stream, receive_queue
notes:
  - This unit owns the push of a routed frame into the receive queue of a stream.
  - An overflow of the queue is a stream error. The connection is not affected.
---
}
unit Http2.Client.Stream.Inbound;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors, Http2.Client.Connection,
  Http2.Client.Stream.Receive, Http2.Common.Frames;

/// Push AFrame into AInbound on the reader thread, then record the peer end
// state in the two flags. Returns False when the DATA passes the byte cap of
// the queue. In that case the frame is dropped, one RST_STREAM with
// FLOW_CONTROL_ERROR is posted, the two flags are set (the stream is over, and
// the reset is sent) and the sender of the upload is woken. The caller marks
// the lease failed and drops it from the connection.
function LeasePushInbound(const AConnection: TConnection;
  const AInbound: TByteBoundedFrameQueue; const AStreamId: LongWord;
  const AFrame: TFrame; const APeerDone, APeerReset: PLongInt): Boolean;

implementation

function LeasePushInbound(const AConnection: TConnection;
  const AInbound: TByteBoundedFrameQueue; const AStreamId: LongWord;
  const AFrame: TFrame; const APeerDone, APeerReset: PLongInt): Boolean;
begin
  try
    AInbound.Push(AFrame);
  except
    on E: EHttpStreamError do
    begin
      // The DATA already counted against the connection window: the reader
      // returned that credit (TrackReceivedData) before it routed the frame.
      InterlockedExchange(APeerReset^, 1);
      InterlockedExchange(APeerDone^, 1);
      AConnection.PostFrame(BuildRstStreamFrame(AStreamId, ecFlowControlError));
      AConnection.WakeSendCredit;
      Exit(False);
    end;
  end;
  // on the reader thread, before the consumer sees the frame: an upload parked
  // on flow-control credit would otherwise wait out its timeout and lose the
  // response that is already sitting in the queue
  if AFrame.Header.FrameType = ftRstStream then
    InterlockedExchange(APeerReset^, 1);
  if (AFrame.Header.FrameType = ftRstStream) or
     ((AFrame.Header.FrameType in [ftHeaders, ftData]) and AFrame.IsEndStream) then
  begin
    InterlockedExchange(APeerDone^, 1);
    AConnection.WakeSendCredit;
  end;
  Result := True;
end;

end.
