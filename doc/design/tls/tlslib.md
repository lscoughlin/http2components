---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, design
updated: 2026-11-11
notes:
  - This document describes the merged TLS API.
---
# TlsLib provider

`Http2.TlsLib` exports `TTlsLibContextFactory`, `TlsLibContext`, and
`TTlsLibIdentity`. The factory accepts common client and server policies and
returns `ITLSContext`. `TTlsLibIdentity` loads PEM and PKCS#12 identities from
files or memory. DER identity loading is unsupported. Application code uses
`ITLSIdentity`; it receives no native engine or certificate handles.

The provider supports client and server roles, TLS 1.2 and TLS 1.3, PEM and
PKCS#12 identities, explicit PEM trust anchors, and partial-chain trust.
Trust anchors are PEM file paths. The secure client policy does not supply
anchors; an application with peer verification enabled selects them with
`WithTrustAnchors`. TlsLib does not use system trust. Verification depth is
fixed at four; a policy
that sets depth, including zero, fails during context construction. Client
peer verification requires hostname verification. Distinct SNI and
verification names are unsupported. Session resumption and early data are
disabled.

The pinned engine does not expose these OpenSSL controls. The adapter reports
its capabilities and rejects unsupported requests instead of silently
ignoring them. It requires explicit trust anchors when client peer
verification is enabled. The engine's CertificateRequest evidence is not
available before some failed handshakes, so TLS 1.2 alert 40 can remain a
generic connection error when no request evidence exists. A received wire
alert remains available in session error metadata.

TlsLib uses a sans-I/O engine. Sessions accept and return bounded byte
buffers. Each transport serializes its own session calls, and every session
retains its context. One context can be shared across client and server roles
and threads. The package has no OpenSSL dependency. On macOS with Free Pascal,
the build uses a hash-checked CryptoLib random-provider overlay in `bin/`;
the pinned dependency checkout remains unchanged. Package builds use a
private Lazarus configuration and preserve the ordered CryptoLib bootstrap.
After that fresh bootstrap, a scoped wrapper removes only the forced `-B`
argument from the TlsLib `lazbuild` invocation. This keeps the bootstrap PPUs
available through the upstream source cycle. The wrapper does not change
global compiler settings.

RFC 8446 sections 4, 5, and 6 define the TLS behavior used by the adapter.
RFC 5280 sections 4.1 and 6 define path validation. RFC 9525 sections 4
through 7 define service identity checks. These references were checked
2026-11-11: [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html),
[RFC 5280](https://www.rfc-editor.org/rfc/rfc5280.html), and
[RFC 9525](https://www.rfc-editor.org/rfc/rfc9525.html).
