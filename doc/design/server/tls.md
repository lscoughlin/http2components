---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls
---
# Server TLS and ALPN

The server factory selects TLS with `WithTlsContext(const AContext: ITLSContext)`.
The context must support the server role. TLS identity, client trust, version
range, and client-auth mode belong to the provider-neutral server policy.
Cleartext permission and HTTP/1.1 fallback remain separate server settings.
A server without a TLS context does not enable TLS implicitly.

The async accept path creates one common `ITLSSession` for each TLS
connection. It moves encrypted bytes between the socket and the session and
passes plaintext to the HTTP protocol core only after the session is open.
The session has bounded input and output buffers. A session call does not
perform socket I/O or block. Session state is serialized per connection;
listener policy and provider context can be shared across connections.
Each session retains its context until it closes.

ALPN remains an application-protocol decision. The server offers `h2`; when
HTTP/1.1 fallback is enabled, it also offers `http/1.1`. A completed session
with `h2` enters the HTTP/2 core. A completed session with `http/1.1` enters
the HTTP/1.1 path only when fallback is enabled. Missing or unsupported ALPN
is refused when fallback is disabled. RFC 7301 sections 3.1 and 3.2 define
ALPN. RFC 9113 sections 3.2 and 9.2 require `h2` and TLS 1.2 or newer for
HTTP/2 over TLS. These references were checked 2026-11-11:
[RFC 7301](https://www.rfc-editor.org/rfc/rfc7301.html) and
[RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html).

Handshake deadlines use monotonic time. Socket readiness drives session
progress; a silent or trickling peer cannot restart the absolute deadline.
Transport EOF without TLS `close_notify` is a truncation error. A fatal alert
is terminal. The server stops accepting sessions before it releases the
listener context during shutdown.

The TLS provider remains outside `Http2.Server.*`. OpenSSL and TlsLib both
implement `ITLSContext` and `ITLSSession`. The server does not import provider
units or read native certificate pointers. OpenSSL uses its native SSL and
memory-BIO API inside `Http2.OpenSSL`; TlsLib uses its pinned sans-I/O engine
inside `Http2.TlsLib`. Their feature differences are listed in the provider
designs.

Session resumption and early data are disabled by both providers. RFC 8446
sections 4, 5, and 6 describe handshakes, records, and alerts; RFC 8740
sections 2 through 4 describe HTTP/2 use of TLS 1.3. Checked 2026-11-11:
[RFC 8446](https://www.rfc-editor.org/rfc/rfc8446.html) and
[RFC 8740](https://www.rfc-editor.org/rfc/rfc8740.html).
