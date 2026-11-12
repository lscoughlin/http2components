# Changelog

## 0.30.0 — merged source tree (unreleased)

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
- The default client runner passed 805 registered cases. Thirty-three
  environment-gated client cases did not run. The full server unit suite has no
  completed run in this record.
- The server and the client support Unix domain sockets: `WithUnixSocket` on
  both factories, `WithUnixSocketMode` on the server, and `WithUnixProxy` on the
  client. Results are in the
  [Unix socket verification record](doc/verification/unix-sockets-2026-11-12.md).
- The client inbound queues are unbounded, so a large request body echo no longer
  stalls the connection reader or fails with a flow-control timeout.
- Linux validation, load checks, independent external conformance checks,
  and the full server unit result remain open.

This entry describes the current source tree. It does not state that version
0.30.0 is a published release. The client 0.23.0 and server 0.29.0 records
remain historical source package histories at [doc/README.md](doc/README.md).
