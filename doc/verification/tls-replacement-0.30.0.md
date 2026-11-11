---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, tls, providers, packages, macos
notes:
  - This record separates bounded implementation checks from deferred validation.
---

# TLS replacement verification for 0.30.0

The check date is 2026-11-11. The implementation candidate is `15feb54`.
The result covers the common TLS API, both providers, client and server
transports, public examples, documentation, and package isolation. It is not
release approval. At that checkpoint, Linux, load, containers, external
proxies, independent TLS peers, and full conformance were deferred. The
later [native Linux record](linux-tls-2026-11-11.md) contains their separate
validation results and current status.

## Environment and dependencies

The host was macOS 27.2, build 26B123, arm64. Free Pascal reported 3.2.4
(target `aarch64-darwin`); its compiler banner also identifies the rc2 build.
Lazarus was 4.0. The OpenSSL runtime was 3.5.9, dated 2026-09-29, from
`/opt/homebrew/opt/openssl@3/lib`. The fixture command-line program was
OpenSSL 4.1.0, dated 2026-10-23. These are separate runtime and fixture tools.

| Dependency | Pinned revision |
| --- | --- |
| mORMot2 | `b2b195da1e0580058672a88620ef71bb47283eb1` |
| TlsLib4Pascal | `2b47b18f61e5039a990e623353df88a0379ca948` |
| CryptoLib4Pascal | `f559d27462ddd149ef9d1880f97854a8a4cc8368` |
| HashLib4Pascal | `465c0c7c2c9a78596dd07e022f81073c11775a52` |
| SimpleBaseLib4Pascal | `9310af083d398ed62f01d8c82d39f85ad194dc93` |

The origins and license notices are recorded in `tools/dependencies.json`.
The dependency checkouts stayed clean. The macOS/FPC CryptoLib random-source
patch is a versioned overlay under generated output. It does not modify the
pinned checkout. Other platforms were not validated.

## Executed bounded checks

| Program | Executed checks | Runtime (seconds) | Result |
| --- | ---: | ---: | --- |
| Common contract | 23 | 0.217 | Passed; exit 0; no timeout. |
| OpenSSL provider | 139 | 0.579 | Passed; exit 0; no timeout. |
| TlsLib provider | 87 | 0.854 | Passed; exit 0; no timeout. |
| Client transport | 17 | 0.521 | Passed; exit 0; no timeout. |
| Server adapter | 13 | 0.206 | Passed; exit 0; no timeout. |
| Server listener | 12 | 5.623 | Passed; exit 0; no timeout. |
| HTTP integration | 29 | 6.375 | Passed; exit 0; no timeout. |
| Security integration | 200 | 0.883 | Passed; exit 0; no timeout. |

The commands were `python3 tools/build.py` with these targets:

```text
test:tls:contract
test:tls:openssl
test:tls:tlslib
test:tls:client
test:tls:server
test:tls:integration
```

The final runs started at 15:26:36 UTC and ended at 15:27:14 UTC.
The command records are in `bin/tls-coordinator/final/runtime-results.json`.
The full case logs are `test-tls-contract.log`, `test-tls-openssl.log`,
`test-tls-tlslib.log`, `test-tls-client.log`, `test-tls-server.log`, and
`test-tls-integration.log` in that directory. All named programs ran;
there were no skipped suites. The integration target also compiled the
public API probe.

Each program had a 30-second outer limit. The programs ran sequentially on
the current host, with local buffers or loopback sockets and small fixtures.
Lifecycle checks used at most ten repetitions and a few concurrent sessions.
The logs contain executed case names, counts, UTC start times, elapsed times,
child exit status, and timeout status. A missing or zero-case suite cannot
pass the driver. No required bounded case is recorded as an unavailable pass.

The HTTP runner covers all four client/server provider pairs at TLS 1.2 and
TLS 1.3, an exact shared dual-role context, concurrent sessions, caller
reference release, copied metadata, and interleaved mixed-provider listeners.
The security runner has 200 assertions over 152 handshake scenarios
(19 scenarios, four provider pairs, and two TLS versions). Its cases include
trusted and unknown CAs, expiry with a valid-chain control, DNS/IP names,
none/request/require client authentication, invalid client certificates,
ALPN preference, HTTP/1.1, and no ALPN.

The common and transport tests cover retained partial input and output,
plaintext credit, final plaintext before EOF, fatal-alert drain, cancellation,
absolute deadlines, strict h2 and fallback, proxy/origin separation, explicit
nil identity selection, and context lifetime. The server tests include silent
and trickling peers, failed start, independent bindings, short and zero
writes, and shutdown while provider output is pending.

Additional focused evidence includes 78 preserved client mTLS cases and
62 affected server unit cases across their final focused runs. The added
absent-peer case is in the six-case server mTLS suite. These are separate
from the named-runner counts above. They do not imply a full client or server
suite pass for the replacement.

## Build and source checks

| Check | Command or artifact | Result |
| --- | --- | --- |
| Source and test accounting | `python3 tools/build.py source:check` | 405 Pascal files, one include, 152 production units, and all 1,780 source records passed. |
| Documentation | `python3 tools/build.py docs:check` | 58 documents passed after this record was added. |
| Version | `python3 tools/build.py version:check` | VERSION and six package files passed. |
| Generated package inventory | `python3 tools/packages.py --check` | All six inventories matched. |
| Lazarus package builds | `python3 tools/build.py packages:check` | All six packages built separately; exit 0; 123.974 seconds. |
| Examples | `python3 tools/build.py examples` | All 25 compiled; exit 0; 261.178 seconds. |
| Restricted compiler probes | `bin/tls-coordinator/tls10-artifacts/isolation-*.trace.txt` | All six component/provider probes compiled with the required closure. |
| Lazarus project group | `bin/tls-coordinator/tls10-lazarus-group.log` | One check passed; all six targets loaded. |
| Public API compile probe | Included in `test:tls:integration` | Passed on the merged source. |

The final source, documentation, version, inventory, and package build logs
are in `bin/tls-coordinator/final/`. Their command records are
`static-results.json` and `packages-result.json`. The complete example build
log is `bin/tls-coordinator/tls11-examples-main.log`; its command record is
`tls11-examples-main.json`, and its 25 binary hashes are in
`tls11-main-examples.sha256` in the same directory. The examples were compiled
but not executed. The package build emitted compiler warnings and hints;
its success does not assert a warning-free build.

The package inventory is 11 common units, 55 client units, 71 server units,
6 OpenSSL units, 8 TlsLib units, and 1 optional Readers unit: 152 production
units in five source roots and six packages. Package and source versions are
0.30.0. The source checker follows Pascal includes in their parent unit and
section. The public facade probe checks type identity and provider factories.
The four new integration examples import public facades only.

The original source-test inventory retains all 913 client and 867 server
origin records in their original order. Eighty-seven TLS rows have explicit
migration records. Two native-accessor assertions are obsolete and identify
the replacement contract without claiming equivalent native coverage.
The checker rejects uncovered rows, absent methods, and absent assertion
markers. Six negative/static controls passed. The 1,780 records are inventory
checks, not 1,780 executed runtime tests.

## Provider isolation

Six restricted compiler probes cover common only, each role without a
provider, each provider alone, and both providers. Their traces contain no
forbidden project units. Common, client, server, and TlsLib traces also have
no native OpenSSL binding. The Lazarus 4.0 project-group reader loaded all six
package targets. Each package built in a separate primary configuration;
no normal IDE profile was changed.

The exact TlsLib exchange runner was compiled with a complete unit trace,
then ran with `DYLD_PRINT_LIBRARIES=1` and no `OPENSSL_LIBPATH`. It passed
87 cases in 0.906 seconds, exit 0. The log contains 82 loaded images and no
`libssl` or `libcrypto` image. Its binary SHA-256 is
`b8d61db6fd945af66fd226de3d27e38335b0a04ab72f691f4afc524ebc14ee1c`.
The trace has no OpenSSL provider, mORMot, CocoaAll, or Security random-reader
unit. System CommonCrypto/CoreCrypto images are OS services, not SSL engines.
The log is `bin/tls-coordinator/tls10-main-images.log`; compiler and package
artifacts are retained under `bin/tls-coordinator/tls10-artifacts/`.

The final named TlsLib target also ran with `DYLD_PRINT_LIBRARIES=1` and
without `OPENSSL_LIBPATH`. It passed 87 cases in 0.854 seconds, exit 0.
It loaded 82 images, with no `libssl` or `libcrypto` image. Its complete
log is `bin/tls-coordinator/final/test-tls-tlslib.log`.

The first image check failed despite 87 passing functional cases: macOS
framework dependencies loaded LibreSSL 3.3.6 system libraries. A separate
Security.framework probe showed the same issue. The reviewed random-source
overlay reads `/dev/urandom` with interrupted-operation and short-read handling,
rejects failed reads, and has no weak fallback. It removed that dependency.
The small RNG probe passed three cases before the full exchange check.

Lazarus forces `-B` for an unbuilt package. The TlsLib-only build wrapper
removes that exact argument after a fresh ordered dependency bootstrap, which
avoids the pinned CryptoLib source cycle. Other compiler arguments and
normal IDE settings are unchanged.

## Review corrections and limits

The OpenSSL ALPN selector validates the complete client vector before it
selects a protocol. Empty, nil, zero-length-entry, truncated, and malformed
trailing vectors fail. Encoded server preferences are prepared before the
native callback, which performs no string encoding or vector allocation.
Twenty-one ALPN and 25 policy/identity assertions restore affected regressions.
Combined PEM loading uses the same explicit path for certificate and key.

Native pointers stay inside provider implementation units. Client and server
trust are separate. Sessions retain immutable contexts and use separate
mutable state. Transport code retains unaccepted plaintext and ciphertext,
and the server acknowledges plaintext only after the relevant output drains.
The server deadline is absolute; actual close timing is subject to its
asynchronous scheduling and maintenance sweep.

The OpenSSL native write-retry address and length were reviewed. The native
`SSL_write` WANT branch was not forced deterministically; passed adapter
backpressure cases do not remove this limit. TlsLib lifecycle counters cover
adapter contexts, sessions, credentials, and engine references, not every
allocator operation. Bounded repetition is not a long-duration leak test.

TlsLib does not support system trust, explicit verification depth (including
zero), DER identities, distinct SNI and verification names, or peer verification
with hostname verification disabled. Its verification depth is four. The
engine cannot expose CertificateRequest evidence before some failed TLS 1.2
handshakes; alert 40 can therefore remain a generic connection error. The
wire alert description is retained. Both providers disable resumption and
early data. These limits are documented rather than counted as skipped
required features.

Preliminary failures remain in the implementation logs. They include the
first framework image check, fixture-chain and ALPN expectation corrections,
transport scheduling and test-harness corrections, and stale inventory rows.
The security expiry fixture includes its intermediate chain and a matching
valid-chain control. The final checks replace earlier failures only after
the corresponding correction. The worker example build lacked a retained
exit status, so the merged example build was repeated with a complete log.

## Cleanup and deferred validation

All task branches and worktrees were removed after review and merge.
The main worktree is the only remaining worktree. No generated build output
is tracked. The existing implementation input was left unchanged.

The original sibling repositories remain clean at these revisions:

- `http2client`: `709336f542cbedf9ce1ab67d83bddcfd560eb1c0`.
- `http2server`: `16e2003a9f31648005c5565d118bbd42acf935a8`.

All five dependency checkouts remain clean at their pinned revisions and
origins. The check is recorded in `bin/tls-coordinator/final/cleanup.json`.

Linux amd64 and other untested platforms, load and abuse, slow-handshake load,
connection churn, long-lived sessions, independent TLS/HTTP/WebSocket peers,
real proxy/container matrices, and full timed server suites remain open.
The deferred validation scope includes all five components, all six packages,
all provider pairs, fixed candidate/dependency versions, reviewed performance
bounds, complete case accounting, and release review. Same-library exchanges
prove local integration, not independent protocol conformance.
