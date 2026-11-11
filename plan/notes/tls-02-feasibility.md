# TLS-02 engine and dependency feasibility

Checked 2026-11-11 on macOS arm64. This report covers provider engines and
their pinned inputs. The mORMot event-loop route is a separate adapter
decision recorded by the adapter owner. The engine evidence does not prove
that route.

## Decision

Both providers have a concrete client and server engine route. TlsLib exposes
a sans-IO engine. OpenSSL exposes memory BIOs through the pinned mORMot
bindings and its OpenSSL runtime. The study programs prove handshakes and
record transfer for both roles. TlsLib also proves both TLS versions,
verification, ALPN, SNI behavior, required client authentication, and
partial-chain trust. The OpenSSL study proves both TLS versions, DNS and IP
identity checks, required client authentication, and partial-chain trust.

This finding is a provider-engine gate only. The async server adapter still
needs the separately reviewed mORMot integration route before TLS-08.

## Dependency pins and license evidence

Each revision below was checked with `git remote get-url origin`,
`git rev-parse HEAD`, `git show -s --format=%cI`, and its checked-in license
file. These dependency clones are ignored working copies and are not
committed.

| Dependency | Origin | Revision | Commit date | License |
| --- | --- | --- | --- | --- |
| TlsLib4Pascal | `https://github.com/Xor-el/TlsLib4Pascal.git` | `2b47b18f61e5039a990e623353df88a0379ca948` | 2026-10-29 | MIT, `LICENSE` |
| CryptoLib4Pascal | `https://github.com/Xor-el/CryptoLib4Pascal.git` | `f559d27462ddd149ef9d1880f97854a8a4cc8368` | 2026-10-29 | MIT, `LICENSE` |
| HashLib4Pascal | `https://github.com/Xor-el/HashLib4Pascal.git` | `465c0c7c2c9a78596dd07e022f81073c11775a52` | 2026-10-29 | MIT, `LICENSE` |
| SimpleBaseLib4Pascal | `https://github.com/Xor-el/SimpleBaseLib4Pascal.git` | `9310af083d398ed62f01d8c82d39f85ad194dc93` | 2026-10-29 | MIT, `LICENSE` |
| mORMot2 bindings | local project source | `b2b195da1e0580058672a88620ef71bb47283eb1` | project pin | retain upstream license and notices |

TlsLib directly requires CryptoLib. CryptoLib requires HashLib and
SimpleBaseLib. The two transitive pins are fixed to exact revisions, selected
as the latest revisions with commit times before the selected CryptoLib
revision. The study bootstraps the FPC package units in HashLib, SimpleBase,
CryptoLib order, then compiles TlsLib. Compiling TlsLib directly first
reproduced a circular compile dependency through `ClpMultipliers`,
`ClpWnafUtilities`, and `ClpECAlgorithms`; seeding package PPUs in declared
dependency order resolves it without source edits.

The TlsLib source license is MIT. Owned study source retains
`Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)`.
Dependency licenses and source notices remain in their clones; the build
must preserve them when dependencies are vendored.

## Capability table

`Proved` means an assertion executed in the study. `Source-backed` means the
pinned source or existing project bindings expose the capability, but the
study did not execute that exact case. `Unsupported` means no configurable
capability exists in the examined path. `Unresolved` means the source review
did not settle the behavior. These are provider facts, not a claim of full
protocol conformance.

| Capability | TlsLib client | TlsLib server | OpenSSL client | OpenSSL server |
| --- | --- | --- | --- | --- |
| TLS 1.2 | Proved; selected TLS 1.2, app data | Proved; selected TLS 1.2, app data | Proved; memory BIO handshake | Proved; memory BIO handshake |
| TLS 1.3 | Proved; selected TLS 1.3, app data | Proved; selected TLS 1.3, app data | Proved; memory BIO handshake | Proved; memory BIO handshake |
| Cipher selection | Proved; suite reported, default compatible profile | Proved; suite reported, default compatible profile | Proved; AES-256-GCM negotiated | Proved; AES-256-GCM negotiated |
| Cipher policy breadth | Source-backed; hardened TLS 1.2 ECDHE+AEAD profile | Source-backed; hardened TLS 1.2 ECDHE+AEAD profile | Source-backed; OpenSSL cipher configuration | Source-backed; OpenSSL cipher configuration |
| ALPN | Proved; `h2` selected | Proved; `h2` selected | Source-backed in current client socket (`SSL_CTX_set_alpn_protos`); memory-BIO study did not assert | Source-backed in current server hook (`SSL_CTX_set_alpn_select_cb`); memory-BIO study did not assert |
| DNS SNI | Proved; `localhost` sent/received | Proved; peer name received | Proved; DNS SNI sent | Source-backed; OpenSSL server API supports SNI; study did not assert |
| IP SNI omission | Proved; no SNI for IP literal | Proved; no SNI received | Proved; no SNI for IP literal | Source-backed; client omission is the relevant behavior |
| DNS identity check | Proved; correct name succeeds, wrong name rejected | Source-backed; server verifies client identity by configured anchors, not service name | Proved; correct DNS name succeeds | Source-backed; current server mTLS verifies chain, not a client DNS service identity |
| IP identity check | Proved; IP SAN succeeds | Source-backed; client IP identity is not a server-side client-auth requirement | Proved; IP SAN succeeds on tested OpenSSL 3.5.9 | Source-backed; client IP identity is not a server-side client-auth requirement |
| Trust roots | Proved; explicit local root succeeds; bad root rejected | Proved; explicit local root validates client | Proved; explicit local root validates chain | Proved; explicit local root validates client |
| System trust | Source-backed optional `TlsLib.Trust.System` package; provider build must include this package or system trust is unavailable; not compiled or run | Same optional package requirement; explicit anchors used in study | Source-backed; current client calls `SSL_CTX_set_default_verify_paths` | Source-backed; runtime default trust can be configured; study used explicit anchor |
| Verification depth | Unsupported as a per-policy knob in TlsLib; path builder limit is fixed at 4 | Unsupported as a per-policy knob; fixed path builder limit 4 | Source-backed OpenSSL `SSL_CTX_set_verify_depth`/X509 verify parameters; current client path does not expose or apply a depth option, and this study did not execute it | Source-backed; existing server code dynamically resolves `SSL_CTX_set_verify_depth` |
| Partial-chain trust | Proved; intermediate used as explicit trust anchor | Proved; intermediate used as explicit trust anchor | Proved; OpenSSL `X509_V_FLAG_PARTIAL_CHAIN`, intermediate anchor | Proved; OpenSSL `X509_V_FLAG_PARTIAL_CHAIN`, intermediate anchor |
| Client authentication mode | Source-backed; `None`, `Requested`, `Required`; required credentials exercised | Proved; required mTLS success and missing-cert rejection in TLS 1.2 and 1.3 | Source-backed; client identity configured from PEM fixture | Proved; required mTLS handshake and client certificate validated in TLS 1.2 and 1.3 |
| PEM/DER identity | Source-backed in `TTlsCredential.Load` | Source-backed in `TTlsCredential.Load` | Source-backed in current PEM loaders | Source-backed in current PEM loaders |
| PKCS#12 identity | Source-backed in `TTlsCredential.LoadPkcs12`; not executed | Source-backed in `TTlsCredential.LoadPkcs12`; not executed | Source-backed in current `LoadPkcs12`; not executed | Source-backed; provider context accepts native OpenSSL identity; not executed |
| Encrypted private key | Source-backed password overload; not executed | Source-backed password overload; not executed | Source-backed by OpenSSL key loading API; not executed | Source-backed by OpenSSL key loading API; not executed |
| Peer DN | Source-backed through certificate `SubjectDN`/`IssuerDN` and IETF DN formatter; edge cases not executed | Source-backed through certificate path/peer info; edge cases not executed | Source-backed through existing X509 name conversion | Source-backed through existing X509 name conversion |
| Entropy source | Source-backed default CryptoLib provider and platform random provider; OS-specific implementation not separately tested | Same shared provider | Source-backed OpenSSL RAND/runtime | Source-backed OpenSSL RAND/runtime |
| Sans-IO stepping | Proved; `ProcessInput`, `WantsRead`, `WantsWrite`, bounded `TakeOutgoing` | Proved; same engine API | Not the API model; memory BIO is the transport boundary | Not the API model; memory BIO is the transport boundary |
| Partial output drain | Proved; output pulled in seven-byte capacities until empty | Proved; output pulled in seven-byte capacities until empty | Proved; output drained incrementally from memory BIO | Proved; output drained incrementally from memory BIO |
| Fragmented input | Proved; `ProcessInput` receives one-byte fragments | Proved; `ProcessInput` receives one-byte fragments | Proved; one-byte BIO feeds, then OpenSSL advances over accumulated BIO data | Proved; one-byte BIO feeds, then OpenSSL advances over accumulated BIO data |
| Alert and EOF | Proved; fatal alert surfaced; transport EOF latched separately | Proved; fatal alert surfaced; transport EOF latched separately | Proved; close-notify requires `SSL_ERROR_ZERO_RETURN` | Proved; close-notify requires `SSL_ERROR_ZERO_RETURN` |

## Study execution

Command: `MORMOT=/path/to/pinned/mORMot2/src python3 tools/studies/tls/engines/run.py`.
The runner defaults this path to `third_party/mORMot2/src`; the explicit
override was used with the read-only main-checkout clone. The runner generates
short-lived local root, intermediate, server, and client fixtures beneath
`bin/studies/tls-engines/`; compiles package units in dependency order; and
runs the two programs sequentially with a 30-second per-program timeout.
The OpenSSL study uses `/opt/homebrew/opt/openssl@3/lib`, OpenSSL 3.5.9
(29 Sep 2026), matching the project build environment. The runner writes
provider compiler units to separate subdirectories under `bin`; this is
output placement, not a complete provider dependency-isolation proof. Set
`TLS_STUDY_OUT` to select a fresh output path. On POSIX, the runner starts
each subprocess in a new process group. A timeout terminates that group and
stores captured output with a timeout marker in the command log.

Both programs passed. TlsLib executed TLS 1.2 and 1.3, ALPN, DNS and IP
identity, SNI omission for IP, wrong-name and untrusted-root rejection,
required mTLS and missing-client-cert rejection, and partial-chain trust.
Its transport received input as one-byte `ProcessInput` calls and delivered
output through repeated seven-byte `TakeOutgoing` buffers. The OpenSSL
memory BIO study executed TLS 1.2 and 1.3 mTLS, DNS and IP SAN verification,
partial-chain trust, data transfer, and close-notify. Its one-byte BIO writes
prove incremental transport feed; OpenSSL consumes bytes accumulated in the
BIO when its handshake call runs, so this is not evidence of one handshake
advance per byte. Output was drained in seven-byte chunks.

A clean compile used
`MORMOT=/path/to/pinned/mORMot2/src TLS_STUDY_OUT=bin/tls02-engines-clean python3 tools/studies/tls/engines/run.py --compile-only`
with an empty output directory. HashLib, SimpleBase, CryptoLib, and both
study programs compiled successfully in about 134 seconds. Each dependency
package compile has a 300-second timeout. This is cold-build evidence; the
earlier warm-cache compile time is not reported as a cold-build result.

The work is macOS-only. It does not prove Linux support, a production
conformance matrix, load behavior, or the server event-loop integration.
