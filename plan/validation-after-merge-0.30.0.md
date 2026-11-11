# Deferred validation dependency matrix

| ID | Check | Depends on | Environment | Pass condition |
| --- | --- | --- | --- | --- |
| V00 | Freeze candidate and tool versions | Completed implementation review | macOS | Clean commit, input hashes, and commands recorded |
| V01 | Independent client HTTP/2 conformance | V00 | Isolated local harness host | No WORSE results; every other result classified |
| V02 | Independent server HTTP/2 conformance | V00 | Isolated local peer host | Required cases pass; no unexplained regression |
| V03 | WebSocket conformance | V00 | Isolated Autobahn host and RFC 8441 peer | Expected cases pass; exclusions have reasons |
| V04 | Proxy and mutual TLS container matrix | V00 | Container host | Routes, identities, verification, and cleanup pass |
| V05 | Server load, abuse, and long connection runs | V02, V03 | Dedicated host | Existing limits and resource assertions pass |
| V06 | Linux amd64 build and validation | V00 | Dedicated Linux amd64 host | Builds, packages, bounded tests, and local integration pass |
| V07 | Linux amd64 load and independent peers | V01–V06 | Dedicated Linux amd64 host | Applicable protocol and resource checks pass |
| V08 | Final release review | V01–V07 | Review environment | No unresolved required failure or hidden skip |

## Scope

The user deferred resource-intensive tests and all Linux validation on
2026-11-11. This plan records that separate work. None of these checks is
claimed as passed by the implementation session. This plan does not start
containers, remote jobs, or load generators.

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

V06 runs the three component builds, optional Readers, public API probes,
Lazarus packages, examples, bounded unit suites, and local integration. It
checks that no absolute macOS or sibling-repository path is required. V07
then applies the independent peer, proxy/TLS, and resource checks to Linux.
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
