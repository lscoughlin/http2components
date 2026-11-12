{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
/// http2components client example: one GET request over a Unix socket.
// - build: `task examples` (or see examples/README.md for a raw fpc command)
// - run:   bin/<target>/<profile>/examples-client/programs/unix_client http://localhost/
//   with a server that listens on /tmp/h2.sock and allows cleartext
// - shows: WithUnixSocket, the cleartext policy for an http:// origin, and the
//   Host header that the URL host sets.
program example_unix_client;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client, Http2.Common;

var
  Client: IHttpClient;
  Url: string;
  Response: IHttpResponse;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: example_unix_client <http-url>');
    Halt(2);
  end;
  Url := ParamStr(1);

  // every connection goes to the socket file; the URL host names the authority
  // only.  ctPriorKnowledge sends the HTTP/2 preface at once over the socket.
  Client := THttpClientFactory.Create
    .WithUnixSocket('/tmp/h2.sock')
    .WithClearText(ctPriorKnowledge)
    .Build;
  try
    Response := Client.Send(
      THttpRequest.Create(hmGet, Url)
        .WithHeader('user-agent', 'http2client-example'));

    WriteLn('status: ', Response.StatusCode);
    WriteLn('content-type: ', Response.Headers.GetFirst('content-type'));

    // ReadText drains the body stream to EOF and copies the bytes verbatim.
    WriteLn('body bytes: ', Length(ReadText(Response)));
  except
    on E: EHttpError do
    begin
      WriteLn(StdErr, 'request failed: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
  Client.Close;
end.
