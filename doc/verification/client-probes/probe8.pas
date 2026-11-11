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
program probe8;
uses SysUtils, Classes, SyncObjs, Generics.Collections;
var
  C: TCriticalSection;
  Q: specialize TQueue<Integer>;
begin
  C := TCriticalSection.Create;
  C.Acquire; C.Release; WriteLn('TCriticalSection Acquire/Release ok'); C.Free;

  Q := specialize TQueue<Integer>.Create;
  Q.Enqueue(1);
  WriteLn('TQueue threadsafety: Count=', Q.Count);
  Q.Free;
  WriteLn('done');
end.
