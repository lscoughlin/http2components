{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, test, consoletestrunner
notes:
  - This program runs the common protocol unit tests.
---
}
program Http2.Common.RunTests;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  consoletestrunner, Http2.Common.TestRunner;

var
  App: TTestRunner;
begin
  RegisterTests;
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'http2 common test suite';
    App.Run;
  finally
    App.Free;
  end;
end.
