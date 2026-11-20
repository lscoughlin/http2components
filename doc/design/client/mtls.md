---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
title: "Mutual TLS (client certificates)"
aliases:
  - "mtls"
  - "client-certificates"
tags:
  - http2client
  - design
  - tls
  - api
status: done
up: "[http2components](../../README.md)"
related:
  - "[client-api](client-api.md)"
  - "[transport](transport.md)"
  - "[proxy](proxy.md)"
  - "[errors-redirects](errors-redirects.md)"
  - "[request-observability](request-observability.md)"
  - "[open-questions](open-questions.md)"
updated: 2026-11-20
notes:
  - The current TLS identity contract uses common provider-loaded identities.
---

# Mutual TLS (client certificates)

Mutual TLS uses the same provider context contract as ordinary HTTPS. A
client identity is a provider-loaded `ITLSIdentity`; it is not a native
certificate pointer. `Http2.OpenSSL` and `Http2.TlsLib` provide PEM and
PKCS#12 loaders. The identity summary exposes copied certificate metadata.
The private key and provider handles remain inside the provider.

The client context owns the default identity and server trust policy. The
server context owns its server identity, client trust anchors, and client
authentication mode. Client trust of the server and server trust of the
client are separate. The same context can contain both policies, but each
provider loads each role's trust data independently.

The origin identity precedence is request identity, then the factory
selector, then the factory identity, then the context default. A selector is
called once for each new dial, outside the pool lock. A selector result of nil
explicitly suppresses the context default. Without a selector, the context
default remains in effect. Expired fixed and request identities are rejected
before a dial; an expired selector result is rejected before socket creation.
All identity choices use common `ITLSIdentity` values.

The HTTPS proxy identity is selected separately with
`WithProxyClientIdentity` and is sent only to the proxy. The origin context
and identity never go to the proxy. The proxy context and identity never go
to the origin. Pool keys include origin and proxy context identity and the
selected origin identity, so sessions with different trust or credentials do
not share a connection.

The server maps a verified peer certificate to a request principal with
`WithClientCertPrincipal`. Principal data comes from copied verified peer
metadata. No native certificate handle crosses the common API. Invalid
presented identities fail authentication in both request and require modes.
The copied PEM field is certificate data; private keys are not part of peer
metadata. Secret key material is not written to logs or observer records.

A WebSocket over HTTP/2 ([websocket](websocket.md)) presents the client identity in the
same way as the HTTP/1.1 route. The identity of the request applies to the TLS connection that carries the WebSocket. Without
a request identity, the choice of the selector applies, and then the fixed identity of the
factory. A pooled connection is keyed
by the identity fingerprint, so a pooled HTTP/2 connection serves only the identity that it was
dialled with. The server handler reads the verified certificate of the extended CONNECT request.
The integration test `Http2.Integration.WssH2.Test` shows both identities.

The TLS 1.2 and TLS 1.3 sessions do not use session resumption or early data.
The common session contract exposes no ticket or early-data controls. RFC
8446 sections 4.3.2 and 4.4 describe certificate requests and authentication;
RFC 9113 sections 9.2 and 9.2.1 constrain TLS use with HTTP/2. These references
were checked 2026-11-11: [RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html)
and [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html).

The server selects one of three common modes: none, request, or require. A
presented invalid certificate is rejected in request and require modes. A
required certificate policy cannot be combined with cleartext access. A
cleartext connection has no TLS certificate identity. System trust is
provider policy and the TlsLib provider does not support it.

OpenSSL identities support PEM and PKCS#12 files or memory. TlsLib identities
support PEM and PKCS#12 files or memory; DER is unsupported. OpenSSL exposes
more verification controls. TlsLib uses fixed verification depth four and
requires hostname verification when peer verification is enabled. Details
are in the [OpenSSL provider](../tls/openssl.md) and [TlsLib provider](../tls/tlslib.md)
designs.
