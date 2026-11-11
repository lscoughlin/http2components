{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_runner
notes:
  - this runs the client unit tests
---
}
program Http2.Client.RunTests;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, consoletestrunner, Http2.Client.TestRunner;

var
  App: TTestRunner;
begin
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'http2components client tests';
    App.Run;
  finally
    App.Free;
  end;
end.
