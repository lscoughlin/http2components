---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, design
updated: 2026-11-11
notes:
  - This document describes the merged TLS API.
---
# OpenSSL provider

`Http2.OpenSSL` exports `TOpenSSLTlsContextFactory`, `OpenSSLTlsContext`,
and `TOpenSSLIdentity`. The factory takes common client and server policies
and returns `ITLSContext`. `TOpenSSLIdentity` loads PEM and PKCS#12 identities
from files or memory. Application code uses the common identity interface.
It does not access native `PX509` or `PEVP_PKEY` values.

The provider supports client and server roles, TLS 1.2 and TLS 1.3, PEM and
PKCS#12 identities, system trust, explicit PEM trust anchors, partial-chain
trust, and configurable verification depth. Trust anchors are PEM file paths.
The secure client policy verifies the peer and hostname but adds no trust
anchors and does not enable system trust. A client policy therefore selects
PEM paths with `WithTrustAnchors` or enables the system store explicitly with
`WithSystemTrust(True)`. It uses separate native contexts for client and
server roles. Context policy and credentials are loaded before
sessions are created. Session resumption and early data are disabled.

OpenSSL owns the native SSL objects, BIOs, certificate stores, and identity
handles. `ITLSSession` exposes only bounded byte buffers and common metadata.
The context remains alive while any session refers to it. Sessions are
serialized by their transport owner. One context can therefore create client
and server sessions for different threads without sharing mutable session
state.

The client HTTP/2 role offers `h2`; the server selects from the client's
ALPN offer. The provider reports the selected value. HTTP/2 over TLS requires
TLS 1.2 or later and ALPN `h2` under RFC 9113 sections 3.2 and 9.2. RFC 7301
sections 3.1 and 3.2 define ALPN negotiation. These references were checked
2026-11-11: [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html) and
[RFC 7301](https://www.rfc-editor.org/rfc/rfc7301.html).

The OpenSSL package has a native OpenSSL runtime dependency. TlsLib has no
dependency on the OpenSSL provider. The two provider packages use the same
`ITLSContext` contract and can be selected independently for each application
context.

The common error record carries a neutral error category, an optional native
provider detail, a received peer alert description when available, and
CertificateRequest evidence when the provider observes it. A failed TLS 1.2
handshake does not always expose enough native evidence to identify why the
peer rejected a client identity. This is an error-metadata limit; handshake
rejection behavior remains unchanged. The bounded provider suite does not
force native `SSL_write` WANT_READ or WANT_WRITE. Retry handling retains a
stable write buffer, and common transport tests cover partial drains and
backpressure; a forced native retry is not claimed as a passed test.
