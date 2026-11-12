{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, path check
notes:
  - This unit holds the path checks, the mode and the peer text of a Unix listener.
---
}
unit Http2.Server.Unix.Path;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

type
  /// the state of a socket file path before a Unix listener binds it
  TUnixPathState = (upFree, upStale, upNotSocket, upInUse, upUnreadable);

/// the state of APath; the path is read, never changed
function CheckUnixPath(const APath: string): TUnixPathState;

/// the text of the refusal for AState; empty for upFree and upStale
function UnixStateProblem(const AState: TUnixPathState): string;

/// sets the file mode of the socket file at APath; -1 leaves the mode alone
procedure ApplyUnixSocketMode(const APath: string; const AMode: Integer);

/// the pid of the peer of the connected Unix socket AFd, or 0 when it is not known
function UnixPeerPid(const AFd: Integer): Integer;

/// the remote address text of a Unix connection; empty when AEnabled is False
function UnixPeerText(const AEnabled: Boolean; const AFd: Integer): string;

implementation

uses
  {$IFDEF UNIX}BaseUnix, Sockets,{$ENDIF}
  SysUtils, Http2.Server.Errors;

const
  cProbeCount = 3;
  cProbeGapMs = 50;

{$IFDEF UNIX}
/// one connect attempt to the socket at APath; 0 when it succeeds, else the errno
function ProbeConnect(const APath: string): cint;
var
  Fd: cint;
  Addr: TUnixSockAddr;
begin
  if Length(APath) >= SizeOf(Addr.path) then
    Exit(ESysENAMETOOLONG);
  Fd := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Fd < 0 then
    Exit(fpgeterrno);
  try
    fpFcntl(Fd, F_SETFL, O_NONBLOCK);
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.family := AF_UNIX;
    if APath <> '' then
      Move(APath[1], Addr.path[0], Length(APath));
    if fpConnect(Fd, PSockAddr(@Addr), SizeOf(Addr)) = 0 then
      Result := 0
    else
      Result := fpgeterrno;
  finally
    fpClose(Fd);
  end;
end;

/// the state of a path that is a socket file; the probes decide live or stale
function ProbeSocketState(const APath: string): TUnixPathState;
var
  Attempt: Integer;
  Err: cint;
begin
  for Attempt := 1 to cProbeCount do
  begin
    Err := ProbeConnect(APath);
    if (Err = 0) or (Err = ESysEAGAIN) or (Err = ESysEINPROGRESS) then
      Exit(upInUse);
    if Err <> ESysECONNREFUSED then
      Exit(upUnreadable);
    if Attempt < cProbeCount then
      Sleep(cProbeGapMs);
  end;
  Result := upStale;
end;

function CheckUnixPathOnUnix(const APath: string): TUnixPathState;
var
  St: Stat;
begin
  if fpLStat(APath, St) <> 0 then
  begin
    if fpgeterrno = ESysENOENT then
      Exit(upFree);
    Exit(upUnreadable);
  end;
  if not fpS_ISSOCK(St.st_mode) then
    Exit(upNotSocket);
  Result := ProbeSocketState(APath);
end;
{$ENDIF}

function CheckUnixPath(const APath: string): TUnixPathState;
begin
{$IFDEF UNIX}
  Result := CheckUnixPathOnUnix(APath);
{$ELSE}
  Result := upUnreadable;
{$ENDIF}
end;

function UnixStateProblem(const AState: TUnixPathState): string;
begin
  case AState of
    upNotSocket:
      Result := 'the Unix socket path names a file that is not a socket';
    upInUse:
      Result := 'the Unix socket path is in use by a live listener';
    upUnreadable:
      Result := 'the Unix socket path cannot be checked';
  else
    Result := '';
  end;
end;

procedure ApplyUnixSocketMode(const APath: string; const AMode: Integer);
begin
  if AMode = -1 then
    Exit;
{$IFDEF UNIX}
  if fpChmod(APath, TMode(AMode)) <> 0 then
    raise EHttpConnectionError.Create('the Unix socket mode cannot be set');
{$ELSE}
  raise EHttpConnectionError.Create('Unix sockets are not supported on this target');
{$ENDIF}
end;

{$IFDEF DARWIN}
function UnixPeerPid(const AFd: Integer): Integer;
var
  Pid, Len: LongInt;
begin
  Result := 0;
  Pid := 0;
  Len := SizeOf(Pid);
  // SOL_LOCAL (0) and LOCAL_PEERPID (2)
  if fpGetSockOpt(AFd, 0, 2, @Pid, @Len) = 0 then
    Result := Pid;
  if Result < 0 then
    Result := 0;
end;
{$ELSE}
{$IFDEF LINUX}
function UnixPeerPid(const AFd: Integer): Integer;
type
  /// the record that SO_PEERCRED fills in: pid, uid and gid
  TPeerCred = packed record
    Pid: LongInt;
    Uid: LongInt;
    Gid: LongInt;
  end;
var
  Cred: TPeerCred;
  Len: LongInt;
begin
  Result := 0;
  FillChar(Cred, SizeOf(Cred), 0);
  Len := SizeOf(Cred);
  // SOL_SOCKET (1) and SO_PEERCRED (17)
  if fpGetSockOpt(AFd, 1, 17, @Cred, @Len) = 0 then
    Result := Cred.Pid;
  if Result < 0 then
    Result := 0;
end;
{$ELSE}
function UnixPeerPid(const AFd: Integer): Integer;
begin
  Result := 0;
end;
{$ENDIF}
{$ENDIF}

function UnixPeerText(const AEnabled: Boolean; const AFd: Integer): string;
var
  Pid: Integer;
begin
  if not AEnabled then
    Exit('');
  Pid := UnixPeerPid(AFd);
  if Pid > 0 then
    Result := 'unix:pid=' + IntToStr(Pid)
  else
    Result := 'unix';
end;

end.
