{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, reader
notes:
  - This unit owns the WebSocket reader thread adapter.
---
}
unit Http2.Client.WebSocket.Connection.ReaderThread;

{$mode delphi}{$H+}

interface

uses
  Classes, Http2.Client.WebSocket.Connection;

type
  TWsReaderThread = class(TThread)
  private
    FConn: TWebSocketConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConn: TWebSocketConnection);
  end;

implementation

constructor TWsReaderThread.Create(const AConn: TWebSocketConnection);
begin
  FConn := AConn;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TWsReaderThread.Execute;
var
  Conn: TWebSocketConnection;
begin
  Conn := FConn;
  FConn := nil;
  try
    Conn.ReaderMain;
  finally
    Conn.ReleaseSelf;
  end;
end;

end.
