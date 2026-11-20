---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, websocket, http2, rfc8441, extended connect, tests, loops
scope: The tests of the WebSocket over HTTP/2 client (RFC 8441), their results on Linux x86_64, the loop results, the volume results and the open items that concern the client.
related_docs:
  - doc/verification/current-status.md
  - doc/verification/linux-validation-2026-11-20.md
  - doc/verification/linux-performance-2026-11-20.md
  - doc/design/client/testing-observability.md
  - doc/design/client/websocket.md
  - doc/references/rfc8441.txt
notes:
  - RFC 8441 is at https://www.rfc-editor.org/info/rfc8441. The date of the check is 2026-11-20. The plain-text copy is doc/references/rfc8441.txt.
  - The test design is in doc/design/client/testing-observability.md.
---

# WebSocket over HTTP/2 client: verification record

The client opens a WebSocket on a stream of an HTTP/2 connection with the
extended `CONNECT` method of RFC 8441
([RFC 8441](https://www.rfc-editor.org/info/rfc8441), checked 2026-11-20; the
plain-text copy is `doc/references/rfc8441.txt`). This record states the tests
of the client and their results. The [current status](current-status.md)
summarizes the results. The [Linux validation
record](linux-validation-2026-11-20.md) states the run, the host and the
commits. The [performance record](linux-performance-2026-11-20.md) states the
numbers of the load stages. The [testing
design](../design/client/testing-observability.md) describes what each test
covers.

All results are on commit `ff2d62191a7a9675466d70834ef0a07cc5df54c3`, on
Linux x86_64 in a Debian 12 container. The library server is the peer of the
integration tests.

## Tests

The tests have three groups.

### Unit tests with a scripted peer

The unit tests run the client against mock sockets and scripted loopback
peers. They need no live server. The units that concern the HTTP/2 route are:

- `Http2.Client.WebSocket.ProtocolMode.Test`: the choice of the protocol in
  `Send`, for each mode of `WithProtocolMode`.
- `Http2.Client.WebSocket.H2Handshake.Test`: the fields of the extended
  `CONNECT` request and the answer rule.
- `Http2.Client.WebSocket.H2Socket.Test`: the adapter over a tunnel.
- `Http2.Client.WebSocket.LeaseTunnel.Test`: reads, sends, resets and releases
  of a tunnel over a stream lease.
- `Http2.Client.WebSocket.OpenH2.Test` and
  `Http2.Client.WebSocket.OpenH2.Close.Test`: the opening over a pooled
  connection and the end of the session.
- `Http2.Client.Pool.Tunnel.Test`: the tunnel that the pool hands out.
- `Http2.Client.Connection.PeerSettings.Test`: the wait for the peer SETTINGS.

On Linux the client suite (`task test:client`) ran 1239 tests with 0 errors and
0 failures.

### Integration units

The integration units run the library client against the library server with
no mock.

| Unit | Suite | What it covers | Tests in one run |
| --- | --- | --- | --- |
| `Http2.Integration.WsH2.Test` | `TWsH2IntegrationTest` | echo, fragments, the close paths, the refusals, the subprotocol and the protocol modes over h2c | 15 |
| `Http2.Integration.WssH2.Test` | `TWssH2IntegrationTest` | the same route over TLS, a client certificate, a 4 MiB message, `wpmAuto` with and without a pooled connection, and a server that offers `h2` alone | 7 |
| `Http2.Integration.WsH2Flow.Test` | `TWsH2FlowIntegrationTest` | the volume of a streamed message, back pressure, an upload in fragments, the message limit, the server stop, the reset and the abort | 7 |
| `Http2.Integration.WsH2Mux.Test` | `TWsH2MuxIntegrationTest` | 20 WebSockets on one connection, a request beside an open WebSocket, four sending threads, a close during a send and 200 rounds of open and close | 5 |
| `Http2.Server.HandlerException.Test` | `THandlerExceptionTest` | the answer of the server to a handler that raises an exception, with the body of the request and the credit of the connection | 6 |
| `Http2.Server.WebSocket.QueueBurst.Test` | `TWsQueueBurstTest` | the queue limit of a WebSocket session over HTTP/2 for a burst of small messages | 5 |

On Linux the integration task (`task test:integration`) ran 55 tests with 0
errors and 0 failures, and the server suite (`task test:server`) ran 1086 tests
with 0 errors and 0 failures. On macOS arm64 the client suite ran 1239 tests and
the integration task ran 55 tests, each with 0 errors and 0 failures, on commit
`1fc1c33`. The server suite ran 1086 tests with 0 errors and 0 failures on
commit `7628a51`. The two commits differ from the commit of the Linux run only
in tests of the handler exception. The macOS runs are not part of the Linux run
that this record describes.

The WebSocket live gate (`task validate:client:websocket`) ran 18 tests with 0
errors and 0 failures. The Autobahn run of the client has OK 296,
NON-STRICT 2 and INFORMATIONAL 3. The server gate of the WebSocket over
HTTP/2 route (`task validate:server:websocket:h2`) passed 32 of 32 checks.

## Loop results

Each loop runs one suite in a new process for each run. All runs of the five
suites below passed.

| Suite | Runs | Passed | Tests in one run | Time of one run |
| --- | --- | --- | --- | --- |
| `TWsH2FlowIntegrationTest` | 30 | 30 | 7 | 3.44 s to 3.62 s |
| `TWsH2MuxIntegrationTest` | 30 | 30 | 5 | 4.11 s to 4.33 s |
| `TWsH2IntegrationTest` | 30 | 30 | 15 | 1.12 s to 1.14 s |
| `TWssH2IntegrationTest` | 30 | 30 | 7 | 0.81 s to 0.89 s |
| `THandlerExceptionTest` | 30 | 30 | 6 | 1.95 s to 2.02 s |

Four suites ran 20 times each to find flaky tests.

| Suite | Runs | Failures | Tests in one run |
| --- | --- | --- | --- |
| `THttp1DetachTest` | 20 | 0 | 13 |
| `TDetachLiveTest` | 20 | 1 (run 6) | 7 |
| `TPoolDialTest` | 20 | 0 | 6 |
| `TMutualTlsRejectTest` | 20 | 0 | 11 |

The failure of `TDetachLiveTest` is an open defect. The first open item below
describes it.

## Volume results

The tests of the volume prove the exact octet counts, the exact frame counts and
the order of the octets. The numbers of the last runs, on one host, are:

| Test | Wall time | Peak RSS |
| --- | --- | --- |
| A streamed message of 16 MiB from the server to the client | 0.29 s to 0.30 s | 58,552 KiB to 59,296 KiB |
| A message of 8 MiB from the client to the server in fragments | 0.24 s to 0.25 s | 36,652 KiB to 37,412 KiB |
| 200 rounds of open and close of a WebSocket | 3.46 s to 3.50 s | 18,276 KiB to 19,088 KiB |

The client and the server run in one process. Each value range is from 5
runs. The [performance record](linux-performance-2026-11-20.md) has the
whole-suite timings.

## Documented behavior

A `wss` request to a server that offers only `h2` fails at the TLS handshake
with `EHttpConnectionError` when no pooled HTTP/2 connection exists. The test
in `Http2.Integration.WssH2.Test` covers this behavior. The server has no option
that offers `http/1.1` alone, so the mock tests cover the peer that selects
`http/1.1`.

The server keeps a queue of messages for each WebSocket session. The design of
the [server WebSocket](../design/server/websocket.md) documents the queue, and
`TWsQueueBurstTest` tests it.

## Open items

1. The test `TDetachLiveTest` fails about 1 run in 20 on Linux. In run 6 of 20
   the test `TestDetachedStreamIsServedAndStopEndsIt` raised
   `EArgumentOutOfRangeException` with the message "Argument out of range". The
   cause is not found. The defect is in the test or in the detach path. On
   macOS the same test has a second form of the flake: a socket error EINVAL
   from `SetOptions`.
2. The rule for a failed write of the WebSocket client is that a failed write
   no longer suppresses `OnClose` and `OnError`. The rule changes HTTP/1.1 also.
   No HTTP/1.1 test of the rule exists, because the mock socket has no failure
   switch.
3. No test has run on Windows.
4. No test covers a loss of the network connection with no Close frame for the
   WebSocket client. The repository has no TCP relay helper. The abort tests
   cover the end of a stream without a Close frame from the handler of the
   server.
5. The tests run on loopback. They do not prove the behavior on a network with
   loss or delay.
6. The tests of the WebSocket over HTTP/2 route of the client use the library
   server as the peer. No independent server peer runs this route.
