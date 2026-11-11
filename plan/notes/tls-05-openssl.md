# TLS-05 OpenSSL provider implementation

Checked 2026-11-11 on macOS arm64. The provider uses the pinned mORMot2
OpenSSL bindings at `b2b195da1e0580058672a88620ef71bb47283eb1`. The clone is
read-only and the build output stays in this worktree.

## Source layout

| Unit | Lines | Responsibility |
| --- | ---: | --- |
| `Http2.OpenSSL` | 21 | Public provider names |
| `Http2.OpenSSL.Context` | 163 | Immutable dual-role contexts and sessions factory calls |
| `Http2.OpenSSL.Factory` | 63 | Role policy validation and context construction |
| `Http2.OpenSSL.Session` | 597 | Memory BIO sessions, ALPN, native retry state and metadata |
| `Http2.OpenSSL.Identity` | 306 | PEM and PKCS#12 identities and certificate summaries |
| `Http2.OpenSSL.Trust` | 38 | Trust paths, system trust, partial chains and depth |

Contexts load trust and credentials during `Build`. A client role and server
role use separate native contexts. Each session owns its SSL and memory BIO
state and retains the common context. Provider identity handles stay private.
The identity entry points preserve PEM file and memory loading, encrypted
keys, PKCS#12 file and memory loading, key matching, expiry metadata and
certificate-chain order.

OpenSSL sessions keep accepted plaintext in a bounded 64 KiB queue. A fixed
in-flight write buffer stays unchanged across `SSL_write` retry calls. The
session reserves output capacity before record writes. Local certificate
chains are capped at 32 KiB of PEM and ALPN vectors at 8 KiB. PEM base64 is
larger than DER; the lower aggregate leaves room for TLS certificate framing
and per-certificate overhead inside the 64 KiB encrypted queue. DNS names and
SNI values are limited to 253 bytes. Runtime output checks fail the session
if native output exceeds the queue limit.

The memory-BIO test path does not naturally make `SSL_write` return
`WANT_READ` or `WANT_WRITE`, so the suite does not claim a forced native retry
test. Retry safety uses the retained fixed-address, fixed-length in-flight
buffer. The common transfer tests cover partial transport drains and queue
backpressure.

## Executed provider checks

The OpenSSL runner includes the ten common session contract cases:

| Case | Evidence |
| --- | --- |
| Range validation and zero length | Bad ranges are rejected; zero-length input is accepted. |
| Fragmented handshake and distinct roles | Client and server handshake data is drained and fed in 1-byte and 31-byte pieces. |
| Client write credit and backpressure | Accepted bytes are credited once across a 196,613-byte transfer. |
| Server write credit and backpressure | Reverse-direction transfer has the same exact-credit check. |
| Idle progress stops | Repeated idle advances report no progress. |
| Orderly close and transport EOF | TLS close-notify closes both roles without truncation. |
| Peer snapshot lifetime | Copied metadata remains readable after session teardown. |
| Authenticated plaintext before EOF failure | Buffered bytes are returned before truncation is reported. |
| Abrupt EOF and repeated failure reads | EOF has the transport category; later reads raise fresh errors. |
| Abort clears output | Abort is terminal and repeatable. |

The provider cases also cover:

- PEM files and memory, subject/fingerprint/UTC validity, intermediate order,
  encrypted key passphrase success/failure/absence, key mismatch, truncated
  certificate and key, empty and non-PEM data, missing files, and expired
  identity loading.
- PKCS#12 with and without a chain, memory loading, wrong password, malformed
  data, and secret-free error text.
- TLS 1.2 and TLS 1.3, AEAD cipher selection, DNS name with SNI, IPv4 SAN
  success and wrong-IP rejection.
- mTLS none, request with no identity, request with an invalid presented
  identity, require with a valid identity, and require with missing and
  invalid identities. Failed server handshakes expose no negotiated peer.
- Trusted and wrong-CA certificates, an expired trusted server certificate,
  a partial-chain leaf trust anchor, and verification depth zero.
- Zero-origin handshake timeout, verification error categories, and retained
  alert bytes at the encrypted-output drain boundary.
- Concurrent client and server session creation on one context, ten
  repetitions per role, and ten full context/session create-handshake-release
  cycles.
- Oversized identity chains and ALPN vectors rejected before handshake use.

The native ex-data resource counter is installed before identity loading. After
one warm-up handshake, the measured baseline is X509=6, SSL=0, SSL_CTX=2.
Ten later context and full-handshake cycles return all three counts to that
baseline. This checks native object creation and release counts; it does not
measure process memory or prove behavior on other platforms.

The role factory's expired-identity and missing-identity rejection cases stay
with TLS-07, as agreed during the client migration. IPv6 SAN verification,
full protocol conformance, Linux, load, and cross-provider integration remain
outside this bounded provider run.

## Validation record

Provider build command:

```text
make -C tls/openssl build
```

Runner compile command:

```text
python3 -c "import runpy; from pathlib import Path; m=runpy.run_path('tools/build.py'); m['compile_file'](Path('test/tls/openssl/Http2.Tls.OpenSSL.Tests.pas').resolve(), 'openssl-test', tests=True)"
```

Coordinator run 03 passed 50 cases. Run 07 passed 82 cases. Run 08 passed 84
cases. Post-split run 09 passed 84 cases. Run 10 passed 84 cases after the
pending-write capacity correction and returned X509, SSL, and SSL_CTX counts
to the warmed baseline. The run logs are kept in the coordinator verification
directory. The test suite does not force a native `SSL_write` WANT condition.
