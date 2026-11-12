{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, unix socket, h2c
notes:
  - This example builds a cleartext HTTP/2 server on a Unix domain socket and serves one page.
  - The argument is the socket file path. The default path is /tmp/h2.sock.
  - A client can use curl --unix-socket /tmp/h2.sock http://localhost/ for HTTP/1.1, or
    curl --http2-prior-knowledge --unix-socket /tmp/h2.sock http://localhost/ for HTTP/2.
  - The server does not start when the path holds a regular file or a live listener.
  - The server runs until the caller presses Enter, then stops. The stop removes the socket file.
---
}
/// A small HTTP/2 server on a Unix domain socket
// - the program builds a factory with a socket path, builds the server,
//   starts it and stops it
program unix_server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  mormot.core.base,
  Http2.Server, Http2.Common;

type
  /// the handler of the example
  TUnixHelloHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure TUnixHelloHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
  Text: string;
begin
  // the handler is synchronous: it reads what it needs, writes the response
  // and returns
  Text := 'hello from the Unix socket server; you asked for ' + ARequest.Path +
    sLineBreak;
  SetLength(Body, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Body[0], Length(Text));
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

var
  Server: IHttp2Server;
  Path: string;
  Line: string;
begin
  if ParamCount < 1 then
    Path := '/tmp/h2.sock'
  else
    Path := ParamStr(1);
  Server := THttp2ServerFactory.Create
    .WithUnixSocket(Path)
    .WithClearTextAllowed(True)
    .WithHandler(TUnixHelloHandler.Create)
    .Build;
  Server.Start;
  Writeln('the server listens on the socket file ', Server.UnixSocketPath);
  Writeln('press Enter to stop');
  Readln(Line);
  Server.Stop;
  Writeln('the server stopped');
end.
