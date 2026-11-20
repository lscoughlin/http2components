{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
program Http2.Integration.RunTests;
{$mode delphi}{$H+}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  consoletestrunner, Http2.Integration.Http.Test, Http2.Integration.Events.Test,
  Http2.Integration.Unix.Test, Http2.Integration.WsStream.Test, Http2.Integration.WsH2.Test,
  Http2.Integration.WsH2Mux.Test;
var Runner: TTestRunner;
begin
  Runner := TTestRunner.Create(nil);
  try
    Runner.Initialize;
    Runner.Title := 'http2components local integration';
    Runner.Run;
  finally Runner.Free; end;
end.
