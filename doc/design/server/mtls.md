---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls
---
# Server mutual TLS

The server context owns its server identity, client trust anchors, TLS version
range, and client-auth mode. Client trust of a server belongs to the client's
context and is independent. OpenSSL and TlsLib identities are provider-owned
`ITLSIdentity` values. The common interface exposes copied certificate
summaries and has no `PX509` or `PEVP_PKEY` getter.

The server factory accepts the context through `WithTlsContext`. It selects
the request principal through `WithClientCertPrincipal`. The supported
principal selections are verified subject DN, common name, or no certificate
field, according to `TClientCertPrincipal`. The server derives principal data only from a
verified peer certificate. An unverified or merely presented certificate
never becomes a request principal.

The common client-auth modes are `tlsAuthNone`, `tlsAuthRequest`, and
`tlsAuthRequire`. None does not request a certificate. Request accepts a
connection without a certificate but rejects an invalid certificate when one
is presented. Require rejects both a missing and an invalid certificate.
Required client authentication cannot be combined with cleartext access.
Cleartext has no TLS handshake and no certificate identity. RFC 8446
sections 4.3.2 and 4.4 define CertificateRequest and authentication; RFC 9113
sections 9.2 and 9.2.1 constrain TLS versions and renegotiation for HTTP/2.
These references were checked 2026-11-11: [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html)
and [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html).

Trust settings are provider-specific. OpenSSL supports explicit PEM trust,
system trust, partial-chain trust, and configurable verification depth.
TlsLib requires explicit trust data when client authentication is enabled.
It supports partial-chain trust, does not support system trust, and uses
fixed verification depth four. A TlsLib policy that sets depth, including
zero, fails at context construction. A presented identity loaded by another
provider is rejected before the handshake.

The listener context can be shared by threads and connections. Each accepted
connection owns a separate serialized session that retains the context. Peer
certificate metadata is copied before the session is released. Session
resumption and early data are disabled.

RFC 5280 sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12, and 6 cover certificate
fields, SANs, constraints, extended key usage, and path validation. RFC 4514
sections 2 and 3 define distinguished-name string conversion. Checked
2026-11-11: [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html) and
[RFC 4514](https://www.rfc-editor.org/rfc/rfc4514.html).
