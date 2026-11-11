# TLS-03 frozen common TLS contract

Checked 2026-11-11. This note records the source signatures and behavior that
client, server, and provider tasks use. The common units have no provider,
role, or mORMot dependencies.

## Public interfaces

The interface GUIDs are stable:

| Interface | GUID |
| --- | --- |
| `ITLSContext` | `{D0387A76-78E3-4D18-B2E2-21D7051B2B03}` |
| `ITLSSession` | `{B7C805A9-BC07-47C6-B8C3-E6E5D1AA2303}` |
| `ITLSIdentity` | `{C9F620E7-0F0C-4785-8D69-7CF7A2D92303}` |
| `ITLSPeerCertificate` | `{4C41A6B3-9685-4865-89D3-4B3C991E2303}` |

`ITLSContext` in `Http2.Common.Tls.Context` is the single declaration. The
`Http2.Common` alias points to that exact interface.

```pascal
ITLSContext = interface(IInterface)
  ['{D0387A76-78E3-4D18-B2E2-21D7051B2B03}']
  function BackendName: string;
  function Capabilities: TTlsCapabilities;
  function Info: TTlsContextInfo;
  function CreateClientSession(
    const AOptions: TTlsClientSessionOptions): ITLSSession;
  function CreateServerSession(
    const AOptions: TTlsServerSessionOptions): ITLSSession;
end;
```

The supporting declarations are in these source units:

- `common/src/Http2.Common.Tls.Types.pas`: `TTlsVersion`, `TTlsRole`,
  `TTlsRoles`, `TTlsClientAuthMode`, `TTlsIdentityFormat(s)`,
  `TTlsSessionState`, `TTlsErrorCategory`, `TTlsCapabilities`,
  `TTlsContextInfo`, `ETlsContextError`, and `ETlsSessionError`.
- `common/src/Http2.Common.Tls.Identity.pas`: `TTlsCertificateSummary`,
  `ITLSIdentity`, `ITLSPeerCertificate`, `TTlsPeerCertificateData`, and
  `NewTlsPeerCertificate`.
- `common/src/Http2.Common.Tls.Policy.pas`: `TTlsClientPolicy`,
  `TTlsServerPolicy`, `TTlsIdentitySelection`, and both session option records.
- `common/src/Http2.Common.Tls.Session.pas`: `TTlsNegotiatedInfo`,
  `TTlsProgress`, and `ITLSSession`.
- `common/src/Http2.Common.Tls.Context.pas`: `ITLSContext`.
- `common/src/Http2.Common.pas`: facade aliases and enum/error/buffer constants.

`TTlsCapabilities` fields are `Roles`, `Versions`, `IdentityFormats`,
`SystemTrust`, `PartialChain`, `VerificationDepth`, `SessionResumption`, and
`EarlyData`. `TTlsContextInfo` fields are `Roles`, `ClientAuth`, and
`HandshakeTimeoutMs`; `RequiresClientCertificate` is true only when the
server role is enabled and auth mode is require. `TTlsProgress` fields are
`State`, `NeedInput`, `NeedOutput`, and `MadeProgress`.

`ITLSIdentity` declares `BackendName: string`, `Leaf:
TTlsCertificateSummary`, and `Formats: TTlsIdentityFormats`.
`ITLSPeerCertificate` declares `Verified: Boolean`, `Leaf:
TTlsCertificateSummary`, `Chain: TArray<TTlsCertificateSummary>`, and copied
array getters `DnsNames`, `IpAddresses`, `UriNames`, and `EmailAddresses`.
`TTlsNegotiatedInfo` fields are `Role`, `Version`, `CipherName`,
`SelectedAlpn`, `PeerCertificate`, and `Resumed`.

`TTlsClientPolicy` fluent methods are `SecureDefault`, `WithTrustAnchors`,
`TrustAnchors`, `WithVersions`, `WithInsecure`, `WithDefaultIdentity`,
`WithSystemTrust`, `WithPartialChain`, and `WithVerificationDepth`.
`TTlsServerPolicy` has `SecureDefault`, `WithTrustAnchors`, `TrustAnchors`,
`WithVersions`, `WithClientAuth`, `WithServerIdentity`, `WithSystemTrust`,
`WithPartialChain`, and `WithVerificationDepth`. Trust-file values use
`array of string` input and `TArray<string>` copied output. Client session
options have `WithAlpns` and `AlpnValues`; server options have the same
methods. Session signatures are shown below in full.

`WithVerificationDepth` preserves an explicit depth of zero. A negative
depth raises `ETlsContextError` with `tecConfiguration`. A provider without
depth support rejects every policy with `HasVerificationDepth = True`.

`Info` contains enabled roles, `TTlsClientAuthMode`, and the context handshake
timeout in milliseconds. It contains no credentials, trust anchors, or other
secret values. A timeout of zero means no context limit. Client and server
policies are separate records. The client policy holds server trust,
verification, versions, and a default client identity. The server policy
holds its server identity, independent client trust, client-auth mode, and
versions. Both default version ranges are TLS 1.2 through TLS 1.3. Client
verification and hostname checks are on by default. Resumption and early data
are off.

Trust-anchor strings in both policy records are paths to PEM certificate
files, not PEM contents. Policy setters and getters copy arrays. Fluent
policy setters include trust anchors, versions, insecure mode, default or
server identity, system trust, partial-chain trust, verification depth, and
server client-auth mode.

`TTlsClientSessionOptions` includes `HostName`, optional `ServerName`, ALPN
values, identity selection and identity, `HandshakeStartMs`, and
`HandshakeDeadlineMs`. `TTlsServerSessionOptions` includes ALPN values and
the same deadline fields. `HandshakeStartMs` is the monotonic time sampled at
session creation. The effective absolute deadline is the earliest nonzero
value of `HandshakeStartMs + Info.HandshakeTimeoutMs` and
`HandshakeDeadlineMs`. ALPN inputs and getters copy arrays. The default
identity selection is `tisUseDefault`. `tisExplicit` uses the supplied
identity, including nil, so a selector's deliberate nil never restores the
context default.

`ITLSIdentity` exposes backend name, a non-secret leaf summary, and supported
identity formats. The leaf summary includes subject, issuer, common name,
serial, SHA-256 fingerprint, public leaf PEM, and UTC validity dates. Subject
and issuer use RFC 4514 string form. Serial is uppercase hexadecimal without
colons. The fingerprint is lowercase hexadecimal without separators.

`ITLSPeerCertificate` exposes verified status, leaf and chain summaries, and
DNS, IP, URI, and email SAN arrays. `NewTlsPeerCertificate` copies the chain
and every SAN array on construction. Getters return copies. The chain starts
with the peer leaf at index zero, followed by peer-presented issuer
certificates in verification order. It excludes a local trust anchor that
the peer did not present. Copied metadata stays valid after session close.

`TTlsNegotiatedInfo` contains role, negotiated version, cipher name, selected
ALPN, peer certificate interface, and resumed status. `NegotiatedInfo` is
available only in open state.

## Session methods and terminal behavior

The exact session signatures are:

```pascal
ITLSSession = interface(IInterface)
  ['{B7C805A9-BC07-47C6-B8C3-E6E5D1AA2303}']
  function State: TTlsSessionState;
  function FeedEncrypted(const ABuffer: TBytes;
    const AOffset, ACount: SizeInt): SizeInt;
  function DrainEncrypted(var ABuffer: TBytes;
    const AOffset, ACapacity: SizeInt): SizeInt;
  function WritePlaintext(const ABuffer: TBytes;
    const AOffset, ACount: SizeInt): SizeInt;
  function ReadPlaintext(var ABuffer: TBytes;
    const AOffset, ACapacity: SizeInt): SizeInt;
  function Advance(const AMonotonicMs: Int64): TTlsProgress;
  procedure NotifyTransportEof;
  procedure BeginShutdown;
  procedure Abort;
  function NegotiatedInfo: TTlsNegotiatedInfo;
end;
```

Encrypted input accepts at most 16 KiB per call. The caller keeps all bytes
after the returned count. Ciphertext and plaintext queues each have a 64 KiB
bound. `DrainEncrypted` and `ReadPlaintext` copy only into the supplied range;
they do not resize the array. A session is confined to one serialized
transport owner. It does no socket I/O and does not wait or sleep.

`WritePlaintext` returns the accepted prefix count. The caller never submits
accepted bytes again. A zero result means no plaintext capacity or a state
that does not accept application data. `FeedEncrypted` accepts data while
closing so the peer close response can be processed. `BeginShutdown` blocks
new plaintext writes and starts close-notify.

`Advance` receives an absolute monotonic time. Repeated input does not reset a
deadline. It reports state, need for input, need for output, and progress.
It does not restart a closed or failed session. A successful peer
close-notify reaches closed state. Abrupt EOF reaches failed state. Reads
return buffered plaintext first; a read with no buffered plaintext returns
zero for closed state and raises the stored `ETlsSessionError` for failed
state.

Fatal session failures set failed state and raise `ETlsSessionError` with a
neutral category and optional sanitized provider detail. Pending fatal-alert
bytes remain drainable while failed. `Abort` is prompt and clears all
buffers, including alert output. Invalid buffer ranges raise a protocol
category `ETlsSessionError` and leave session state unchanged. An unavailable
context role raises `ETlsContextError` before transport use.

## Bounded common-only evidence

The fake implementation is `test/support/tls/Http2.Test.Tls.Fake.pas`.
`TTlsFakeContext.Create` accepts supported roles, client-auth mode, context
timeout, and an optional hold-handshake flag. Its session options inspection
interface returns role, client or server option records, copied ALPN values,
and selected identity information. A held handshake reports need-input until
input arrives and enforces the same absolute deadline. Input byte `$FC`
releases the held handshake. Input byte `$FF` produces a fatal-alert failure,
`$FD` produces a verification failure, and `$FE` produces authenticated close
after prior plaintext. Other bytes become plaintext in order. These markers
exist only in the fake.

The standalone common runner compiled with FPC and uses only `common/src`,
`test/common`, and `test/support/tls`. Its 21 cases cover secure defaults,
policy and metadata array isolation, identity selection, facade identity,
distinct client/server sessions, role availability, context lifetime,
buffer bounds, partial acceptance and drain, exact-once plaintext under
backpressure, absolute deadlines, held handshake progress, fatal alerts,
EOF, close-notify, and terminal behavior. The fake session is contract
support; it is not provider conformance evidence.

## Output credit review, 2026-11-11

The server review found that an empty ciphertext queue alone cannot prove that all accepted plaintext is encrypted. OpenSSL can retain queued plaintext or a fixed write buffer across a native retry. `TTlsProgress.PendingPlaintextOutput` now counts accepted bytes that do not yet have complete encrypted output. A transport can release plaintext credit only after that count is zero, provider and adapter ciphertext are drained, and the raw transport queue is empty. Failed or aborted sessions do not establish successful delivery.

OpenSSL reports the sum of its queued and in-flight plaintext. TlsLib protects accepted plaintext synchronously in `TTlsEngine.Write`; its count is zero. The fake session also encodes synchronously and its default progress count is zero. The shared contract checks the count against accepted credit and requires zero after complete delivery. The OpenSSL test also fills the pending queue, observes a positive count after partial encryption, and checks that Abort clears it.

Main bounded checks passed: OpenSSL 90 cases in 0.585 seconds (`bin/tls-coordinator/tls-progress-openssl-03.log`), TlsLib 84 cases in 1.011 seconds (`bin/tls-coordinator/tls-progress-tlslib.log`). The first new OpenSSL assertion failed because the test assumed a full write instead of the permitted 16 KiB prefix. The corrected test retains and submits the suffix. This is not a forced native WANT_READ/WANT_WRITE test.

## Peer close review, 2026-11-11

A one-sided close case now checks that the receiving session returns a close_notify response and preserves the final authenticated plaintext. The shared test uses one local shutdown call only. OpenSSL moves from a received close to closing, then completes SSL_shutdown; TlsLib queues its idempotent native SendClose response before closing. Closed sessions can retain drainable close output. The fake session follows the same response rule.

Main bounded checks passed: OpenSSL 91 cases in 0.692 seconds (`bin/tls-coordinator/tls-close-openssl.log`), TlsLib 85 cases in 1.193 seconds (`bin/tls-coordinator/tls-close-tlslib.log`), and common 22 cases in 0.215 seconds (`bin/tls-coordinator/tls-close-common.log`). No load or Linux validation was run.
