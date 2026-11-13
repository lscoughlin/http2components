{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, read_timeout, framing, reader_poll
notes:
  - this checks that a gap inside a frame does not lose the bytes that
    already arrived
  - the test uses a real Unix socket and the 20 ms reader poll
---
}
unit Http2.Client.PartialReadTimeout.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, BaseUnix, Sockets, fpcunit, testregistry,
  Http2.Common.Errors, Http2.Client.Tls, Http2.Client.Tls.Plain,
  Http2.Client.Connection, Http2.Client.Unix.TestKit, Http2.Client.SigPipe;

type
  /// a peer that sends one PING frame in two parts with a gap between them
  TSplitPingPeer = class(TUnixListener)
  private
    FFirstPart: Integer;
    FGapMs: Integer;
    FReceived: RawByteString;
    FDone: TEvent;
  public
    constructor Create(const APath: string; AFirstPart, AGapMs: Integer);
    destructor Destroy; override;
    procedure Serve(AFd: Integer); override;
    function WaitDone(AMs: Integer): Boolean;
    property Received: RawByteString read FReceived;
  end;

  TPartialReadTimeoutTest = class(TTestCase)
  private
    procedure RunSplit(AFirstPart: Integer);
  published
    procedure TestGapInsideFrameHeaderKeepsFraming;
    procedure TestGapInsideFramePayloadKeepsFraming;
  end;

implementation

const
  cPingData = #1#2#3#4#5#6#7#8;
  // length 8, type PING, flags 0, stream 0, then the eight data bytes
  cPingFrame: RawByteString = #0#0#8#6#0#0#0#0#0 + cPingData;
  // the PING acknowledgement that the client has to send back
  cPingAck: RawByteString = #0#0#8#6#1#0#0#0#0 + cPingData;

{ TSplitPingPeer }

constructor TSplitPingPeer.Create(const APath: string; AFirstPart,
  AGapMs: Integer);
begin
  FFirstPart := AFirstPart;
  FGapMs := AGapMs;
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(APath);
end;

destructor TSplitPingPeer.Destroy;
begin
  inherited Destroy;
  FDone.Free;
end;

procedure TSplitPingPeer.Serve(AFd: Integer);
begin
  try
    fpSend(AFd, @cPingFrame[1], FFirstPart, cMsgNoSignal);
    // the gap is many times the 20 ms read poll of the client
    Sleep(FGapMs);
    fpSend(AFd, @cPingFrame[FFirstPart + 1], Length(cPingFrame) - FFirstPart, cMsgNoSignal);
    // the acknowledgement arrives at once; the peer closes after the read
    FReceived := ReadAll(AFd, 1000);
  finally
    FDone.SetEvent;
  end;
end;

function TSplitPingPeer.WaitDone(AMs: Integer): Boolean;
begin
  Result := FDone.WaitFor(AMs) = wrSignaled;
end;

{ TPartialReadTimeoutTest }

procedure TPartialReadTimeoutTest.RunSplit(AFirstPart: Integer);
var
  Path: string;
  Peer: TSplitPingPeer;
  Sock: TPlainSocket;
  Conn: TConnection;
begin
  Path := NewUnixTestPath;
  Peer := TSplitPingPeer.Create(Path, AFirstPart, 300);
  try
    Sock := TPlainSocket.CreateUnix(Path, 2000);
    Conn := TConnection.Create(Sock);
    try
      Conn.Start;
      AssertTrue('the peer finishes', Peer.WaitDone(6000));
      AssertTrue('the PING is answered after the gap: ' + Conn.ErrorMessage,
        Pos(cPingAck, Peer.Received) > 0);
    finally
      Conn.Free;
    end;
  finally
    Peer.Stop;
    Peer.Free;
  end;
end;

procedure TPartialReadTimeoutTest.TestGapInsideFrameHeaderKeepsFraming;
begin
  RunSplit(5);
end;

procedure TPartialReadTimeoutTest.TestGapInsideFramePayloadKeepsFraming;
begin
  RunSplit(12);
end;

initialization
  RegisterTest(TPartialReadTimeoutTest);

end.
