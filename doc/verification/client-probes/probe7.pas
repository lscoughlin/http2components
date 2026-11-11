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
program probe7;
uses SysUtils, Classes;
var
  Ev: PRTLEvent;
  T: TThread;
begin
  Ev := RTLEventCreate;
  RTLEventSetEvent(Ev);
  RTLEventWaitFor(Ev, 0); WriteLn('RTLEvent ok');
  RTLEventDestroy(Ev);
  WriteLn('done');
end.
