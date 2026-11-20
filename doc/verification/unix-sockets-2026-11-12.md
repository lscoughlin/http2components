---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, unix socket, linux, macos
notes:
  - This record holds the results of the Unix domain socket feature on macOS arm64 and on native Linux amd64.
---

# Unix domain socket verification

This record states the results of the Unix domain socket feature of the server
and the client. The checks ran on 2026-11-12 on source revision `c49c79c`. The
record is not release approval.

## Environment

| Host | Detail |
| --- | --- |
| macOS | arm64, Free Pascal 3.2.4, tasks run with `task` |
| Linux | amd64 Docker context on the host `rzbox`, Ubuntu 24.04, Free Pascal 3.2.4, OpenSSL 3.0.13 |

## macOS results

- `task build`, `task packages:check`, `task source:check`, `task docs:check`,
  `task version:check` and `task examples` pass.
- `task test:common` runs 237 tests with no error and no failure.
- `task test:client` runs 854 tests with no error and no failure.
- The Unix suites of the server pass by name: `TUnixPathTest` 17,
  `TConfigUnixTest` 13, `TUnixServerTest` 10, `TUnixOptionsTest` 4,
  `TUnixFacadeTest` 5 and `TUnixProtocolTest` 2.
- The integration suite `TUnixIntegrationTest` runs 10 tests with no failure
  in repeated runs.
- The server suites run by name, because the full `task test:server` does not
  finish in the time limit on this host.

## Linux results

- The Unix suites of the server, the client and the common component pass.
  The result includes the peer process identifier read with `SO_PEERCRED`, the
  socket path of 103 bytes, the stop with an open connection and the removal of
  the socket file.
- The unfiltered targets pass: `test:common` 237 tests, `test:client` 854
  tests, `test:integration` 19 tests and `test:server` 775 tests, each with no
  error and no failure.
- `TUnixIntegrationTest` runs 10 tests with no failure. The TLS tests,
  `TestTlsOverUnix` and `TestTlsH2OverUnix`, run with a certificate directory
  and are not skipped.
## Limits

- The per-stream inbound queue and the connection queue are unbounded, so the reader
  never blocks on a queue. Window credit is returned on arrival. Per-stream memory of a
  stalled consumer therefore has no hard limit.
- The load, abuse and external conformance checks did not run for this
  feature.
- A Linux abstract socket, peer credentials other than the process identifier,
  socket activation and Windows are not part of the feature.
