{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, isolation, client
notes:
  - This program checks the client package search path without a provider.
---
}
program ClientOnly;
{$mode delphi}
uses Http2.Client, Http2.Common;
begin
  WriteLn('PASS client-without-provider');
end.
