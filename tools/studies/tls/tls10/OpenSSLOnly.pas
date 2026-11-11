{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, isolation, openssl
notes:
  - This program checks the OpenSSL provider package search path.
---
}
program OpenSSLOnly;
{$mode delphi}
uses Http2.OpenSSL, Http2.Common.Tls.Context;
begin
  WriteLn('PASS openssl-only');
end.
