{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket_pump, body_producer, chunk sink
notes:
  - This unit holds the sink that runs an IBodyProducer for the pump of a streamed
    WebSocket message. The producer runs on one streaming pool thread, and the thread
    is not given back until the producer ends.
  - Each Chunk call encodes one fragment and writes it through the port of the pump.
    When the channel answers srFull the sink waits on the gate of the port. A drain,
    the end of the session and a timeout of cWsProducerWaitMs set the gate or end the
    wait. The sink then sends the same encoded fragment again. It never encodes it twice.
  - The wait holds no lock of the pump and no lock of the session.
  - The end of the session, and a channel that answers srClosed, make the sink raise
    EStreamCancelled, so the Write of the producer raises.
  - RFC 6455 section 5.4 defines the fragments. The first fragment has the message
    opcode, later fragments continue, and the last fragment has FIN.
---
}
/// The sink of a producer that writes one streamed WebSocket message
unit Http2.Server.WebSocket.Pump.Producer;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs,
  Http2.Common.Body, Http2.Common.Errors, Http2.Server.Duplex, Http2.Server.Errors,
  Http2.Server.WebSocket.Frames;

const
  /// the longest time that the sink waits for a wake before it sends the fragment again
  cWsProducerWaitMs = 250;

type
  /// what the sink needs from its pump
  // - the pump implements it; the calls are safe from the thread that runs the producer
  IWsProducerPort = interface
    ['{7E1F0C11-00F5-4A11-9C72-000000003401}']
    /// write one encoded fragment; srClosed when the pump has ended or the host answers it
    function Write(const AWire: TBytes; const AFin: Boolean): TSendResult;
    /// the channel took a fragment with APayload octets of payload
    procedure Count(const APayload: Integer);
    /// the session ended or the pump stopped
    function Ended: Boolean;
    /// the event that a drain, a Stop and a timer signal set
    function Gate: TEvent;
  end;

/// run AProducer on the calling thread and write its chunks as fragments of one message
// - True: the message ended with a FIN fragment
// - False: the session ended or the channel closed; this end is quiet and the pump
//   reports no failure
// - any other exception of the producer, of the encoder or of the host passes to the caller
function WsRunProducer(const AProducer: IBodyProducer; const APort: IWsProducerPort;
  const AText: Boolean; const AFrameSize: Integer; const AMaxChunk: Int64): Boolean;

implementation

type
  TWsProducerSink = class(TInterfacedObject, IBodyChunkSink)
  private
    FPort: IWsProducerPort;
    FText: Boolean;
    FFrameSize: Integer;
    FMaxChunk: Int64;
    FStarted: Boolean;
    FFinSent: Boolean;
    FCancelled: Boolean;
    /// the sink raised once: every later call raises the same failure
    FFailed: Boolean;
    FFailText: string;
    procedure Cancel;
    procedure SendChunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
  public
    constructor Create(const APort: IWsProducerPort; const AText: Boolean;
      const AFrameSize: Integer; const AMaxChunk: Int64);
    procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
    property FinSent: Boolean read FFinSent;
    property Cancelled: Boolean read FCancelled;
    property Failed: Boolean read FFailed;
    property FailText: string read FFailText;
  end;

constructor TWsProducerSink.Create(const APort: IWsProducerPort; const AText: Boolean;
  const AFrameSize: Integer; const AMaxChunk: Int64);
begin
  inherited Create;
  FPort := APort;
  FText := AText;
  FFrameSize := AFrameSize;
  FMaxChunk := AMaxChunk;
end;

procedure TWsProducerSink.Cancel;
begin
  FCancelled := True;
  raise EStreamCancelled.Create('the WebSocket stream ended before the producer');
end;

procedure TWsProducerSink.Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
begin
  // a failure of the sink is final: a producer that catches the exception and writes on
  // gets the same failure again, so no message can complete with a missing fragment
  if FFailed then
  begin
    if FCancelled then
      raise EStreamCancelled.Create(FFailText);
    raise EHttpError.Create(FFailText);
  end;
  if FFinSent then
    raise EHttpError.Create('a producer wrote after its last chunk');
  // an empty chunk that is not the last one is skipped, as the pulled stream skips it
  if (ACount = 0) and not ALast then
    Exit;
  try
    SendChunk(ABuffer, ACount, ALast);
  except
    on E: Exception do
    begin
      FFailed := True;
      FFailText := E.Message;
      raise;
    end;
  end;
end;

procedure TWsProducerSink.SendChunk(const ABuffer; const ACount: Integer;
  const ALast: Boolean);
var
  Op: Byte;
  Wire: TBytes;
  Gate: TEvent;
  Done: Boolean;
begin
  if FPort.Ended then
    Cancel;
  if ACount > FMaxChunk then
    raise EHttpError.Create('a chunk of a streamed message is over the size limit');
  if FStarted then
    Op := WsOpContinuation
  else if FText then
    Op := WsOpText
  else
    Op := WsOpBinary;
  // the fragment is encoded once; a refused write sends the same octets again
  Wire := WsEncodeFragment(Op, ALast, ABuffer, ACount, FFrameSize);
  Gate := FPort.Gate;
  Done := False;
  repeat
    // the reset comes before the write: a wake after the refusal is not lost
    Gate.ResetEvent;
    case FPort.Write(Wire, ALast) of
      srQueued:
        Done := True;
      srClosed:
        // no data frame may go out any more: the session knows, so this is quiet
        Cancel;
    else
      begin
        // the pool thread waits here, and it holds no lock
        Gate.WaitFor(cWsProducerWaitMs);
        if FPort.Ended then
          Cancel;
      end;
    end;
  until Done;
  FPort.Count(ACount);
  FStarted := True;
  if ALast then
    FFinSent := True;
end;

function WsRunProducer(const AProducer: IBodyProducer; const APort: IWsProducerPort;
  const AText: Boolean; const AFrameSize: Integer; const AMaxChunk: Int64): Boolean;
var
  Sink: TWsProducerSink;
  SinkRef: IBodyChunkSink;
  None: Byte;
begin
  Sink := TWsProducerSink.Create(APort, AText, AFrameSize, AMaxChunk);
  SinkRef := Sink;
  None := 0;
  try
    AProducer.Produce(SinkRef);
    // a producer that caught the failure of the sink and ended: the session fails
    if Sink.Failed and not Sink.Cancelled then
      raise EHttpError.Create(Sink.FailText);
    if not Sink.Cancelled and not Sink.FinSent then
      // a producer that ended without its last chunk: the message ends with an empty frame
      SinkRef.Chunk(None, 0, True);
  except
    // a failure that follows the end of the session is quiet; any other one passes on
    if not Sink.Cancelled then
      raise;
  end;
  Result := Sink.FinSent and not Sink.Cancelled;
end;

end.
