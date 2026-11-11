{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, api, test, fpcunit
notes:
  - This unit registers API-boundary checks for role errors.
---
}
unit Http2.Api.TestRunner;

{$mode delphi}{$H+}

interface

procedure RegisterTests;

implementation

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Http2.Client.Errors.Test,
  Http2.Server.Errors.Test,
  Http2.Api.ErrorsIdentity.Test;

procedure RegisterTests;
begin
end;

end.
