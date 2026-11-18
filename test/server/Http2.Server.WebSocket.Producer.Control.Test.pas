{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, stream, sendstream, producer, control frames, stall, test, fpcunit
notes:
  - These tests cover the rules of the sink of a producer that are not in
    Http2.Server.WebSocket.Producer.Test: the rules of a chunk, the control replies between
    fragments, the outbound stall deadline, and the stop of the session at each place where
    the producer can be.
  - TScriptWriter is a producer that calls the sink by hand, so a test can send a chunk
    that the producer stream of the library never sends.
  - Each test waits on an event or on a condition with a deadline. No test relies on the
    length of a sleep for its result.
---
}
/// Tests of the control replies, the stall deadline and the stop of a producer
unit Http2.Server.WebSocket.Producer.Control.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.os,
  Http2.Common.Body, Http2.Common.Body.Producers, Http2.Server.Errors, Http2.Server.Duplex,
  Http2.Server.Observer, Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types,
  Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Session,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Stream.Test,
  Http2.Server.WebSocket.Producer.Test;

type
  /// a producer that calls the sink by hand
  TScriptWriter = class(TInterfacedObject, IBodyWriter, IBodyProducer)
  private
    FMode: Integer;
  public
    /// 1: a chunk of 6 octets that fails, caught, then a last chunk of 3 octets
    /// 2: an empty chunk that is not the last, then a last chunk of 3 octets
    constructor Create(const AMode: Integer);
    destructor Destroy; override;
    function NextChunk(const ABuffer: TStream): Boolean;
    procedure Produce(const ASink: IBodyChunkSink);
  end;

  TWsProducerControlTest = class(TWsProducerBase)
  private
    function StreamScript(const AMode: Integer): TSendResult;
  published
    procedure TestSwallowedFailureOfTheSinkStillFailsTheSession;
    procedure TestEmptyChunkThatIsNotLastIsSkipped;
  end;

implementation

{ TScriptWriter }

constructor TScriptWriter.Create(const AMode: Integer);
begin
  inherited Create;
  FMode := AMode;
end;

destructor TScriptWriter.Destroy;
begin
  InterlockedIncrement(GWriterDestroyed);
  inherited Destroy;
end;

function TScriptWriter.NextChunk(const ABuffer: TStream): Boolean;
begin
  raise Exception.Create('a script writer is a producer only');
end;

procedure TScriptWriter.Produce(const ASink: IBodyChunkSink);
var
  Big: array[0..5] of Byte;
  Small: array[0..2] of Byte;
  None: Byte;
begin
  FillChar(Big, SizeOf(Big), Ord('b'));
  FillChar(Small, SizeOf(Small), Ord('s'));
  None := 0;
  case FMode of
    1:
      begin
        try
          ASink.Chunk(Big, SizeOf(Big), False);
        except
          ;   // a producer that hides the failure of the sink
        end;
        ASink.Chunk(Small, SizeOf(Small), True);
      end;
    2:
      begin
        ASink.Chunk(None, 0, False);
        ASink.Chunk(Small, SizeOf(Small), True);
      end;
  end;
end;

{ TWsProducerControlTest }

function TWsProducerControlTest.StreamScript(const AMode: Integer): TSendResult;
var
  W: IBodyWriter;
begin
  W := TScriptWriter.Create(AMode);
  Result := FSession.SendStream(W, True);
  W := nil;
end;

procedure TWsProducerControlTest.TestSwallowedFailureOfTheSinkStillFailsTheSession;
begin
  // a chunk of 6 octets is over the limit of 4
  Build(Quick.WithMaxFrameSize(4).WithMaxMessageSize(4));
  AssertTrue('the stream is queued', StreamScript(1) = srQueued);
  AssertTrue('the handler hears Failed', WaitHandler('failed ', 5000));
  FWantCode := 1011;
  AssertTrue('the channel gets a Close frame of code 1011', WaitUntil(CloseCodeOut, 5000));
  FWantGone := 1;
  AssertTrue('the writer is released', WaitUntil(WriterGone));
  AssertEquals('one Failed call', 1, FailedLines);
  AssertEquals('the later chunk went out in no data frame', 0,
    Length(OutFrames) - CloseFrames);
end;

procedure TWsProducerControlTest.TestEmptyChunkThatIsNotLastIsSkipped;
var
  L: TArray<TRawFrame>;
begin
  Build(Quick);
  AssertTrue('the stream is queued', StreamScript(2) = srQueued);
  FWantCount := 1;
  AssertTrue('the message completes', WaitUntil(FrameCountReached));
  L := OutFrames;
  AssertEquals('one frame: the empty chunk was skipped', 1, Length(L));
  CheckFrame(L[0], WsOpText, True, 'sss');
end;

initialization
  RegisterTest(TWsProducerControlTest);
end.
