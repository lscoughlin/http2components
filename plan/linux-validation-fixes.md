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

## LV-11: General integration TLS migration

The Linux `test:integration` compile on candidate e41fb5e fails in
Http2.Integration.Http.Test.pas line 73 on removed WithTls and
TTlsServerOptions symbols. The server owner migrates general integration
server and client setup to explicit contexts, preserving its nine cases and
separate-process checks. Scope extends to test/integration/Http2.Integration.*
and a needed server-side probe setup. Build-driver changes are coordinated
with the runner owner. This gate remains separate from the 29/200-case TLS
integration runners that already passed.

## LV-12: SSE encoding time regression on Linux

The full Linux server suite completed 714 cases with one error and 13 failures.
TSseHardeningTest.TestManyShortLinesEncodeInBoundedTime failed its existing
linear-time bound and dominated runtime. The runner owner, after LV-09,
reviews the encoder and fixture for repeated allocation or copying, fixes a
confirmed cause, and preserves the existing test bound. Scope is
server/src/Http2.Server.Sse.Encoder.pas and its hardening tests. Acceptance
includes the original short-line case, output equivalence, and complete-suite
rerun. Measurement is on the same host with fixed inputs.

## LV-13: Remaining full server suite failures

The server owner diagnoses the other full-suite failures: Async idle/header
closure, three connection-age closures, connection-cap closure, four abuse
GOAWAY closures, slow-reader handler progress (503 instead of 200), idle stop
time, and WebSocket HTTP/2 going-away EPIPE. Linux EOF observation is checked
first where the failed assertion is socket closure, with real nonblocking
EOF proof. Production backpressure/lifecycle code is in scope only after a
reproduced defect. Existing deadlines and error expectations remain intact.
The initial full log is baseline-test-server.log; runtime was 708.577 seconds,
exit 3. The earlier API probe link failure is covered by LV-05 and the repaired
API run already passed.

## LV-14: Complete client suite and external peer repairs

Candidate dc8bbe5 completes all 776 client cases without SIGPIPE, but reports
one error and eleven failures. Ten pool and routing checks still expect the
old pool key; the statistics checks expose the added TLS/protocol suffix. The
client owner verifies the new pool isolation contract before updating those
expectations. The broken-peer TLS test still supplies a removed legacy trust
option and needs an explicit context. No pool separation assertion is removed.

The live WebSocket (18) and proxy (10) gates now pass. The mTLS gate still
reports a generic connection error for a rejected missing identity. The owner
checks alert propagation against the existing required error contract. The real
proxy probe fails compilation because its mORMot source search path is absent.
The owner repairs build paths and checks the real mTLS probe for the same
problem. Acceptance includes all affected complete gates with retained peer
logs and counts; failures must not become skips.

### LV-14 evidence, 2026-11-11 18:31 UTC

The real mTLS run completes but its final table fails to print because the
container has no column utility. Cleanup then removes the detailed rows. The
client owner makes table formatting portable and preserves the result rows
and peer logs under the validation output before removing private fixtures.
The earlier live row sample confirms TLS 1.3 alert propagation failures for
Apache and Caddy, including large POST cases; they remain required failures.
The real proxy compiler has a separate mount issue: the candidate dependency
symlink resolves outside the nested compiler container mount. The owner maps
the resolved mORMot root, including static objects, into that container.

## LV-15: Disabled session resumption acceptance contract

The server live mTLS gate passes 38 checks and fails two old requirements that
saved TLS 1.2 and TLS 1.3 sessions resume. The approved replacement contract
explicitly disables session resumption in its first implementation. The
OpenSSL design document and context configuration state this policy.
The server owner replaces the two obsolete positive resumption checks with
positive evidence for the approved disabled policy: valid independent full
handshakes succeed for both versions, no connection reports reuse, and a
saved session attempt cannot bypass a fresh identity/trust check. The tests
record whether a ticket/session was issued; missing output or a failed first
handshake is a failure, not evidence that resumption is disabled. The result
record names this requirement change and keeps the initial failures.

## LV-16: Connection load evidence checks

Review of the preserved connection load tool finds two weak result paths.
The idle mode returns success when a requested process CPU sample is absent,
and it counts connections opened without checking that they stay open for
the requested window. The active mode counts DATA END_STREAM without checking
the expected response body or rejecting protocol error frames.

The runner owner repairs tools/server/seam/seam.py in its own worktree. An
explicit process ID requires usable CPU samples. Idle sockets remain open
through the measured window. Active and delayed results require the expected
response bytes and reject unexpected resets or GOAWAY errors. Existing load
parameters, the half-core idle bound, and delayed-response bounds stay fixed.
The tool reports complete counts and closes its own sockets after every path.
Acceptance includes valid peer behavior and controlled closed/error responses.

## LV-17: Apache HTTPS proxy client identity rejection

The real proxy gate on e3a8ae6 reports 59 passes, six failures, and three
explicit Squid/GnuTLS exclusions. All six failures use the Apache HTTPS
proxy: valid proxy identity, separate proxy/origin identities, identity log,
keep-alive, ACL rejection, and WebSocket route. They fail before CONNECT with
a TLS client-authentication error. The client owner checks the preserved
Apache peer log and fixture certificate chain, then repairs the demonstrated
configuration or transport cause. Valid and invalid identity cases retain
their existing expectations. The Squid build limitations stay explicit and
are not extended to Apache. Acceptance is the complete real proxy matrix.

## LV-18: Client harness evidence retention

The client owner checks the independent harness result path before the full
Linux run. Per-case reference and client output, the expected ID list, the
produced rows, and the final summary remain in a run-specific validation
directory after cleanup. Success requires every expected ID exactly once;
missing, extra, or duplicate rows fail. Existing outcome classes and expected
results do not change. Private temporary inputs and containers are removed.
A controlled incomplete result confirms that the checker fails.

## LV-19: WebSocket and SSE load liveness evidence

The combined load tool currently counts successful opening responses but
does not prove that all connections remain open through the measured window.
The runner owner adds checks for valid WebSocket upgrade headers and SSE
content type, plus connection liveness through the full window. An early
close fails the run. Readers drain bounded protocol data as needed so buffered
data cannot hide EOF or prevent liveness checks. WebSocket close frames fail
the hold requirement. Ordinary request counts and existing success checks
remain intact. All clients close on failure, and post-disconnect server memory
and CPU samples are recorded. Controlled early-close peers verify rejection.
The required final load remains 10,000 WebSocket connections plus 10,000 SSE
connections with 50 ordinary requests per second for 20 seconds.

## LV-20: Complete server conformance result evidence

The preserved server conformance script discards h2spec and h2load output.
The h2load process exit alone does not prove that every request succeeded.
The server owner retains external tool output under a run-specific validation
directory and checks the h2load summary for exactly 200 completed successful
requests with zero failed or errored requests. The independent h2spec HTTP/2
and HPACK packages both run, with counts and original output preserved. Each
required failure remains a failure. Tools and load parameters stay fixed.
A controlled incomplete h2load summary confirms failure detection.

## LV-21: Independent TLS server identity checks for both providers

The independent provider server probe currently covers server identity and
TLS version selection but has no client identity mode. The client owner adds
optional client-authentication mode and trust-anchor arguments to that probe,
with the current four-argument use preserved. A Python or OpenSSL peer then
checks both providers with TLS 1.2 and 1.3: a valid client certificate succeeds;
missing, expired, and unrelated-CA certificates fail when required; requested
client authentication accepts a missing certificate but rejects invalid
certificates. Positive requests require the fixed HTTP/2 response and ALPN h2.
Negative requests must fail before an HTTP response. The peer verifies the
server certificate and hostname. Result rows and peer output are retained;
generated private keys are removed. No provider policy is weakened.

## LV-22: Long-lived TLS connection evidence and run cleanup

The performance driver checks one million successful HTTP/2 responses, but
one concurrent h2load client does not prove one connection over the full run.
The provider probe records accepted connections with its server observer and
returns a counter snapshot on a `stats` input line. The existing stop input
and EOF shutdown remain valid. The performance driver takes snapshots before
and after the measured request run and requires exactly one new connection.
The driver records complete timeout results and terminates its process groups
on failure. Each compile has a retained log, initial samples follow a settle
period, and generated private keys are removed. Process socket file-descriptor
counts are named as such; they are not reported as accepted-connection totals.
The requests use the unchanged count of one million and one concurrent stream.

## LV-23: New client harness error-scope differences

The native Linux sweep has three CLASS-DIFF rows not fully explained by the
historical result record: 5.1.2/1, 5.3.1/2, and 8.1.2.3/7. The observed client
errors include a socket write failure or closed TLS transport instead of a
specific protocol error. The client owner reads the pinned case and verifier
source and preserves the initial reference, client, and container logs.
After the full isolated sweep, a separate trace run repeats these cases with
the same TLS URL, timeout, and keep-open period. Its frame trace establishes
whether the invalid frame reached the client and which side closed first.
A demonstrated client defect receives a narrow fix and regression check in
the owner's worktree, followed by affected independent cases. An oracle or
peer-lifetime limit has explicit evidence and remains a classified limit;
it does not become a strict protocol pass. No expected outcome is changed.

## LV-24: Concurrent incomplete TLS handshake evidence

The final matrix needs load evidence for incomplete TLS handshakes in addition
to successful handshake churn. The server owner adds a separate Python probe
for both providers at TLS 1.2 and TLS 1.3. It uses the existing provider server
binary and its declared handshake timeout. Concurrent peers include silent
TCP connections and partial ClientHello records. The probe records connection
counts, close times, process memory, CPU, and file descriptors. It checks
bounded timeout or admission refusal and a verified HTTP/2 request after the
incomplete peers close. A valid request during the load has a recorded result;
capacity refusal is reported separately from protocol success. All peers and
server processes close on every exit path. The measured deadline follows the
configured timeout and listener scheduling, with an explicit finite margin.
The run preserves raw results and does not reduce existing handshake checks.
The owner prepares and checks the tool locally. Root reviews it and runs it
alone on the Linux validation host after the functional acceptance batch.

## LV-25: HTTP/1 slow reader still holds the only handler on Linux

The full Linux run on candidate 609ab70 completed 716 cases with zero errors
and one failure. TestAClientThatNeverReadsDoesNotPinTheOnlyHandlerThread still
received HTTP 503 for the second request after 6.277 seconds. The earlier
output-progress repair did not resolve this case. The server owner preserves
this result and traces the stalled write, timer callback, socket queue, and
handler completion on Linux. A narrow repair must release the stalled handler
within the configured write timeout and let the original single second request
receive HTTP 200. Retries, a weaker expected status, or a larger test timeout
do not satisfy this requirement. A focused native Linux check precedes another
complete server run; the full run remains required to detect shared-state
failures. Affected general integration and server peer checks run again after
a production repair. Performance waits for this failure to be resolved.

## LV-26: Live mTLS cleanup exception after successful raw request

The final live mTLS run on 609ab70 exited 217 after its first three successful
mode-none checks. The exception was ETlsSessionError with the message
transport ended without TLS close_notify. The earlier 40-case run passed, so
this result needs a repeated, isolated check and a traced cleanup path. The
client owner reviews the raw peer and server shutdown order. A test-peer
cleanup error is handled at that boundary only; a genuine truncated response
must still fail. A production defect receives a separate narrow repair.
All 40 live mTLS cases must pass again, and initial failed logs remain.

## LV-27: Abuse gate uses the wrong server readiness parser

The independent abuse gate reports that the strict interop server did not
become ready. It starts that binary with the generic example helper, which
expects a URL in the readiness line. The interop binary reports a port and
has its own helper. The runner owner corrects the helper and port use, keeps
strict mode, and preserves startup and peer output on success and failure.
A controlled readiness check and the full Linux abuse gate verify the change.
The HTTP/1 WebSocket abuse checks already pass and remain required.

## LV-28: Validation helper child-process reaping

The validation container contains defunct example-server and pipe-holder
processes after completed gates. The shell helpers terminate the children and
then terminate their parent shell before it can collect the child exit status.
The runner owner changes stop handling so the parent can reap its children,
with a finite fallback for a child or parent that does not exit. Cleanup still
stops only processes created by that helper. Controlled repeated start/stop
checks verify that no live or defunct descendants remain. Startup failures
must preserve logs and release children too. Existing defunct processes in
the old container remain part of the evidence; container removal at completion
removes them. This repair does not change protocol expectations.

## LV-29: Empty-DATA abuse case fails before its expected rate-limit result

The corrected Linux abuse gate reaches all eight HTTP/2 cases. Seven pass;
the empty-DATA flood receives GOAWAY PROTOCOL_ERROR instead of the expected
ENHANCE_YOUR_CALM result. The runner owner checks the peer's stream setup and
frame sequence against the strict server policy. The trace must establish
whether the flood reaches a valid open stream. An invalid fixture is repaired
without weakening the expected rate-limit result. A valid fixture that exposes
a server defect receives a narrow production repair with a regression check.
The original seven passes, failed peer output, and server log remain retained.
The complete eight-case HTTP/2 and WebSocket abuse gate runs again. Process
cleanup must continue to create no new live or defunct child processes.

## LV-30: Full server regression after forced socket closure repair

Candidate 610a86b passes the original HTTP/1 slow-reader case in 1.114
seconds. The complete server run reports failures in
TWsHttp1Test.TestStopSendsGoingAway and
TWriteTimeoutTest.TestSlowSteadyReaderIsNotClosed. The first failure occurs
in shutdown; the second case runs for approximately 30 seconds. The exact
assertions and complete run summary remain required evidence.

The server owner traces both paths against the forced-close change. A
normal WebSocket shutdown must deliver close code 1001 before the transport
ends. A reader that makes progress must not be closed as a stalled reader.
The owner distinguishes a production regression from a fixture defect with
retained old/new evidence. The repair keeps the original stalled-reader
HTTP 200 requirement and explicit abort with write timeout disabled. The
owner does not weaken expected close codes or remove slow-reader progress
checks. Root reviews the repair and runs all affected tests followed by the
complete server suite. Performance stays blocked until the required server
checks pass. Remote diagnostic runs wait for the current batch to finish.

The complete run finished with 717 tests, one error, and two failures.
TAbuseLimitTest.TestResetFloodGoAway raised ECONNRESET in the test peer's
send path. This third result is part of the same investigation. The peer
must verify the intended GOAWAY result; an abort that discards a required
protocol notice is not accepted as a passing flood response. Existing
independent abuse coverage remains required after the repair.

The work is split between two existing Luna worktrees. The server owner
handles async write progress and the reset-flood result. The client owner
handles HTTP/1 WebSocket shutdown accounting in the runtime and channel
lifecycle. The latter work checks whether the server stops waiting before
the queued close frame drains. A repair has bounded completion and no fixed
sleep used as proof. The server owner retains the single remote diagnostic
slot; the owners coordinate affected files and hand off focused candidates.

The Linux TCP trace reproduced the paced-reader failure with a 4 MiB
kernel send buffer. The mORMot queue stayed at 2,731,113 bytes while the
kernel send queue fell from 4,151,472 to 3,398,461 bytes and TCP acknowledged
bytes rose from 1,515,336 to 2,268,347. This progress continued over more
than one second. The existing sweep ignored that progress and closed the
connection. The raw socket samples are in `lv30-tcpinfo7-20261111T211258`.

The repair adds kernel transmission progress to the Linux write-stall
clock without increasing the timeout. Local send progress remains available
on other platforms. Queue-budget and HTTP/2 flow-control accounting remain
separate from timeout progress. The owner checks queue refill and first
positive backlog behavior and adds a regression that distinguishes a
continued kernel drain from a stalled peer. The unchanged no-reader close,
paced full-body, explicit abort, and complete server checks remain required.

## LV-31: Load fixture admission capacity

The combined load check holds 10,000 WebSocket connections and 10,000 SSE
connections while it sends additional ordinary requests. The examples raise
the detached-stream limit to 30,000 but retain the default listener limit of
10,000 connections. The SSE listener therefore has no capacity for those
ordinary requests after all hold connections open.

The client owner sets an explicit listener limit with capacity for the
required held connections and concurrent ordinary requests. The WebSocket
load mode and the SSE hold example describe their effective limits. Normal
WebSocket example behavior outside load mode remains unchanged. Library
defaults and the 10,000-session workload are unchanged. Root reviews the
fixture change and compiles the affected examples before the load run.

The incomplete-handshake tool also needs an exact admission-bound check.
The public limit maps to mORMot MaxConnections minus one, but mORMot compares
the current reader count with a strict greater-than test. The owner checks
that complete path and a small controlled local probe before claiming an
effective limit of public limit minus one. The tool must use the verified
public limit and actual accepted counts; it must not call client-closed
excess sockets server refusals. No remote jobs overlap the acceptance batch.

## LV-32: Progress sampling changes idle activity

The pristine full run on 475db3d reports failures in
TAsyncServerTest.TestIdleConnectionIsClosed and TestFirstHeaderBlockTimeout,
each after approximately 8.14 seconds. The new sampler calls mORMot
TPollAsyncConnection.TryLock even when the application backlog is zero.
The pinned implementation sets fWasActive when that lock succeeds. Sampling
therefore makes an idle connection appear active and delays idle callbacks.

The server owner makes the no-output sample return without acquiring that
activity-marking connection lock or querying the socket. Idle sampling still
clears stale queue comparison state and permits the next positive backlog to
start a new write-progress period. The repair must not clear fWasActive by
hand, because that could erase real concurrent activity. The existing idle,
first-header, stalled-reader, and steady-reader tests keep their expectations.
Focused checks precede another complete server run. Root reviews and merges
the repair; the current acceptance batch continues alone on Linux.
