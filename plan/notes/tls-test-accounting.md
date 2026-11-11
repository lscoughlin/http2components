# TLS test accounting review

The source inventory retains 913 client test records and 867 server test
records. The prior static accounting check found 87 missing target methods:
34 client records and 53 server records.

## Client targets

The client inventory maps all 34 removed TLS records. The OpenSSL identity
program has explicit assertion markers for PEM and PKCS#12 loading, chain
metadata, encrypted keys, wrong and missing passphrases, passphrase redaction,
malformed input, missing-file diagnostics, expired certificate metadata, and
key mismatch. The neutral identity selector tests check successful Build,
expired identity rejection at Build, and Build without an identity.

The file-based identity API loads and validates files before client Build. The
old assertions about unreadable files failing at Build or not failing during a
`With` call therefore map to the loader boundary. The retained lower-level ALPN
checks cover HTTP/1.1 refusal, empty selection refusal, and h2 acceptance. The
neutral TLS contract checks incremental record drains.

## Server targets

The former server ALPN callback cases target named assertions in the OpenSSL
provider helper. These cases check malformed and unacceptable protocol vectors,
nil callback input, selected-name pointer and length, and policy argument
separation. The OpenSSL provider owns callback pointer and native context flag
behavior. These assertions are not claims about the common TLS API.

The former server context and range tests target OpenSSL policy cases for the
server auth default, protocol bounds, copied policy settings, trust input,
system trust, missing CA files, version range validation, and missing server
identity. Handshake cases check effective trust, depth, client auth, and
unknown-CA behavior. The no-anchor policy now fails on an unknown peer CA during
the handshake, rather than during server factory validation.

The old combined certificate and key file form targets a provider case that
passes the same PEM path as the certificate and key path. This preserves the
combined-file behavior. The old empty-key-path shorthand is not a claim.

## Accounting rule

A migration entry has a current method or a named program case as its target.
The target name exists in the target source. A migration reason says whether
the old assertion remains covered, moved to provider ownership, or changed
with the API. The checker fails any row with an uncovered disposition. A
program case target names an assertion marker in the target routine. A provider
handshake or a general TLS test is not evidence for an unrelated old assertion.
