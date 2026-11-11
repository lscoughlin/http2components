---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, status, tls, integration
notes:
  - Results distinguish current bounded checks from historical source checks.
---

# Current verification status

The current implementation candidate is `15feb54`, checked on 2026-11-11
on macOS 27.2 arm64 with Free Pascal 3.2.4, Lazarus 4.0, and OpenSSL 3.5.9.
The [TLS replacement record](tls-replacement-0.30.0.md) contains the commands,
versions, counts, artifacts, review limits, and cleanup results.

## Completed checks

| Check | Result |
| --- | --- |
| Common TLS contract | 23 checks passed. |
| OpenSSL provider | 139 checks passed. |
| TlsLib provider | 87 checks passed. The process loaded no OpenSSL or LibreSSL library. |
| Client TLS transport | 17 checks passed. |
| Server TLS transport | 13 adapter and 12 listener checks passed. |
| HTTP integration | 29 checks passed across both providers and TLS versions. |
| Security integration | 200 assertions passed over 152 handshake scenarios. |
| Public API and isolation | The facade probe and six restricted compiler probes passed. |
| Examples | All 25 examples compiled. They were not executed. |
| Lazarus packages and group | All six packages built separately. The Lazarus group reader loaded all six targets. |
| Source and documentation | 405 Pascal files, one include, 152 production units, and 58 documents passed. |
| Version and package inventory | Version 0.30.0 and all six package inventories passed. |
| Test inventory | All 1,780 source records have checked accounting. This is not a runtime case count. |

Each named TLS program completed within a 30-second outer limit, with exit 0
and no skipped suite. The runtime checks used local buffers or loopback
sockets. Same-library exchanges establish local integration; independent
protocol conformance remains untested by these checks.

Additional focused runs passed 78 client mTLS cases and 62 affected server
unit cases. The full legacy client and server suites were not run for this
replacement. Earlier source-merge results, including the 805-case client run
and four-package build, describe an earlier implementation. They do not count
as current TLS replacement results.

## Deferred checks

Linux, containers, load, abuse, long-duration cleanup, full timed server
suites, real proxy matrices, independent TLS/HTTP/WebSocket peers, and full
conformance remain deferred. Release readiness depends on that separate
validation. No Linux or load run was made for this implementation.

The [repository README](../../README.md) describes the build and validation
commands. The detailed TLS record identifies unsupported provider features
and the limits of the executed checks.
