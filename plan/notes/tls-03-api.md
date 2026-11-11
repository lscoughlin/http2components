# TLS-03 common API proposal

Checked 2026-11-11. This note records the shared signatures for consumer
review. The interface GUIDs are fixed in their declarations.

## Dependencies and public types

The unit order is `Http2.Common.Tls.Types`, `.Identity`, `.Policy`,
`.Session`, and `.Context`. `Http2.Common` aliases the types and interfaces;
it does not define a second interface. The common package uses only FPC RTL.

`ITLSContext` GUID is `{D0387A76-78E3-4D18-B2E2-21D7051B2B03}`.
`ITLSSession` GUID is `{B7C805A9-BC07-47C6-B8C3-E6E5D1AA2303}`.
`ITLSIdentity` GUID is `{C9F620E7-0F0C-4785-8D69-7CF7A2D92303}`.
`ITLSPeerCertificate` GUID is `{4C41A6B3-9685-4865-89D3-4B3C991E2303}`.

Context operations are `BackendName: string`, `Capabilities:
TTlsCapabilities`, `Info: TTlsContextInfo`, `CreateClientSession(const
AOptions: TTlsClientSessionOptions): ITLSSession`, and
`CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession`.
`Info` contains only enabled roles, client-auth mode, and context handshake
timeout. It does not expose credentials or trust material. A timeout value of
zero means no context limit. Session options hold a monotonic start time and
optional absolute role deadline. The session deadline is the earlier nonzero
value of `HandshakeStartMs + Info.HandshakeTimeoutMs` and
`HandshakeDeadlineMs`.

Client identity selection uses `IdentitySelection` and `Identity` together.
`tisUseDefault` permits the context default. `tisExplicit` honors the supplied
identity value, including nil. This prevents a nil selector result from
restoring a default identity.

Policy trust-anchor strings are filesystem paths to PEM certificate files;
they are not PEM contents. Policy trust-anchor inputs and getters copy their
dynamic arrays. Session option ALPN inputs and getters also copy. Negotiated
peer data is returned through `ITLSPeerCertificate`; its string-array getters
return copies. The common `NewTlsPeerCertificate` helper copies the chain and
all SAN arrays. Subject and issuer use RFC 4514 string form. Common name
preserves the certificate common-name value. Leaf PEM contains the public
leaf certificate. Serial is uppercase hexadecimal without colons. The SHA-256
fingerprint is lowercase hexadecimal without separators. Validity values are
UTC. The peer contract includes verified status, chain summaries, and
DNS/IP/URI/email SAN values. The chain is leaf-first and includes the peer leaf
at index zero, then peer-presented issuer certificates in verification order.
It does not add a local trust anchor that the peer did not present.

## Session operations

`State: TTlsSessionState` is available in every state. `FeedEncrypted` accepts
a bounded prefix (maximum 16 KiB) and returns the accepted count; callers
retain the suffix. `DrainEncrypted` copies queued bytes into an existing
destination range (maximum capacity 64 KiB) without resizing it. Caller owns
the copied bytes. `WritePlaintext` accepts a prefix and returns its count;
accepted plaintext is never resubmitted. `ReadPlaintext` copies a prefix into
an existing range, without resizing it. Plaintext and encrypted output queues
are bounded at 64 KiB.

`Advance(const AMonotonicMs: Int64): TTlsProgress` performs no wait or sleep.
The timestamp is absolute monotonic time. The earliest context and role
deadlines apply; new input does not reset them. Progress reports state,
readiness needs, and progress. `NotifyTransportEof` reports abrupt transport
EOF. Incoming authenticated close-notify reaches closed state; abrupt EOF
reaches failed state. Buffered plaintext remains readable first, then a failed
read raises the stored error. `BeginShutdown` queues TLS close-notify.
`Abort` is terminal and prompt, and clears pending alert output.
`NegotiatedInfo` raises `ETlsSessionError` until the handshake succeeds and
after the session becomes terminal.

Fatal session operations raise `ETlsSessionError` and set state to failed.
Failed and closed are terminal. `Advance` reports terminal state without
restarting it. `Abort` is valid in any state. Close-notify output remains
drainable while closing. Fatal-alert output remains drainable while failed
until `Abort`. Methods validate offset and capacity against the caller's
existing array; they do not resize caller buffers. A bad range raises
`ETlsSessionError` and leaves the session state unchanged.

The fake context creates a separate session per call and retains the context
for each session. Its bounded tests cover policy array copies, role rejection,
partial buffer operations, independent sessions, EOF, alerts, deadlines,
failure state, and lifetime. This note does not claim provider conformance.
