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
program probe6;
uses SysUtils, Classes, SyncObjs;
var
  E: TEvent;
  C: TCriticalSection;
begin
  C := TCriticalSection.Create;
  C.Enter; C.Leave; WriteLn('critical section ok'); C.Free;

  E := TEvent.Create(nil, True, False, 'probe-ev');
  WriteLn('named TEvent ok');
  E.SetEvent;
  WriteLn('wait state=', E.WaitFor(0));
  E.Free;
  WriteLn('done');
end.
