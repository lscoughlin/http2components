{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, test, fpcunit
notes:
  - This unit registers the shared protocol test cases.
---
}
unit Http2.Common.TestRunner;

{$mode delphi}{$H+}

interface

procedure RegisterTests;

implementation

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Http2.Common.Errors.Test,
  Http2.Common.Headers.ClientOrigin.Test,
  Http2.Common.Headers.ServerOrigin.Test;

procedure RegisterTests;
begin
end;

end.
