{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, async, socket, tcp, keep-alive
notes:
  - This unit applies the factory socket options to an accepted socket.
  - Each option is guarded, so the failure of one never closes a good
    connection.
---
}
/// The socket options of an accepted connection
// - ApplySocketOptions runs in AfterCreate, before the first read
unit Http2.Server.Async.Socket;

{$mode delphi}{$H+}

interface

uses
  mormot.net.sock,
  Http2.Server.Config.Socket;

/// apply the socket options to one accepted socket
// - the chosen value is always set, on or off, because mORMot2 leaves an
//   accepted async socket at the operating system defaults
// - a buffer size of 0 keeps the operating system default
// - an idle time of 0 leaves keep-alive off
// - AUnix is True for a Unix socket: the TCP options are skipped, and the
//   buffer sizes still apply
procedure ApplySocketOptions(const ASocket: TNetSocket;
  const AOptions: TSocketOptions; const AUnix: Boolean);
/// set SO_LINGER to zero for an aborted socket
// - the peer may have reset the socket, and then the option fails (EINVAL on
//   macOS); the failure is ignored, so the close and its cleanup still run
procedure AbortLinger(const ASocket: TNetSocket);
/// read bytes still queued in the kernel TCP send queue when supported
// - the result is false on platforms without the Linux TIOCOUTQ query
function TryGetSocketSendQueue(const ASocket: TNetSocket;
  out ABytes: Int64): Boolean;

implementation

uses
  {$IFDEF UNIX}Sockets, BaseUnix,{$ENDIF}
  SysUtils;

{$IFDEF UNIX}
// the TCP keep-alive knobs, one set per platform
// - the values match mormot.net.sock.posix.inc, read 2026-11-06
{$IFDEF DARWIN}
const
  cTcpKeepIdle = $10;
  cTcpKeepIntvl = $101;
  cTcpKeepCnt = $102;
{$ELSE} {$IFDEF FREEBSD}
const
  cTcpKeepIdle = 256;
  cTcpKeepIntvl = 512;
  cTcpKeepCnt = 1024;
{$ELSE}
const
  cTcpKeepIdle = 4;
  cTcpKeepIntvl = 5;
  cTcpKeepCnt = 6;
{$ENDIF} {$ENDIF}
{$ENDIF}

/// enable keep-alive with the exact idle time, interval and count
// - SO_KEEPALIVE turns the probes on, and the three TCP knobs tune them
// - each call is raw, so a platform without one knob keeps the rest
procedure ApplyKeepAlive(const ASocket: TNetSocket;
  const AIdle, AInterval, ACount: Integer);
{$IFDEF UNIX}
var
  Fd: TSocket;
  Enable: Integer;
  Value: Integer;
begin
  if AIdle <= 0 then
    exit;
  Fd := TSocket(ASocket.Socket);
  Enable := 1;
  if fpsetsockopt(Fd, SOL_SOCKET, SO_KEEPALIVE, @Enable,
    SizeOf(Enable)) <> 0 then
    exit;
  Value := AIdle;
  if fpsetsockopt(Fd, IPPROTO_TCP, cTcpKeepIdle, @Value,
    SizeOf(Value)) <> 0 then
    exit;
  Value := AInterval;
  fpsetsockopt(Fd, IPPROTO_TCP, cTcpKeepIntvl, @Value, SizeOf(Value));
  Value := ACount;
  fpsetsockopt(Fd, IPPROTO_TCP, cTcpKeepCnt, @Value, SizeOf(Value));
end;
{$ELSE}
begin
  if AIdle <= 0 then
    exit;
  // mORMot2 maps the seconds to its own idle, interval and count values on
  // this platform, so the interval and the count are approximate here
  try
    ASocket.SetKeepAlive(cardinal(AIdle) * 2);
  except
    on ENetSock do
      ; // keep-alive stays off, and the connection still proceeds
  end;
end;
{$ENDIF}

procedure AbortLinger(const ASocket: TNetSocket);
begin
  try
    ASocket.SetLinger(0);
  except
    on ENetSock do
      ; // the socket keeps its linger value
  end;
end;

procedure ApplySocketOptions(const ASocket: TNetSocket;
  const AOptions: TSocketOptions; const AUnix: Boolean);
begin
  if not AUnix then
  begin
    try
      ASocket.SetNoDelay(AOptions.TcpNoDelay);
    except
      on ENetSock do
        ; // Nagle keeps its default, and the connection still proceeds
    end;
    ApplyKeepAlive(ASocket, AOptions.KeepAliveIdleSec,
      AOptions.KeepAliveIntervalSec, AOptions.KeepAliveCount);
  end;
  if AOptions.SendBufferBytes > 0 then
  try
    ASocket.SendBufferSize := AOptions.SendBufferBytes;
  except
    on ENetSock do
      ; // the send buffer keeps its default, and the connection proceeds
  end;
  if AOptions.RecvBufferBytes > 0 then
  try
    ASocket.RecvBufferSize := AOptions.RecvBufferBytes;
  except
    on ENetSock do
      ; // the receive buffer keeps its default, and the connection proceeds
  end;
end;

function TryGetSocketSendQueue(const ASocket: TNetSocket;
  out ABytes: Int64): Boolean;
{$IFDEF LINUX}
var
  QueueBytes: cint;
{$ENDIF}
begin
  ABytes := 0;
  Result := False;
  {$IFDEF LINUX}
  if ASocket = nil then
    Exit;
  QueueBytes := 0;
  // Linux TIOCOUTQ returns bytes sent to the socket but not yet acknowledged.
  Result := fpIOCtl(cint(ASocket.Socket), $5411, @QueueBytes) = 0;
  if Result then
    ABytes := QueueBytes;
  {$ENDIF}
end;

end.
