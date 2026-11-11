# TLS-08 reading notes

Check date: 2026-11-11.

## R1: HTTP/2 and ALPN

RFC 9113 sections 3.2 and 9.2 require ALPN for HTTP/2 over TLS and use the
`h2` identifier. The identifier `h2c` is not valid in TLS. The TLS handshake
must finish before either side sends the HTTP/2 connection preface. HTTP/2
over TLS requires TLS 1.2 or later. RFC 7301 sections 3.1 and 3.2 place the
client protocol list in ClientHello and the server selection in ServerHello.
The server therefore selects HTTP routing only from completed session
metadata. RFC 8740 sections 2 and 3 prohibit post-handshake client
CertificateRequest for HTTP/2. Section 4 allows TLS messages that do not
need application-layer interaction, including TLS 1.3 KeyUpdate.

## R2: TLS records, handshake, and closure

RFC 8446 sections 4.1, 4.2, 4.3.2, 4.4, 5, and 6 describe handshake
messages, extensions, CertificateRequest, authentication, records, and
alerts. A transport adapter must preserve record bytes and order, advance
the handshake without blocking socket workers, and pass application bytes
only after authentication succeeds. It must treat fatal alerts and
transport truncation as terminal. Session close-notify is distinct from
raw EOF. The common session API carries these states and separates
ciphertext from plaintext queues.

## R3: Certificate verification and names

RFC 5280 sections 4.1 and 6 define certificate fields and certification
path validation. Sections 4.2.1.6, 4.2.1.9, and 4.2.1.12 define subject
alternative names, basic constraints, and extended key usage. A client
identity is available to the server only after the TLS provider reports a
verified path. RFC 4514 sections 2 and 3 define distinguished-name text
encoding and parsing. The server must derive principal data from copied,
verified peer metadata and must retain that data for each request lifetime.

## R5: Existing server behavior

The server TLS design and mTLS design, plus the current async accept, ALPN,
principal, and TLS tests, show the behavior to preserve: TLS and cleartext
policy are separate; required client authentication cannot be combined
with cleartext; HTTP/1.1 fallback is a separate policy; a verified peer
certificate supplies the request principal; and a connection owns the
certificate metadata used by its exchanges. The new adapter keeps those
rules while replacing raw OpenSSL access with the common session interface.

## R6: Transport and provider source

The pinned mORMot source is read at
`/Users/liamcoughlin/Source/lscoughlin/http2components/third_party/mORMot2`.
The accepted route keeps mORMot TLS disabled and uses its raw async read,
write, and idle-sweep paths. The TLS-02 adapter study showed that separate
listeners can retain separate sessions, fragmented input and short writes
can be handled, and silent and trickling peers can be removed by an
accept-time deadline. This study used a fake session. Provider behavior is
outside this story's evidence. The provider-specific sources remain private
to their provider packages; the server uses only common TLS interfaces.

## Implementation constraints

The session accepts and reports plaintext credit separately from encrypted
output. The server must retain unaccepted plaintext and unsent ciphertext.
It must not report HTTP credit by subtracting ciphertext backlog from
plaintext totals. Session calls are serialized per connection, while raw
socket writes run without the session lock because a write may re-enter
`AfterWrite`. The monotonic clock is `mormot.core.os.GetTickCount64`.

## Source record

- RFC 9113, <https://www.rfc-editor.org/rfc/rfc9113.html>, checked
  2026-11-11. Sections 3.2, 9.2, and 9.2.1 were read.
- RFC 8740, <https://www.rfc-editor.org/rfc/rfc8740.html>, checked
  2026-11-11. Sections 2, 3, and 4 were read.
- RFC 7301, <https://www.rfc-editor.org/rfc/rfc7301.html>, checked
  2026-11-11. Sections 3.1 and 3.2 were read.
- RFC 8446, <https://www.rfc-editor.org/rfc/rfc8446.html>, checked
  2026-11-11. Sections 4.1, 4.2, 4.3.2, 4.4, 5, and 6 were read.
- RFC 5280, <https://www.rfc-editor.org/rfc/rfc5280.html>, checked
  2026-11-11. Sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12, and 6 were read.
- RFC 4514, <https://www.rfc-editor.org/rfc/rfc4514.html>, checked
  2026-11-11. Sections 2 and 3 were read.
- The current TLS, mTLS, async accept/read/write, ALPN, principal, and
  server TLS test sources were read in this worktree.

## Assertion migration

The server role tests now check common context roles and client-auth policy,
server ALPN offers, deadline calculation, and copying of verified peer fields.
The OpenSSL contract suite already checks TLS 1.2 and 1.3 negotiation,
negotiated ALPN, AEAD cipher selection, requested and required client
authentication, missing and invalid client certificates, trust anchors,
partial-chain trust, and verification depth. These checks use provider
contexts and sessions. The old server tests that inspected OpenSSL flags on
a server-owned `SSL_CTX` were removed with the server-native TLS helper.

The old server mTLS test for the principal choices `CommonName`, `SubjectDn`,
and no principal remains as a common verified-peer metadata test. The old
server ALPN test for offered protocol bytes remains as a common policy test.
The loopback runner checks selected `h2`, strict rejection of missing and
unsupported selections, HTTP/1.1 fallback, and fallback with no selection.
It also checks a held handshake during stop, two live bindings, failed start
cleanup, silent and trickling handshake deadlines, a fatal alert before raw
close, peer close response output, retained short plaintext writes, and an
`h2` session after its handshake deadline has passed. Its adapter case checks
that graceful close remains pending while the provider reports accepted
plaintext without complete encrypted output, then completes after an
explicit release. The small server suites cover context role, mTLS policy,
configuration, and principal metadata. The coordinator runs these binaries
and selected unit suites; this worker compiles them only.
