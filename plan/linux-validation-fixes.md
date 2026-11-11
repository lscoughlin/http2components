# Linux validation and repair plan

Candidate: dc46dabc6840dbfef3174b4b58b8642ee660f8e4.
Host: liam-rzbox.local, native Linux x86_64, Docker 29.9.2.
The user authorized Linux validation, acceptance, performance, and repair on
2026-11-11. The host is dedicated to this work. Other workloads are being
removed by the user. Test jobs do not remove unrelated resources.

## Evidence and sequence

1. Record host, compiler, dependency and image versions under
   bin/validation/20261111-rzbox. The existing user implementation plan stays
   unchanged and uncommitted.
2. Build all components, examples, API probes and six packages in Linux Docker.
   Run source checks, complete unit suites, local integration, and both TLS
   provider suites. Each command records its count, exit, duration and timeout.
3. Run independent HTTP/2, WebSocket, proxy, mTLS and TLS acceptance checks.
   Missing cases, tools and skips are explicit failures or open gaps.
4. Run load, abuse, connection churn, memory and provider performance checks
   serially after their functional prerequisites pass. Record resource limits
   and host load. No performance threshold is invented after a measurement.
5. Review each repair, merge it, rerun affected checks, and remove its worktree
   and branch. Final documentation separates passes, failures and limitations.

## LV-01: Linux build and validation setup

Observed: the server Dockerfile installs neither Python nor Lazarus and only
fetches mORMot. The replacement needs five pinned dependencies and six packages.
The gate compiler compile_server_examples omits explicit provider flags used
by the new TLS examples. Historical Linux builds also failed to link missing
mORMot static objects.

Owner: linux_setup. Files: tools/server/container/, tools/build.py, new shared
Linux container setup under tools/validation/ if needed. Other owners do not
edit these paths.

The repair supplies reproducible FPC 3.2.4-rc2 and Lazarus tooling, all pinned
dependencies and needed test tools. Existing cached compiler images can speed
this run, but their versions and image IDs are recorded. Native mORMot static
objects require checked provenance; unsupported silent fallback is not allowed.
Acceptance: native Linux builds, six package builds and example gate compilation
work without macOS paths. The root coordinator runs remote checks serially.

## LV-02: Client acceptance tool migration

Observed risk: validation scripts were preserved from the old implicit TLS
API. The implementation changed provider selection and identity loaders;
external gates were deferred. Every client gate needs review against the
current public API before its Linux execution.

Owner: linux_client. Files: tools/client/validate/ and associated client-only
validation probes. No change to shared build driver or production code without
an additional issue plan and coordinator agreement.

Review all gate commands, fixture paths, explicit origin/proxy contexts and
identity loading. Repair demonstrated stale assumptions. Preserve expected
results and exact case accounting. Container routes must work on native Linux
without host macOS mounts. Report required tools and exact gate order.
Acceptance: sanity, interop, harness, cleartext, SSE, WebSocket/Autobahn,
proxy and mTLS gates exercise the current implementation with no hidden skips.

## LV-03: Server acceptance and performance tools

Observed: ws_sse_load.py parses macOS cputime fields incorrectly on Linux and
sleeps for an hour after its measurement without a cleanup result. Current
server and TLS validation probes also need an API migration check.

Owner: linux_server. Files: tools/server/validate/ and server-only integration
probes under test/integration/server/. No shared driver or production edits.

Repair the CPU measurement for Linux and bounded load completion/cleanup.
Review conformance, WebSocket HTTP/1.1 and HTTP/2, SSE, abuse and seam commands.
Preserve assertions and expected results. Supply reproducible performance runs
for both providers, TLS 1.2/1.3, handshake churn, throughput, latency and memory
where existing tools support them. Missing coverage gets an explicit added
probe or an open issue, not an invented pass. Keep runs isolated and serial.
Acceptance: tools terminate with meaningful exit status, counts, runtime and
cleanup results; independent peers are distinct from same-library exchanges.

## New defects

Runtime failures receive a dated issue entry here or a linked plan before a
GPT-6-Luna worker implements a repair in its own worktree. The root reviews
and merges each repair and records affected reruns.
