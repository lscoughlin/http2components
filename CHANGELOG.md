# Changelog

## 0.31.0 — in development

- Version bump after the 0.30.0 source release. No other change yet.

## 0.30.0 — 2026-11-12 (source release)

- Client and server source now share one repository and the common protocol
  units.
- The public entry units are `Http2.Common`, `Http2.Client`, and
  `Http2.Server`.
- Client transport, HTTP/1 body, stream types, and API/pool implementation
  have separate units. The `Http2` client umbrella is removed.
- Common, client, server, and optional client Readers Lazarus packages use
  version 0.30.0.
- The root build driver provides component builds, unit and API tests,
  in-process integration checks, examples, package checks, source checks,
  documentation checks, and explicit validation gates.
- Common, API, facade, local integration, server TLS, and server mTLS results
  are recorded in the [current verification record](doc/verification/current-status.md).
- The default client runner passes 854 registered cases on macOS and on Linux,
  with no error and no failure. The full server unit suite passes 775 tests on
  Linux. The full server unit suite has no completed run on macOS, because it
  does not finish in the time limit on the development host.
- The server and the client support Unix domain sockets: `WithUnixSocket` on
  both factories, `WithUnixSocketMode` on the server, and `WithUnixProxy` on the
  client. Results are in the
  [Unix socket verification record](doc/verification/unix-sockets-2026-11-12.md).
- The client inbound queues are unbounded, so a large request body echo no longer
  stalls the connection reader or fails with a flow-control timeout.
- The Unix socket suites and the unfiltered common, client, integration and
  server targets pass on Linux amd64.
- Load checks, independent external conformance checks, and the full server
  unit run on macOS remain open.

This release is a source release. It has no binary artifacts. The client 0.23.0
and server 0.29.0 records remain historical source package histories at
[doc/README.md](doc/README.md).
