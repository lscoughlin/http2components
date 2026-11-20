---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: documentation, index, verification
scope: The verification records of the library, their checks, and their limits.
---

# Verification records

This directory holds the verification records of the library. Each record
states the checks of one platform, one source revision or one date, with the
results and their limits. The records are not release approvals.

| Document | Subject |
| --- | --- |
| [Streamed bodies record](body-reader-2026-11-18.md) | The Linux gate results and load runs of the streamed bodies and messages, with the findings that remain open. |
| [Current status](current-status.md) | The current verification results for the combined tree, with their peer limits. |
| [Native Linux record](linux-tls-2026-11-11.md) | The native Linux Docker validation of the TLS work, with its environment, results and peer limits. |
| [TLS replacement record](tls-replacement-0.30.0.md) | The bounded macOS checks of the TLS replacement for version 0.30.0, and the validation that remained deferred. |
| [Unix socket record](unix-sockets-2026-11-12.md) | The macOS and Linux results of the Unix domain socket feature. |
| [Client compiler probes](client-probes/README.md) | The compiler probes of the client source project, kept as historical evidence. |
| [Source records](source/README.md) | The source records of the client and server projects, grouped by role. |
