{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, receive_queue, stream_error
notes:
  - this checks that an overflow of one stream receive queue is a stream error, not a connection error
---
}
unit Http2.Client.ReceiveOverflow.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Hpack,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.Frames, Http2.Client.Stream.Support;

type
  /// a peer that sends more DATA than the receive cap on one stream
  TReceiveOverflowTest = class(TStreamLeaseTestBase)
  published
    procedure TestOverflowFailsOnlyThatStream;
  end;

implementation

const
  cFrameBytes = 16384;
  // the default cap is 1048576 bytes: 64 frames fill it, the 65th passes it
  cFrameCount = 70;

procedure TReceiveOverflowTest.TestOverflowFailsOnlyThatStream;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Alloc: TStreamIdAllocator;
  Lease1, Lease3: TStreamLease;
  IL1, IL3: IConnectionStream;
  Enc: THpackCodec;
  Data: TBytes;
  Frames: TArray<TFrame>;
  I, Waited, Resets: Integer;
  ConnCredit: Int64;
  Failed: Boolean;
  Code: THttp2ErrorCode;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  Lease1 := nil;
  Lease3 := nil;
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Conn.ApplyPeerSettingsValue(Conn.PeerSettings);
    Lease1 := TStreamLease.Create(Conn, Alloc,
      TStreamRequest.WithMethod(hmGet, 'api.example'));
    IL1 := Lease1;
    Lease3 := TStreamLease.Create(Conn, Alloc,
      TStreamRequest.WithMethod(hmGet, 'api.example'));
    IL3 := Lease3;
    Lease1.Start;
    Lease3.Start;
    AssertEquals('first stream id', 1, Integer(Lease1.StreamId));
    AssertEquals('second stream id', 3, Integer(Lease3.StreamId));

    SetLength(Data, cFrameBytes);
    for I := 1 to cFrameCount do
      Sock.FeedFrame(BuildDataFrame(1, Data, False));
    Enc := THpackCodec.Create;
    try
      Sock.FeedFrame(ResponseHeadersFrame(Enc, '200', [], 3, True));
    finally
      Enc.Free;
    end;

    AssertTrue('stream 3 completes', Lease3.WaitForResponseHeader(5000));
    AssertEquals('stream 3 status', 200, Lease3.StatusCode);
    AssertTrue('the connection stays open', Conn.State = csOpen);

    Failed := False;
    Code := ecNoError;
    try
      Lease1.WaitForResponseHeader(2000);
    except
      on E: EHttpStreamError do
      begin
        Failed := True;
        Code := E.ErrorCode;
      end;
    end;
    AssertTrue('stream 1 failed with a stream error', Failed);
    AssertEquals('stream 1 error code', Ord(ecFlowControlError), Ord(Code));
    AssertEquals('stream 1 left the connection', 1, Lease1.UnregisterCount);

    // bounded poll for the writer thread: one reset for stream 1
    Waited := 0;
    Resets := 0;
    ConnCredit := 0;
    while Waited < 5000 do
    begin
      Frames := ParseFrameSequence(Sock.WrittenBytes, True);
      Resets := 0;
      ConnCredit := 0;
      for I := 0 to High(Frames) do
      begin
        if (Frames[I].Header.FrameType = ftRstStream) and
           (Frames[I].Header.StreamId = 1) then
          Inc(Resets);
        if (Frames[I].Header.FrameType = ftWindowUpdate) and
           (Frames[I].Header.StreamId = 0) then
          Inc(ConnCredit, ParseWindowUpdate(Frames[I]));
      end;
      // the credit of the dropped frames has to come back as well
      if (Resets >= 1) and
         (ConnCredit >= Int64(cFrameCount) * cFrameBytes - 32768) then
        Break;
      Sleep(10);
      Inc(Waited, 10);
    end;
    AssertEquals('one RST_STREAM for stream 1, none for every later frame', 1,
      Resets);
    for I := 0 to High(Frames) do
      if (Frames[I].Header.FrameType = ftRstStream) and
         (Frames[I].Header.StreamId = 1) then
      begin
        ParseRstStream(Frames[I], Code);
        AssertEquals('reset code', Ord(ecFlowControlError), Ord(Code));
      end;
    AssertTrue('the connection credit of every frame came back',
      ConnCredit >= Int64(cFrameCount) * cFrameBytes - 32768);
  finally
    if Lease1 <> nil then Lease1.ReleaseLease;
    if Lease3 <> nil then Lease3.ReleaseLease;
    IL1 := nil;
    IL3 := nil;
    Alloc.Free;
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TReceiveOverflowTest);

end.
