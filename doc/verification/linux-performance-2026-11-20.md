---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, linux, performance, load, admission, memory, latency
scope: The numbers of the load stages of the Linux run of 2026-11-20 - admission, connection load, four runs of one million requests, the combined WebSocket and server-sent event load, and the timings of the large WebSocket messages over HTTP/2.
related_docs:
  - doc/verification/current-status.md
  - doc/verification/linux-validation-2026-11-20.md
  - doc/verification/websocket-http2-client-2026-11-20.md
notes:
  - The numbers come from one host, one container and the commits that the Linux validation record names.
---

# Linux performance numbers of 2026-11-20

This record states the numbers of the load stages. The [Linux validation
record](linux-validation-2026-11-20.md) states the host, the image, the commits
and the other stages. The [current status](current-status.md) summarizes the
results. The [WebSocket over HTTP/2 record](websocket-http2-client-2026-11-20.md)
states the tests that the timings of the last section belong to.

The host has 16 logical CPUs and 15,383 MiB of memory. The container limits are
16 CPUs, 12 GiB of memory, 8192 processes and 65536 open files. All stages except
D03 ran on commit `ff2d62191a7a9675466d70834ef0a07cc5df54c3`. Stage D03 ran on
commit `531b3ebb149230abed247b88f40622d06bf3962e`. The only difference between
the two commits is the `load` mode of `examples/server/ws_echo.pas`.

## Host load

The load average has three values: the average of 1, 5 and 15 minutes. The
values come from the stage record before and after each stage.

| Stage | Load before | Load after |
| --- | --- | --- |
| D01 admission | 1.34 1.38 1.37 | 1.49 1.42 1.38 |
| D02 connection load | 1.49 1.42 1.38 | 2.25 1.59 1.44 |
| D04 million requests | 1.33 1.44 1.39 | 1.45 1.78 1.72 |
| D03 run 1 | 1.08 0.98 0.97 | 2.87 1.44 1.12 |
| D03 run 2 | 2.12 1.36 1.10 | 1.33 1.25 1.08 |
| D03 run 3 | 1.33 1.25 1.08 | 1.33 1.28 1.09 |
| F10 timings | 0.30 0.68 1.00 | 0.51 0.67 0.98 |

## D01. Admission of incomplete TLS handshakes

The test opens connections that start a TLS handshake and do not finish it.
The server admits 64 of them. It rejects the 64 excess connections. The
recovery time is the time in which the server answers an HTTP/2 request after
the load. The number of open file descriptors goes from 6 to 70 and
back to 6 in each case. The CPU time of the server is 0.00 s at the three
measuring points.

| Provider and version | Admitted | Rejected | Recovery | RSS baseline, peak, settled (KiB) |
| --- | --- | --- | --- | --- |
| OpenSSL, TLS 1.2 | 64 | 64 | 5.31 ms | 27228, 29100, 29148 |
| OpenSSL, TLS 1.3 | 64 | 64 | 4.48 ms | 27256, 29116, 29168 |
| TlsLib, TLS 1.2 | 64 | 64 | 5.88 ms | 23768, 24424, 24556 |
| TlsLib, TLS 1.3 | 64 | 64 | 6.32 ms | 23796, 24480, 24604 |

All 4 cases pass.

## D02. Connection load

| Case | Result |
| --- | --- |
| 100 idle connections (fresh server) | All stayed open for 20.0 s. CPU 0.210 s, which is 1.05 percent of one core. |
| 1,000 idle connections (fresh server) | All stayed open for 20.0 s. CPU 0.210 s, which is 1.05 percent of one core. |
| 10,000 idle connections (fresh server) | All stayed open for 20.0 s. CPU 0.230 s, which is 1.15 percent of one core. RSS settled at 66,276 KiB, from 7,080 KiB before. |
| 500 active streams (fresh server) | 500 of 500 answered in 0.13 s, which is 3,916 streams a second. Latency p50 5.9 ms, p90 8.0 ms, p99 8.7 ms, maximum 9.0 ms. |
| 8 delayed streams, delay 600 ms | The answers took 602 ms to 1203 ms. |
| Sequence on one server | 10,000 idle connections with CPU 1.15 percent; 500 active streams at 3,816 streams a second with p99 9.3 ms; the delayed streams with answers from 601 ms to 1202 ms; RSS from 64,208 KiB to 69,060 KiB. The number of file descriptors returned to 6 after each case. |

## D04. Four runs of one million requests over TLS

Each run sends 1,000,000 requests over one connection with `h2load`. In each run
all 1,000,000 requests succeeded, 0 failed and 0 errored. The server accepted
one more connection in each run. The latencies are in milliseconds.

| Provider and version | Time | Requests a second | p50 | p99 | Maximum | RSS start to end (KiB) | Server CPU |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OpenSSL, TLS 1.2 | 381.50 s | 2,621.20 | 0.352 | 0.558 | 6.245 | 27,260 to 28,276 | 298 s |
| OpenSSL, TLS 1.3 | 389.36 s | 2,568.30 | 0.358 | 0.564 | 7.201 | 27,256 to 28,776 | 304 s |
| TlsLib, TLS 1.2 | 383.32 s | 2,608.81 | 0.354 | 0.564 | 7.170 | 23,796 to 25,020 | 301 s |
| TlsLib, TLS 1.3 | 386.68 s | 2,586.14 | 0.356 | 0.564 | 7.007 | 23,884 to 25,572 | 302 s |

The runs took 381 s to 389 s. The previous Linux run took 364 s to 371 s for
each run, with p50 from 0.336 ms to 0.344 ms and p99 from 0.520 ms to 0.546 ms.
The runs of this record are 4 to 5 percent slower.

## D03. 10,000 WebSocket sessions and 10,000 server-sent event streams

This stage ran on commit `531b3ebb149230abed247b88f40622d06bf3962e`. In the
`load` mode, `examples/server/ws_echo.pas` raises the limit of WebSocket
sessions to 30000. The default of `MaxWsSessions` is 5000, and a server answers
with status 503 beyond the limit. One WebSocket server and one server-sent
event server are under load. The stage opens all connections, measures the
bytes of each, sends 1,000 ordinary requests, holds the load for 20 s, then
closes all connections. The RSS before the load is 7,548 KiB for the WebSocket
server and 7,168 KiB for the event server.

| Run | Opened (WebSocket, event) | Open time | Bytes for each WebSocket, each stream | Ordinary requests | p50, p99, maximum | Server CPU over 20 s (WebSocket, event) | RSS after disconnect, KiB (WebSocket, event) | Closed | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 10,000 of 10,000; 10,000 of 10,000 | 4.6 s | 10,783; 5,909 | 1,000 sent, 1,000 passed, 0 failed | 1.6 ms, 6.3 ms, 11.2 ms | 5.0 %; 10.0 % | 113,248; 67,008 | 20,000 of 20,000 | PASS |
| 2 | 10,000 of 10,000; 10,000 of 10,000 | 6.6 s | 10,782; 5,895 | 1,000 of 1,000 passed | 1.6 ms, 6.3 ms, 8.2 ms | 5.0 %; 5.0 % | 113,216; 66,892 | 20,000 of 20,000 | PASS |
| 3 | 10,000 of 10,000; 10,000 of 10,000 | 6.5 s | 10,736; 5,890 | 1,000 of 1,000 passed | 1.6 ms, 6.2 ms, 9.4 ms | 5.0 %; 5.0 % | 112,792; 66,960 | 20,000 of 20,000 | PASS |

The run times are 31.1 s, 33.2 s and 33.0 s. In all three runs both servers
report `stopped: true`, exit 0 and no cleanup error. After each run no
`ws_echo` process and no `sse_replay` process is alive. All 3 runs pass.

## F10. WebSocket over HTTP/2: large messages

The client and the server run in one process. Each test ran 5 times under
`/usr/bin/time -v`. The table gives the lowest and the highest value of the 5
runs.

| Test | Wall time | Peak RSS (KiB) |
| --- | --- | --- |
| `TWsH2FlowIntegrationTest.TestServerStreamedMessageReachesTheClient` (16 MiB streamed message) | 0.29 s to 0.30 s | 58,552 to 59,296 |
| `TWsH2FlowIntegrationTest.TestClientSendsLargeMessageInFragments` (8 MiB message from the client) | 0.24 s to 0.25 s | 36,652 to 37,412 |
| `TWsH2MuxIntegrationTest.TestRepeatedOpenAndClose` (200 rounds of open and close) | 3.46 s to 3.50 s | 18,276 to 19,088 |
| Whole `TWsH2FlowIntegrationTest` (7 tests) | 3.42 s to 3.55 s | 103,128 to 104,112 |
| Whole `TWsH2MuxIntegrationTest` (5 tests) | 4.13 s to 4.74 s | 39,220 to 41,148 |

The tests prove the exact octet counts and the order of the octets. A bound on
throughput or on memory is not proven by one host and one run size.
