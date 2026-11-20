{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_connection_test
notes:
  - this checks the wait for the peer SETTINGS and the extended CONNECT setting
---
}
unit Http2.Client.Connection.PeerSettings.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Connection,
  Http2.Client.MockSocket.Support;

type
  TConnectionPeerSettingsTest = class(TTestCase)
  published
    procedure TestSettingsWithConnectProtocolAllowsExtendedConnect;
    procedure TestSettingsWithoutConnectProtocolDoesNotAllow;
    procedure TestNoSettingsFrameWaitTimesOut;
    procedure TestLaterZeroKeepsExtendedConnectAllowed;
    procedure TestFailureBeforeSettingsReturnsFalseAtOnce;
  end;

implementation

procedure TConnectionPeerSettingsTest.TestSettingsWithConnectProtocolAllowsExtendedConnect;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Peer: TConnectionSettings;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    AssertFalse('no peer settings yet', Conn.PeerAllowsExtendedConnect);
    Peer := TConnectionSettings.Defaults;
    Peer.EnableConnectProtocol := True;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('peer settings arrive', Conn.WaitForPeerSettings(2000));
    AssertTrue('extended CONNECT is allowed', Conn.PeerAllowsExtendedConnect);
  finally
    Conn.Free;
  end;
end;

procedure TConnectionPeerSettingsTest.TestSettingsWithoutConnectProtocolDoesNotAllow;
var
  Sock: TMockSocket;
  Conn: TConnection;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Sock.FeedFrame(BuildSettingsFrame(TConnectionSettings.Defaults));
    AssertTrue('peer settings arrive', Conn.WaitForPeerSettings(2000));
    AssertFalse('extended CONNECT is not allowed', Conn.PeerAllowsExtendedConnect);
  finally
    Conn.Free;
  end;
end;

procedure TConnectionPeerSettingsTest.TestNoSettingsFrameWaitTimesOut;
var
  Sock: TMockSocket;
  Conn: TConnection;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    AssertFalse('no SETTINGS frame: the wait times out',
      Conn.WaitForPeerSettings(200));
    AssertFalse('no SETTINGS frame: extended CONNECT is not allowed',
      Conn.PeerAllowsExtendedConnect);
  finally
    Conn.Free;
  end;
end;

procedure TConnectionPeerSettingsTest.TestLaterZeroKeepsExtendedConnectAllowed;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Peer: TConnectionSettings;
  Payload: TBytes;
begin
  // the client latches the answer of the first SETTINGS frame that enables
  // the setting; a later frame with the value 0 does not clear it
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Peer := TConnectionSettings.Defaults;
    Peer.EnableConnectProtocol := True;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('first settings are acknowledged', Sock.WaitForWrites(3, 2000));
    SetLength(Payload, 6);
    Payload[0] := 0;
    Payload[1] := 8;
    Payload[2] := 0;
    Payload[3] := 0;
    Payload[4] := 0;
    Payload[5] := 0;
    Sock.FeedFrame(TFrame.Create(ftSettings, [], 0, Payload));
    AssertTrue('second settings are acknowledged', Sock.WaitForWrites(4, 2000));
    AssertTrue('extended CONNECT stays allowed', Conn.PeerAllowsExtendedConnect);
  finally
    Conn.Free;
  end;
end;

procedure TConnectionPeerSettingsTest.TestFailureBeforeSettingsReturnsFalseAtOnce;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Started: QWord;
  Elapsed: QWord;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Started := GetTickCount64;
    Conn.FailWith('peer closed the connection before its SETTINGS',
      ecProtocolError);
    AssertFalse('a failed connection gives no SETTINGS',
      Conn.WaitForPeerSettings(2000));
    Elapsed := GetTickCount64 - Started;
    AssertTrue('the wait ends at once, took ' + IntToStr(Elapsed) + ' ms',
      Elapsed < 1000);
  finally
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TConnectionPeerSettingsTest);
end.
