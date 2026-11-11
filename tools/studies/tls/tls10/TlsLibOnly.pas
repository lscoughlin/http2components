{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, isolation, tlslib
notes:
  - This program checks the TlsLib provider package search path.
---
}
program TlsLibOnly;
{$mode delphi}
uses Http2.TlsLib, Http2.Common.Tls.Context;
begin
  WriteLn('PASS tlslib-only');
end.
