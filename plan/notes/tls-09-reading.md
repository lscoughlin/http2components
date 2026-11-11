# TLS-09 reading and evidence

Checked 2026-11-11 at base `f52bdf7d2b50b7a64bb337fa519637043f667019`.

## Reading

- R1: RFC 9113 sections 3.2, 3.4 and 9.2; RFC 8740 sections 2 and 3; RFC 7301 sections 3.1 and 3.2. HTTPS HTTP/2 uses ALPN `h2`, then both peers send their connection preface. HTTP/2 does not use `h2c` over TLS. RFC 8740 permits TLS 1.3 post-handshake messages and requires implementations to support KeyUpdate. ALPN carries a list of non-empty protocol IDs and the server selects one offered value.
- R2: RFC 8446 sections 4.1, 4.2, 4.3.2, 4.4, 5 and 6. The handshake negotiates versions and extensions, CertificateRequest controls client authentication, certificate messages and verification form the authentication exchange, record protection carries application data, and alerts carry errors and closure. `close_notify` is the authenticated closure signal.
- R3: RFC 5280 sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12 and 6; RFC 4514 sections 2 and 3. Certificate identity includes subject and issuer names, validity, key usage and SAN forms. Path validation checks certificate signatures and constraints. Distinguished-name strings use escaped attribute values and reverse RDN order.
- R4: `doc/design/client/mtls.md` and client TLS, proxy, fallback, selector, pool and socket tests. Origin and HTTPS proxy contexts are separate; explicit nil identity selection must not restore a default identity; TLS context participates in pool identity.
- R5: `doc/design/server/tls.md`, `doc/design/server/mtls.md`, server async accept, TLS policy, ALPN, principal and listener tests. The server selects ALPN by its per-listener policy. Peer identity is verified before a principal is exposed and copied metadata remains tied to the connection.

## Frozen integration contract

`ITLSContext` is the sole declaration in `Http2.Common.Tls.Context`; the
`Http2.Common` facade aliases it. Client and server factories accept this
interface. The context has separate client and server policies. Its sessions
are distinct role objects and retain the context. The provider factories are
`TOpenSSLTlsContextFactory` and `TTlsLibContextFactory`. Identity loaders live
in provider facades. Server configuration uses `WithTlsContext`, `WithClearTextAllowed`,
`WithHttp11Fallback`, and `WithClientCertPrincipal`; client configuration uses
`WithTlsContext` and `WithProxyTlsContext`.

The acceptance matrix requires all four client/server provider pairs and both
TLS 1.2 and 1.3 for valid HTTP/2 requests. Shared trust, client-auth, ALPN,
identity and lifetime features apply to all pairs. Same-provider loopback is
integration evidence only. Required rows cannot be reported as skipped.

## Scope and bounded execution

This worktree owns test/API probes, integration tests and TLS fixtures. The
plan is user-owned and is not changed here. Tests compile only in this worktree.
No TLS or network test executable is run by this worker. The central run limit
is one executable at a time, 30 seconds per executable, at most ten lifecycle
repetitions, and only a few simultaneous sessions. Test timeouts need cleanup.

RFC reading is protocol context, not test evidence. The standalone integration
program is `test/integration/tls/Http2.Tls.Integration.Tests.pas`. It has eight
provider-pair TLS metadata cases, eight provider-pair HTTP/2 request/response
cases, five listener cases, and eight concurrent request cases. Each pair is
tested at TLS 1.2 and TLS 1.3. It records negotiated version, ALPN, cipher,
verified client and server peer identities, distinct client and server
identity summaries, copied metadata after session teardown, HTTP status, and
response content. Negotiated version, ALPN, cipher and peer-summary checks use
direct provider sessions. They do not inspect metadata from the separate HTTP
transport sessions. The HTTP exchanges constrain the same contexts to the
same TLS version, require strict `h2`, and require a verified client
certificate principal in the request handler. Same-provider cases pass one
context reference to both role factories. Concurrent request cases use two
clients and one listener, all using that context. A handler barrier checks
that both concurrent requests are active at the same time. Listener requests
use new clients so each request creates a new connection. The listener cases
use OpenSSL and TlsLib in one process, interleave requests, stop one listener,
and verify fresh connections to the other. The expected count is 29 cases.
Output case IDs use A03 for the 16 TLS metadata and HTTP/2 pairs, A04 for the
five listener requests, and A02 for the eight concurrent requests. API probes
check exact common facade and declaration assignments, client/server factory
acceptance, and OpenSSL/TlsLib identity, context, and factory aliases.
Fixture paths resolve by walking upward from the executable to the repository
root, so the integration target can run from its isolated `bin/.../programs`
directory. Body reads use the configured idle timeout.
The run limit is 30 seconds. The coordinator ran 29 cases at revision
`696e1cd` in 6.488 seconds with exit 0. Log:
`bin/tls-coordinator/tls09-integration-03.log`. It reported TLS 1.2 and 1.3,
ALPN `h2`, nonempty ciphers, and verified peers for all eight provider pairs.
That tested revision preceded the per-case A02/A04 output labels and
executable-relative fixture lookup in later commits.

Earlier runs failed for test-driver and test-setup reasons. At `61b7a4f`, the
child returned exit 0 with `PASS 20 provider-pair TLS metadata and HTTP/2
cases`, but the driver rejected the nonstandard summary and empty FPCUnit
suite (`tls09-integration-01.log`). At `2266a87`, the run stopped after 20
cases because the listener test used a server-only context for a fresh client
(`tls09-integration-02.log`). The listener now creates a client-role context.

The worker compiled the runner and API probe with these compile-only
commands. The final merged target remains the runtime check for the later
logging and fixture-resolution changes:

```sh
MORMOT2_ROOT=/Users/liamcoughlin/Source/lscoughlin/http2components/third_party/mORMot2 \
TLSLIB4PASCAL_ROOT=/Users/liamcoughlin/Source/lscoughlin/http2components/third_party/TlsLib4Pascal \
CRYPTOLIB4PASCAL_ROOT=/Users/liamcoughlin/Source/lscoughlin/http2components/third_party/CryptoLib4Pascal \
HASHLIB4PASCAL_ROOT=/Users/liamcoughlin/Source/lscoughlin/http2components/third_party/HashLib4Pascal \
SIMPLEBASELIB4PASCAL_ROOT=/Users/liamcoughlin/Source/lscoughlin/http2components/third_party/SimpleBaseLib4Pascal \
python3 -c 'import tools.build as b; b.compile_file(b.ROOT / "test/integration/tls/Http2.Tls.Integration.Tests.pas", "tls-integration-test", tests=True); b.compile_file(b.ROOT / "test/api/Http2.Tls.ApiIdentity.Probe.pas", "tls-integration-test", tests=True)'
```
