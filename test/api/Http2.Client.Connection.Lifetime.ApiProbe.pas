program Http2ClientConnectionLifetimeApiProbe;

{$mode delphi}{$H+}

uses
  cthreads, Http2.Client.Connection;

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
