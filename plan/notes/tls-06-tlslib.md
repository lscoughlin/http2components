# TLS-06 TlsLib implementation notes

## Readings and decisions

- R1: RFC 9113 sections 3.2 and 9.2, RFC 8740 sections 2 and 3, and RFC 7301 sections 3.1 and 3.2. The adapter uses negotiated ALPN metadata. It leaves the HTTP/2 fallback decision to the role.
- R2: RFC 8446 sections 4.1, 4.2, 4.3.2, 4.4, 5, and 6. The implementation uses the TlsLib sans-I/O engine, retains outgoing alert records, and treats transport EOF without `close_notify` as a failure.
- R3: RFC 5280 sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12, and 6, and RFC 4514 sections 2 and 3. Certificate metadata uses copied values, hexadecimal serials, SHA-256 fingerprints, and the engine-validated path.
- R6: mORMot revision `b2b195da1e0580058672a88620ef71bb47283eb1` and the pinned TlsLib4Pascal engine. The adapter uses `ITlsEngine`, `TTlsCredential`, the PKIX verifier, and immutable per-engine configuration. It does not import or load OpenSSL.
- The frozen common TLS contract and `plan/notes/tls-03-contract.md` define role separation, explicit nil identity, monotonic deadlines, bounded queues, and peer-certificate snapshots.
- TLS-02 feasibility and engine-study notes establish that the engine verifies against configured trust certificates and can accept intermediate anchors. The strict policy therefore removes non-self-signed anchors from the engine trust input when partial-chain trust is disabled. It fails Build if that leaves no root. With partial-chain trust enabled, the full configured trust data is retained.

## Implemented behavior

- `TTlsLibContextFactory` is a fluent record. It creates immutable role-specific policy copies and loads each trust bundle at Build time. The context retains client and server trust data separately. Each session retains the context.
- Identity loaders accept PEM files, PEM byte/string pairs, and PKCS#12 files/data. Credential objects stay behind the TlsLib adapter. Malformed data, wrong passphrases, mismatched keys, and unsupported provider identities produce sanitized errors.
- Client and server sessions use the sans-I/O engine. Input, output, and plaintext queues have fixed limits. Partial feeds, drains, writes, alerts, close, EOF, and abort are mapped to the common session contract.
- TLS 1.2 and TLS 1.3 are enabled. System trust and configurable verification depth are rejected. Session resumption and early data remain disabled. Client verification requires hostname checking. Distinct SNI and verification names are rejected because the engine interface does not expose separate values.
- mTLS None, Request, and Require map to role-specific engine configuration. Explicit nil identity does not restore a configured default.
- Peer metadata is copied from the verified path. It includes subject and issuer DN, common name, serial, PEM, lowercase SHA-256 fingerprint, validity times, and DNS/IP/URI/email SANs. The test fixture `escaped-name.crt` covers comma escaping and UTF-8 byte escaping in the RFC 4514 subject.

## Evidence and limits

- `make -C tls/tlslib build` passes on the pinned macOS/aarch64 setup. The latest build output is in `bin/tls06-build-run09.log`. The test source compiles with the TLS-06 test flags; output is in `bin/tls06-test-compile-run09.log`.
- The bounded run in `bin/tls-coordinator/tls06-coordinator-12.log` completed successfully in 0.945 seconds. It emitted 84 individual PASS assertions, including malformed-anchor rejection in both partial-chain modes. Its summary counter printed 78 because several assertions before the shared session suite were not included. The source now counts each local assertion and adds the shared suite count; the corrected summary still needs a central bounded run. The earlier run in `bin/tls-coordinator/tls06-coordinator-11.log` reported 78 assertions in 0.934 seconds before the malformed-anchor checks.
- The source has a concurrent client/server session-creation case using one context (two threads with five session creations each), ten lifecycle repetitions with provider counters, strict root-only trust, root-plus-intermediate trust, an expired certificate, malformed anchors with both partial-chain values, and escaped UTF-8 DN fixtures. The counters track adapter contexts, sessions, credentials, and engine handles; they do not inspect allocations inside TlsLib or CryptoLib.
- Factory validation, context/engine creation, session adaptation, credential loading, trust parsing, metadata conversion, and resource counters are in separate provider units. The factory rejects foreign identities before reading provider credential data.
- The compatible preset's versioned cipher registry offers TLS 1.2 ECDHE RSA/ECDSA AES-GCM and ChaCha20 suites, and TLS 1.3 AEAD suites. The negotiated names are reported from IANA cipher-suite identifiers. Local identity chain DER is limited to 32 KiB. The engine has a separate handshake reassembly limit of 64 KiB per message and 128 KiB total; this is protocol state, not queued application ciphertext.
- System trust, configurable verification depth, resumption, early data, DER identity loading, and separate SNI from verification name are unsupported. The adapter rejects explicit depth, including zero. No Linux, load, or full integration validation has been run.

## Main acceptance review

- Coordinator run 13 passed all 84 checks in 0.983 seconds after the counter correction. The implementation was merged at `a7daf73`. The merged `make test-tls-tlslib` run passed 84 checks in 1.185 seconds on 2026-11-11. Both runs exited 0 under the 30-second test limit.
- The generated TlsLib package now lists all eight source units. `make -C tls/tlslib check` passed with no failures across 54 documents and 383 Pascal files.
- The main checkout compiled the pinned crypto dependencies locally before the test. No Linux or load test was run. Loaded-image isolation and the real client/server matrix remain assigned to TLS-10 and TLS-09.
