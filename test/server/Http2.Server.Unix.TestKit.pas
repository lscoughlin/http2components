{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test kit, raw client
notes:
  - This unit holds a raw AF_UNIX client and a path maker for the Unix socket tests.
  - The client uses descriptors, so a test can check the socket file itself.
---
}
unit Http2.Server.Unix.TestKit;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

/// a new socket path under /tmp; the name is short because sun_path is short
function NewUnixTestPath: string;

/// a new socket path of exactly ALength bytes under /tmp
function NewUnixTestPathOfLength(const ALength: Integer): string;

/// connects to the socket file at APath; -1 when the connect fails or times out
function UnixConnect(const APath: string; const ATimeoutMs: Integer): Integer;

/// writes all of AText to AFd
procedure UnixSend(const AFd: Integer; const AText: RawByteString);

/// reads until the peer closes or ATimeoutMs passes; answers what it read
function UnixReadAll(const AFd: Integer; const ATimeoutMs: Integer): RawByteString;

/// closes the descriptor AFd
procedure UnixClose(const AFd: Integer);

/// true when a file system entry exists at APath, a socket included
function UnixPathExists(const APath: string): Boolean;

/// true when APath is a socket file
function UnixPathIsSocket(const APath: string): Boolean;

implementation

uses
  {$IFDEF UNIX}BaseUnix, Sockets,{$ENDIF}
  SysUtils;

var
  GUnixPathCounter: Integer = 0;

const
  // the send flag that suppresses SIGPIPE, as cMsgNoSignal in
  // client/src/Http2.Client.SigPipe.pas (the server test build does not use that unit)
{$IFDEF LINUX}
  cUnixSendNoSignal = $4000;
{$ELSE}
  cUnixSendNoSignal = 0;
{$ENDIF}

{$IFDEF UNIX}
/// the address record of a Unix socket path
function UnixAddrOf(const APath: string): TUnixSockAddr;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.family := AF_UNIX;
  if APath <> '' then
    Move(APath[1], Result.path[0], Length(APath));
end;
{$ENDIF}

/// the process id, for the name of a socket path
function UnixPid: Integer;
begin
{$IFDEF UNIX}
  Result := fpGetPid;
{$ELSE}
  Result := 0;
{$ENDIF}
end;

function NewUnixTestPath: string;
begin
  Inc(GUnixPathCounter);
  Result := Format('/tmp/h2-%d-%d.sock', [UnixPid, GUnixPathCounter]);
  while UnixPathExists(Result) do
  begin
    Inc(GUnixPathCounter);
    Result := Format('/tmp/h2-%d-%d.sock', [UnixPid, GUnixPathCounter]);
  end;
end;

function NewUnixTestPathOfLength(const ALength: Integer): string;
begin
  Result := NewUnixTestPath;
  // the name holds the pid and the counter; the filler makes up the rest
  Result := Copy(Result, 1, Length(Result) - 5);
  while Length(Result) < ALength - 5 do
    Result := Result + 'x';
  Result := Result + '.sock';
end;

procedure UnixClose(const AFd: Integer);
begin
{$IFDEF UNIX}
  fpClose(AFd);
{$ENDIF}
end;

function UnixPathExists(const APath: string): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
{$ENDIF}
begin
{$IFDEF UNIX}
  Result := fpLStat(APath, St) = 0;
{$ELSE}
  Result := FileExists(APath);
{$ENDIF}
end;

function UnixPathIsSocket(const APath: string): Boolean;
{$IFDEF UNIX}
var
  St: Stat;
{$ENDIF}
begin
{$IFDEF UNIX}
  Result := (fpLStat(APath, St) = 0) and fpS_ISSOCK(St.st_mode);
{$ELSE}
  Result := False;
{$ENDIF}
end;

function UnixConnect(const APath: string; const ATimeoutMs: Integer): Integer;
{$IFDEF UNIX}
var
  Addr: TUnixSockAddr;
  Deadline: QWord;
  Err: cint;
begin
  Result := -1;
  Result := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if Result < 0 then
    Exit;
  Addr := UnixAddrOf(APath);
  fpFcntl(Result, F_SETFL, O_NONBLOCK);
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    if fpConnect(Result, PSockAddr(@Addr), SizeOf(Addr)) = 0 then
      Exit;
    Err := fpgeterrno;
    if (Err <> ESysEAGAIN) and (Err <> ESysEINPROGRESS) then
      Break;
    Sleep(5);
  until GetTickCount64 >= Deadline;
  fpClose(Result);
  Result := -1;
end;
{$ELSE}
begin
  Result := -1;
end;
{$ENDIF}

procedure UnixSend(const AFd: Integer; const AText: RawByteString);
{$IFDEF UNIX}
var
  Sent: TSsize;
  Done: Integer;
begin
  Done := 0;
  while Done < Length(AText) do
  begin
    Sent := fpSend(AFd, @AText[Done + 1], Length(AText) - Done, cUnixSendNoSignal);
    if Sent <= 0 then
      Break;
    Inc(Done, Sent);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

function UnixReadAll(const AFd: Integer; const ATimeoutMs: Integer): RawByteString;
{$IFDEF UNIX}
var
  Buf: array[0..4095] of Byte;
  Got: TSsize;
  Deadline: QWord;
begin
  Result := '';
  fpFcntl(AFd, F_SETFL, O_NONBLOCK);
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Got := fpRecv(AFd, @Buf[0], SizeOf(Buf), 0);
    if Got > 0 then
    begin
      SetLength(Result, Length(Result) + Got);
      Move(Buf[0], Result[Length(Result) - Got + 1], Got);
    end
    else if Got = 0 then
      Break
    else if fpgeterrno <> ESysEAGAIN then
      Break
    else
      Sleep(5);
  until GetTickCount64 >= Deadline;
end;
{$ELSE}
begin
  Result := '';
end;
{$ENDIF}

end.
