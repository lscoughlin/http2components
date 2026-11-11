# http2components 0.30.0

This repository contains a Free Pascal HTTP/2 client and server. The source
version is 0.30.0. This repository does not state that this version is a
published release.

## Public units

| Unit | Purpose |
| --- | --- |
| `Http2.Common` | Shared HTTP/2 errors, headers, HPACK, frames, and flow control. |
| `Http2.Client` | Client factory, request, response, and client API. |
| `Http2.Server` | Server factory, handlers, requests, and responses. |

Production units are in `common/src`, `client/src`, and `server/src`. Client
and server feature units use their matching `Http2.Client.*` and
`Http2.Server.*` namespaces. The client and server use shared protocol units
from `Http2.Common.*`. The old `Http2` client umbrella is removed. Client
features use their named units. JSON and XML readers are in the optional
`http2clientreaders` package. The package counts are six common units, 55
client units, 73 server units, and one Readers unit.

## Build commands

The Makefile and Taskfile use `tools/build.py`. The build writes compiler
units and programs under `bin/<cpu>-<os>/<profile>/`. It writes no compiler
output into the source directories.

```sh
task setup:deps
task build
task build:readers
task test
task test:api
task test:integration
task examples
task packages:check
task source:check
task docs:check
task validate:fast
```

`task setup:deps` checks out the pinned mORMot2 revision. The common build has
no mORMot2 dependency. Client and server builds require Free Pascal 3.2.4,
the pinned mORMot2 source, and OpenSSL 3 at run time. The Readers package is
optional and uses the Free Pascal JSON and XML units. The Makefile exposes
the same operations with hyphenated target names, such as `make build-client`
and `make test-integration`.

The client harness also needs `task setup:harness`. Docker gates need Docker
and their external images. `task validate` runs `validate:fast` and all
explicit client and server validation gates. The explicit gates include
external conformance, Docker, and load checks. Their execution is deferred
in the current verification record.

## Verification status

On macOS arm64 with Free Pascal 3.2.4 and OpenSSL 3, the bounded common suite
passed 229 tests. The API suite passed 16 tests and six facade probes. All
nine in-process integration cases passed. The server TLS gate passed 21
checks and the server mTLS gate passed 40 checks. A separate-process HTTP
and TLS check also passed. The default client runner passed 805 registered
cases. Thirty-three environment-gated proxy, WebSocket, SSE, TLS, and lifecycle
cases did not run. Source checks passed for 353 Pascal headers and
size limits, 337 active Pascal files, 135 production units, 54 documentation
files, and 1,780 source test mappings. All four Lazarus package checks passed.

The full server unit run reached its 60-second deadline. A progress sample
showed normal test progress; this run is not a pass. Focused server factory
and TLS-context suites passed. The default client runner passed 805 registered
cases. Thirty-three environment-gated client cases did not run.
Linux validation, load tests, and independent external
conformance checks are deferred. The [current verification record](doc/verification/current-status.md)
lists the results and limits.

## Migration and history

The [0.30.0 migration table](doc/migration-0.30.0.md) records the source unit
map, split client API, removed umbrella, packages, and qualified API names.
The [documentation map](doc/README.md) lists design, verification, reference,
and historical records. The historical source package numbers 0.23.0 and
0.29.0 do not establish that those versions were published.

## License

Project-owned code and documentation use the Apache License, Version 2.0, or
the GNU Lesser General Public License, version 2.1, with the Free Pascal
Independent Modules exception. The license choice is
`Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)`. The
full license texts and source provenance are in `LICENSES/`. Third-party
works and specification copies keep their own terms.
