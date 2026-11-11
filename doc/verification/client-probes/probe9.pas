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
{$mode delphi}
program probe9;
uses SysUtils;
type
  TUtil = class
  public
    class procedure Foo<T>(out AValue: T); static;
  end;
class procedure TUtil.Foo<T>(out AValue: T);
begin
  FillChar(AValue, SizeOf(T), 0);
end;
var
  I: Integer;
begin
  TUtil.Foo<Integer>(I);
  WriteLn('delphi generic method ok: ', I);
end.
