{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this smoke tests the hostile peer helper for client tests
---
}
unit Http2.Client.MockSocket.Hostile.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Client.Connection, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.TestSupport, Http2.Client.MockSocket.Frames,
  Http2.Client.MockSocket.Hostile;

type
  THostilePeerTest = class(TTestCase)
  private
    FCalls: Integer;
    FLastIndex: Integer;
    procedure CountFlood(AIndex: Integer);
    function ReadWire(const ASock: TMockSocket; const ACount: Integer): TBytes;
  published
    procedure TestSendDataReachesClientBytes;
    procedure TestContinuationChainReachesClientBytes;
    procedure TestSendFrameWritesRawFrame;
    procedure TestFloodCallsActionCount;
    procedure TestWrittenFramesParsesClientOutput;
  end;

implementation

procedure THostilePeerTest.CountFlood(AIndex: Integer);
begin
  Inc(FCalls);
  FLastIndex := AIndex;
end;

function THostilePeerTest.ReadWire(const ASock: TMockSocket;
  const ACount: Integer): TBytes;
begin
  SetLength(Result, ACount);
  AssertEquals('bytes read from the client side', ACount,
    ASock.Read(Result[0], ACount));
end;

procedure THostilePeerTest.TestSendDataReachesClientBytes;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Wire: TBytes;
  Frames: TArray<TFrame>;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  try
    Peer.SendData(1, 5, True);
    Wire := ReadWire(Sock, FrameHeaderSize + 5);
    Frames := ParseFrameSequence(Wire, False);
    AssertEquals('one frame', 1, Length(Frames));
    AssertEquals('frame type', Ord(ftData), Ord(Frames[0].Header.FrameType));
    AssertEquals('stream id', 1, Integer(Frames[0].Header.StreamId));
    AssertTrue('end stream', Frames[0].IsEndStream);
    AssertEquals('payload length', 5, Length(Frames[0].Payload));
    AssertEquals('payload byte', Ord('A'), Ord(Frames[0].Payload[0]));
  finally
    Peer.Free;
    Srv.Free;
    Sock.Free;
  end;
end;

procedure THostilePeerTest.TestContinuationChainReachesClientBytes;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Wire: TBytes;
  Frames: TArray<TFrame>;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  try
    Peer.SendHeadersFragment(3, BytesOfString('ab'), False, False);
    Peer.SendContinuation(3, BytesOfString('c'), False);
    Peer.SendContinuation(3, BytesOfString('d'), True);
    Wire := ReadWire(Sock, (FrameHeaderSize + 2) + (FrameHeaderSize + 1) +
      (FrameHeaderSize + 1));
    Frames := ParseFrameSequence(Wire, False);
    AssertEquals('three frames', 3, Length(Frames));
    AssertEquals('first is HEADERS', Ord(ftHeaders),
      Ord(Frames[0].Header.FrameType));
    AssertFalse('HEADERS without END_HEADERS', Frames[0].IsEndHeaders);
    AssertEquals('second is CONTINUATION', Ord(ftContinuation),
      Ord(Frames[1].Header.FrameType));
    AssertFalse('first CONTINUATION without END_HEADERS',
      Frames[1].IsEndHeaders);
    AssertEquals('third is CONTINUATION', Ord(ftContinuation),
      Ord(Frames[2].Header.FrameType));
    AssertTrue('last CONTINUATION has END_HEADERS', Frames[2].IsEndHeaders);
    AssertEquals('same stream id', 3, Integer(Frames[2].Header.StreamId));
  finally
    Peer.Free;
    Srv.Free;
    Sock.Free;
  end;
end;

procedure THostilePeerTest.TestSendFrameWritesRawFrame;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Raw: TFrame;
  Wire, Expected: TBytes;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  try
    Raw := BuildPingFrame(BytesOfString('12345678'), False);
    Peer.SendFrame(Raw);
    Expected := FrameToBytes(Raw);
    Wire := ReadWire(Sock, Length(Expected));
    AssertTrue('raw frame bytes reach the client',
      CompareMem(@Wire[0], @Expected[0], Length(Wire)));
  finally
    Peer.Free;
    Srv.Free;
    Sock.Free;
  end;
end;

procedure THostilePeerTest.TestFloodCallsActionCount;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  try
    FCalls := 0;
    FLastIndex := -1;
    Peer.Flood(4, CountFlood);
    AssertEquals('action calls', 4, FCalls);
    AssertEquals('last index', 3, FLastIndex);
  finally
    Peer.Free;
    Srv.Free;
    Sock.Free;
  end;
end;

procedure THostilePeerTest.TestWrittenFramesParsesClientOutput;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Pre, Ack: TBytes;
  Frames: TArray<TFrame>;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  try
    Pre := ClientPrefaceBytes;
    Ack := FrameToBytes(BuildSettingsAck);
    Sock.Write(Pre[0], Length(Pre));
    Sock.Write(Ack[0], Length(Ack));
    Frames := Peer.WrittenFrames;
    AssertEquals('one client frame', 1, Length(Frames));
    AssertEquals('frame type', Ord(ftSettings),
      Ord(Frames[0].Header.FrameType));
    AssertTrue('ACK flag', Frames[0].IsAck);
  finally
    Peer.Free;
    Srv.Free;
    Sock.Free;
  end;
end;

initialization
  RegisterTest(THostilePeerTest);

end.
