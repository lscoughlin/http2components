# http2components 0.31.0

This repository contains Free Pascal HTTP/2 client and server libraries. The
source version is 0.31.0. This text does not state that the version is a
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
separate from client core. All six packages use version 0.31.0.

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
task build
task build:readers
task build:openssl
task build:tlslib
task packages:check
task source:check
task docs:check
task version:check
task examples
```

`task build` runs the five-component build. `task setup:deps` is the explicit
dependency setup task. It prepares the pins recorded in
`tools/dependencies.yml`. The setup operation is separate from `task build`.
The Readers package is optional. The root build compiles common, client,
server, OpenSSL, and TlsLib in dependency order. `task build:<component>`
builds one component. `task clean` removes generated output from this
repository's `bin/` directory. `task --list` shows every task.
The repository checks are Taskfile tasks. `source:check`, `docs:check`,
`version:check`, and `packages:check` run 29 simple rules over the file lists.
Each rule is one shell command. Review and the repository guidelines cover the
other rules.
Six relative Lazarus package targets are listed in `http2components.lpg`.
Package outputs and Lazarus primary configuration directories are isolated
under `bin/`. The root build does not run tests, examples, external peers, or
load checks.

The required tools are `fpc` 3.2.4, `git`, and `task` (go-task, version 3.42.0
or later). Lazarus 4.0 is needed for package builds. Python 3 is needed only
where an interop peer, a load driver, an abuse or seam test, or
`tools/server/validate/local_process.py` runs. The gate scripts skip with a
message when a program is missing. The OpenSSL provider needs OpenSSL 3 at runtime. The TLS fixture and
interop tools use the OpenSSL command-line program. The pinned provider and
mORMot sources are local inputs. Dependency path overrides are
`MORMOT2_ROOT`, `TLSLIB4PASCAL_ROOT`, `CRYPTOLIB4PASCAL_ROOT`,
`HASHLIB4PASCAL_ROOT`, and `SIMPLEBASELIB4PASCAL_ROOT`. `OPENSSL_LIBPATH`
selects the OpenSSL runtime library directory when it is outside the system
loader path.

The TlsLib package uses the pinned TlsLib, CryptoLib, HashLib, and
SimpleBaseLib sources. The bootstrap unit order is retained. Lazarus package builds
use a private configuration and a scoped compiler wrapper. The wrapper
removes only the forced `-B` argument from the TlsLib `lazbuild` invocation,
after the fresh ordered bootstrap, so its PPUs remain available through the
upstream source cycle. No user's compiler settings or IDE profile are changed.

`task examples` compiles the example programs only. It does not send external
requests or run network examples. The bounded TLS tasks are
`task test:tls-contract`, `task test:tls-openssl`, `task test:tls-tlslib`,
`task test:tls-client`, `task test:tls-server`, and
`task test:tls-integration`. The integration task contains protocol and
security runners. These tasks do not run as part of `task build`.

The integration examples are `examples/integration/tls_openssl.pas`,
`tls_tlslib.pas`, `tls_dual_role.pas`, and `tls_https_proxy.pas`. They use the
public common, client, server, and provider facades.

## Unix domain sockets

The server listens on a socket file with `WithUnixSocket(path)` and
`WithUnixSocketMode(mode)`. The client connects to a socket file with
`WithUnixSocket(path)`, or through a proxy that listens on a socket file with
`WithUnixProxy(path, kind)`. HTTP/2, HTTP/1.1, server-sent events, WebSocket and
TLS run over the same byte stream. The [server
design](doc/design/server/unix-socket.md) and the [client
transport](doc/design/client/transport.md) describe the rules. The examples are
`examples/server/unix_server.pas` and `examples/client/unix_client.pas`. The
[Unix socket verification record](doc/verification/unix-sockets-2026-11-12.md)
states the results and one open client defect.

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
