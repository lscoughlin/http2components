{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: compiler_probe
notes:
  - Historical compiler probe source.
  - Not a merged library unit.
---
}
{$mode objfpc}{$H+}
program probe11;
uses SysUtils, SyncObjs;
var
  Ev: TSimpleEvent;
begin
  Ev := TSimpleEvent.Create;
  Ev.SetEvent;
  WriteLn('TSimpleEvent ok, wait=', Ev.WaitFor(0));
  Ev.Free;
  WriteLn('done');
end.
