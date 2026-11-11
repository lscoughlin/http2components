---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, design
updated: 2026-11-11
notes:
  - This document describes the merged TLS API.
---
# Common TLS context and session contract

## Ownership

`Http2.Common.Tls.Context` owns the `ITLSContext` interface. The common
facade re-exports this same interface by alias. Client and server factories
accept this interface; neither role declares a second TLS context type.
Provider units are `Http2.OpenSSL` and `Http2.TlsLib`.

A context is immutable policy and loaded credential state. It has no socket,
current peer, hostname, ALPN selection, or active session. A context can
create client and server sessions when it has both role policies. One such
context can be shared by a client and a listener, including across threads.
Each session retains the context and belongs to one serialized transport
owner. Separate sessions carry each connection's name, ALPN, identity, and
deadline. Session state is not shared between connections.

## Policy and trust

Client trust and server trust are separate policies. Client trust validates
the server certificate. Server trust validates client certificates for mTLS.
Neither role inherits the other role's trust anchors. A provider identity is
also provider-specific. A context rejects an identity loaded by another
provider.

The client policy verifies the peer and hostname by default. A secure default
does not select system trust or add trust anchors. Trust anchors are PEM file
paths supplied through `WithTrustAnchors`; OpenSSL system trust is an explicit
`WithSystemTrust(True)` choice. `WithInsecure` sets both verification flags
off and is an explicit policy choice. The server
policy selects a local server identity, TLS version range, client-auth mode,
and client trust anchors. The server role factory selects the request
principal with `WithClientCertPrincipal`. TLS 1.2 and 1.3 are the supported
versions. Session resumption and early data are disabled.

A nil client identity selection is explicit: it suppresses the context's
default identity. It does not restore the default. Identity summaries and
peer certificate summaries contain copied text, validity times, fingerprints,
and SAN values. They expose no native certificate or key pointers.

## Buffer sessions

`ITLSSession` accepts and returns TLS ciphertext and application plaintext
through bounded buffers. It performs no socket I/O and does not sleep. The
transport retains unaccepted input and unsent output. `Advance` reports
progress against an absolute monotonic deadline. Transport EOF without an
authenticated TLS close is a truncation error. `Abort` is terminal and clears
queued session data.

Negotiated metadata becomes available only after the handshake. It includes
role, version, cipher, ALPN, and copied verified peer data. A certificate that
was presented but not verified is not an application principal.

RFC 8446 sections 4, 5, and 6 define the handshake, records, and alerts.
RFC 5280 sections 4.1 and 6 define certificate path validation. RFC 9525
sections 4 through 7 define service identity checks. These references were
checked 2026-11-11: [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html),
[RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html), and
[RFC 9525](https://www.rfc-editor.org/rfc/rfc9525.html).
