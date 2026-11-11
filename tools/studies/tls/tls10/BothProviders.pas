{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, isolation, provider-pair
notes:
  - This program checks both provider package search paths.
---
}
program BothProviders;
{$mode delphi}
uses Http2.OpenSSL, Http2.TlsLib, Http2.Common.Tls.Context;
begin
  WriteLn('PASS both-providers');
end.
