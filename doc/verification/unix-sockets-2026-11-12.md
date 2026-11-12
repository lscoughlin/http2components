---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, unix socket, linux, macos
notes:
  - This record holds the results of the Unix domain socket feature on macOS arm64 and on native Linux amd64.
  - One open defect of the client flow control limits the Linux integration result.
---

# Unix domain socket verification

This record states the results of the Unix domain socket feature of the server
and the client. The checks ran on 2026-11-12 on source revision `ed4fa61`. The
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
- `task test:client` runs 851 tests with no error and no failure.
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
- The unfiltered targets pass: `test:common` 237 tests, `test:client` 851
  tests, `test:integration` 19 tests and `test:server` 775 tests, each with no
  error and no failure.
- `TUnixIntegrationTest` ran five times. The TLS tests, `TestTlsOverUnix` and
  `TestTlsH2OverUnix`, ran in each run with a certificate directory and were
  not skipped. Four runs passed all 10 tests. One run failed
  `TestPostOneMiBodyEchoes` with a flow-control timeout.

## Open defect

A client request that sends a large body while the server echoes the body can
stall. The client sends the whole body before it reads the response. The
connection worker blocks when the inbound frame queue of the stream is full,
and the window updates of the peer stay unread. The request then fails with a
flow-control timeout after 3000 ms, and `Close` waits for the blocked worker.

- The defect is independent of the Unix socket. It occurs on the revision before
  the feature with plain TCP, for bodies of 2 MiB or more on macOS.
- Linux Unix socket buffers are smaller than the buffers of macOS. The
  intermittent failure therefore appears at 1 MiB on Linux.
- The test uses time limits for the request, for `Close` and for `Stop`. A stall
  fails the test in about 13 seconds. The test remains in the suite.

## Limits

- The load, abuse and external conformance checks did not run for this
  feature.
- A Linux abstract socket, peer credentials other than the process identifier,
  socket activation and Windows are not part of the feature.
