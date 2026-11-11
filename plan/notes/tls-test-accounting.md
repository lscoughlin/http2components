# TLS test accounting review

The source inventory retains 913 client test records and 867 server test
records. The static accounting check reports 87 missing target methods. The
client inventory has 34 missing methods. The server inventory has 53 missing
methods.

## Current provider coverage

`test/tls/openssl/Http2.Tls.OpenSSL.Tests.pas` contains the client identity
cases in `CheckLegacyIdentityInputs`. These cases check PEM and PKCS#12
loading, chain metadata, encrypted keys, wrong and missing passphrases,
passphrase redaction, malformed input, missing-file diagnostics, expired
certificate metadata, and key mismatch. The provider program also checks SNI,
ALPN negotiation, trust, verification depth, expired and untrusted peers, and
TLS session behavior.

`test/common/Http2.Common.Tls.Contract.Run.pas` checks neutral role, policy,
ALPN-option, session, deadline, and verification-depth contracts. The current
server TLS policy unit checks protocol offer policy through a fake context.

## Behavior without an equivalent current case

The former server ALPN callback tests checked malformed and unacceptable
protocol vectors, nil callback input, selected-name pointer and length, and
policy argument separation. The current test set does not check these callback
behaviors. The OpenSSL provider owns the native callback, so callback pointer
and native flag assertions are obsolete as cross-provider assertions. The
malformed and unacceptable input behavior remains meaningful and has no
current relocated test.

The current provider-neutral client identity selector tests check successful
Build, rejection of an expired identity at Build, and Build without an
identity. The file-based identity API now loads and validates files before
client Build. The old assertions about unreadable files failing at Build or
not failing during a `With` call therefore belong to the loader boundary.
OpenSSL identity cases check the missing-file diagnostic and passphrase
redaction at that boundary.

The old transport tests checked socket short reads, timeout conversion, and
TLS plaintext chunk reassembly. These belong to the neutral transport/session
boundary. Coverage must name a current neutral case when one checks the same
behavior; a TLS handshake case is not equivalent.

## Accounting rule

A migration entry needs a current method or a named program case as its target.
The target name must exist in the target source. A migration reason must say
whether the old assertion remains covered, moved to provider ownership, or is
uncovered. A provider handshake or a general TLS test is not evidence for an
unrelated old assertion. Uncovered behavior remains an explicit follow-up.
