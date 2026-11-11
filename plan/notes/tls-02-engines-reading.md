# TLS-02 engine reading

Checked 2026-11-11. RFC references were checked at their RFC Editor URLs and
their plain-text copies are listed in `doc/references/README.md`.

## R1 — HTTP/2, ALPN, and TLS use

- RFC 9113 sections 3.2 and 9.2: connection establishment and TLS
  requirements for HTTP/2.
- RFC 8740 sections 2 and 3: HTTP/2 use of TLS 1.3, including protocol
  negotiation and TLS 1.3 connection behavior.
- RFC 7301 sections 3.1 and 3.2: ALPN extension negotiation and protocol
  selection.

The study selects `h2` in TlsLib. OpenSSL ALPN bindings and the current server
selection callback are source-backed; the memory BIO engine study does not
assert ALPN. The HTTP/2 application layer must reject an absent or wrong ALPN
selection according to its protocol policy.

Official references checked 2026-11-11:
[RFC 9113](https://www.rfc-editor.org/rfc/rfc9113),
[RFC 8740](https://www.rfc-editor.org/rfc/rfc8740),
[RFC 7301](https://www.rfc-editor.org/rfc/rfc7301).

## R2 — TLS handshake, records, alerts, and close

- RFC 8446 sections 4.1, 4.2, 4.3.2, 4.4, 5, and 6: handshake messages,
  extensions, certificate requests, authentication, record processing,
  alerts, and connection closure.
- RFC 5246 sections 6 and 7: TLS 1.2 record protocol and handshake protocol.
  RFC 8446 obsoletes RFC 5246 for TLS 1.3; RFC 5246 remains the relevant
  protocol reference for the TLS 1.2 cases in this study.

The TlsLib engine is sans-IO and reports events and output to its caller.
OpenSSL uses BIOs as the encrypted transport boundary. Study assertions
cover fatal-alert propagation and transport EOF for TlsLib, and require
OpenSSL `SSL_ERROR_ZERO_RETURN` for close-notify. Fragmented transport feed
and capped output are asserted, but no claim is made that an OpenSSL handshake
call advances once per individual byte fed into its buffering BIO.

Official references checked 2026-11-11:
[RFC 8446](https://www.rfc-editor.org/rfc/rfc8446),
[RFC 5246](https://www.rfc-editor.org/rfc/rfc5246).

## R3 — certificate paths, identities, and distinguished names

- RFC 5280 sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12, and 6: certificate
  structure, subject alternative names, basic constraints, extended key
  usage, and certification path validation.
- RFC 4514 sections 2 and 3: DN string syntax and serialization rules.
- RFC 9525 sections 4 through 7: reference identifiers, certificate
  identifiers, matching, and service identity verification in TLS.

The studies use SAN-bearing local certificates, explicit root trust, and an
intermediate-only trust anchor case. They prove DNS and IP identity checks,
wrong-name rejection, untrusted-root rejection, required client
authentication, and partial-chain behavior for the listed versions. They do
not execute DN escaping edge cases, encrypted keys, or PKCS#12 loading.

RFC 9525 is the current service-identity specification and obsoletes RFC
6125. RFC 9525 section 4 defines reference identifiers; sections 5 through 7
cover certificate identifiers, matching, and application-specific identity
considerations. RFC 5280 path construction remains distinct from service
name matching. The TlsLib path builder has a fixed maximum built path length
of four and no exposed per-policy depth setting in the pinned source.

Official references checked 2026-11-11:
[RFC 5280](https://www.rfc-editor.org/rfc/rfc5280),
[RFC 4514](https://www.rfc-editor.org/rfc/rfc4514),
[RFC 9525](https://www.rfc-editor.org/rfc/rfc9525).

## R6 — mORMot source and provider engine

The binding source is mORMot2 revision
`b2b195da1e0580058672a88620ef71bb47283eb1`. The existing client TLS path
uses `SSL_CTX_set_alpn_protos`, `SSL_set1_host`, and
`SSL_set_tlsext_host_name`; it omits SNI for IP literals. The existing server
client-certificate path resolves `SSL_CTX_set_verify_depth` and sets
`X509_V_FLAG_PARTIAL_CHAIN`. The existing server ALPN unit resolves
`SSL_CTX_set_alpn_select_cb`. The OpenSSL library runtime in this study is
3.5.9 from `/opt/homebrew/opt/openssl@3/lib`.

The pinned TlsLib engine API provides `StartHandshake`, `ProcessInput`,
`WantsRead`, `WantsWrite`, `TakeOutgoing`, `ReadAppData`, and `NextEvent`.
`TakeOutgoing` accepts a destination buffer, which supports bounded output
drain. Engine calls are serialized by the adapter. The engine source does not
prove that mORMot's existing `TAsyncServer` can defer its first-read TLS
callback or schedule pending output without application plaintext. The
server adapter decision therefore remains a separate gate.

## Implementation route and evidence IDs

- E1: `tlslib_engine_study.pas` — both roles, TLS 1.2 and 1.3, DNS and IP
  verification, ALPN, required mTLS, trust failures, partial-chain trust,
  payload, fatal alert, EOF, one-byte input calls, and seven-byte output
  drains.
- E2: `openssl_memory_bio_study.pas` — memory BIO role pair, TLS 1.2 and
  1.3, mTLS, DNS and IP checks, partial-chain trust, payload, and
  close-notify.
- E3: `run.py` — deterministic fixture generation, dependency bootstrap,
  search paths, output directories, time bounds, and OpenSSL runtime path.
- E4: `tls-02-feasibility.md` — exact pins, licenses, capability table, and
  evidence interpretation.

No Linux, container, load, or full conformance run was performed.
