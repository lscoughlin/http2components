# Provider and client review record

Review date: 2026-11-11. This is an interim record. TLS-05, TLS-06, and
TLS-07 are not yet accepted or merged.

## Execution control

The coordinator runs one bounded executable at a time. Workers compile in
separate worktrees. Each executable has a 30-second outer deadline. The
worker keeps the binary unchanged during its run. Compiler work can occur
in parallel. No load test, Linux validation, or broad validation target ran.

The logs are under `bin/tls-coordinator/`. A log records the binary path,
UTC start, monotonic elapsed time, and child exit status. These worktree
runs do not replace final checks of the merged source.

## OpenSSL

`tls05-coordinator-03.log` passed 50 cases before the pending-write change.
Runs 04, 05, and 06 passed the ten shared session cases, then failed the
new verification-alert assertion. Run 06 showed a failed client with the
verification category, but the final alert drain returned zero. The review
must distinguish an alert already consumed by the test from missing output.

Review found that direct native write retries did not preserve input
ownership. A copied queue is required. A native retry also needs a fixed
count and stable bytes: later appends must not change the in-flight call.
The OpenSSL error queue must be clear before native I/O. Output limits must
include handshake output and TLS record overhead. The current proposed
local limits are 32 KiB of identity PEM and 8 KiB of ALPN wire data.

Peer chain deduplication must compare certificates, not only subject names.
Metadata remains available only in the open state. Native resource counters
must return to their baseline after the bounded lifecycle cases. The old
X509 ex_data counter is in the server mTLS live test helper. Its behavior
moves into provider test ownership without a provider-to-server dependency.

## TlsLib

Run 01 timed out because a test transfer loop repeated after zero input
acceptance. This was a test fault, not evidence of slow cryptography. Runs
02 and 03 then failed the distinguished-name assertion in less than one
second. Run 04 also failed that assertion after a multi-valued RDN was
added. RFC 4514 does not impose order within the attributes of one RDN SET.
The test must preserve grouping and escaping without imposing a false
cross-provider order on that SET.

The native engine has an advisory 1 MiB plaintext threshold. The wrapper
must enforce the common 64 KiB queue bound across wrapper and engine data.
Completing a buffered TLS record can produce a whole record of plaintext;
a one-byte feed is not a one-byte plaintext bound. Native output and TLS
record overhead also count toward the encrypted output limit. Handshake
reassembly is separate bounded protocol state.

Other open checks include named cipher metadata, unverified peer metadata,
fixed deadline overflow, fatal exception categories with retained alerts,
Build-time required credentials/trust, leaf-unit separation, and explicit
resource ownership evidence.

## Client

`tls07-coordinator-06.log` passed eight cases in 0.311 seconds. It includes
constructor cleanup after a zero-progress transport write. Earlier runs
found missing thread initialization, then a lock double free in constructor
failure cleanup. The automatic destructor is the sole lock owner.

Further source review found an application-read path that still applies the
handshake deadline, IPv6 literal detection that rejects hexadecimal letters,
and a session lock held across a blocking transport read. Required checks
include a concurrent write during a blocked read, prompt cancellation,
retained input after zero acceptance, and an absolute trickle deadline.

Existing CONNECT, SOCKS, HTTPS proxy, WebSocket, SSE, and mTLS tests remain
in the client suite. Native loader support in those tests still needs the
new provider facade. Their presence is not a pass: the affected bounded
cases must compile and run after provider merge. The general client suite
and network/container proxy suites are not story checks.
