# Implementation state — 2026-11-11 08:40 UTC

## Scope and constraints

The merge targets this repository only. Both sibling source repositories
remain clean and read-only. The version is 0.30.0. Owned code has the license
choice Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception).
All library files are under src/common, src/client, or src/server.
Linux, load, containers, and external conformance are not run. The separate
validation plan records these checks and the full timed server suite.

## Accepted work

Main is at 82929f1. Integration is at 63947c5. Accepted imports include
common M02–M05, client M06, server M07, most client tests M08, tooling M09,
package/API preparation M10, and local integration M11. C01 and C04 are
complete. C04 copied all 207 original routine bodies without change apart
from the pool state class owner. The facade retains original public names.

Build outputs use target/profile/role folders. The root driver supports
Make and Task validation commands and compiles required programs. The four
Lazarus packages are generated from role source folders. The package
inventory currently matches C04; it needs regeneration after C02/C03.

Latest parent changes after main include exact server test mappings,
test-accounting checks, validation prerequisites, corrected server source
fixture paths, and separate-process integration. The combined API probe
now imports only the three public facades.

## Evidence

- Common: 229 tests pass.
- API: 16 tests and five facade probes pass. The facade-only combined probe
  also passes after C04.
- Local integration: nine cases pass (HTTP/2 binary/flow window, HTTP/1,
  TLS, reuse/HEAD, start/stop, concurrency, SSE resume, ws/wss echo).
- Separate processes: cleartext and TLS HTTP/2 each pass status 200 and
  clean server stop.
- Local TLS gate: 21 checks pass.
- Local mTLS gate: 40 checks pass, including identities and X509 counters.
- Server factory: 27 pass after source path correction.
- Server TLS context: ten pass in isolation.
- Full server: 60-second deadline exceeded. A 45-second diagnostic sample
  shows a normal timed connection-age Sleep, not a proven deadlock. No full
  pass is claimed. The observed early failure was stale fixture paths and
  is corrected. Long timed completion is in the deferred plan.
- Full client: earlier imported 801-case pass precedes the latest splits.
  The post-C01 full run reached 90 seconds. The test agent is diagnosing it;
  selected suites pass. No current full-client pass is claimed yet.

Raw logs are in integration/bin. M09 logs were copied into
integration/bin/agent-evidence/tools before its worktree was removed.
Eight completed worktrees and branches have been removed.

## Active worktrees

- client / merge/client: Luna source agent; C02 Connection/Stream and C03
  WebSocket. The abandoned thread base/bridge caused an external FPC
  constructor compile failure. The direct TThread wrapper is restored and
  a fresh create/free probe passes. C02 commit and review are pending.
- tests / merge/tests: Luna test agent; RequestObserver split selected
  suites pass 74 cases, MutualTls split is in progress. Stale MockSocket
  imports and accounting paths are fixed locally. All 1780 manifest rows
  pass the checker there. Final commits and full runner diagnosis pending.
- final-docs / merge/final-docs: Luna final docs/provenance agent. Owns
  README, changelog, doc, provenance TSV, and missing server Docker context.
  No container execution. C04 review found inherited response body lifetime
  and generic reader limitations; docs will state those constraints and
  the plan will record follow-up work.
- integration / merge/integration: parent review and local checks.

## Remaining work

Review/merge C02/C03 and final client tests; resolve current client runner
failure or timeout; merge docs/provenance and confirm all 440 source records;
regenerate and compile packages; run final source/docs/version/accounting
checks; repeat affected bounded API/integration cases; verify a clean source
archive without sibling repositories; move independent mORMot dependency
and evidence to main; remove all remaining owned worktrees and branches.
No release tag or publication is required.

The independent mORMot clone is integration/third_party/mORMot2 at
b2b195da1e0580058672a88620ef71bb47283eb1. Agents read it through MORMOT.
OpenSSL 3 is /opt/homebrew/opt/openssl@3/lib. All shell tool commands use
explicit workdir and login=false.
