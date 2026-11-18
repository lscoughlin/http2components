{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, write_timeout, lock_order, header_encoder
notes:
  - this checks that a write timeout is a fatal connection error
  - this checks that the reader never waits for the header encoder lock
---
}
unit Http2.Client.WriteTimeout.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Errors, Http2.Common.Frames, Http2.Common.Hpack,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Client.Connection,
  Http2.Client.MockSocket.Support;

type
  /// a socket whose next write sends half of its bytes and then times out
  TTimeoutOnWriteSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FInner: IHttp2Socket;
    FMock: TMockSocket;
    FArmed: LongInt;
  public
    constructor Create(const AMock: TMockSocket);
    /// the next Write call times out in the middle of its bytes
    procedure ArmWriteTimeout;
    function Read(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
  end;

  TWriteTimeoutFatalTest = class(TTestCase)
  published
    procedure TestWriteTimeoutMidFrameClosesConnection;
    procedure TestIdleReadTimeoutKeepsConnectionOpen;
    procedure TestSettingsWhileEncoderLockIsHeldDoesNotStallReader;
  end;

implementation

{ TTimeoutOnWriteSocket }

constructor TTimeoutOnWriteSocket.Create(const AMock: TMockSocket);
begin
  inherited Create;
  FInner := AMock;
  FMock := AMock;
end;

procedure TTimeoutOnWriteSocket.ArmWriteTimeout;
begin
  InterlockedExchange(FArmed, 1);
end;

function TTimeoutOnWriteSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := FInner.Read(ABuffer, ACount);
end;

function TTimeoutOnWriteSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  if (ACount > 1) and (InterlockedExchange(FArmed, 0) = 1) then
  begin
    FInner.Write(ABuffer, ACount div 2);
    raise EHttpTimeout.Create('write timed out');
  end;
  Result := FInner.Write(ABuffer, ACount);
end;

procedure TTimeoutOnWriteSocket.Close;
begin
  FInner.Close;
end;

function TTimeoutOnWriteSocket.GetConnected: Boolean;
begin
  Result := FInner.Connected;
end;

function TTimeoutOnWriteSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FInner.ConnectTimeoutMs;
end;

procedure TTimeoutOnWriteSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FInner.ConnectTimeoutMs := AValue;
end;

function TTimeoutOnWriteSocket.GetReadTimeoutMs: Integer;
begin
  Result := FInner.ReadTimeoutMs;
end;

procedure TTimeoutOnWriteSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FInner.ReadTimeoutMs := AValue;
end;

function TTimeoutOnWriteSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FInner.WriteTimeoutMs;
end;

procedure TTimeoutOnWriteSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FInner.WriteTimeoutMs := AValue;
end;

{ TWriteTimeoutFatalTest }

procedure TWriteTimeoutFatalTest.TestWriteTimeoutMidFrameClosesConnection;
var
  Mock: TMockSocket;
  Sock: TTimeoutOnWriteSocket;
  Conn: TConnection;
  Before: Integer;
  Failure: EHttpError;
begin
  Mock := TMockSocket.Create;
  Sock := TTimeoutOnWriteSocket.Create(Mock);
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    AssertTrue('preface and settings are written', Mock.WaitForWrites(2, 2000));
    Sock.ArmWriteTimeout;
    Conn.PostFrame(BuildWindowUpdateFrame(0, 100));
    AssertTrue('the write timeout closes the connection',
      Conn.WaitForState(csClosed, 5000));
    AssertEquals('error code: ' + Conn.ErrorMessage, Ord(ecInternalError),
      Ord(Conn.ErrorCode));
    // the next request gets a connection error, not a frame out of step
    Failure := Conn.FailureError(Conn.ErrorMessage, Conn.ErrorCode);
    try
      AssertTrue('a connection error', Failure is EHttpConnectionError);
    finally
      Failure.Free;
    end;
    Before := Length(Mock.WrittenBytes);
    Conn.PostFrame(BuildWindowUpdateFrame(0, 100));
    AssertEquals('nothing is written after the partial frame', Before,
      Length(Mock.WrittenBytes));
  finally
    Conn.Free;
  end;
end;

procedure TWriteTimeoutFatalTest.TestIdleReadTimeoutKeepsConnectionOpen;
var
  Mock: TMockSocket;
  Conn: TConnection;
begin
  Mock := TMockSocket.Create;
  Conn := TConnection.Create(Mock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    // every poll of the mock raises EHttpTimeout; a PING that the peer sends
    // after several polls is still answered, so the reader kept polling
    Mock.FeedFrame(BuildSettingsFrame(Conn.LocalSettings));
    Mock.EnqueuePing(TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8), False);
    AssertTrue('the PING is answered', Mock.WaitForFrames(3, 2000));
    AssertTrue('still open', Conn.State = csOpen);
  finally
    Conn.Free;
  end;
end;

procedure TWriteTimeoutFatalTest.TestSettingsWhileEncoderLockIsHeldDoesNotStallReader;
var
  Mock: TMockSocket;
  Conn: TConnection;
  Encoder: THpackCodec;
  Lock: TCriticalSection;
  Peer: TConnectionSettings;
begin
  Mock := TMockSocket.Create;
  Conn := TConnection.Create(Mock);
  Encoder := THpackCodec.Create;
  Lock := TCriticalSection.Create;
  Conn.HeaderEncoderLock := Lock;
  Conn.HeaderEncoder := Encoder;
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    AssertTrue('preface and settings are written', Mock.WaitForWrites(2, 2000));
    // this thread plays a stream thread that holds the encoder lock while it
    // waits for queue room; only the reader makes room
    Lock.Acquire;
    try
      Peer := TConnectionSettings.Defaults;
      Peer.HeaderTableSize := 256;
      Mock.FeedFrame(BuildSettingsFrame(Peer));
      AssertTrue('the reader acknowledges the SETTINGS and does not wait',
        Mock.WaitForWrites(3, 2000));
      AssertEquals('the encoder keeps its size while the lock is held',
        LongWord(4096), Encoder.EncoderMaxSize);
      // the stream thread applies the size before it encodes its block
      Conn.TableHandoff.Apply(Conn.HeaderEncoder);
      AssertEquals('the encoder takes the deferred size', LongWord(256),
        Encoder.EncoderMaxSize);
    finally
      Lock.Release;
    end;
  finally
    Conn.Free;
    Encoder.Free;
    Lock.Free;
  end;
end;

initialization
  RegisterTest(TWriteTimeoutFatalTest);

end.
