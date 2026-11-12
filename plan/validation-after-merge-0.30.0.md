# Deferred validation dependency matrix

| ID | Check | Depends on | Environment | Pass condition |
| --- | --- | --- | --- | --- |
| V00 | Freeze candidate and tool versions | Completed implementation review | macOS | Clean commit, input hashes, and commands recorded |
| V01 | Independent client HTTP/2 conformance | V00 | Isolated local harness host | No WORSE results; every other result classified |
| V02 | Independent server HTTP/2 conformance | V00 | Isolated local peer host | Required cases pass; no unexplained regression |
| V03 | WebSocket conformance | V00 | Isolated Autobahn host and RFC 8441 peer | Expected cases pass; exclusions have reasons |
| V04 | Proxy and mutual TLS container matrix | V00 | Container host | Routes, identities, verification, and cleanup pass |
| V05 | Server load, abuse, and long connection runs | V02, V03 | Dedicated host | Existing limits and resource assertions pass |
| V06 | Linux amd64 build and validation across five production components | V00 | Dedicated Linux amd64 host | Common, client, server, OpenSSL, and TlsLib builds and all six packages pass; Readers is optional; bounded tests and local integration pass |
| V07 | Linux amd64 load and independent peers | V01–V06, V09–V12 | Dedicated Linux amd64 host | Applicable protocol and resource checks pass |
| V08 | Final release review | V00–V07, V09–V14 | Review environment | No unresolved required failure or hidden skip |
| V09 | TLS provider matrix on Linux | V06 | Dedicated Linux amd64 host | Both providers pass TLS 1.2/1.3, client/server, mTLS, identity, trust, and ALPN cases |
| V10 | Independent TLS peer interoperability | V00, V06 | Isolated peer host | OpenSSL CLI and independent peers interoperate for required provider and role pairs |
| V11 | TLS load, churn, and long-lived sessions | V06, V09 | Dedicated test host | Handshake rate, tail latency, memory, cleanup, and failure limits are recorded against reviewed bounds |
| V12 | Full HTTP/2 and TLS conformance | V01, V02, V06 | Isolated conformance hosts | Required HTTP/2/TLS cases pass; exclusions and regressions are classified |
| V13 | HTTPS proxy and mTLS route matrix | V04, V06, V09 | Container host | Separate origin/proxy contexts and identities pass all configured routes |
| V14 | Timed TLS server lifecycle suite | V06, V09 | Dedicated test host | Full lifecycle runner completes without timeout, leak, or unexplained skip |

## Scope

The user first deferred resource-intensive tests and Linux validation on
2026-11-11, then authorized this separate phase on liam-rzbox.local. The run
started at 17:55:40 UTC. It uses native Linux amd64 Docker containers. The
user assigned the host to this work and authorized repair plans implemented
by GPT-6-Luna agents in separate worktrees. Root reviews and merges repairs
and removes completed worktrees and branches. Brief reports are due every
15 minutes and detailed reports every 20 minutes.

The first version is 0.30.0. Release publication follows the final review;
a prepared source tree is not evidence that the deferred checks passed.
The implementation evidence identifies its tested macOS environment and
bounded checks separately.

## Candidate and evidence contract

V00 records the candidate Git commit, clean status, package versions,
compiler version, mORMot2 revision, OpenSSL runtime and CLI versions,
external tool versions, host CPU/OS, and available resources. The mORMot2
revision remains `b2b195da1e0580058672a88620ef71bb47283eb1`; the client
harness revision remains `0bc075cc21e5a247dfd222e005d1e7e5679d2bff`.

Each run records its exact command, start/end time, exit status, test names,
counts, skips, expected exclusions, raw log path, and result summary. A
missing tool or unavailable host is a gap, not a pass. A timeout is recorded
with its last completed case and cleanup result. An infrastructure failure
is distinguished from a protocol failure.

Generated output stays under a run-specific `bin/validation/` directory.
Published evidence is summarized in `doc/verification/` with the required
YAML front matter and actual check dates. Documentation does not refer to
this plan.

## V01 — Client HTTP/2 harness

The source reading is the migrated client validation document and the
harness script. The final tool map identifies the corresponding
`task validate:client:harness` command and its inputs. The original harness
uses host port 8080 and runs alone. No second sweep, server load run, or
heavy build shares its host during measurement.

The outcome classes remain MATCH, BETTER, WORSE, CLASS-DIFF, and UNKNOWN.
Zero WORSE rows is required. A zero exit status with missing cases is not
sufficient. Expected case IDs are compared with produced rows. A suspect
case is repeated alone after the original result is retained.

## V02 — Server HTTP/2 conformance

The source reading is the migrated server validation record and preserved
validation scripts. The command map supplies the server conformance and
short-check targets. Independent clients exercise SETTINGS, HPACK,
continuation order, stream lifetime, flow credit, frame validation, limits,
and graceful shutdown. A client built from the same common units is not
an independent protocol oracle.

## V03 — WebSocket conformance

The preserved client Autobahn target and server WebSocket validation tools
run separately. Expected-results files remain fixed inputs. The result
checks cover masking direction, fragmentation, UTF-8, control frames,
closing behavior, message limits, and cleanup. Server WebSocket over HTTP/2
uses an independent RFC 8441 peer. No new RFC 8441 client support is assumed.

## V04 — Proxy and mutual TLS matrix

The migrated real-proxy and real-mTLS tool configurations identify each
container image and version. HTTP CONNECT, HTTPS proxy, and SOCKS5 paths
retain their original cases. Origin and proxy identities remain separate.
The result record covers missing, valid, expired, and untrusted identities,
TLS versions, hostname verification, and the exact route seen in peer logs.
Generated keys remain local to the run and are removed with its containers.

## V05 — Load, abuse, and long-lived connections

The preserved server abuse and seam tools define the individual cases and
expected limits. Their exact commands and configuration are reviewed before
the run. The host has a known connection/file-descriptor limit; the original
10,000-connection run needs a per-process limit above that count. Setup does
not silently alter global host limits.

Measurements include open connections, retained memory, CPU use, queue
sizes, timeout behavior, refused work, graceful drain, and cleanup after
peer disconnect. A before/after idle measurement distinguishes retained
state from temporary load. The source-project results provide context;
they are not fixed performance promises for another host.

The known original server combined-suite cancellation failures and the
incomplete baseline remain in the defect record until merged-code results
resolve them. Passing isolated cases alone is not evidence that an
order-dependent failure is resolved.

## V06 and V07 — Linux amd64

Linux validation starts only in this separate phase. It uses a dedicated
checkout and output directory. The source build instructions identify the
Free Pascal 3.2.4 toolchain source and mORMot2 pin. A compiler or container
build is explicit work with its own log; it is not hidden inside a test.

V06 runs all five production component builds, all six packages, optional
Readers, public API probes, examples, bounded unit suites, and local
integration. It checks that no absolute macOS or sibling-repository path is
required. V07 then applies the independent peer, proxy/TLS, and resource
checks to Linux.
An emulated target is identified as emulated and is not reported as native.

## V08 — Release decision

The reviewer compares the final candidate with every evidence commit. A
code fix invalidates the affected results and causes the affected checks
to run again. Missing mandatory cases, unexplained skips, resource leaks,
and unresolved failures keep the release incomplete. The final record
lists the tested platforms and remaining explicit limits. Version fields
remain 0.30.0; the intended release tag is `v0.30.0`.

## Timed suite completion

The complete server unit runner includes timed connection-age and lifecycle
cases. The implementation review stopped the whole run at 60 seconds. A
45-second diagnostic sample reached a normal sleep in
`TConnectionAgeTest.TestH1WebSocketStaysOpenPastAgeAndGrace`. V00 records a
complete server run with a deadline based on these timed cases, before V05.
The earlier timeout is not a pass and does not by itself prove a deadlock.
The stale factory source paths found during that run are corrected; its
27 focused tests pass. The original baseline cancellation failures remain
part of the comparison record and require classification if they recur.


## Execution status at 2026-11-12 00:06 UTC

| IDs | Status |
| --- | --- |
| V00 | Complete. Final candidate 9f0f8de has a Git archive and exact command/result records. The final evidence archive has 6,264 files with verified hashes. The absent 610a86b nested artifacts remain an explicit historical gap; its source and top-level logs remain. |
| V01 | Complete with classifications. All 146 expected rows are present: MATCH 30, BETTER 39, WORSE 0, CLASS-DIFF 15, UNKNOWN 62. Non-matching outcomes have source and trace classifications. This is not 146 strict passes. |
| V02, V12 | Passed. Full server conformance passed 94 HTTP/2 and eight HPACK cases with no skips; final affected conformance gates pass on a3298bd production, unchanged in 9f0f8de. |
| V03 | Passed. Client Autobahn and independent HTTP/2 WebSocket, HTTP/1 WebSocket, and SSE checks retain their original scope and exclusions. |
| V04, V13 | Passed with explicit peer limits. Real mTLS passed 54 rows; real proxy passed 65 rows with three Squid build limitations. Client interoperation passed all 13 required cases with its existing A8 limitation. |
| V05, V07, V11 | Passed. Final abuse, all four incomplete-handshake cases, fresh and sequential connection load up to 10,000, combined 10,000 WebSocket/10,000 SSE load, and all four million-request TLS runs pass. Each million-request run used exactly one connection and returned one million HTTP 200 responses. Cleanup completed normally. |
| V06 | Passed. Five production builds, 25 examples, six packages, 777 client tests, and final 724 server tests pass. Final server errors/failures are both zero. The earlier failures remain in the evidence. |
| V09, V10 | Passed. Provider/security matrices, independent client checks, and all 32 independent server identity rows pass. |
| V14 | Passed. All 13 adapter and 13 listener cases, 40 live mTLS cases, and 20 repeated shutdown cases pass after the final production repair. |
| V08 | Evidence review is complete with the stated harness classifications, peer limits, and historical artifact gap. No release approval or publication is recorded. |

The evidence record is `doc/verification/linux-tls-2026-11-11.md`. All agent
worktrees and branches are removed after review and merge. The validation
container is removed after archive verification. The remote run directory
and local expanded evidence remain. The original TLS replacement input and
both sibling repository revisions are unchanged.
