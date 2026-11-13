{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, socket
notes:
  - This unit owns the plain socket operations of a WebSocket connection.
  - The operations take no lock. The caller holds the lock that the operation needs.
---
}
unit Http2.Client.WebSocket.Connection.Io;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors, Http2.Client.Tls;

/// write all bytes of AWire to the socket; raises when a write makes no progress
procedure WsWriteAll(const ASock: IHttp2Socket; const AWire: TBytes);

/// close the socket and ignore a failure of the close
procedure WsCloseQuiet(const ASock: IHttp2Socket);

implementation

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
