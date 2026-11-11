{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_connection_test
notes:
  - this checks peer settings and shared encoder state
---
}
unit Http2.Client.ConnectionSettings.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Classes, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Common.Hpack, Http2.Client.Connection,
  Http2.Client.MockSocket, Http2.Client;

type
  TConnectionSettingsRegressionTest = class(TTestCase)
  published
    procedure TestHeaderDecoderUsesLocalSettings;
    procedure TestPooledConnectionCreatesEncoderLock;
    procedure TestHeaderTableSettingPreservesOtherPeerSettings;
    procedure TestSettingsFailureReleasesEncoderLock;
  end;

implementation

procedure TConnectionSettingsRegressionTest.TestHeaderDecoderUsesLocalSettings;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Decoder: THpackCodec;
  Local: TConnectionSettings;
begin
  Sock := TMockSocket.Create;
  Local := TConnectionSettings.Defaults;
  Local.HeaderTableSize := 256;
  Local.MaxHeaderListSize := 8192;
  Conn := TConnection.Create(Sock, Local);
  Decoder := THpackCodec.Create;
  try
    Conn.HeaderDecoder := Decoder;
    AssertEquals('local table limit', LongWord(256), Decoder.DecoderMaxSize);
    AssertEquals('local header-list limit', LongWord(8192),
      Decoder.MaxHeaderListSize);
  finally
    Conn.Free;
    Decoder.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestPooledConnectionCreatesEncoderLock;
var
  Conn: TConnection;
  Pooled: THttpConnection;
begin
  Conn := TConnection.Create(TMockSocket.Create);
  Pooled := THttpConnection.Create(Conn, 'lock.example', 1);
  try
    AssertTrue('connection has its shared encoder lock',
      Conn.HeaderEncoderLock <> nil);
    AssertTrue('pool and connection use the same lock',
      Pooled.GetLock = Conn.HeaderEncoderLock);
  finally
    Pooled.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestHeaderTableSettingPreservesOtherPeerSettings;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Encoder: THpackCodec;
  EncoderLock: TCriticalSection;
  Peer: TConnectionSettings;
  Decoder: THpackCodec;
  Payload: TBytes;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Encoder := THpackCodec.Create;
  Decoder := THpackCodec.Create;
  EncoderLock := TCriticalSection.Create;
  Conn.HeaderEncoderLock := EncoderLock;
  Conn.HeaderEncoder := Encoder;
  Conn.HeaderDecoder := Decoder;
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Peer := TConnectionSettings.Defaults;
    Peer.InitialWindowSize := 1234;
    Peer.MaxConcurrentStreams := 7;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('first settings are acknowledged', Sock.WaitForWrites(4, 2000));
    SetLength(Payload, 6);
    Payload[0] := 0;
    Payload[1] := 1;
    Payload[2] := 0;
    Payload[3] := 0;
    Payload[4] := 1;
    Payload[5] := 0;
    Sock.FeedFrame(TFrame.Create(ftSettings, [], 0, Payload));
    AssertTrue('table setting is acknowledged', Sock.WaitForWrites(5, 2000));
    AssertEquals('initial window remains unchanged', LongWord(1234),
      Conn.PeerSettings.InitialWindowSize);
    AssertEquals('stream cap remains unchanged', LongWord(7),
      Conn.PeerSettings.MaxConcurrentStreams);
    AssertEquals('encoder applies peer table cap', LongWord(256),
      Encoder.EncoderMaxSize);
    AssertEquals('peer settings do not change local decoder cap',
      LongWord(4096), Decoder.DecoderMaxSize);
    AssertEquals('peer settings do not change local header-list cap',
      TConnectionSettings.Defaults.MaxHeaderListSize,
      Decoder.MaxHeaderListSize);
  finally
    Conn.Free;
    Encoder.Free;
    Decoder.Free;
    EncoderLock.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestSettingsFailureReleasesEncoderLock;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Encoder: THpackCodec;
  EncoderLock: TCriticalSection;
  Peer: TConnectionSettings;
  Payload: TBytes;
  Acquired: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Encoder := THpackCodec.Create;
  EncoderLock := TCriticalSection.Create;
  Conn.HeaderEncoderLock := EncoderLock;
  Conn.HeaderEncoder := Encoder;
  Conn.FlowControl.OpenStream(1);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Peer := TConnectionSettings.Defaults;
    Peer.InitialWindowSize := 1;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('first settings are acknowledged', Sock.WaitForWrites(4, 2000));

    SetLength(Payload, 4);
    Payload[0] := $7f;
    Payload[1] := $ff;
    Payload[2] := $ff;
    Payload[3] := $fe;
    Sock.FeedFrame(TFrame.Create(ftWindowUpdate, [], 1, Payload));
    Peer := Conn.PeerSettings;
    Peer.InitialWindowSize := 2;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('invalid window change closes the connection',
      Conn.WaitForState(csClosed, 2000));
    Acquired := EncoderLock.TryEnter;
    if Acquired then
      EncoderLock.Leave;
    AssertTrue('settings failure releases encoder lock', Acquired);
  finally
    Conn.Free;
    Encoder.Free;
    EncoderLock.Free;
  end;
end;

initialization
  RegisterTest(TConnectionSettingsRegressionTest);
end.
