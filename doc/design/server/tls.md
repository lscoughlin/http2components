---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls, alpn, openssl
notes:
  - The TLS route and the ALPN binding of the server.
  - "The route is option A: the mORMot2 INetTls interface plus one ALPN
    select callback, installed on the server context after the socket binds."
  - Imported from http2server/doc/design/server/tls.md at the source commit recorded in the source inventory.
  - API and architecture details await final merged-source review.
scope: How the server reaches ALPN, the TLS plug-in of a connection, and the mORMot2 TLS facts the route rests on.
primary_types:
  - TAlpnSelectCb
  - TSslCtxSetAlpnSelectCb
  - TTransport
  - TTlsPolicy
db_tables: None.
related_docs:
  - doc/design/server/protocol.md
  - doc/design/server/fpc-runtime.md
  - doc/design/server/io-pool.md
  - doc/design/server/mtls.md
invariants:
  - A client that offers no acceptable ALPN protocol is refused with a
    fatal alert, so no HTTP/1.1 request ever reaches an HTTP/2 code path.
    With the HTTP/1.1 fallback on, a client that offers http/1.1 or no ALPN
    extension is served by the HTTP/1.1 core and never by the HTTP/2 core.
  - The ALPN callback argument outlives every handshake. It is one of two static records, one for each value of the HTTP/1.1 fallback, so two servers in one process keep their own policy.
  - The server chooses the protocol (RFC 7301 section 3.2). It picks h2 wherever the client lists it, and http/1.1 only when the fallback is on and h2 is absent.
  - A TLS connection that did not negotiate h2 is refused after the handshake when the fallback is off, and is served as HTTP/1.1 when the fallback is on.
  - The handshake deadline of the factory never exceeds the mORMot2 bound.
---
# TLS and ALPN

A TLS connection carries an ALPN extension. The server selects `h2` from the
list that the client offers. When the HTTP/1.1 fallback is off, a client that
does not offer `h2` is refused with a fatal alert, so the server never receives
an HTTP/1.1 request on a connection it believes to be HTTP/2. When the fallback
is on (the default), the server also accepts `http/1.1`, and a client that sends
no ALPN extension is served as HTTP/1.1. The factory flag feeds the policy field
`AllowHttp11`. The document [http1](http1.md) describes the fallback.

## The route

The server uses the mORMot2 `INetTls` interface, which wraps OpenSSL, and adds
one callback: `SSL_CTX_set_alpn_select_cb`. This route needs no change to
mORMot2. It is the option A of the analysis below.

## mORMot2 facts the route rests on

The following facts come from reading the pinned mORMot2 revision
`b2b195da1e0580058672a88620ef71bb47283eb1`. They are the facts that decide the
route, so they are recorded here with their citations.

**Where the server context exists.** `TOpenSslNetTls.AfterBind` creates the
server `SSL_CTX` with `SSL_CTX_new_server`, runs `SetupCtx` on it, and stores
it in the `AcceptCert` field of the `TNetTlsContext` record
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas`). The
context outlives every connection, and `AfterAccept` reuses it.

**`AcceptCert` is public.** `AcceptCert` is a public field of the
`TNetTlsContext` record (`third_party/mORMot2/src/net/mormot.net.sock.pas`).
A caller that holds the context reaches the server `SSL_CTX` with a pointer
cast, so a hook after `AfterBind` needs no new mORMot2 entry point.

**Where to install the callback.** `AfterBind` runs `SetupCtx` and
sets only the servername callback
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas`). It sets
no ALPN select callback, so a caller can install one after `AfterBind` returns.
The server does this through `Http2AlpnAttach`, which reads the context from a
bound `TCrtSocket`.

**The handshake blocks the calling thread.** `AfterAccept` calls
`CheckProc(@SSL_accept, 'AfterAccept SSL_accept')`
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas`).
`CheckProc` loops on `SSL_accept` and, on a `WANT_READ` or `WANT_WRITE`,
calls `fSocket.WaitFor(100, ne)` (`...:12169-12188`, `...:12146-12167`). The
loop carries a deadline of 5000 ms and raises a timeout exception when it
passes. The calling IO thread therefore blocks inside the handshake, and a
client that opens TCP and sends nothing holds that thread for 5 seconds at
most.

**The stalled-client cost.** Because the handshake blocks its IO thread for up
to 5 seconds, a client that stalls delays only the thread that accepted it.
The async server accepts asynchronously when TLS is on
(`third_party/mORMot2/src/net/mormot.net.async.pas`, `async=false` for the
accept), and the handshake runs at the first read in
`OnFirstReadDoTls` (`...:4247-4270`). A second client still completes its
handshake on another thread.

**How the async server reports no data.** `INetTls.ReceivePending` returns the
bytes held in the TLS buffer, `0` when that buffer is empty but socket-level
data may still be unciphered, and `-1` when no TLS connection is open
(`third_party/mORMot2/src/net/mormot.net.sock.pas`). `INetTls.Send`
returns `nrRetry` when the socket is not ready, and the caller retries the same
buffer (`...:1223-1228`).

**The per-connection object.** The async server holds one `INetTls` instance
per connection, in the `fSecure` field of `TPollAsyncConnection`
(`third_party/mORMot2/src/net/mormot.net.async.pas`, `...:4264`). The
instance is created by `NewNetTls`, which `mormot.lib.openssl11` points at
`NewOpenSslNetTls` once OpenSSL loads
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas`).

## The binding

`Http2.Server.Alpn` resolves `SSL_CTX_set_alpn_select_cb` from libssl. The
mORMot2 `libssl` handle is a private variable of
`mormot.lib.openssl11` (`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas`),
and no public accessor names it, so the unit loads libssl a second time. The
second load uses the same path rules as mORMot2: `OPENSSL_LIBPATH` first, then
the platform library names `LIB_SSL4`, `LIB_SSL3` and `LIB_SSL1`
(`...:150-243`). A second `dlopen` of an already-loaded library returns the
same handle, so no second copy of the library enters the process.

`Http2AlpnBindingAvailable` reports whether the symbol resolved
(`src/Http2.Server.Alpn.pas`). `Http2AlpnAttachCtx` installs the
callback on a server context, and `Http2AlpnAttach` reads that context from a
bound `TCrtSocket` (`src/Http2.Server.Alpn.pas`).

## The select rule

The callback receives the client protocol list in the wire format of RFC 7301:
a vector of 8-bit length-prefixed byte strings. It chooses `h2` wherever that
entry appears. When the caller permits the fallback, it accepts `http/1.1` as
well. When no entry matches, the callback returns
`SSL_TLSEXT_ERR_ALERT_FATAL` (`2`), which refuses the handshake with a fatal
alert. A malformed list — a zero length entry, or an entry that claims more
octets than remain — is refused in the same way.

The decision is a pure function, `Http2AlpnSelectOffset`, which returns the
offset of the chosen entry or `-1` (`src/Http2.Server.Alpn.pas`). The
OpenSSL callback is a thin wrapper over it, so a test reaches every branch of
the rule with no handshake and no socket.

The callback argument is a record with a process lifetime, because the OpenSSL
manual page requires that the argument outlive the handshake
(`src/Http2.Server.Alpn.pas`).

## The negotiated name

`Http2AlpnSelected` reads the negotiated name with `SSL_get0_alpn_selected`
through the `PSSL` returned by `INetTls.GetRawTls`
(`src/Http2.Server.Alpn.pas`). An empty result means that no protocol
was selected.

## The TLS plug-in of a connection

The unit `src/Http2.Server.Tls.pas` applies the policy to a bound socket. It
keeps every decision in a pure function, so a test reaches each branch with no
socket and no OpenSSL.

| Function | Decision |
| --- | --- |
| `TransportFor` | Which transport a policy offers: TLS, cleartext or a refusal (`src/Http2.Server.Tls.pas`). |
| `HandshakeExpired` | Whether a handshake has used up a deadline; a zero deadline never expires (`src/Http2.Server.Tls.pas`). |
| `EffectiveHandshakeTimeoutMs` | The deadline the server applies, clamped to the mORMot2 bound (`src/Http2.Server.Tls.pas`). |
| `NegotiatedH2` and `NegotiatedAlpnName` | Whether the finished handshake selected `h2`; a nil TLS instance answers False (`src/Http2.Server.Tls.pas`). |

`ApplyTls` carries out the policy on a bound socket
(`src/Http2.Server.Tls.pas`). The order is fixed: mORMot2 creates the
server `SSL_CTX` inside `AfterBind`, so the server records the certificate and
the key, calls `DoTlsAfter(cstaBind)`, and only then installs the ALPN
callback on the context that `AfterBind` stored in `AcceptCert`. The protocol
range follows the ALPN callback on the same context, and `ApplyClientTrust`
follows the range: it loads the trust anchors, sets the verify mode and disables
renegotiation ([mtls](mtls.md)). The call answers False when no certificate is
named, the certificate file is absent, the client CA file cannot be loaded, or
OpenSSL refuses the protocol range.

## The protocol range

RFC 9113 section 9.2 requires TLS version 1.2 or higher for HTTP/2 over TLS.
RFC 9113 is the source for the version floor. It was checked on 2026-11-06 at
https://www.rfc-editor.org/info/rfc9113. The plain-text copy is
doc/references/rfc9113.txt. The factory holds the accepted range in
`MinTlsVersion` and `MaxTlsVersion` (1.2 to 1.3 by default), and the factory
refuses a minimum above the maximum at build time. `BuildTlsPolicy`
(`src/Http2.Server.Async.Options.pas`) copies the range to `MinProtocol`
and `MaxProtocol` of `TTlsPolicy` (`src/Http2.Server.Tls.pas`) as the
OpenSSL version numbers `TLS1_2_VERSION` and `TLS1_3_VERSION`. `ApplyTls` sets
the range on the server context with `SSL_CTX_set_min_proto_version` and
`SSL_CTX_set_max_proto_version` (`src/Http2.Server.Tls.pas`), after the
ALPN callback and before the client trust call. A zero bound keeps the context
value, so a policy that names no range leaves the mORMot2 defaults in place. A
refused range makes `ApplyTls` answer False, and `Start` then raises instead of
serving (`THttp2AsyncServer.Start` in `src/Http2.Server.Async.pas`), so the
server never runs with an unset range. The fpcunit suite holds the mapping test
and the loopback handshake tests of the range in
`test/Http2.Server.TlsProtocols.Test.pas`.

## The handshake deadline

mORMot2 runs the server handshake at the first read of each connection, inside
`INetTls.AfterAccept`, and it bounds the `SSL_accept` loop with a 5000 ms
deadline (`mormot.lib.openssl11.pas`). A larger factory value can
never take effect, so `EffectiveHandshakeTimeoutMs` clamps the factory value to
that bound (`EffectiveHandshakeTimeoutMs` in `src/Http2.Server.Tls.pas`). The
server also sets the socket send and receive deadlines to the clamped value
before the handshake runs (`SetHandshakeDeadline` in
`src/Http2.Server.Async.Options.pas`). A client that opens a socket and sends
nothing holds one IO thread for a bounded time only, and other clients still
complete their handshakes on other threads.

After the handshake the connection checks the negotiated name. The name `h2`
starts the HTTP/2 core. Any other name starts the HTTP/1.1 core when the fallback
is on, and the connection is refused when the fallback is off
(`THttp2AsyncConnection.OnFirstRead` in `src/Http2.Server.Async.pas`).

## Open verification

The unit tests cover the pure select rule and symbol resolution
of `test/Http2.Server.Alpn.Test.pas`, which run in the normal test suite. The
pure TLS decisions and the h2c loopback are verified by
`test/Http2.Server.Async.Test.pas`.

**Live handshake coverage.** The fpcunit suite has no live TLS handshake loopback because the mORMot2
client socket offers no ALPN list. The source client TLS socket offers any
list, so three separate runs drive OpenSSL handshakes. `make tls-live` runs two servers
in one process, with and without the HTTP/1.1 fallback, and checks each ALPN offer
([validation](../../verification/source/server/validation.md)). The h2spec validation uses TLS and negotiates h2. The mutual-TLS validation
checks the client certificate paths. Unit tests cover the ALPN selection rule, selected protocol name, and handshake
deadline. The h2c loopback demonstrates the IO pool end to end. The platform run on Linux amd64 is open, because this host is
macOS aarch64.

## Sources

| Claim | Source | Read |
|---|---|---|
| The callback signature, the return codes, and the protocol list wire format | OpenSSL manual page `SSL_CTX_set_alpn_select_cb(3ssl)` | 2026-10-07 |
| The `INetTls` surface | `third_party/mORMot2/src/net/mormot.net.sock.pas` | 2026-10-07 |
| The server `SSL_CTX` and its lifetime | `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas` | 2026-10-07 |
| The blocking handshake and its 5000 ms deadline | `...:11953-12009`, `...:12146-12188` | 2026-10-07 |
| The range setters, their return of 1 on success, and the meaning of 0 as the library default | OpenSSL 4.1.0 manual page `SSL_CTX_set_min_proto_version(3ssl)` (`/opt/homebrew/share/man/man3`) | 2026-11-06 |
| The Pascal wrappers and the default range of the server context | `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas`, `...:10853-10860`, `...:11874-11883` | 2026-11-06 |
| The TLS version floor of 1.2 for HTTP/2 | RFC 9113 section 9.2 (https://www.rfc-editor.org/info/rfc9113, copy in doc/references/rfc9113.txt) | 2026-11-06 |

## RFC references

- [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301.html), checked 2026-11-11.
- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html), checked 2026-11-11.
