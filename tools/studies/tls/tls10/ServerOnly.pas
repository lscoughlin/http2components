{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, isolation, server
notes:
  - This program checks the server package search path without a provider.
---
}
program ServerOnly;
{$mode delphi}
uses Http2.Server, Http2.Common;
begin
  WriteLn('PASS server-without-provider');
end.
