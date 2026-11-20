{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves mock socket client tests from the source project
---
}
unit Http2.Client.MockSocket.Capture.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Hpack, Http2.Client.Tls, Http2.Client.Observer,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames, Http2.Client.Connection.Preface;

type
  TMockSocketCaptureTest = class(TTestCase)
  published
    procedure TestCapturesExactOutboundFrameSequence;
    procedure TestOutboundBytesSkipPreface;
    procedure TestStalledReadNeverReturnsUntilReleased;
    procedure TestMalformedFrameEnqueueFailsTheConnection;
  end;

implementation

procedure TMockSocketCaptureTest.TestCapturesExactOutboundFrameSequence;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Expected, Actual: TArray<TFrame>;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('SETTINGS written', Sock.WaitForFrames(1, 2000));
    AssertTrue('data frame posted',
      Conn.PostFrame(BuildDataFrame(1, BytesOfString('hi'), True)));
    AssertTrue('data frame written', Sock.WaitForFrames(2, 2000));

    SetLength(Expected, 2);
    Expected[0] := BuildSettingsFrame(TConnectionSettings.Defaults);
    Expected[1] := BuildDataFrame(1, BytesOfString('hi'), True);
    Actual := Sock.OutboundFrames(True);
    AssertFrameSequence(Expected, Actual, 'client preface + data');
  finally
    Conn.Free;
  end;
end;
procedure TMockSocketCaptureTest.TestOutboundBytesSkipPreface;
var
  Sock: TMockSocket;
  Conn: TConnection;
  All, NoPreface: TBytes;
  Pre: TBytes;
  I: Integer;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('SETTINGS written', Sock.WaitForFrames(1, 2000));
    All := Sock.OutboundBytes(False);
    NoPreface := Sock.OutboundBytes(True);
    Pre := ClientPrefaceBytes;
    AssertEquals('full capture includes 24-byte preface plus frames',
      24 + Length(NoPreface), Length(All));
    for I := 0 to 23 do
      AssertEquals('preface byte ' + IntToStr(I), Pre[I], All[I]);
    // the skipped capture begins at the SETTINGS frame header
    AssertEquals('no-preface capture starts with SETTINGS type', Ord(ftSettings),
      Ord(NoPreface[3]));
  finally
    Conn.Free;
  end;
end;
procedure TMockSocketCaptureTest.TestStalledReadNeverReturnsUntilReleased;
var
  Sock: TMockSocket;
  ISock: IHttp2Socket;
  Probe: TReadProbe;
begin
  Sock := TMockSocket.Create;
  ISock := Sock;          // hold the interface ref; TReadProbe also holds one
  Sock.StallReads;
  Probe := TReadProbe.Create(Sock);
  try
    Probe.Start;
    // a stalled read must NOT complete within the bounded window
    AssertFalse('a stalled read does not return on its own',
      Probe.WaitDone(300));
    // releasing the stall lets the parked read surface a timeout
    Sock.UnstallReads;
    AssertTrue('the released read returns', Probe.WaitDone(2000));
  finally
    Probe.Free;
    Sock.Close;
    ISock := nil;         // release the socket last, through its interface
  end;
end;
procedure TMockSocketCaptureTest.TestMalformedFrameEnqueueFailsTheConnection;
var
  Sock: TMockSocket;
  Conn: TConnection;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Sock.EnqueueOversizedFrameHeader;
    AssertTrue('an oversized frame closes the connection',
      Conn.WaitForState(csClosed, 2000));
    AssertTrue('an error code was recorded',
      Conn.ErrorCode = ecFrameSizeError);
  finally
    Conn.Free;
  end;
end;

{ TScriptedScenarioTest }


initialization
  RegisterTest(TMockSocketCaptureTest);
end.
