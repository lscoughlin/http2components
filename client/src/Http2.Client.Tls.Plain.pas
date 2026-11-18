{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, tls
notes:
  - This unit is part of the imported client transport.
---
}
unit Http2.Client.Tls.Plain;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, Sockets, ssockets, BaseUnix, Http2.Client.Tls.Types;

type
  /// a plain (cleartext) TCP socket over fcl-net's TInetSocket. When a proxy
  /// is configured the TCP connection goes to the proxy and a CONNECT tunnel
  /// to the real target is negotiated first, so every layer above (TLS, h2c,
  /// HTTP/1.1) sees a transparent byte stream to the origin.
  TPlainSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader,
    IPendingInput, IReadInterrupt)
  private
    FSocket: TInetSocket;
    FHandle: Integer;
    /// the two ends of the non-blocking pipe that ends a read early; -1 when off
    FWakeRead: Integer;
    FWakeWrite: Integer;
    FConnected: Boolean;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    procedure WaitReadable;
  public
    constructor Create(const AHost: string; const APort: Word;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs;
      const AProxyHost: string = ''; const AProxyPort: Word = 0);
    /// connects to a Unix socket file; APath is absolute and at most 103 bytes
    // - the socket holds no TInetSocket: the descriptor is FHandle only
    constructor CreateUnix(const APath: string;
      const AConnectTimeoutMs: Integer = cDefaultSocketTimeoutMs);
    destructor Destroy; override;
    /// the underlying OS socket handle (used for proxy handshakes)
    property Handle: Integer read FHandle;
    function Read(var ABuffer; ACount: Integer): Integer;
    function ReadSome(var ABuffer; ACount: Integer): Integer;
    function HasPendingInput: Boolean;
    procedure EnableInterrupt;
    procedure InterruptRead;
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

implementation

uses
  Http2.Client.Errors, Http2.Client.SigPipe,
  Http2.Client.Tls.Tunnel, Http2.Common.UnixPath;

/// fills an address for a socket file; returns the address length
// - the length covers the family, the path bytes and the terminating NUL
function FillUnixAddr(const APath: string; out AAddr: TUnixSockAddr): Integer;
var
  Bytes: RawByteString;
begin
  FillChar(AAddr, SizeOf(AAddr), 0);
  AAddr.family := AF_UNIX;
  Bytes := UTF8Encode(APath);
  Move(Bytes[1], AAddr.path[0], Length(Bytes));
  Result := 2 + Length(Bytes) + 1;
{$IFDEF DARWIN}
  AAddr.sa_len := Byte(Result);
{$ENDIF}
end;

/// the milliseconds left before ADeadline; 0 when the deadline has passed
function MsLeft(const ADeadline: QWord): Integer;
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if Now >= ADeadline then
    Exit(0);
  Result := Integer(ADeadline - Now);
end;

/// waits up to AMs milliseconds for AFd to become writable
function WaitWritable(AFd, AMs: Integer): Boolean;
var
  Pfd: pollfd;
begin
  Pfd.fd := AFd;
  Pfd.events := POLLOUT;
  Pfd.revents := 0;
  Result := fpPoll(@Pfd, 1, AMs) > 0;
end;

/// the pending socket error of AFd (SO_ERROR); 0 when none
function SocketErrorOf(AFd: Integer): Integer;
var
  Len: tsocklen;
begin
  Result := 0;
  Len := SizeOf(Result);
  if fpGetSockOpt(AFd, SOL_SOCKET, SO_ERROR, @Result, @Len) <> 0 then
    Result := fpGetErrno;
end;

/// connects AFd to a socket file within AMs milliseconds
// - a connect that waits on a full queue retries until the deadline
procedure ConnectUnixWithin(AFd: Integer; const APath: string; AMs: Integer);
var
  Addr: TUnixSockAddr;
  AddrLen, Err: Integer;
  Deadline: QWord;
begin
  AddrLen := FillUnixAddr(APath, Addr);
  Deadline := GetTickCount64 + QWord(AMs);
  while True do
  begin
    if fpConnect(AFd, @Addr, AddrLen) = 0 then
      Exit;
    Err := fpGetErrno;
    if Err = ESysEISCONN then
      Exit;
    if Err = ESysEINPROGRESS then
    begin
      if not WaitWritable(AFd, MsLeft(Deadline)) then
        raise EHttpTimeout.CreateFmt('connect timed out after %d ms', [AMs]);
      Err := SocketErrorOf(AFd);
      if Err = 0 then
        Exit;
      raise EHttpConnectionError.CreateFmt(
        'connect to unix socket %s failed: %s', [APath, SysErrorMessage(Err)]);
    end;
    if Err = ESysEAGAIN then
    begin
      if MsLeft(Deadline) = 0 then
        raise EHttpTimeout.CreateFmt('connect timed out after %d ms', [AMs]);
      Sleep(10);
    end
    else if Err <> ESysEINTR then
      raise EHttpConnectionError.CreateFmt(
        'connect to unix socket %s failed: %s', [APath, SysErrorMessage(Err)]);
  end;
end;

/// opens a socket, connects it to a socket file and returns the descriptor
// - the descriptor is blocking again when this function returns
function OpenUnixSocket(const APath: string; AMs: Integer): Integer;
var
  Flags, Opt: Integer;
begin
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    raise EHttpConnectionError.CreateFmt(
      'socket for unix socket %s failed: %s',
      [APath, SysErrorMessage(fpGetErrno)]);
  try
    Opt := 1;
{$IFDEF DARWIN}
    fpSetSockOpt(Result, SOL_SOCKET, SO_NOSIGPIPE, @Opt, SizeOf(Opt));
{$ENDIF}
    Flags := fpFcntl(Result, F_GETFL);
    fpFcntl(Result, F_SETFL, Flags or O_NONBLOCK);
    ConnectUnixWithin(Result, APath, AMs);
    fpFcntl(Result, F_SETFL, Flags);
  except
    fpClose(Result);
    raise;
  end;
end;

constructor TPlainSocket.CreateUnix(const APath: string;
  const AConnectTimeoutMs: Integer);
var
  Problem: string;
begin
  inherited Create;
  FHandle := -1;
  FWakeRead := -1;
  FWakeWrite := -1;
  FConnectTimeoutMs := AConnectTimeoutMs;
  FReadTimeoutMs := cDefaultSocketTimeoutMs;
  FWriteTimeoutMs := cDefaultSocketTimeoutMs;
  Problem := UnixPathProblem(APath);
  if Problem <> '' then
    raise EHttpConnectionError.Create(Problem);
  // the descriptor is assigned only after a successful connect, so a failed
  // constructor never leaves a closed descriptor in FHandle
  FHandle := OpenUnixSocket(APath, AConnectTimeoutMs);
  FConnected := True;
end;

constructor TPlainSocket.Create(const AHost: string; const APort: Word;
  const AConnectTimeoutMs: Integer;
  const AProxyHost: string; const AProxyPort: Word);
var
  opt: LongInt;
  DialHost: string;
  DialPort: Word;
begin
  inherited Create;
  // set first: a failed TInetSocket.Create must not leave 0 (stdin) in FHandle
  FHandle := -1;
  FWakeRead := -1;
  FWakeWrite := -1;
  FConnectTimeoutMs := AConnectTimeoutMs;
  FReadTimeoutMs := cDefaultSocketTimeoutMs;
  FWriteTimeoutMs := cDefaultSocketTimeoutMs;
  // with a proxy the TCP connection goes to the proxy; everything above then
  // talks to the origin through a CONNECT tunnel
  if AProxyHost <> '' then
  begin
    DialHost := AProxyHost;
    DialPort := AProxyPort;
  end
  else
  begin
    DialHost := AHost;
    DialPort := APort;
  end;
  try
    FSocket := TInetSocket.Create(DialHost, DialPort, AConnectTimeoutMs);
  except
    on E: ESocketError do
      if E.Code = seConnectTimeOut then
        raise EHttpTimeout.CreateFmt('connect timed out after %d ms',
          [AConnectTimeoutMs])
      else
        raise EHttpConnectionError.CreateFmt('connect to %s:%d failed: %s',
          [DialHost, DialPort, E.Message]);
  end;
  FHandle := FSocket.Handle;
  FSocket.WriteFlags := cMsgNoSignal;
  FConnected := True;
  opt := 1;
{$IFDEF DARWIN}
  fpSetSockOpt(FHandle, SOL_SOCKET, SO_NOSIGPIPE, @opt, SizeOf(opt));
{$ENDIF}
  if AProxyHost <> '' then
    try
      EstablishProxyTunnelFd(FHandle, AHost, APort, AConnectTimeoutMs, '', '');
    except
      Close;
      raise;
    end;
end;

destructor TPlainSocket.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TPlainSocket.Close;
begin
  // TInetSocket.Free owns the OS close; calling fpClose here as well would
  // close the descriptor twice (and could close an unrelated reused fd)
  if FSocket <> nil then
  begin
    FSocket.Free;
    FSocket := nil;
  end
  else if FHandle >= 0 then
    // a Unix socket has no TInetSocket: this object owns the descriptor
    fpClose(FHandle);
  FHandle := -1;
  FConnected := False;
  if FWakeRead >= 0 then
    fpClose(FWakeRead);
  if FWakeWrite >= 0 then
    fpClose(FWakeWrite);
  FWakeRead := -1;
  FWakeWrite := -1;
end;

procedure TPlainSocket.EnableInterrupt;
var
  Fds: TFilDes;
  I: Integer;
begin
  if FWakeRead >= 0 then
    Exit;
  if fpPipe(Fds) <> 0 then
    Exit;                       // no pipe: the read keeps its timed poll
  for I := 0 to 1 do
  begin
    fpFcntl(Fds[I], F_SETFL, fpFcntl(Fds[I], F_GETFL) or O_NONBLOCK);
    fpFcntl(Fds[I], F_SETFD, FD_CLOEXEC);
  end;
  FWakeWrite := Fds[1];
  FWakeRead := Fds[0];
end;

procedure TPlainSocket.InterruptRead;
var
  Fd: Integer;
  B: Byte;
begin
  Fd := FWakeWrite;
  if Fd < 0 then
    Exit;
  B := 1;
  // a full pipe already holds a wake, so a failed write loses nothing
  fpWrite(Fd, B, 1);
end;

/// waits for input or an interrupt; an interrupt with no input ends as a timeout
procedure TPlainSocket.WaitReadable;
var
  Pfds: array[0..1] of pollfd;
  Skip: array[0..63] of Byte;
  R, Wait: Integer;
begin
  if FWakeRead < 0 then
    Exit;
  Pfds[0].fd := FHandle;
  Pfds[0].events := POLLIN;
  Pfds[1].fd := FWakeRead;
  Pfds[1].events := POLLIN;
  Wait := FReadTimeoutMs;
  if Wait <= 0 then
    Wait := -1;
  repeat
    Pfds[0].revents := 0;
    Pfds[1].revents := 0;
    R := fpPoll(@Pfds[0], 2, Wait);
  until (R >= 0) or (fpGetErrno <> ESysEINTR);
  if R = 0 then
    raise EHttpTimeout.CreateFmt('read timed out after %d ms', [FReadTimeoutMs]);
  if (R > 0) and (Pfds[1].revents <> 0) then
  begin
    while fpRead(FWakeRead, Skip, SizeOf(Skip)) > 0 do;
    if Pfds[0].revents = 0 then
      raise EHttpTimeout.Create('read interrupted');
  end;
end;

function TPlainSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('socket is closed');
  WaitReadable;
  // a timeout after some bytes returns them: the caller reads on, so no
  // consumed byte of a frame is lost
  Result := SocketReadPartial(FHandle, ACount, FReadTimeoutMs, ABuffer);
end;

function TPlainSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
var
  n: ssize_t;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('socket is closed');
  if ACount <= 0 then
    Exit(0);
  WaitReadable;
  SetSocketTimeout(FHandle, SOL_SOCKET, SO_RCVTIMEO, FReadTimeoutMs);
  while True do
  begin
    n := fpRecv(FHandle, @ABuffer, ACount, 0);
    if n >= 0 then
      Exit(n);
    if SocketTimedOut then
      raise EHttpTimeout.CreateFmt('read timed out after %d ms',
        [FReadTimeoutMs])
    else if fpGetErrno <> ESysEINTR then
      raise EHttpConnectionClosed.CreateFmt('socket read failed (errno %d)',
        [fpGetErrno]);
  end;
end;

/// a zero-timeout poll: True when a read would not block (input or end of
// stream is waiting); an unconnected socket reports False
function TPlainSocket.HasPendingInput: Boolean;
var
  Pfd: pollfd;
begin
  Result := False;
  if FHandle < 0 then
    Exit;
  Pfd.fd := FHandle;
  Pfd.events := POLLIN;
  Pfd.revents := 0;
  Result := fpPoll(@Pfd, 1, 0) > 0;
end;

function TPlainSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  if not FConnected then
    raise EHttpConnectionClosed.Create('socket is closed');
  Result := SocketWriteFully(FHandle, ACount, FWriteTimeoutMs, ABuffer);
end;

function TPlainSocket.GetConnected: Boolean;
begin
  Result := FConnected;
end;

function TPlainSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TPlainSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TPlainSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TPlainSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TPlainSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TPlainSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

end.
