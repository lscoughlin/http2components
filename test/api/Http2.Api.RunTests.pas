{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, api, test, consoletestrunner
notes:
  - This program runs API type-identity and role-error checks.
---
}
program Http2.Api.RunTests;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  consoletestrunner, Http2.Api.TestRunner;

var
  App: TTestRunner;
begin
  RegisterTests;
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Title := 'http2 API test suite';
    App.Run;
  finally
    App.Free;
  end;
end.
