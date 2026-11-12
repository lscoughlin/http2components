{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests cover the client socket that connects to a socket file.
---
}
/// Tests for the client socket that connects to a Unix socket file
// - each test runs its own listener on a fresh socket file, and removes the
//   file in TearDown
unit Http2.Client.UnixSocket.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Tls.Plain, Http2.Client.Unix.TestKit;

type
  /// a listener that closes each connection at once
  TClosingListener = class(TUnixListener)
  public
    procedure Serve(AFd: Integer); override;
  end;

  /// a listener that keeps each connection silent for 1.5 seconds
  THoldingListener = class(TUnixListener)
  public
    procedure Serve(AFd: Integer); override;
  end;

  /// tests for the client socket on a Unix socket file
  TUnixSocketTest = class(TTestCase)
  private
    FPath: string;
    FListener: TUnixListener;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestConnectAndEcho;
    procedure TestMissingPathRaisesConnectionError;
    procedure TestNonSocketFileRaises;
    procedure TestPathTooLongRaises;
    procedure TestConnectTimeoutOnFullBacklog;
    procedure TestReadTimeoutRaises;
    procedure TestCloseIsIdempotent;
    procedure TestWriteToClosedPeerRaisesAndKeepsProcessAlive;
  end;

implementation

uses
  Http2.Common.UnixPath;

procedure TClosingListener.Serve(AFd: Integer);
begin
  // the connection closes before the client writes
end;

procedure THoldingListener.Serve(AFd: Integer);
begin
  Sleep(1500);
end;

procedure TUnixSocketTest.SetUp;
begin
  FPath := NewUnixTestPath;
  FListener := nil;
end;

procedure TUnixSocketTest.TearDown;
begin
  FreeAndNil(FListener);
  if FileExists(FPath) then
    DeleteFile(FPath);
end;

procedure TUnixSocketTest.TestConnectAndEcho;
var
  Sock: TPlainSocket;
  Payload, Reply: RawByteString;
begin
  FListener := TUnixListener.Create(FPath);
  Payload := 'hello';
  SetLength(Reply, 5);
  Sock := TPlainSocket.CreateUnix(FPath, 2000);
  try
    AssertTrue('connected', Sock.GetConnected);
    Sock.Write(Payload[1], 5);
    AssertEquals('echoed bytes', 5, Sock.Read(Reply[1], 5));
    AssertEquals('echo text', 'hello', string(Reply));
  finally
    Sock.Close;
    Sock.Free;
  end;
  AssertEquals('one accepted connection', 1, FListener.Accepted);
  AssertEquals('first byte seen by the listener', Ord('h'), FListener.FirstByte);
end;

procedure TUnixSocketTest.TestMissingPathRaisesConnectionError;
var
  Msg: string;
begin
  Msg := '';
  try
    TPlainSocket.CreateUnix(FPath, 1000).Free;
    Fail('a connect to a missing path must raise');
  except
    on E: EHttpConnectionError do
      Msg := E.Message;
  end;
  AssertTrue('the text holds the path: ' + Msg, Pos(FPath, Msg) > 0);
end;

procedure TUnixSocketTest.TestNonSocketFileRaises;
var
  Handle: THandle;
  Msg: string;
begin
  Handle := FileCreate(FPath);
  AssertTrue('test file created', Handle <> THandle(-1));
  FileClose(Handle);
  Msg := '';
  try
    TPlainSocket.CreateUnix(FPath, 1000).Free;
    Fail('a connect to a regular file must raise');
  except
    on E: EHttpConnectionError do
      Msg := E.Message;
  end;
  AssertTrue('the text holds the path: ' + Msg, Pos(FPath, Msg) > 0);
end;

procedure TUnixSocketTest.TestPathTooLongRaises;
var
  LongPath, Msg: string;
begin
  // 1 slash plus 103 letters is 104 bytes, one more than the limit
  LongPath := '/' + StringOfChar('a', 103);
  Msg := '';
  try
    TPlainSocket.CreateUnix(LongPath, 1000).Free;
    Fail('a path of 104 bytes must raise');
  except
    on E: EHttpConnectionError do
      Msg := E.Message;
  end;
  AssertEquals('the text names the rule', UnixPathProblem(LongPath), Msg);
  AssertTrue('the text gives the length: ' + Msg, Pos('104 bytes', Msg) > 0);
end;

procedure TUnixSocketTest.TestConnectTimeoutOnFullBacklog;
const
  cFillLimit = 256;
  cTimeoutMs = 300;
var
  Srv, Fillers: array[0..cFillLimit - 1] of Integer;
  Count, I, Holder: Integer;
  Start: QWord;
  Sock: TPlainSocket;
  Raised: Boolean;
  Msg: string;
begin
  // a listener that never accepts: its queue fills and stops taking clients
  Holder := ListenUnixSocket(FPath, 0);
  try
    Count := 0;
    for I := 0 to cFillLimit - 1 do
    begin
      Fillers[I] := NonBlockingConnectUnix(FPath);
      if Fillers[I] < 0 then
        Break;
      Inc(Count);
    end;
    if Count = cFillLimit then
    begin
      Ignore('the queue of this system does not block');
      Exit;
    end;
    Raised := False;
    Msg := '';
    Start := GetTickCount64;
    try
      Sock := TPlainSocket.CreateUnix(FPath, cTimeoutMs);
      Sock.Free;
    except
      on E: EHttpTimeout do
        Raised := True;
      on E: EHttpConnectionError do
        Raised := True;
    end;
    AssertTrue('a full queue must fail the connect', Raised);
    AssertTrue('the connect returned within the timeout',
      GetTickCount64 - Start <= cTimeoutMs + 200);
  finally
    for I := 0 to Count - 1 do
      fpClose(Fillers[I]);
    fpClose(Holder);
  end;
end;

procedure TUnixSocketTest.TestReadTimeoutRaises;
var
  Sock: TPlainSocket;
  Reply: RawByteString;
  Raised: Boolean;
begin
  FListener := THoldingListener.Create(FPath);
  Reply := '';
  SetLength(Reply, 5);
  Sock := TPlainSocket.CreateUnix(FPath, 2000);
  try
    Sock.SetReadTimeoutMs(200);
    Raised := False;
    try
      Sock.Read(Reply[1], 5);
    except
      on E: EHttpTimeout do
        Raised := True;
    end;
    AssertTrue('a silent peer must time out the read', Raised);
  finally
    Sock.Close;
    Sock.Free;
  end;
end;

procedure TUnixSocketTest.TestCloseIsIdempotent;
var
  Sock: TPlainSocket;
begin
  FListener := TUnixListener.Create(FPath);
  Sock := TPlainSocket.CreateUnix(FPath, 2000);
  Sock.Close;
  Sock.Close;
  AssertFalse('closed socket is not connected', Sock.GetConnected);
  Sock.Free;
end;

procedure TUnixSocketTest.TestWriteToClosedPeerRaisesAndKeepsProcessAlive;
var
  Sock: TPlainSocket;
  Buf: array[0..4095] of Byte;
  I: Integer;
  Raised: Boolean;
begin
  FListener := TClosingListener.Create(FPath);
  FillChar(Buf, SizeOf(Buf), 1);
  Sock := TPlainSocket.CreateUnix(FPath, 2000);
  try
    Raised := False;
    I := 0;
    // the first writes may fit in the buffer before the peer's close arrives
    while (I < 50) and not Raised do
    begin
      Inc(I);
      try
        Sock.Write(Buf, SizeOf(Buf));
      except
        on EHttpConnectionClosed do
          Raised := True;
      end;
    end;
    AssertTrue('a write to a closed peer must raise', Raised);
  finally
    Sock.Close;
    Sock.Free;
  end;
  // reaching this line proves that no SIGPIPE ended the process
end;

initialization
  RegisterTest(TUnixSocketTest);

end.
