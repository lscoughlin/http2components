{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, header_block, header_limits, hpack
notes:
  - this checks the limit on a header block and on the decoded header list
  - a hostile peer sends the frames over a mock socket, so the client reads them as wire bytes
---
}
unit Http2.Client.HeaderLimits.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Common.Errors, Http2.Common.Frames, Http2.Common.Hpack,
  Http2.Client.Connection, Http2.Client.Connection.HeaderBlock,
  Http2.Client.Config.Security, Http2.Client.MockSocket.Support,
  Http2.Client.MockSocket.Frames, Http2.Client.MockSocket.Hostile,
  Http2.Client.MockSocket.TestSupport;

type
  /// a stream that ignores every event; it makes stream 1 open for the peer
  TNullStream = class(TInterfacedObject, IConnectionStream)
  public
    procedure OnConnectionFailed(const AMessage: string;
      const ACode: THttp2ErrorCode);
    procedure OnConnectionGoAway(const ALastStreamId: LongWord);
    procedure OnStreamFrame(const AFrame: TFrame);
  end;

  THeaderLimitsTest = class(TTestCase)
  private
    function NewConnection(const ASock: TMockSocket): TConnection;
    function Filled(const ACount: Integer; const AByte: Byte): TBytes;
  published
    procedure TestEndlessContinuationClosesWithEnhanceYourCalm;
    procedure TestStaticIndexBombClosesWithEnhanceYourCalm;
    procedure TestDynamicEntryBombRaisesInDecoder;
    procedure TestBlockAtLimitIsAccepted;
    procedure TestBlockOneByteOverLimitIsRefused;
    procedure TestCrInResponseHeaderValueClosesWithProtocolError;
    procedure TestSettingsAdvertiseOptionLimit;
  end;

implementation

const
  // the smallest value that WithMaxHeaderListSize accepts
  cTestLimit = 1024;

procedure TNullStream.OnConnectionFailed(const AMessage: string;
  const ACode: THttp2ErrorCode);
begin
end;

procedure TNullStream.OnConnectionGoAway(const ALastStreamId: LongWord);
begin
end;

procedure TNullStream.OnStreamFrame(const AFrame: TFrame);
begin
end;

function THeaderLimitsTest.NewConnection(const ASock: TMockSocket): TConnection;
var
  Decoder: THpackCodec;
  Stream: IConnectionStream;
begin
  Result := TConnection.Create(ASock);
  Result.SetSecurity(TClientSecurityOptions.Default.WithMaxHeaderListSize(
    cTestLimit));
  Decoder := THpackCodec.Create;
  Result.HeaderDecoder := Decoder;
  // a HEADERS or CONTINUATION frame on an idle stream is a connection error
  Stream := TNullStream.Create;
  Result.RegisterStream(1, Stream);
end;

function THeaderLimitsTest.Filled(const ACount: Integer;
  const AByte: Byte): TBytes;
begin
  SetLength(Result, ACount);
  if ACount > 0 then
    FillChar(Result[0], ACount, AByte);
end;

procedure THeaderLimitsTest.TestEndlessContinuationClosesWithEnhanceYourCalm;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Conn: TConnection;
  I: Integer;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  Conn := NewConnection(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Peer.SendHeadersFragment(1, Filled(200, Ord('a')), False, False);
    // the block passes the limit on the sixth fragment (1200 bytes)
    for I := 1 to 10 do
      Peer.SendContinuation(1, Filled(200, Ord('a')), False);
    AssertTrue('connection closes', Conn.WaitForState(csClosed, 2000));
    AssertEquals('error code: ' + Conn.ErrorMessage, Ord(ecEnhanceYourCalm),
      Ord(Conn.ErrorCode));
  finally
    Conn.Free;
    Peer.Free;
    Srv.Free;
  end;
end;

procedure THeaderLimitsTest.TestStaticIndexBombClosesWithEnhanceYourCalm;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Conn: TConnection;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  Conn := NewConnection(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    // 200 octets, each an indexed reference to static entry 58 (user-agent,
    // empty value): each field is 42 octets in the decoded list
    Peer.SendHeadersFragment(1, Filled(200, $BA), True, True);
    AssertTrue('connection closes', Conn.WaitForState(csClosed, 2000));
    AssertEquals('error code', Ord(ecEnhanceYourCalm),
      Ord(Conn.ErrorCode));
  finally
    Conn.Free;
    Peer.Free;
    Srv.Free;
  end;
end;

procedure THeaderLimitsTest.TestDynamicEntryBombRaisesInDecoder;
var
  Dec: THpackCodec;
  Insert, Bomb: TBytes;
  Block: THeaderBlock;
  Raised: Boolean;
  I: Integer;
begin
  Dec := THpackCodec.Create;
  try
    // a literal with incremental indexing: name 'x-big', a 4000 octet value
    // (the 7-bit prefix integer 4000 is 0x7F, 0xA1, 0x1E)
    Insert := BytesOfString(#$40 + #5 + 'x-big' + #$7F + #$A1 + #$1E);
    Insert := Insert + Filled(4000, Ord('a'));
    Dec.MaxHeaderListSize := 0;
    Block := Dec.Decode(Insert);
    AssertEquals('one field', 1, Length(Block));
    // a single indexed reference to the 4 KiB entry, repeated 100000 times
    Bomb := Filled(100000, $BE);   // index 62: the newest dynamic entry
    Dec.MaxHeaderListSize := cTestLimit;
    Raised := False;
    try
      Dec.Decode(Bomb);
    except
      on E: EHttpProtocolError do
      begin
        Raised := True;
        AssertEquals('error code', Ord(ecEnhanceYourCalm), Ord(E.ErrorCode));
      end;
    end;
    AssertTrue('the decode raises', Raised);
  finally
    Dec.Free;
  end;
end;

procedure THeaderLimitsTest.TestBlockAtLimitIsAccepted;
var
  Assembler1: THeaderBlockAssembler;
begin
  Assembler1 := THeaderBlockAssembler.Create;
  try
    Assembler1.MaxBytes := cTestLimit;
    Assembler1.Start(1, Filled(512, Ord('a')));
    Assembler1.Append(1, Filled(cTestLimit - 512 - 1, Ord('a')));
    AssertEquals('one byte under the limit', Int64(cTestLimit - 1), Assembler1.Size);
    Assembler1.Append(1, Filled(1, Ord('a')));
    AssertEquals('at the limit', Int64(cTestLimit), Assembler1.Size);
    AssertEquals('block is still open', 1, Integer(Assembler1.OpenStreamId));
  finally
    Assembler1.Free;
  end;
end;

procedure THeaderLimitsTest.TestBlockOneByteOverLimitIsRefused;
var
  Assembler1: THeaderBlockAssembler;
  Raised: Boolean;
begin
  Assembler1 := THeaderBlockAssembler.Create;
  try
    Assembler1.MaxBytes := cTestLimit;
    Assembler1.Start(1, Filled(cTestLimit, Ord('a')));
    Raised := False;
    try
      Assembler1.Append(1, Filled(1, Ord('a')));
    except
      on E: EHttpProtocolError do
      begin
        Raised := True;
        AssertEquals('error code', Ord(ecEnhanceYourCalm), Ord(E.ErrorCode));
      end;
    end;
    AssertTrue('one byte over the limit raises', Raised);
  finally
    Assembler1.Free;
  end;
end;

procedure THeaderLimitsTest.TestCrInResponseHeaderValueClosesWithProtocolError;
var
  Sock: TMockSocket;
  Srv: TScriptedServer;
  Peer: THostilePeer;
  Conn: TConnection;
  Block: TBytes;
begin
  Sock := TMockSocket.Create;
  Srv := TScriptedServer.Create(Sock);
  Peer := THostilePeer.Create(Sock, Srv);
  Conn := NewConnection(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    // literal without indexing: name 'x-bad', value 'a', CR, 'b'
    Block := BytesOfString(#$00 + #5 + 'x-bad' + #3 + 'a' + #13 + 'b');
    Peer.SendHeadersFragment(1, Block, True, True);
    AssertTrue('connection closes', Conn.WaitForState(csClosed, 2000));
    AssertEquals('error code', Ord(ecProtocolError), Ord(Conn.ErrorCode));
    AssertTrue('the value check names the octets',
      Pos('CR, LF or NUL', Conn.ErrorMessage) > 0);
  finally
    Conn.Free;
    Peer.Free;
    Srv.Free;
  end;
end;

procedure THeaderLimitsTest.TestSettingsAdvertiseOptionLimit;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Frames: TArray<TFrame>;
  Advertised: TConnectionSettings;
begin
  Sock := TMockSocket.Create;
  Conn := NewConnection(Sock);
  try
    Conn.Start;
    AssertTrue('preface and SETTINGS written', Sock.WaitForFrames(1, 2000));
    Frames := Sock.OutboundFrames(True);
    AssertEquals('first frame is SETTINGS', Ord(ftSettings),
      Ord(Frames[0].Header.FrameType));
    Advertised := TConnectionSettings.Decode(Frames[0].Payload);
    AssertEquals('SETTINGS_MAX_HEADER_LIST_SIZE', Int64(cTestLimit),
      Int64(Advertised.MaxHeaderListSize));
  finally
    Conn.Free;
  end;
end;

initialization
  RegisterTest(THeaderLimitsTest);

end.
