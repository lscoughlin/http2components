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

### LV-03 extension, 2026-11-11 17:56 UTC

Review found that existing load tools exercise plaintext only and server TLS
live gates use the component client. A dedicated validation server under
`tools/server/validate/` can select OpenSSL or TlsLib and TLS 1.2 or TLS 1.3
from command arguments. The server owner supplies this probe and its build
contract. Independent OpenSSL and h2load clients measure handshake churn,
throughput and latency against the same response body and host settings.
The existing plaintext WS/SSE probe remains a separate baseline. Correctness
requires all requested operations to complete without unexpected errors.
Performance values are measurements; the run does not assert an invented
cross-host regression threshold. Resource cleanup is checked after disconnect.

### LV-02 findings, 2026-11-11 17:57 UTC

`interop.sh` and `h2probe-sanity.sh` contain macOS OpenSSL/PATH settings;
interop also sets a Darwin FPC unit directory. `proxy_real_client.pas` uses
old trust and certificate factory methods. The client owner replaces these
with platform-correct tool discovery and explicit provider contexts and
identity loaders, including separate HTTPS proxy policy. The owner checks
h2probe's insecure option against the new API. Docker-required cases A.11
and A.12 cannot become successful SKIP results after Docker failure.

### Required external tools, 2026-11-11 17:57 UTC

The server conformance gate currently skips missing required tools and can
return success. The server owner makes missing h2spec, nghttp, curl, h2load,
and required Python protocol packages fail the requested full gate. Existing
fixed protocol expectations stay unchanged. Exact missing tools remain in
logs. The client owner applies the same rule to required Docker peer cases.

### LV-02 Docker path finding, 2026-11-11 18:00 UTC

`mtls-real.sh` creates bind-mounted peer configuration below container-local
`/tmp`. The remote Docker daemon cannot see that path. The client owner moves
this scratch directory below the run output in the shared source mount and
keeps cleanup restricted to its own generated directory. The main test
container and host use the same absolute source path.

## LV-04: OpenSSL 3.0 fixture compatibility

The first native Linux OpenSSL suite failed before its first case at
2026-11-11 18:00:27 UTC. Ubuntu OpenSSL 3.0.13 rejects `openssl req -quiet`.
The macOS fixture CLI was OpenSSL 4.1.0. The setup owner checks all owned
fixture-generation calls, removes unsupported output-only options or uses a
version-compatible quiet output capture, and preserves certificate semantics.
Files: affected test TLS fixture helpers and provider runners. No production
TLS behavior changes are implied. Acceptance: the OpenSSL provider suite and
all integration suites using these fixtures run on OpenSSL 3.0 and the
existing fixture format remains valid. The original failure log is retained.

## LV-05: Linux native static library search path

The native library component build passed, but the executable link for TLS
integration failed at 18:01:19 UTC: `ld: cannot find libdeflatepas.a`.
The checksum-verified archive is present in the pinned mORMot static directory.
The setup owner reviews generated compiler/linker arguments and adds the
appropriate target-specific static library search path without a macOS path
or reliance on the caller's working directory. Acceptance is executable links
for role, provider, integration, examples and Lazarus package consumers.

## LV-06: Linux client suite SIGPIPE termination

The complete client suite terminated by SIGPIPE at 18:02:44 UTC after 23.628
runtime seconds, before it printed a final case count. This is a failure, not
an empty-suite pass. The client owner identifies the active test and signal
stack, then fixes the socket or fixture boundary that permits the signal.
Production client transport files and directly related tests are added to
this owner's scope only for this defect. A global signal override must not
conceal a transport error. Acceptance includes the reproduced broken-peer
case and the complete combined client suite, with normal error reporting and
no process signal termination. Earlier logs remain unchanged.

## LV-07: Server live probe TLS API migration

Review confirms that Http2.Server.TlsLive still calls removed WithTls and
TTlsServerOptions APIs. It and Http2.Server.Mtls.Live.Raw use legacy
TTlsSocket.DialWithAlpn arguments with no explicit context, which the new
transport rejects. The server owner migrates these server-only probes and
related fixtures to explicit OpenSSL contexts and identity loaders. Existing
ALPN/mTLS expectations remain unchanged. The independent provider probe is
additional coverage and does not replace these existing policy cases.

## LV-08: Linux TLS listener close/deadline failures

The repaired Linux TLS server target runs 13 adapter checks successfully.
Its 12-case listener suite then reports four assertion failures at
18:08:26 UTC: StopClosesAnAcceptedHeldHandshake,
TwoBindingsKeepTheirSessionsSeparate,
SilentAndTricklingPeersMeetTheAcceptDeadline, and
StrictMissingAndUnsupportedAlpnAreRejected. All four fail on peer closure.
The server owner checks the Linux test observation first, then the epoll
transport close and deadline paths. Production server transport and the
listener test helper are in scope if the failure requires them. No assertion
is weakened to hide a live connection. Acceptance is the complete listener
suite with actual closure/deadline behavior and unaffected adapter checks.

## LV-09: Timed suite limits and per-case evidence

The full server suite exceeds ten minutes while the generic runner default
is 180 seconds. The Docker build currently does not supply a longer limit.
The validation runner also buffers all output until exit, so a timeout lacks
the last active case required by the evidence contract. The runner owner
adds an explicit configurable full-suite Docker timeout (initially 1200
seconds), leaves named bounded TLS limits at 30 seconds, and supplies an
optional server test listener that records each case start/end with a flush.
The trace does not change assertions, case registration or execution order.
The build driver streams and retains child output while preserving timeout
process-group cleanup and nonzero/empty-suite failure checks. Acceptance is
exact case progress and complete output on pass, failure and timeout.

## LV-10: Client external gate failures

On candidate d270c08, sanity passes five cases, cleartext passes, and SSE
passes two cases. Interop reports A.11 h2c upgrade failure against Apache:
connection closes while reading a frame header. A.8 remains an explicit
historical exclusion because nghttpd has no trigger for mid-flight GOAWAY.
The WebSocket live gate reports failures in its 18 registered cases.
The client owner repairs stale explicit TLS policy calls in gated live tests
and diagnoses A.11 against an independent client and retained peer logs.
Production client changes require a demonstrated wire or state defect, not a
weaker expectation. Existing fixed mandatory case IDs stay unchanged.

LV-06 remains open: the complete client suite still exits SIGPIPE after the
first fixture wrapper repair. A new stack identifies the remaining raw socket
or SSL call; all fixture operations that can write are covered with scoped
signal handling. The prior failed rerun is retained as evidence.

### LV-10 evidence, 2026-11-11 18:14 UTC

WebSocket live: one of 18 cases errors because the HTTPS proxy context is
absent. Proxy live: three of ten cases error (two absent HTTPS proxy contexts,
one loopback certificate verification failure). The client owner fixes test
policies and trust inputs while keeping certificate verification meaningful.
The mTLS PKI script uses x509 -not_before/-not_after, which requires newer
OpenSSL than Ubuntu 3.0. The client owner generates the same fixed expired
certificate dates with the compatible CA signing command and verifies expiry.

The first real proxy and mTLS command invocations attempted a nested SSH hop.
The root coordinator uses their documented local/native mode environment in
this already-remote Docker container; the failed invocations remain recorded.
