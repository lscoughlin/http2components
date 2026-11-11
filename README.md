# http2components 0.30.0

This repository contains Free Pascal HTTP/2 client and server libraries. The
source version is 0.30.0. This text does not state that the version is a
published release.

## Public units and packages

| Unit or package | Units | Purpose |
| --- | ---: | --- |
| `Http2.Common` / `http2common` | 11 | Shared protocol units and provider-neutral TLS interfaces. |
| `Http2.Client` / `http2client` | 55 | Client factory, requests, responses, and transport. |
| `Http2.Server` / `http2server` | 71 | Server factory, handlers, requests, and responses. |
| `Http2.OpenSSL` / `http2openssl` | 6 | OpenSSL TLS context and identity provider. |
| `Http2.TlsLib` / `http2tlslib` | 8 | TlsLib TLS context and identity provider. |
| `http2clientreaders` | 1 | Optional JSON and XML readers. |

Production units are in five source roots: `common/src`, `client/src`,
`server/src`, `tls/openssl/src`, and `tls/tlslib/src`. Readers remain
separate from client core. All six packages use version 0.30.0.

Applications select a provider by creating a context and passing it to a role
factory with `WithTlsContext`. HTTPS proxy TLS uses the separate
`WithProxyTlsContext` setting. A single common context can serve client and
server roles. Provider trust settings remain role-specific. The [TLS context
design](doc/design/common/tls-context.md) describes the shared contract.

## Build

The ordinary build is offline and does not fetch dependencies. Dependency
setup is an explicit operation. The build writes compiler units and programs
under `bin/<cpu>-<os>/<profile>/`.

```sh
make build
make build-readers
make build-openssl
make build-tlslib
make packages-check
make source-check
make docs-check
make version-check
make examples
```

`task build` runs the same five-component build. `make setup-deps` or
`task setup:deps` is the explicit dependency setup target. It prepares the
pins recorded in `tools/dependencies.json`. The setup operation is separate
from `make build`. The Readers package is optional. The root Makefile builds
common, client, server, OpenSSL, and TlsLib in dependency order. A component
Makefile also supports direct `build`, `check`, and `clean` operations. Root
`make clean` removes generated output from this repository's `bin/` directory.
Six relative Lazarus package targets are listed in `http2components.lpg`.
Package outputs and Lazarus primary configuration directories are isolated
under `bin/`. The root build does not run tests, examples, external peers, or
load checks.

The expected local toolchain is Free Pascal 3.2.4 and Lazarus 4.0 for package
builds. The OpenSSL provider needs OpenSSL 3 at runtime. The TLS fixture and
interop tools use the OpenSSL 3 command-line program. The pinned provider and
mORMot sources are local inputs. Dependency path overrides are
`MORMOT2_ROOT`, `TLSLIB4PASCAL_ROOT`, `CRYPTOLIB4PASCAL_ROOT`,
`HASHLIB4PASCAL_ROOT`, and `SIMPLEBASELIB4PASCAL_ROOT`.

The TlsLib package uses the pinned TlsLib, CryptoLib, HashLib, and
SimpleBaseLib sources. On macOS with Free Pascal, a hash-checked CryptoLib
random-provider overlay is generated under `bin/`; the dependency checkout is
not modified. Its bootstrap unit order is retained. Lazarus package builds
use a private configuration and a scoped compiler wrapper to handle the
upstream source cycle. No user's IDE profile is changed.

`make examples` compiles the example programs only. It does not send external
requests or run network examples. The bounded TLS targets are
`make test-tls-contract`, `make test-tls-openssl`, `make test-tls-tlslib`,
`make test-tls-client`, `make test-tls-server`, and
`make test-tls-integration`. The integration target contains protocol and
security runners. These targets do not run as part of `make build`.

The integration examples are `examples/integration/tls_openssl.pas`,
`tls_tlslib.pas`, `tls_dual_role.pas`, and `tls_https_proxy.pas`. They use the
public common, client, server, and provider facades.

## TLS documentation

- [Common TLS context](doc/design/common/tls-context.md)
- [OpenSSL provider](doc/design/tls/openssl.md)
- [TlsLib provider](doc/design/tls/tlslib.md)
- [0.30.0 migration](doc/migration-0.30.0.md)
- [Documentation map](doc/README.md)

## Verification

The TLS implementation has bounded provider, transport, integration, and
package isolation results on macOS arm64. This does not establish Linux,
load, independent-peer, or full conformance results. The client 0.23.0 and
server 0.29.0 source records describe earlier source revisions. Their test
counts are not results for this TLS implementation. The merged result and
remaining validation limits are recorded in the [current verification
record](doc/verification/current-status.md).

## License

Project-owned code and documentation use the Apache License, Version 2.0, or
the GNU Lesser General Public License, version 2.1, with the Free Pascal
Independent Modules exception. The license choice is
`Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)`. The full
license texts and source provenance are in `LICENSES/`. Third-party works
and specification copies keep their own terms.
