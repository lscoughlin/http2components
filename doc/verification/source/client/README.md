---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, client, source-history
notes:
  - These files record source-project results, not merged-tree results.
---

# Client source verification records

These records describe client source commit
`709336f542cbedf9ce1ab67d83bddcfd560eb1c0`. They do not validate the combined
source tree.

| Document | Subject |
| --- | --- |
| [Toolchain record](toolchain.md) | The compiler, the platform and the tool revisions of the client source. |
| [Validation record](validation.md) | The results of the client source against external test suites. |
| [Proxy record](proxy-real.md) | The client results against Apache httpd and Squid proxy servers. |
| [Mutual TLS record](mtls-real.md) | The client results against three server stacks that require a client certificate. |
| [Observer overhead record](observer-overhead.md) | The method for measuring the cost of the request observers. The results table is empty. |
| [Harness run log](harness-run-full.log) | The log of a full harness run that compares the reference and the client for each case. |
| [Harness expectations](harness-expectations.tsv) | The expected outcome of each harness case, with one row for each case. |
