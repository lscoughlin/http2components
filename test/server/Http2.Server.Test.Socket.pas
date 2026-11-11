{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, socket
notes:
  - This unit confirms peer EOF after an optional drain of pending data.
---
}
/// Socket close checks shared by server tests
unit Http2.Server.Test.Socket;

{$mode delphi}{$H+}

interface

uses
  mormot.net.sock;

/// True only when a receive proves peer EOF or a socket error.
/// ADrainPendingData is true when callers have already checked protocol data.
function TestSocketClosed(const ASocket: TCrtSocket;
  const ADrainPendingData: Boolean = False): Boolean;

implementation

uses
  {$IFDEF UNIX}Sockets, BaseUnix,{$ENDIF}
  SysUtils;

function TestSocketClosed(const ASocket: TCrtSocket;
  const ADrainPendingData: Boolean): Boolean;
var
  Pending: TCrtSocketPending;
  B: Byte;
  N: Integer;
  Data: RawByteString;
begin
  Pending := ASocket.SockReceivePending(0);
  if Pending in [cspSocketError, cspSocketClosed] then
    Exit(True);
  if Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket] then
  begin
    if ADrainPendingData then
    begin
      repeat
        Data := ASocket.SockReceiveString;
        if Data = '' then
          Break;
        Pending := ASocket.SockReceivePending(0);
      until not (Pending in [cspDataAvailable, cspDataAvailableOnClosedSocket]);
      if Pending in [cspSocketError, cspSocketClosed] then
        Exit(True);
    end;
    {$IFDEF UNIX}
    N := fpRecv(ASocket.Sock.Socket, @B, SizeOf(B), MSG_PEEK or MSG_DONTWAIT);
    if N = 0 then
      Exit(True);
    if N > 0 then
      Exit(False);
    Exit(not (fpgeterrno in [ESysEAGAIN, ESysEINTR]));
    {$ELSE}
    Exit(False);
    {$ENDIF}
  end;
  Result := False;
end;

end.
