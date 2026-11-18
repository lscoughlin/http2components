---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, body reader, body writer, producer, WebSocket, streaming, load test, linux
notes:
  - This record holds the Linux results of the streamed bodies and messages of version 0.33.0.
  - The record covers the shared body writer and body reader, the WebSocket send and receive streams, the producers, the cookie and format helpers, and the load runs of 2026-11-18.
  - Two defects of the HTTP/2 flow control were found by the load runs. They are open.
  - The load program is not stored in the repository.
---

# Streamed bodies and messages: Linux verification

This record states the results of the streamed bodies and messages on native Linux. The
checks ran on 2026-11-18 on the tree of the branch `body-reader`. The tree is the merge
of the branch `ws-streaming` and the stories that follow it. The record is not release
approval.

## Environment

| Item | Detail |
| --- | --- |
| Host | Linux amd64 Docker container on the host `liam-rzbox`, Ubuntu 24.04, 16 cores, Free Pascal 3.2.4 |
| Host load | The host also runs unrelated containers. The load average stayed near 15 during the runs, so the times in this record are not benchmark figures |
| Staging | The tracked files of the tree, with the `third_party` checkouts of the pinned revisions |

## Gate results

| Step | Result |
| --- | --- |
| `build:common`, `build:client`, `build:server` | pass |
| `source:check`, `docs:check`, `version:check`, `packages:check` | pass |
| `test:common` | 414 tests, no error, no failure |
| `test:client` | 1111 tests, no error, no failure |
| `test:server` | 1043 tests, no error, no failure |
| `test:integration` | 21 tests, no error, no failure |
| `TWsPumpTest` | 30 runs, no failure |
| `TWsStreamThreadTest` | 30 runs, no failure |
| `TWsInboundThreadTest` | 15 runs, no failure |
| `TWsProducerThreadTest` | 800 runs, no failure |

One full run of `test:server` stopped at the time limit of 1200 s on an earlier tree. A second
full run of that tree finished in 6 minutes 38 seconds. The cause of the first stop is not
known. Each test class passed when it ran alone.

## Load runs

The load program starts a server and clients in one process, on the loopback interface, and
samples the resident memory of the process every 50 ms. The WebSocket options were:
inline limit 65536 octets, pipe 64 MiB, inbound stall 120 s, a message limit of 2 GiB minus 1,
a stream pool of 400 threads, and a limit of 64 GiB for queued WebSocket octets.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| HTTP/2 prior-knowledge download of 256 MB from a producer to a reader that sleeps after each read | all octets arrived | 17 MB |
| Inbound WebSocket message of 256 MB over HTTP/1.1 to a handler that reads at once | exact octet count, 1.8 s | 76 MB |
| The same message to a handler that sleeps 20 ms after each chunk | the session closed with 1009, reason `the handler reads too slowly`, after 1.1 s | 207 MB |
| 200 parallel inbound WebSocket sessions of 2 MB each | all 200 completed in 1.9 s | 287 MB |
| `SendStream` of a producer, 128 MB to a client that grants demand one message at a time | all octets arrived in 0.4 s | 17 MB |

The inbound results show the rule of an HTTP/1.1 channel: the channel has no flow control,
so the pipe cap bounds the memory and a handler that reads too slowly loses its session.

## Defects found and open

The load runs found two defects in the HTTP/2 server flow control on the cleartext
prior-knowledge path. A build of the previous main branch (before the work of this record)
shows both, so neither comes from the streamed bodies.

- An upload of 1 MB or more fails. The server handler reads the body with `Read`, and the
  read times out after the 30 s limit for a request body. The response is status 500. The
  failure is the same for a pull writer and for a producer.
- A download costs 16 to 20 ms for each read. A download of 4 MB with 321 reads takes 5.25 s,
  on the branch and on the previous main branch. A download of 256 MB would take about
  5.6 minutes.

The load run of an HTTP/2 upload of a body larger than memory therefore did not run.

## Not covered

- HTTP/2 uploads of large bodies (see the open defects).
- The WebSocket handshake of RFC 8441 over HTTP/2 with streamed messages.
- A run longer than one pass of each scenario, and a run with the host idle.
