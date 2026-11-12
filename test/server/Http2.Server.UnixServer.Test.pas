{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, bind, path check, cleanup, test, fpcunit
notes:
  - This unit tests the bind of a Unix socket listener, the path check before the
    bind, and the removal of the socket file on Stop.
  - Each test uses a path under /tmp that TearDown removes.
---
}
unit Http2.Server.UnixServer.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads, BaseUnix, Sockets,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server, Http2.Server.Errors, Http2.Server.Http1.RawClient,
  Http2.Server.Unix.TestKit;

type
  /// the tests of a Unix socket listener on a running server
  TUnixServerTest = class(TTestCase)
  private
    FPath: string;
    FHandler: IHttp2Handler;
    FServer: IHttp2Server;
    function Factory(const APath: string): THttp2ServerFactory;
    procedure StartServer(const APath: string);
    procedure TryBuild(const APath: string; out ARefused: Boolean);
    function GetOverUnix(const APath: string): string;
    procedure WriteFile(const APath, AText: string);
    function ReadFile(const APath: string): string;
    procedure MakeStaleSocket(const APath: string);
    procedure AssertAnswersHi(const AAnswer: string);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSocketFileExistsAfterStart;
    procedure TestHttp11GetOverUnix;
    procedure TestFileRemovedAfterStop;
    procedure TestBuildRefusesRegularFile;
    procedure TestBuildRefusesLiveSocket;
    procedure TestStartReplacesStaleSocket;
    procedure TestPathOf103BytesBinds;
    procedure TestStopWithOpenConnection;
    procedure TestTcpStillWorks;
  end;

implementation

type
  /// a handler that answers every request with the body hi
  THiHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

const
  CRLF2 = #13#10#13#10;

procedure THiHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  H: THeaderBlock;
  Body: TBytes;
begin
  SetLength(H, 1);
  H[0].Name := 'content-length';
  H[0].Value := '2';
  SetLength(Body, 2);
  Body[0] := Ord('h');
  Body[1] := Ord('i');
  AResponse.SendHeaders(200, H, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

procedure TUnixServerTest.SetUp;
begin
  FPath := NewUnixTestPath;
  FHandler := THiHandler.Create;
end;

procedure TUnixServerTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandler := nil;
  if FPath <> '' then
    DeleteFile(FPath);
end;

function TUnixServerTest.Factory(const APath: string): THttp2ServerFactory;
begin
  Result := THttp2ServerFactory.Create
    .WithUnixSocket(APath)
    .WithClearTextAllowed(True)
    .WithHttp11Fallback(True)
    .WithHandler(FHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500);
end;

procedure TUnixServerTest.StartServer(const APath: string);
var
  LFactory: THttp2ServerFactory;
begin
  LFactory := Factory(APath);
  FServer := LFactory.Build;
  FServer.Start;
end;

procedure TUnixServerTest.TryBuild(const APath: string; out ARefused: Boolean);
var
  LFactory: THttp2ServerFactory;
  LServer: IHttp2Server;
begin
  ARefused := False;
  LFactory := Factory(APath);
  try
    LServer := LFactory.Build;
    LServer := nil;
  except
    on E: EHttpConnectionError do
      ARefused := True;
  end;
end;

function TUnixServerTest.GetOverUnix(const APath: string): string;
var
  Fd: Integer;
begin
  Fd := UnixConnect(APath, 2000);
  AssertTrue('the socket accepts a connect', Fd >= 0);
  try
    UnixSend(Fd, 'GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
      'Connection: close' + CRLF + CRLF);
    Result := string(UnixReadAll(Fd, 3000));
  finally
    UnixClose(Fd);
  end;
end;

procedure TUnixServerTest.AssertAnswersHi(const AAnswer: string);
begin
  AssertTrue('a 200 status line: ' + AAnswer, Pos('HTTP/1.1 200', AAnswer) = 1);
  AssertTrue('the body hi: ' + AAnswer, Pos(CRLF2 + 'hi', AAnswer) > 0);
end;

procedure TUnixServerTest.WriteFile(const APath, AText: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then
      F.WriteBuffer(AText[1], Length(AText));
  finally
    F.Free;
  end;
end;

function TUnixServerTest.ReadFile(const APath: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

procedure TUnixServerTest.MakeStaleSocket(const APath: string);
{$IFDEF UNIX}
var
  Fd: Integer;
  Addr: TUnixSockAddr;
begin
  // a listener that is closed without an unlink leaves the socket file behind
  Fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  AssertTrue('the socket is made', Fd >= 0);
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.family := AF_UNIX;
  Move(APath[1], Addr.path[0], Length(APath));
  AssertTrue('the bind succeeds', fpBind(Fd, PSockAddr(@Addr), SizeOf(Addr)) = 0);
  AssertTrue('the listen succeeds', fpListen(Fd, 1) = 0);
  fpClose(Fd);
end;
{$ELSE}
begin
  Fail('Unix sockets are not supported on this target');
end;
{$ENDIF}

procedure TUnixServerTest.TestSocketFileExistsAfterStart;
begin
  StartServer(FPath);
  AssertTrue('the path is a socket file', UnixPathIsSocket(FPath));
end;

procedure TUnixServerTest.TestHttp11GetOverUnix;
begin
  StartServer(FPath);
  AssertAnswersHi(GetOverUnix(FPath));
end;

procedure TUnixServerTest.TestFileRemovedAfterStop;
begin
  StartServer(FPath);
  AssertTrue('the file exists while the server runs', UnixPathExists(FPath));
  FServer.Stop;
  FServer := nil;
  AssertFalse('the file is removed on Stop', UnixPathExists(FPath));
end;

procedure TUnixServerTest.TestBuildRefusesRegularFile;
var
  Refused: Boolean;
begin
  WriteFile(FPath, 'keep me');
  TryBuild(FPath, Refused);
  AssertTrue('Build refuses a regular file', Refused);
  AssertEquals('the file keeps its bytes', 'keep me', ReadFile(FPath));
end;

procedure TUnixServerTest.TestBuildRefusesLiveSocket;
var
  Refused: Boolean;
begin
  StartServer(FPath);
  TryBuild(FPath, Refused);
  AssertTrue('Build refuses a live socket', Refused);
  AssertAnswersHi(GetOverUnix(FPath));
end;

procedure TUnixServerTest.TestStartReplacesStaleSocket;
begin
  MakeStaleSocket(FPath);
  AssertTrue('the stale socket file exists', UnixPathIsSocket(FPath));
  StartServer(FPath);
  AssertAnswersHi(GetOverUnix(FPath));
end;

procedure TUnixServerTest.TestPathOf103BytesBinds;
begin
  FPath := NewUnixTestPathOfLength(103);
  AssertEquals('the path is 103 bytes', 103, Length(FPath));
  StartServer(FPath);
  AssertAnswersHi(GetOverUnix(FPath));
end;

procedure TUnixServerTest.TestStopWithOpenConnection;
var
  Fd: Integer;
begin
  StartServer(FPath);
  Fd := UnixConnect(FPath, 2000);
  AssertTrue('the socket accepts a connect', Fd >= 0);
  try
    UnixSend(Fd, 'GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF);
    FServer.Stop;
    FServer := nil;
    AssertFalse('the file is gone after Stop with an open connection',
      UnixPathExists(FPath));
  finally
    UnixClose(Fd);
  end;
end;

procedure TUnixServerTest.TestTcpStillWorks;
var
  LFactory: THttp2ServerFactory;
  C: TRawHttp;
  R: TRawResponse;
begin
  LFactory := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(0)
    .WithClearTextAllowed(True)
    .WithHttp11Fallback(True)
    .WithHandler(FHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500);
  FServer := LFactory.Build;
  FServer.Start;
  AssertTrue('the TCP port is set', FServer.Port > 0);
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send('GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
      'Connection: close' + CRLF + CRLF);
    AssertTrue('a TCP response', C.ReadResponse(False, ResponseMs, R));
    AssertEquals(200, R.Status);
    AssertEquals('hi', R.Body);
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TUnixServerTest);

end.
