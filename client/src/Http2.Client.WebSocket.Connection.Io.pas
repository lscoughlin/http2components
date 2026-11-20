{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, socket
notes:
  - This unit owns the plain socket operations of a WebSocket connection.
  - The operations of WsWriteAll and WsCloseQuiet take no lock. The caller holds the lock
    that they need.
  - WsReadLocked and WsWriteLocked take the io lock themselves when the socket is locked
    (the reads and writes of one TLS state), and they count the senders that wait for it.
---
}
unit Http2.Client.WebSocket.Connection.Io;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Http2.Client.Errors, Http2.Client.Tls, Http2.Client.Http1.Body;

/// write all bytes of AWire to the socket; raises when a write makes no progress
procedure WsWriteAll(const ASock: IHttp2Socket; const AWire: TBytes);

/// close the socket and ignore a failure of the close
procedure WsCloseQuiet(const ASock: IHttp2Socket);

/// read up to ACount octets; a read that times out gives -1
// - when ALocked, the read waits for the senders that wait for AIo, then holds AIo
function WsReadLocked(const AReader: TBufferedReader; var ABuffer; const ACount: Integer;
  const ALocked: Boolean; const AIo: TCriticalSection; const AWriters: PInteger): Integer;

/// write all bytes of AWire; when ALocked, the write holds AIo and counts as a waiting sender
procedure WsWriteLocked(const ASock: IHttp2Socket; const AWire: TBytes;
  const ALocked: Boolean; const AIo: TCriticalSection; const AWriters: PInteger);

implementation

function WsReadLocked(const AReader: TBufferedReader; var ABuffer; const ACount: Integer;
  const ALocked: Boolean; const AIo: TCriticalSection; const AWriters: PInteger): Integer;
begin
  try
    if ALocked then
    begin
      while AWriters^ > 0 do
        Sleep(1);
      AIo.Enter;
      try
        Result := AReader.ReadBytes(ABuffer, ACount);
      finally
        AIo.Leave;
      end;
    end
    else
      Result := AReader.ReadBytes(ABuffer, ACount);
  except
    on EHttpTimeout do
      Result := -1;
  end;
end;

procedure WsWriteLocked(const ASock: IHttp2Socket; const AWire: TBytes;
  const ALocked: Boolean; const AIo: TCriticalSection; const AWriters: PInteger);
begin
  if ALocked then
  begin
    InterlockedIncrement(AWriters^);
    AIo.Enter;
    InterlockedDecrement(AWriters^);
  end;
  try
    WsWriteAll(ASock, AWire);
  finally
    if ALocked then
      AIo.Leave;
  end;
end;

procedure WsWriteAll(const ASock: IHttp2Socket; const AWire: TBytes);
var
  Sent, N: Integer;
begin
  Sent := 0;
  while Sent < Length(AWire) do
  begin
    N := ASock.Write(AWire[Sent], Length(AWire) - Sent);
    if N <= 0 then
      raise EHttpConnectionError.Create('WebSocket write failed');
    Inc(Sent, N);
  end;
end;

procedure WsCloseQuiet(const ASock: IHttp2Socket);
begin
  try
    ASock.Close;
  except
  end;
end;

end.
