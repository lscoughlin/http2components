---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, status, tls, integration
notes:
  - Results distinguish current bounded checks from historical source checks.
---

# Current verification status

Native Linux Docker validation is in progress on 2026-11-11. The
[Linux verification record](linux-tls-2026-11-11.md) contains the current
candidates, repairs, executed checks, failures, and peer limitations.
Candidate `5ecf0fc` passed all 777 client tests, five production builds,
25 example builds, seven idle/header cases, and two general integration
runs. The package-only update in `97aca1d` passed all six packages and the
complete server suite: 721 tests, zero errors, and zero failures. Server TLS,
independent identities, conformance, abuse, and repeated shutdown checks also
passed. The remaining client peer checks passed. The first performance stage found
an incomplete-handshake admission failure at the configured connection
limit. The admission repair passes all four focused cases. Its final
acceptance candidate `9f0f8de` passes all 724 server tests and all affected
TLS, identity, conformance, abuse, and shutdown checks. Performance has resumed.
There is no release approval.

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
| Source and documentation | 405 Pascal files, one include, 152 production units, and 58 documents passed. |
| Version and package inventory | Version 0.30.0 and all six package inventories passed. |
| Test inventory | All 1,780 source records have checked accounting. This is not a runtime case count. |

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

Linux builds, packages, examples, both full unit suites, provider matrices,
independent server peers, conformance, and abuse have passing results. The
real proxy matrix passed 65 cases with three documented Squid limitations.
The client mTLS upload matrix passed all 54 rows, and client interoperation
passed all 13 required cases with its existing peer limitation. Performance
found and corrected an incomplete-handshake admission defect. Complete
affected acceptance passes after the repair; the resource checks continue. The Linux
record distinguishes strict passes from explicit peer limitations and
classified harness rows.

The [repository README](../../README.md) describes the build and validation
commands. The detailed TLS record identifies unsupported provider features
and the limits of the executed checks.
