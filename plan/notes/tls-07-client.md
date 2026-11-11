# TLS-07 client migration

Checked 2026-11-11. This note records the client role migration to the frozen
provider-neutral TLS contract in `plan/notes/tls-03-contract.md`.

## Source and API changes

- `Http2.Client.Tls.Socket` owns one `ITLSSession` and moves encrypted bytes
  through `IPartialReader`. The same adapter wraps direct transports and
  connected proxy streams.
- Origin and HTTPS proxy contexts are independent. Owned HTTPS dials require
  client-capable contexts before transport creation. Injected socket factories
  keep their own transport policy.
- The adapter retains DNS-only SNI, ALPN, absolute handshake deadlines,
  partial writes, transport EOF, cancellation, and SIGPIPE protection. A
  serialized session lock protects provider state. A separate reader owner and
  output owner permit full-duplex reads and writes. Pending ciphertext survives
  zero-feed backpressure and is retried after observable session or output
  progress.
- Negotiated ALPN data crosses through `IHttp2TlsSocketInfo`. HTTP/2 requires
  `h2`; configured fallback accepts `http/1.1` or missing ALPN. WebSocket uses
  the HTTP/1.1 metadata path.
- `IClientIdentity` is an alias of `ITLSIdentity`. Identity selection uses
  common leaf metadata. A selector answer of nil remains explicit and does not
  restore the context default.
- Pool keys include origin and proxy context identity, ALPN fallback policy,
  cleartext policy, and the selected client identity. Context references stay
  owned by the socket factory and pool.
- The client no longer imports OpenSSL units or exposes native identity
  loaders. Providers own PEM, DER, and PKCS#12 loaders. `WithCACertFile` and
  `WithInsecureTls(True)` raise `EHttpTlsConfigError`; trust and verification
  policy belongs in `WithTlsContext`. Empty CA-file and false insecure values
  remain no-op legacy defaults.
- Session timeout and abrupt EOF errors map to `EHttpTimeout` and
  `EHttpConnectionClosed`. `SecureRandomCardinal` uses the operating-system
  random device on supported Unix targets. It retries interrupted and short
  reads and raises on failure.

## Test coverage

`test/client/Http2.Client.Tls.Session.Runner.pas` uses helpers in
`Http2.Client.Tls.Session.TestSupport` and contains 17 bounded fake-session
cases. They cover direct and nested TLS pumps, partial encrypted writes and
reads, IPv6 SNI suppression, application reads after the handshake deadline,
zero-feed retention and output-drain retry, absolute deadline under trickle
input, explicit nil identity, ALPN policy, missing/invalid context validation,
pool context-key isolation, selector execution outside the pool lock, cleartext
HTTP/1.1 and prior-knowledge routes through an HTTPS proxy, EOF mapping,
constructor cleanup, blocked read/write cancellation, reader failure waking a
waiting writer, forced write backpressure with a concurrent read, and retention
of the application read timeout after the handshake.

`Http2.Client.ClientCert.Test` checks provider-neutral fixed-selector identity
and nil behavior, factory acceptance of a valid identity, expiry rejection,
and a build without an identity. Native identity-loading and certificate
parsing assertions remain assigned to the OpenSSL provider suite.

## Validation

- `make -C client build` passed before the final focused session fixes.
- The TLS client fake runner compiled with `tools.build.compile_file` after the
  final source changes.
- Coordinator run 16 passed all 17 cases in 0.537 seconds. Earlier diagnostics
  found and fixed lock restoration on handshake failure, output-drain retry,
  and EOF propagation to a concurrent writer.
- An accidental invocation of `make test-tls-client` ran an earlier binary and
  failed with `EThreadError` during the trickle-deadline case. The lock issue
  was corrected and covered by the passing coordinator run. No worker-side
  executable was run after centralized execution was requested.
- The complete `Http2.Client.RunTests` source still needs compilation and
  runtime validation after legacy TLS tests migrate to provider-owned fixtures.
  Earlier compilation stopped in `Http2.Client.MutualTls.Support` on removed
  role-native `TClientIdentity` loaders. Those assertions are preserved for
  migration to `Http2.OpenSSL` APIs after the provider merge.

## Remaining coverage

The fake runner exercises client session and selected tunnel routes. Existing
client tests retain detailed CONNECT, SOCKS, HTTPS-proxy, WebSocket, SSE,
HTTP/1.1 fallback, and mutual-TLS routing assertions. Several of those tests
still call removed role-native TLS loaders or setters and must be migrated to
the provider facade before the broad client test runner can compile. The pool
fake verifies context-key isolation; it does not run two complete HTTPS
requests through distinct contexts.

## Provider-backed legacy test migration

After the OpenSSL provider merge, the client mutual-TLS fixtures now load
identities with `TOpenSSLIdentity` and build immutable client contexts with
`TOpenSSLTlsContextFactory`. Their CA trust anchors and proxy contexts remain
independent. Subject and fingerprint assertions use `ITLSIdentity.Leaf`.

The old `TFakeTlsSocket` subclass and its native method-seam checks were
removed from `Http2.Client.Tls.Support`. Their behavioral coverage remains in
the bounded fake-session runner: SNI, ALPN, partial I/O, context lifetime,
handshake deadline, EOF, close, cancellation, and backpressure. The real
self-signed handshake tests now use an OpenSSL client context with explicit
verification policy. The existing fd-read and proxy CONNECT assertions remain.
Native provider loader, certificate parser, trust, and key ownership checks
remain in the OpenSSL provider suite.

All remaining client live tests use `OpenSslClientTestContext` instead of the
removed CA-file and insecure setters. The live context helper uses a configured
trust anchor when present and system trust only when no anchor is supplied and
verification remains enabled.

The full `Http2.Client.RunTests` program now compiles with
`-Fu tls/openssl/src -dUSE_OPENSSL`. No broad client test executable has run.
The registered bounded mutual-TLS groups are
`TMutualTlsRoutingTest`, `TMutualTlsOtherTest`, `TMutualTlsAcceptTest`,
`TMutualTlsRejectTest`, and `TMutualTlsRequestTest`. Proxy transport groups are
`TProxyTransportTest` and `TProxyTransportAdditionalTest`.
