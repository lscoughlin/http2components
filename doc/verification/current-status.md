---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, status, tls, integration
notes:
  - Results distinguish current bounded checks from historical source checks.
---

# Current verification status

Native Linux Docker validation completed on 2026-11-12. The
[Linux verification record](linux-tls-2026-11-11.md) contains the candidates,
repairs, commands, results, peer limits, and retained failure evidence.
The unchanged client code passed all 777 tests. Final acceptance candidate
`9f0f8de` passed all 724 server tests, with zero errors and failures. Five
production builds, six packages, 25 examples, and the required TLS, identity,
proxy, conformance, abuse, and shutdown checks have passing results.

All four final performance stages pass: incomplete-handshake admission,
connection load up to 10,000, combined 10,000 WebSocket and 10,000 SSE load,
and four million-request TLS runs. Every million-request run used one
connection and returned one million HTTP 200 responses without failed or
errored requests. The archive contains 6,264 files with verified hashes.
Agent worktrees, branches, and the validation container were removed.

The independent harness has 146 classified rows: MATCH 30, BETTER 39,
WORSE 0, CLASS-DIFF 15, and UNKNOWN 62. These are not 146 strict passes.
Three Squid cases and the nghttpd A8 case retain their documented peer
limitations. Nested artifacts from one early failed candidate are missing;
its source archive and top-level logs remain. These limits remain part of
the evidence. No release approval or publication is recorded.

The earlier bounded implementation candidate was `15feb54`, checked on
macOS 27.2 arm64 with Free Pascal 3.2.4, Lazarus 4.0, and OpenSSL 3.5.9.
The [TLS replacement record](tls-replacement-0.30.0.md) preserves those
commands, versions, counts, artifacts, and review limits.

## Earlier bounded macOS checks

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
| Source and documentation | 405 Pascal files, one include, and 58 documents passed under the rules of that time. The current checks are 29 simple rules in the tasks `source:check`, `docs:check`, `version:check`, and `packages:check`. |
| Version and package inventory | Version 0.30.0 and all six package inventories passed. |
| Test inventory | The checker of that time covered 1,780 source records. This is not a runtime case count. The current checks do not include this accounting. |

Each named TLS program completed within a 30-second outer limit, with exit 0
and no skipped suite. The runtime checks used local buffers or loopback
sockets. Same-library exchanges establish local integration; independent
protocol conformance remains untested by these checks.

Additional focused macOS runs passed 78 client mTLS cases and 62 affected
server unit cases. Those bounded checks did not include the complete legacy
client and server suites. Their Linux results appear above. Earlier
source-merge results, including the 805-case client run
and four-package build, describe an earlier implementation. They do not count
as current TLS replacement results.

## Linux validation status

The Linux run is complete with the explicit limits above. The real proxy
matrix passed 65 cases with three documented Squid limitations. The client
mTLS upload matrix passed all 54 rows, and client interoperation passed all
13 required cases with its existing peer limitation. The repaired admission
guard and all final resource checks passed. The Linux record distinguishes
strict passes from peer limitations and classified harness rows.

The [repository README](../../README.md) describes the build and validation
commands. The detailed TLS record identifies unsupported provider features
and the limits of the executed checks.
