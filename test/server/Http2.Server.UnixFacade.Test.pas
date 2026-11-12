{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit tests the public server facade for a Unix socket listener.
  - It covers the file mode, the port answer and the socket path text.
  - Each test uses a path under /tmp that TearDown removes.
---
}
unit Http2.Server.UnixFacade.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads, BaseUnix, Sockets,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server, Http2.Server.Unix.TestKit;

type
  /// the tests of the public server facade for a Unix socket listener
  TUnixFacadeTest = class(TTestCase)
  private
    FPath: string;
    FHandler: IHttp2Handler;
    FServer: IHttp2Server;
    function Factory(const APath: string): THttp2ServerFactory;
    procedure StartServer(const APath: string; const AMode: Integer);
    function ModeBits(const APath: string): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestModeIsApplied;
    procedure TestModeMinusOneKeepsTheUmask;
    procedure TestPortAnswersZero;
    procedure TestUnixSocketPathIsTheFactoryPath;
    procedure TestUnixSocketPathIsEmptyForTcp;
  end;

implementation

type
  /// a handler that answers every request with the body hi
  THiFacadeHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure THiFacadeHandler.Handle(const ARequest: IServerRequest;
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

procedure TUnixFacadeTest.SetUp;
begin
  FPath := NewUnixTestPath;
  FHandler := THiFacadeHandler.Create;
end;

procedure TUnixFacadeTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandler := nil;
  if FPath <> '' then
    DeleteFile(FPath);
end;

function TUnixFacadeTest.Factory(const APath: string): THttp2ServerFactory;
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

procedure TUnixFacadeTest.StartServer(const APath: string; const AMode: Integer);
var
  LFactory: THttp2ServerFactory;
begin
  LFactory := Factory(APath).WithUnixSocketMode(AMode);
  FServer := LFactory.Build;
  FServer.Start;
end;

function TUnixFacadeTest.ModeBits(const APath: string): Integer;
{$IFDEF UNIX}
var
  St: Stat;
{$ENDIF}
begin
{$IFDEF UNIX}
  AssertTrue('the path can be read', fpStat(APath, St) = 0);
  Result := Integer(St.st_mode and $1FF);
{$ELSE}
  Result := 0;
  Fail('Unix sockets are not supported on this target');
{$ENDIF}
end;

procedure TUnixFacadeTest.TestModeIsApplied;
begin
  StartServer(FPath, $180);
  AssertEquals('the socket file has mode 0600', $180, ModeBits(FPath));
end;

procedure TUnixFacadeTest.TestModeMinusOneKeepsTheUmask;
{$IFDEF UNIX}
var
  Ref: string;
  Fd: Integer;
  Addr: TUnixSockAddr;
  Expected: Integer;
  OldUmask: TMode;
{$ENDIF}
begin
{$IFDEF UNIX}
  // a plain bind under a strict umask gives the reference mode; -1 must match it
  OldUmask := fpUmask(TMode($077));
  try
    Ref := NewUnixTestPath;
    Fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    AssertTrue('the reference socket is made', Fd >= 0);
    try
      FillChar(Addr, SizeOf(Addr), 0);
      Addr.family := AF_UNIX;
      Move(Ref[1], Addr.path[0], Length(Ref));
      AssertTrue('the reference bind succeeds',
        fpBind(Fd, PSockAddr(@Addr), SizeOf(Addr)) = 0);
    finally
      fpClose(Fd);
    end;
    Expected := ModeBits(Ref);
    DeleteFile(Ref);
    StartServer(FPath, -1);
    AssertEquals('the umask sets the same mode', Expected, ModeBits(FPath));
  finally
    fpUmask(OldUmask);
  end;
{$ELSE}
  Fail('Unix sockets are not supported on this target');
{$ENDIF}
end;

procedure TUnixFacadeTest.TestPortAnswersZero;
begin
  StartServer(FPath, -1);
  AssertEquals('the Unix listener has no port', 0, FServer.Port);
end;

procedure TUnixFacadeTest.TestUnixSocketPathIsTheFactoryPath;
begin
  StartServer(FPath, -1);
  AssertEquals('the path is the factory path', FPath, FServer.UnixSocketPath);
end;

procedure TUnixFacadeTest.TestUnixSocketPathIsEmptyForTcp;
var
  LFactory: THttp2ServerFactory;
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
  AssertEquals('a TCP listener has no socket path', '', FServer.UnixSocketPath);
end;

initialization
  RegisterTest(TUnixFacadeTest);

end.
