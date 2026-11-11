# http2components 0.30.0

This repository is the planned combined source tree for the Free Pascal
HTTP/2 client and server. The documentation describes the planned combined
version 0.30.0. The release is not published by this record.

## Public entry points

| Unit | Role |
| --- | --- |
| `Http2.Common` | Shared protocol types and operations. |
| `Http2.Client` | Client factory, request, response, and client API. |
| `Http2.Server` | Server factory, handler, request, and response API. |

Client and server feature units use the `Http2.Client.*` and
`Http2.Server.*` names. The five shared protocol areas are Errors, Headers,
HPACK, Frames, and FlowControl. Their intended layout is described in the
[common architecture](doc/design/common/architecture.md) and
[protocol design](doc/design/common/protocol.md).

JSON and XML helpers are optional. They belong to the client Readers package;
the core client package does not require those helpers.

## Build and validation status

Root build commands are under integration review. The expected command
contract includes `make all`, `make test`, `make examples`, and
`task docs:check`. This page does not claim that these commands are present
or pass. The final command list follows review of the root build files.

Resource-intensive tests, load checks, and Linux validation are deferred.
There is no merged-tree validation result in this initial documentation.
Historical client and server verification records are indexed separately in
the [documentation map](doc/README.md).

## Migration

The [0.30.0 migration table](doc/migration-0.30.0.md) maps all 102 source
units. It also records the removed client umbrella, package changes, and
qualified API cases. The source changelogs remain separate historical
records for the client 0.23.0 and server 0.29.0 source snapshots.

## License

Project-owned code and documentation use the license choice in
[LICENSE](LICENSE): `Apache-2.0 OR (LGPL-2.1-only WITH
Independent-modules-exception)`. Third-party works and specification text
keep their own terms.
