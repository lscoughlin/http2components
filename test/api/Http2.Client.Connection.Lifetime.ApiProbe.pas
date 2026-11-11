{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, connection, api
notes:
  - This probe checks suspended connection thread construction and release.
---
}
program Http2ClientConnectionLifetimeApiProbe;

{$mode delphi}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  Http2.Client.Connection;

var
  Conn: TConnection;
  Worker: TConnectionThread;
begin
  Conn := TConnection.Create(nil);
  try
    Worker := TConnectionThread.Create(Conn);
    Worker.Free;
  finally
    Conn.Free;
  end;
end.
