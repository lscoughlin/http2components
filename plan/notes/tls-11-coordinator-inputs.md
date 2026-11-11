# TLS-11 coordinator inputs

This list records migration details from the accepted implementation on
2026-11-11. Integration and package acceptance are still in progress. This
list is not a verification result for those tasks.

## Public surface

- Common owns the TLS types, policies, identity metadata, context, and
  buffer-session interfaces. Client and server facades use type aliases.
- Both role factories have `WithTlsContext`. The client also has
  `WithProxyTlsContext`. Context selection is explicit. A TLS URL without a
  suitable context fails before DNS or socket creation.
- Server `WithTls` and `TTlsServerOptions` are removed. Cleartext and
  HTTP/1.1 fallback remain role settings. Principal selection is
  `WithClientCertPrincipal`. Required client authentication rejects
  cleartext permission.
- Client `WithInsecureTls(True)` and a nonempty `WithCACertFile` remain
  compatibility errors with migration guidance. They do not select a
  provider. Provider policies now own trust and verification settings.
- Identity loading belongs to `TOpenSSLIdentity` or `TTlsLibIdentity`.
  `IClientIdentity` aliases the common identity type. A nil selector result
  explicitly suppresses the default identity. Proxy and origin contexts
  and identities remain separate.
- Peer data has no native certificate pointer. Verified peer data supplies
  the server principal. Copied metadata survives the native TLS session.

## Provider capabilities and limits

Both providers support TLS 1.2 and 1.3, both roles, ALPN, explicit PEM trust,
PEM and PKCS#12 identities, and partial-chain policy. Session resumption and
early data are disabled.

TlsLib rejects system trust, explicit verification depth including zero,
DER identities, distinct SNI and verification names, and peer verification
with hostname verification disabled. Its native verification depth is four.
It requires explicit trust anchors. The pinned engine does not expose a
TLS 1.2 CertificateRequest before a failed handshake. A received alert 40
therefore remains a generic connection error when that evidence is absent.
The wire alert description is still available. The OpenSSL provider retains
the prior client certificate error mapping when request evidence exists.

The OpenSSL write-retry buffer was reviewed for stable address and length.
The native `SSL_write` WANT branch was not forced deterministically. This
limit remains separate from passed transport backpressure tests.

## Documentation and examples

Current migration references occur in client API, proxy, and mTLS design
documents, and server configuration, architecture, TLS, and mTLS documents.
The client 0.23.0 history describes its own historical API; historical claims
are distinct from current instructions.

Existing examples with removed calls include `client/mtls_get.pas` and
server `mtls_server.pas`, `tls_server.pas`, and `interop_server.pas`.
Existing command-line options can select explicit OpenSSL policies inside
these programs. The integration examples add explicit OpenSSL selection,
TlsLib selection, one dual-role context, and separate proxy context.

Five source roots and six packages are present. Readers remains optional
and separate from client core. The server TLS implementation also uses
`server/src/Http2.Server.Async.Tls.inc`; it is part of its parent unit.
Normal builds are offline. Dependency setup is an explicit operation.

The existing deferred validation rows remain deferred. The later plan adds
TLS-specific Linux, load, independent peer, full conformance, proxy, and
timed server checks. The old three-component build row requires the new
five-component scope. Documentation does not refer to plan files.
