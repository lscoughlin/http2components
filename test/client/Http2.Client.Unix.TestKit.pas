{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - This unit is a plain unit. It holds the listener and the helpers that the
    Unix socket tests share.
---
}
unit Http2.Client.Unix.TestKit;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets;

/// a new socket file path for one test, '/tmp/h2-<pid>-<counter>.sock'
// - the path is short, because sun_path holds at most 103 bytes
function NewUnixTestPath: string;

/// fills an address for a socket file; returns the address length
function UnixSockAddrOf(const APath: string; out AAddr: TUnixSockAddr): Integer;

/// binds and listens on a socket file; the caller closes the descriptor
// - the caller does not accept, so a full queue stays full
function ListenUnixSocket(const APath: string; ABacklog: Integer): Integer;

/// a non-blocking connect to a socket file; -1 when it fails at once
// - the caller closes a descriptor that is not -1
function NonBlockingConnectUnix(const APath: string): Integer;

/// sends the bytes of AText on a descriptor; stops at the first error
procedure WriteAll(AFd: Integer; const AText: RawByteString);

/// reads until the peer closes or the timeout expires; returns what arrived
function ReadAll(AFd, ATimeoutMs: Integer): RawByteString;

type
  /// a listener on a socket file. It accepts on its own thread and calls
  /// Serve once for each accepted connection.
  TUnixListener = class(TThread)
  private
    FPath: string;
    FListenFd: Integer;
    FAccepted: Integer;
    FFirstByte: Integer;
  protected
    procedure Execute; override;
  public
    /// binds and listens before it returns, so a client can connect at once
    constructor Create(const APath: string; ABacklog: Integer = 8);
    destructor Destroy; override;
    /// serves one accepted connection; the default echoes until the peer closes
    procedure Serve(AFd: Integer); virtual;
    /// stops the accept loop, closes the listener and removes the path
    // - Stop may be called more than once
    procedure Stop;
    /// the socket file path of this listener
    property Path: string read FPath;
    /// the number of accepted connections
    property Accepted: Integer read FAccepted;
    /// the first byte that the default Serve read, -1 before any byte
    property FirstByte: Integer read FFirstByte;
  end;

implementation

uses
  Http2.Client.SigPipe;

var
  GUnixPathCounter: LongInt = 0;

function NewUnixTestPath: string;
begin
  Result := '/tmp/h2-' + IntToStr(fpGetPid) + '-' +
    IntToStr(InterlockedIncrement(GUnixPathCounter)) + '.sock';
end;

function UnixSockAddrOf(const APath: string; out AAddr: TUnixSockAddr): Integer;
var
  Bytes: RawByteString;
begin
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.family := AF_UNIX;
  Bytes := UTF8Encode(APath);
  Move(Bytes[1], AAddr.path[0], Length(Bytes));
  // the length covers the family and the path with its terminating NUL
  Result := 2 + Length(Bytes) + 1;
{$IFDEF DARWIN}
  AAddr.sa_len := Result;
{$ENDIF}
end;

function ListenUnixSocket(const APath: string; ABacklog: Integer): Integer;
var
  Addr: TUnixSockAddr;
  Len: Integer;
begin
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    raise Exception.CreateFmt('socket failed (errno %d)', [fpGetErrno]);
  Len := UnixSockAddrOf(APath, Addr);
  if fpBind(Result, @Addr, Len) <> 0 then
  begin
    fpClose(Result);
    raise Exception.CreateFmt('bind to %s failed (errno %d)',
      [APath, fpGetErrno]);
  end;
  if fpListen(Result, ABacklog) <> 0 then
  begin
    fpClose(Result);
    raise Exception.CreateFmt('listen on %s failed (errno %d)',
      [APath, fpGetErrno]);
  end;
end;

function NonBlockingConnectUnix(const APath: string): Integer;
var
  Addr: TUnixSockAddr;
  Len, Flags: Integer;
begin
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    Exit(-1);
  Flags := fpFcntl(Result, F_GETFL);
  fpFcntl(Result, F_SETFL, Flags or O_NONBLOCK);
  Len := UnixSockAddrOf(APath, Addr);
  if fpConnect(Result, @Addr, Len) <> 0 then
  begin
    fpClose(Result);
    Exit(-1);
  end;
end;

procedure SendBytes(AFd: Integer; ABuffer: PByte; ACount: Integer);
var
  N: Integer;
begin
  while ACount > 0 do
  begin
    N := fpSend(AFd, ABuffer, ACount, cMsgNoSignal);
    if N > 0 then
    begin
      Inc(ABuffer, N);
      Dec(ACount, N);
    end
    else if fpGetErrno <> ESysEINTR then
      Exit;
  end;
end;

procedure WriteAll(AFd: Integer; const AText: RawByteString);
begin
  if AText <> '' then
    SendBytes(AFd, PByte(@AText[1]), Length(AText));
end;

function ReadAll(AFd, ATimeoutMs: Integer): RawByteString;
var
  Pfd: pollfd;
  Buf: array[0..1023] of Byte;
  N, Old: Integer;
  Left: Integer;
  Start: QWord;
begin
  Result := '';
  Left := ATimeoutMs;
  Start := GetTickCount64;
  while Left > 0 do
  begin
    Pfd.fd := AFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    if fpPoll(@Pfd, 1, Left) <= 0 then
      Break;
    N := fpRecv(AFd, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then
      Break;
    Old := Length(Result);
    SetLength(Result, Old + N);
    Move(Buf[0], Result[Old + 1], N);
    Left := ATimeoutMs - Integer(GetTickCount64 - Start);
  end;
end;

{ TUnixListener }

constructor TUnixListener.Create(const APath: string; ABacklog: Integer);
begin
  // suspended, so the thread starts only after the listener is bound
  inherited Create(True);
  FFirstByte := -1;
  FListenFd := -1;
  // FPath is set only after the bind succeeds, so Stop never removes a
  // file that this listener did not bind
  FListenFd := ListenUnixSocket(APath, ABacklog);
  FPath := APath;
  Resume;
end;

destructor TUnixListener.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TUnixListener.Execute;
var
  Pfd: pollfd;
  Conn: Integer;
begin
  while not Terminated do
  begin
    Pfd.fd := FListenFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    // a short poll lets the loop see Terminated
    if fpPoll(@Pfd, 1, 50) <= 0 then
      Continue;
    Conn := fpAccept(FListenFd, nil, nil);
    if Conn < 0 then
      Continue;
    InterlockedIncrement(FAccepted);
    try
      Serve(Conn);
    finally
      fpClose(Conn);
    end;
  end;
end;

procedure TUnixListener.Serve(AFd: Integer);
var
  Buf: array[0..1023] of Byte;
  N: Integer;
begin
  while True do
  begin
    N := fpRecv(AFd, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then
      Break;
    if FFirstByte < 0 then
      FFirstByte := Buf[0];
    SendBytes(AFd, @Buf[0], N);
  end;
end;

procedure TUnixListener.Stop;
begin
  if Suspended then
    Resume;
  Terminate;
  WaitFor;
  if FListenFd >= 0 then
  begin
    fpClose(FListenFd);
    FListenFd := -1;
  end;
  if (FPath <> '') and FileExists(FPath) then
    DeleteFile(FPath);
end;

end.
