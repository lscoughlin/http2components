{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
---
}
unit Http2.Server.Unix.Path.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry;

type
  /// the tests of the path checks, the file mode and the peer text of a Unix listener
  TUnixPathTest = class(TTestCase)
  private
    FPath: string;
    FTarget: string;
    function ListenOn(const APath: string; const ABacklog: Integer): Integer;
    function NewClient: Integer;
    function ConnectOnce(const AFd: Integer; const APath: string): Integer;
    function FillQueue(const APath: string; out AFds: TArray<Integer>): Integer;
    procedure CloseAll(const AFds: TArray<Integer>);
    procedure ConnectedPair(out AClientFd, AServerFd: Integer);
    procedure WriteText(const APath, AText: string);
    function ReadText(const APath: string): string;
    function ModeBits(const APath: string): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestMissingPathIsFree;
    procedure TestRegularFileIsRefused;
    procedure TestDirectoryIsRefused;
    procedure TestLiveSocketIsRefused;
    procedure TestStaleSocketIsAccepted;
    procedure TestBusyListenerIsNotStale;
    procedure TestDeadListenerWithFullQueueIsStale;
    procedure TestSymlinkToFileIsRefused;
    procedure TestStateTextsDiffer;
    procedure TestApplyModeSetsBits;
    procedure TestApplyModeMinusOneChangesNothing;
    procedure TestApplyModeOnMissingPathRaises;
    procedure TestPeerPidOfAConnectedPair;
    procedure TestPeerPidOfClosedDescriptorIsZero;
    procedure TestPeerTextDisabledIsEmpty;
    procedure TestPeerTextHasThePid;
    procedure TestPeerTextWithoutPidIsUnix;
  end;

implementation

uses
  BaseUnix, Sockets, Http2.Server.Errors, Http2.Server.Unix.Path;

type
  /// a thread that accepts one connection on a listener after a short delay
  TAcceptOnceThread = class(TThread)
  private
    FListener: Integer;
    FAccepted: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const AListener: Integer);
    /// the descriptor of the accepted connection, or -1
    property Accepted: Integer read FAccepted;
  end;

var
  GPathCounter: Integer = 0;

/// a new socket path under /tmp; the name is short because sun_path is short
function NewPath: string;
begin
  Inc(GPathCounter);
  Result := Format('/tmp/h2-%d-%d.sock', [fpGetPid, GPathCounter]);
end;

/// the address record of a Unix socket path
function UnixAddr(const APath: string): TUnixSockAddr;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.family := AF_UNIX;
  if APath <> '' then
    Move(APath[1], Result.path[0], Length(APath));
end;

constructor TAcceptOnceThread.Create(const AListener: Integer);
begin
  inherited Create(True);
  FListener := AListener;
  FAccepted := -1;
  Start;
end;

procedure TAcceptOnceThread.Execute;
begin
  Sleep(20);
  FAccepted := fpAccept(FListener, nil, nil);
end;

procedure TUnixPathTest.SetUp;
begin
  FPath := NewPath;
  FTarget := FPath + '.target';
end;

procedure TUnixPathTest.TearDown;
begin
  fpUnlink(FPath);
  fpRmdir(FPath);
  fpUnlink(FTarget);
end;

function TUnixPathTest.ListenOn(const APath: string; const ABacklog: Integer): Integer;
var
  Addr: TUnixSockAddr;
begin
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  AssertTrue('the socket is made', Result >= 0);
  Addr := UnixAddr(APath);
  if fpBind(Result, PSockAddr(@Addr), SizeOf(Addr)) <> 0 then
  begin
    fpClose(Result);
    Fail('the bind of the test socket failed');
  end;
  if fpListen(Result, ABacklog) <> 0 then
  begin
    fpClose(Result);
    Fail('the listen of the test socket failed');
  end;
end;

function TUnixPathTest.NewClient: Integer;
begin
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  AssertTrue('the client socket is made', Result >= 0);
  fpFcntl(Result, F_SETFL, O_NONBLOCK);
end;

function TUnixPathTest.ConnectOnce(const AFd: Integer; const APath: string): Integer;
var
  Addr: TUnixSockAddr;
begin
  Addr := UnixAddr(APath);
  if fpConnect(AFd, PSockAddr(@Addr), SizeOf(Addr)) = 0 then
    Exit(0);
  Result := fpgeterrno;
end;

/// connects until one connect fails; the open client descriptors are returned
function TUnixPathTest.FillQueue(const APath: string; out AFds: TArray<Integer>): Integer;
var
  Fd, Err: Integer;
begin
  SetLength(AFds, 0);
  while Length(AFds) < 400 do
  begin
    Fd := NewClient;
    Err := ConnectOnce(Fd, APath);
    if (Err <> 0) and (Err <> ESysEINPROGRESS) then
    begin
      fpClose(Fd);
      Break;
    end;
    SetLength(AFds, Length(AFds) + 1);
    AFds[High(AFds)] := Fd;
  end;
  Result := Length(AFds);
end;

procedure TUnixPathTest.CloseAll(const AFds: TArray<Integer>);
var
  I: Integer;
begin
  for I := 0 to High(AFds) do
    fpClose(AFds[I]);
end;

/// a connected pair; the client is a blocking socket, the server end is accepted
procedure TUnixPathTest.ConnectedPair(out AClientFd, AServerFd: Integer);
var
  Listener: Integer;
begin
  Listener := ListenOn(FPath, 8);
  try
    AClientFd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
    AssertTrue('the client socket is made', AClientFd >= 0);
    AssertEquals('the client connects', 0, ConnectOnce(AClientFd, FPath));
    AServerFd := fpAccept(Listener, nil, nil);
    AssertTrue('the server end is accepted', AServerFd >= 0);
  finally
    fpClose(Listener);
  end;
end;

procedure TUnixPathTest.WriteText(const APath, AText: string);
var
  S: TFileStream;
begin
  S := TFileStream.Create(APath, fmCreate);
  try
    if AText <> '' then
      S.WriteBuffer(AText[1], Length(AText));
  finally
    S.Free;
  end;
end;

function TUnixPathTest.ReadText(const APath: string): string;
var
  S: TFileStream;
begin
  S := TFileStream.Create(APath, fmOpenRead);
  try
    SetLength(Result, S.Size);
    if S.Size > 0 then
      S.ReadBuffer(Result[1], S.Size);
  finally
    S.Free;
  end;
end;

function TUnixPathTest.ModeBits(const APath: string): Integer;
var
  St: Stat;
begin
  AssertTrue('the path can be read', fpStat(APath, St) = 0);
  Result := Integer(St.st_mode and $1FF);
end;

procedure TUnixPathTest.TestMissingPathIsFree;
begin
  AssertTrue(CheckUnixPath(FPath) = upFree);
end;

procedure TUnixPathTest.TestRegularFileIsRefused;
begin
  WriteText(FPath, 'keep me');
  AssertTrue(CheckUnixPath(FPath) = upNotSocket);
  AssertEquals('the file keeps its bytes', 'keep me', ReadText(FPath));
end;

procedure TUnixPathTest.TestDirectoryIsRefused;
begin
  AssertTrue('the directory is made', CreateDir(FPath));
  AssertTrue(CheckUnixPath(FPath) = upNotSocket);
  AssertTrue('the directory stays', DirectoryExists(FPath));
end;

procedure TUnixPathTest.TestLiveSocketIsRefused;
var
  Listener: Integer;
begin
  Listener := ListenOn(FPath, 8);
  try
    AssertTrue(CheckUnixPath(FPath) = upInUse);
  finally
    fpClose(Listener);
  end;
end;

procedure TUnixPathTest.TestStaleSocketIsAccepted;
begin
  fpClose(ListenOn(FPath, 8));
  AssertTrue('the socket file stays after the close', FileExists(FPath));
  AssertTrue(CheckUnixPath(FPath) = upStale);
end;

procedure TUnixPathTest.TestBusyListenerIsNotStale;
var
  Listener: Integer;
  Fds: TArray<Integer>;
  Accepter: TAcceptOnceThread;
begin
  Listener := ListenOn(FPath, 0);
  try
    AssertTrue('the queue fills', FillQueue(FPath, Fds) > 0);
    AssertTrue('the queue is full before the limit', Length(Fds) < 400);
    Accepter := TAcceptOnceThread.Create(Listener);
    try
      AssertTrue('the second probe finds a live listener', CheckUnixPath(FPath) = upInUse);
    finally
      Accepter.WaitFor;
      if Accepter.Accepted >= 0 then
        fpClose(Accepter.Accepted);
      Accepter.Free;
    end;
  finally
    CloseAll(Fds);
    fpClose(Listener);
  end;
end;

procedure TUnixPathTest.TestDeadListenerWithFullQueueIsStale;
var
  Listener: Integer;
  Fds: TArray<Integer>;
begin
  Listener := ListenOn(FPath, 0);
  try
    AssertTrue('the queue fills', FillQueue(FPath, Fds) > 0);
    AssertTrue('the queue is full before the limit', Length(Fds) < 400);
    {$IFDEF DARWIN}
    // macOS answers ECONNREFUSED to a full queue, so the path looks stale (F23)
    AssertTrue('a full queue on macOS looks stale', CheckUnixPath(FPath) = upStale);
    {$ELSE}
    // Linux answers EAGAIN to a full queue, so the path is judged in use
    AssertTrue('a full queue on Linux looks in use', CheckUnixPath(FPath) = upInUse);
    {$ENDIF}
  finally
    CloseAll(Fds);
    fpClose(Listener);
  end;
end;

procedure TUnixPathTest.TestSymlinkToFileIsRefused;
begin
  WriteText(FTarget, 'target');
  AssertEquals('the symlink is made', 0, fpSymlink(PChar(FTarget), PChar(FPath)));
  AssertTrue(CheckUnixPath(FPath) = upNotSocket);
  AssertEquals('the target keeps its bytes', 'target', ReadText(FTarget));
end;

procedure TUnixPathTest.TestStateTextsDiffer;
begin
  AssertEquals('a free path has no text', '', UnixStateProblem(upFree));
  AssertEquals('a stale path has no text', '', UnixStateProblem(upStale));
  AssertTrue(UnixStateProblem(upNotSocket) <> '');
  AssertTrue(UnixStateProblem(upInUse) <> '');
  AssertTrue(UnixStateProblem(upUnreadable) <> '');
  AssertTrue(UnixStateProblem(upNotSocket) <> UnixStateProblem(upInUse));
  AssertTrue(UnixStateProblem(upInUse) <> UnixStateProblem(upUnreadable));
  AssertEquals('the text holds no path', 0, Pos('/', UnixStateProblem(upInUse)));
end;

procedure TUnixPathTest.TestApplyModeSetsBits;
begin
  WriteText(FPath, 'x');
  ApplyUnixSocketMode(FPath, $180);
  AssertEquals('the mode is 0600', $180, ModeBits(FPath));
end;

procedure TUnixPathTest.TestApplyModeMinusOneChangesNothing;
var
  Before: Integer;
begin
  WriteText(FPath, 'x');
  AssertEquals('the file mode is set', 0, fpChmod(FPath, $1A4));
  Before := ModeBits(FPath);
  ApplyUnixSocketMode(FPath, -1);
  AssertEquals('the mode is kept', Before, ModeBits(FPath));
end;

procedure TUnixPathTest.TestApplyModeOnMissingPathRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    ApplyUnixSocketMode(FPath, $180);
  except
    on EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('a missing path raises', Raised);
end;

procedure TUnixPathTest.TestPeerPidOfAConnectedPair;
var
  ClientFd, ServerFd: Integer;
begin
  ConnectedPair(ClientFd, ServerFd);
  try
    AssertEquals('the peer is this process', Integer(fpGetPid), UnixPeerPid(ServerFd));
  finally
    fpClose(ClientFd);
    fpClose(ServerFd);
  end;
end;

procedure TUnixPathTest.TestPeerPidOfClosedDescriptorIsZero;
begin
  AssertEquals(0, UnixPeerPid(-1));
end;

procedure TUnixPathTest.TestPeerTextDisabledIsEmpty;
begin
  AssertEquals('', UnixPeerText(False, 5));
end;

procedure TUnixPathTest.TestPeerTextHasThePid;
var
  ClientFd, ServerFd: Integer;
begin
  ConnectedPair(ClientFd, ServerFd);
  try
    AssertEquals('unix:pid=' + IntToStr(fpGetPid), UnixPeerText(True, ServerFd));
  finally
    fpClose(ClientFd);
    fpClose(ServerFd);
  end;
end;

procedure TUnixPathTest.TestPeerTextWithoutPidIsUnix;
begin
  AssertEquals('unix', UnixPeerText(True, -1));
end;

initialization
  RegisterTest(TUnixPathTest);

end.
