---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, body reader, body writer, producer, WebSocket, streaming, load test, linux
notes:
  - This record holds the Linux results of the streamed bodies and messages of version 0.33.0.
  - The record covers the shared body writer and body reader, the WebSocket send and receive streams, the producers, the cookie and format helpers, and the load runs of 2026-11-18.
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
| `test:client` | 1113 tests, no error, no failure |
| `TConnectionThreadTest` | 30 runs, no failure |
| `test:server` | 1043 tests, no error, no failure |
| `test:integration` | 21 tests, no error, no failure |
| `TWsPumpTest` | 30 runs, no failure |
| `TWsStreamThreadTest` | 30 runs, no failure |
| `TWsInboundThreadTest` | 15 runs, no failure |
| `TWsProducerThreadTest` | 800 runs, no failure |

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

## HTTP/2 cleartext runs

These runs used the tree at `main` (commit `a65f924`) on the loopback interface. The client
and the server are in one process.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| Upload of 1 MB, pull writer | status 200, all octets seen, 52 ms | 17 MB |
| Upload of 64 MB, pull writer | status 200, all octets seen, 839 ms | 17 MB |
| Upload of 64 MB, producer | status 200, all octets seen, 768 ms | 17 MB |
| Upload of 16 MB, producer, handler sleeps 1 ms per read | status 200, all octets seen, 424 ms | 17 MB |
| Download of 4 MB, producer | all octets arrived in 321 reads, 63 ms | 17 MB |
| Download of 64 MB, producer | all octets arrived in 5121 reads, 423 ms | 17 MB |
| Download of 64 MB, pull writer | all octets arrived, 590 ms | 17 MB |

## Not covered

- The WebSocket handshake of RFC 8441 over HTTP/2 with streamed messages.
- A run longer than one pass of each scenario, and a run with the host idle.
