---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, linux, validation, conformance, interoperability, peers, limits
scope: The full Linux x86_64 validation run of 2026-11-20 - host, commits, every stage with its result, the peers and their limits, and the open items.
related_docs:
  - doc/verification/current-status.md
  - doc/verification/linux-performance-2026-11-20.md
  - doc/verification/websocket-http2-client-2026-11-20.md
  - doc/verification/client-probes/README.md
notes:
  - This record states the results of one run. It is not a release approval.
  - A stage with a result of PASS passed its own check. A stage with a result of SKIPPED did not run.
---

# Linux validation run of 2026-11-20

This record states the results of the full validation run on Linux x86_64. The
run used the native Linux host and a container. The [current
status](current-status.md) summarizes the results. The [performance
record](linux-performance-2026-11-20.md) states every number of the load
stages. The [WebSocket over HTTP/2 record](websocket-http2-client-2026-11-20.md)
states the tests of the WebSocket over HTTP/2 client.

## Scope and commits

The run covers the build, the unit tests, the integration tests, the TLS
tasks, the source, documentation and version checks, the interoperability and
conformance gates, the live gates, the real peer matrices, the Unix socket
gate, the load stages and the repeated runs of the suites that use
threads.

| Item | Value |
| --- | --- |
| Commit of all stages except the combined load stage | `ff2d62191a7a9675466d70834ef0a07cc5df54c3` |
| Commit of the combined load stage (10,000 WebSocket sessions and 10,000 server-sent event streams) | `531b3ebb149230abed247b88f40622d06bf3962e` |
| SHA-256 of the source archive of the first commit | `5110136f18c0fed5b9b67f2ce61b2de563f54b08def0d9ab7e31b197e8c7586e` |
| SHA-256 of the source archive of the second commit | `3aca3f5088a0478666bf49117201bfd4a01e3f548256b4c5f50fe196a23ef8fd` |
| Library version | 0.34.0 |

The only difference between the two commits is the `load` mode of
`examples/server/ws_echo.pas`. In this mode the example raises the WebSocket
session limit to 30000. The default of `MaxWsSessions` is 5000, and the server
answers with status 503 beyond the limit. The unit, integration and client
suites did not run again on the second commit, because the code of the
library is the same on both commits.

The run date is 2026-11-20. Each stage has a log, and a record of its command,
its start and end time in UTC, its duration and the host load before and
after it.

## Host and image

| Item | Value |
| --- | --- |
| Host name | `liam-rzbox.local` |
| Processor | AMD Ryzen 7 5800H with Radeon Graphics, 16 logical CPUs (8 cores, 2 threads per core) |
| Memory | 15,383 MiB |
| Host kernel | Linux 7.0.0-43-generic, x86_64 |
| Docker daemon | 29.9.2 |
| Image | `do-dev/build-image:amd64`, Debian 12 |
| Free Pascal | 3.2.4-rc1 |
| OpenSSL | 3.0.22 |
| Python | 3.11.2 |
| nghttp2 tools (`nghttp`, `nghttpd`, `h2load`) | 1.52.0 |
| curl | 7.88.1 |
| go-task | 3.53.1 |
| h2spec | 2.6.0 |
| Container limits | 16 CPUs, 12 GiB of memory, 8192 processes, 65536 open files |
| `lazbuild` | absent from the image |

The tools `h2spec`, `nghttp` and `h2load` were installed into the container
before the run. The task `packages:check` needs `lazbuild`. It did not run.

The Docker command-line client in the container is version 20.10.24. It talks
to the daemon of the host through the Docker socket. The real peer matrices use
the images `nginx:1.28-alpine`, `httpd:2.4`, `caddy:2` and `ubuntu/squid`. The
real mutual TLS rows report nginx 1.28.3, Apache httpd 2.4.70 and Caddy 2.11.9.

## Stages

A stage with the result PASS passed its own check. The gate tasks decide their
own result. A duration is the wall-clock time of the stage.

### A. Build, unit and integration tests, TLS tasks and checks

| Stage | Command | Result | Counts | Duration |
| --- | --- | --- | --- | --- |
| A01 | `task build` | PASS | 5 production builds | 51 s |
| A02 | `task examples` | PASS | 25 examples compiled | 190 s |
| A03 | `task test:common` | PASS | 415 tests, 0 errors, 0 failures | 4 s |
| A04 | `task test:client` | PASS | 1239 tests, 0 errors, 0 failures | 201 s |
| A05 | `task test:server` | PASS | 1086 tests, 0 errors, 0 failures | 243 s |
| A06 | `task test:api` | PASS | 16 tests, 0 errors, 0 failures, and the API probes | 18 s |
| A07 | `task test:integration` | PASS | 55 tests, 0 errors, 0 failures | 46 s |
| A08 | `task test:tls-contract` | PASS | 23 cases | 2 s |
| A08 | `task test:tls-openssl` | PASS | 140 cases | 4 s |
| A08 | `task test:tls-tlslib` | PASS | 88 cases | 10 s |
| A08 | `task test:tls-client` | PASS | 23 cases | 5 s |
| A08 | `task test:tls-server` | PASS | 13 tests of the session runner, and the lifecycle runner | 14 s |
| A08 | `task test:tls-integration` | PASS | 29 cases, and the security runner | 33 s |
| A08 | `task test:local-process` | PASS | HTTP and HTTPS exchange between two processes | 10 s |
| A15 | `task source:check` | PASS | | 2 s |
| A16 | `task docs:check` | PASS | | 1 s |
| A17 | `task version:check` | PASS | version 0.34.0 | 0 s |
| A18 | `task packages:check` | SKIPPED | `lazbuild` is absent from the image | |

The task `test:integration` includes the local-process exchange.

### B. Interoperability and conformance gates

| Stage | Command | Result | Counts | Duration |
| --- | --- | --- | --- | --- |
| B01 | `task validate:client:harness` | PASS | 146 identifiers: MATCH 36, BETTER 16, WORSE 0, CLASS-DIFF 32, UNKNOWN 62, INFRASTRUCTURE 0 | 1918 s |
| B02 | `task validate:client:interop` | PASS | 13 pass, 0 fail, 1 skipped (case A.8) | 13 s |
| B03 | `task validate:client:sanity` | PASS | 5 pass, 0 fail | 8 s |
| B04 | `task validate:server:conformance` | PASS | h2spec `http2` 94 of 94, h2spec `hpack` 8 of 8; 200 requests with `h2load`; WebSocket over HTTP/2 32 checks; HTTP/1.1 WebSocket 5 checks; server-sent events 4 | 110 s |
| B05 | independent client, 12 rows | PASS | 12 of 12 | 3 s |
| B06 | independent server identity (`provider_mtls.py`) | PASS | 32 of 32 | 15 s |
| B07 | abrupt and graceful repeats | PASS | 20 of 20 rows (10 abrupt, 10 graceful) | 2 s |
| B08 | `task validate:client:websocket` | PASS | 18 tests, 0 errors, 0 failures | 6 s |
| B09 | `task validate:server:websocket` | PASS | 2 gate checks (5 checks and the abuse checks) | 107 s |
| B10 | `task validate:server:websocket:h2` | PASS | 32 of 32 checks | 107 s |
| B11 | `task validate:client:websocket:autobahn` | PASS | OK 296, NON-STRICT 2, INFORMATIONAL 3 | 40 s |

The harness gate has no case that the client fails. The gate summary line is
52 passes, 0 failures, 32 CLASS-DIFF and 62 UNKNOWN. These counts are not 146
strict passes. The section on the peers explains the classes.

The Autobahn report holds 301 cases. Two cases have the result NON-STRICT:
6.4.3 and 6.4.4. Three cases have the result INFORMATIONAL: 7.1.6, 7.13.1 and
7.13.2. The cases 12 and 13 (`permessage-deflate`) are excluded, because the
client offers no extension.

### C. Live gates, real peer matrices and the Unix socket gate

| Stage | Command | Result | Counts | Duration |
| --- | --- | --- | --- | --- |
| C01 | `task validate:client:cleartext` | PASS | | 5 s |
| C02 | `task validate:client:mtls` | PASS | | 19 s |
| C03 | `task validate:client:proxy` | PASS | 10 tests, 0 errors, 0 failures | 5 s |
| C04 | `task validate:client:sse` | PASS | 2 tests, 0 errors, 0 failures | 6 s |
| C05 | `task validate:server:fast` | PASS | h2spec 4.2 3 of 3, h2spec 6.5 10 of 10 | 105 s |
| C06 | `task validate:server:sse` | PASS | | 104 s |
| C07 | `task validate:server:tls-live` | PASS | 21 passed, 0 failed | 5 s |
| C08 | `task validate:server:mtls-live` | PASS | 40 passed, 0 failed | 63 s |
| C09 | `task validate:server:abuse` | PASS | 8 HTTP/2 checks, and the HTTP/1.1 WebSocket abuse checks | 116 s |
| C10 | real proxy matrix (`PROXY_REAL_LOCAL=1`) | PASS | 65 pass, 0 fail, 0 known, 3 skipped | 35 s |
| C11 | real mutual TLS matrix, native (`MTLS_REAL_NATIVE=1`) | PASS | 54 rows | 428 s |
| C12 | real mutual TLS matrix, host-local (`MTLS_REAL_HOST=local`) | PASS | 54 rows | 440 s |
| C13 | Unix socket gate on the Linux host (`tools/server/unix-linux.sh`) | PASS | every Unix suite and test target passed, with 20 test runners in the build | 1004 s |

The Unix socket gate ran on the host through the Docker socket, with a copy of
the tree in a Git repository. Its result line is "every Unix suite and test
target passed".

### D. Load stages

The [performance record](linux-performance-2026-11-20.md) states the numbers.

| Stage | Subject | Result | Counts | Duration |
| --- | --- | --- | --- | --- |
| D01 | incomplete-handshake admission | PASS | 4 of 4 cases (OpenSSL and TlsLib, TLS 1.2 and TLS 1.3) | 30 s |
| D02 | connection load | PASS | idle 100, 1,000 and 10,000 connections; 500 active streams; 8 delayed streams | 119 s |
| D03 | 10,000 WebSocket sessions and 10,000 server-sent event streams (commit `531b3eb`) | PASS | 3 of 3 runs | 31 s to 33 s of run time in each run |
| D04 | four runs of 1,000,000 requests over TLS | PASS | 1,000,000 succeeded, 0 failed, 0 errored in each run | 1597 s |

### F. Repeated runs

Each loop runs one suite many times in a new process. The
[WebSocket over HTTP/2 record](websocket-http2-client-2026-11-20.md) states the
test counts and the time of each run.

| Stage | Suite | Runs | Result |
| --- | --- | --- | --- |
| F01 | `TWsH2FlowIntegrationTest` | 30 | 30 of 30 pass |
| F02 | `TWsH2MuxIntegrationTest` | 30 | 30 of 30 pass |
| F03 | `TWsH2IntegrationTest` | 30 | 30 of 30 pass |
| F04 | `TWssH2IntegrationTest` | 30 | 30 of 30 pass |
| F05 | `THandlerExceptionTest` | 30 | 30 of 30 pass |
| F06 | `THttp1DetachTest` | 20 | 20 of 20 pass, 0 failures |
| F07 | `TDetachLiveTest` | 20 | 19 of 20 pass, 1 failure in run 6 |
| F08 | `TPoolDialTest` | 20 | 20 of 20 pass, 0 failures |
| F09 | `TMutualTlsRejectTest` | 20 | 20 of 20 pass, 0 failures |
| F10 | timings of the large WebSocket messages | | 5 runs of each test; see the performance record |

The stage durations of the loops are: F01 107 s, F02 125 s, F03 34 s, F04 25 s,
F05 60 s, F06 26 s, F07 178 s, F08 20 s, F09 247 s and F10 59 s.

## Peers and limitations

The independent harness compares the client with a reference client for each
of 146 identifiers. The classes are:

- MATCH: the client and the reference give the same result.
- BETTER: the client meets the declared outcome, and the reference does not
  demonstrate it.
- WORSE: the client fails an outcome that the reference meets. The count is 0.
- CLASS-DIFF: the client and the reference give a different class of result.
  The count is 32.
- UNKNOWN: neither side resolves to an outcome class. The count is 62.
- INFRASTRUCTURE: the run itself failed. The count is 0.

The peers of this run differ from the peers of an earlier Linux run. The image
has nghttp2 1.52.0. The distribution of the classes differs because of the
peers. The count of WORSE is 0, and the count of UNKNOWN is 62, as before.

Two peer limitations remain:

- The Squid peer of the real proxy matrix has GnuTLS limits. Three cases of
  the matrix are skipped for this reason.
- The peer `nghttpd` cannot trigger a GOAWAY frame while a request is in
  flight. The interoperability case A.8 is skipped for this reason.

A `wss` request to a server that offers only `h2` fails at the TLS handshake
with `EHttpConnectionError` when no pooled HTTP/2 connection exists. This is
documented behavior. The [WebSocket over HTTP/2
record](websocket-http2-client-2026-11-20.md) lists it.

The server keeps a queue of messages for each WebSocket session. The
[server WebSocket design](../design/server/websocket.md) documents it.

## Open items

The items below are open limits and open defects of this run.

1. The rule for a failed write of the WebSocket client is that a failed write
   no longer suppresses `OnClose` and `OnError`. The rule changes HTTP/1.1 also.
   No HTTP/1.1 test of the rule exists, because the mock socket has no
   failure switch.
2. A window that depends on timing remains in `ReadPeerAlertAfterWriteFailure`
   on HTTP/2. The function waits at most 100 ms. A TLS client-certificate
   alert can be lost when the write path fails first. No deterministic test
   exists.
3. No test has run on Windows.
4. No test covers a loss of the network connection with no Close frame for the
   WebSocket client. The repository has no TCP relay helper.
5. The task `packages:check` did not run on Linux, because the image has no
   `lazbuild`.
6. The distribution of the classes of the independent harness differs from the
   distribution of an earlier Linux run, because the peers differ. The count of
   WORSE is 0, and the count of UNKNOWN is 62.
7. The connection load and the million-request runs were 4 to 5 percent slower
   than in the previous Linux run. A million-request run took 381 to 389 s in
   this run, and 364 to 371 s in the previous run.
8. The peer limitations in the section above remain: three Squid cases
   skipped, and the case A.8 of `nghttpd` skipped.
