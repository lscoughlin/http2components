---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, body reader, body writer, producer, WebSocket, streaming, load test, linux
notes:
  - This record holds the Linux results of the streamed bodies and messages of version 0.33.0.
  - The record covers the shared body writer and body reader, the WebSocket send and receive streams, the producers, the cookie and format helpers, and the load runs of 2026-11-18 and 2026-11-19.
  - One finding is open. A code review found a possible lock-order conflict between the connection lock and the write lock of the socket layer. No run has shown it.
  - The load programs are not stored in the repository.
---

# Streamed bodies and messages: Linux verification

This record states the results of the streamed bodies and messages on native Linux. The
checks ran on 2026-11-19 on commit `a8da965` of the branch `main`. The record
is not release approval.

## Environment

| Item | Detail |
| --- | --- |
| Host | Linux amd64 Docker container on the host `liam-rzbox`, Ubuntu 24.04, 16 cores, Free Pascal 3.2.4 |
| Host load | The host also runs unrelated containers. The load average was between 0.2 and 2.4 during the runs. The times in this record are not benchmark figures |
| Staging | The tracked files of the commit, with the `third_party` checkouts of the pinned revisions |

## Gate results

| Step | Result |
| --- | --- |
| `build:client`, `build:server` | pass |
| `source:check`, `packages:check` | pass |
| `test:client` | 1114 tests, no error, no failure |
| `test:server` | 1060 tests, no error, no failure |
| `test:integration` | 21 tests, no error, no failure |
| `TWsHttp2LocksTest` | 30 runs, no failure |
| `TWsPumpTest` | 30 runs, no failure |
| `TWsStreamThreadTest` | 30 runs, no failure |
| `TWsInboundThreadTest` | 15 runs, no failure |
| `TWsProducerThreadTest` | 100 runs, no failure |
| `TConnectionThreadTest` | 30 runs, no failure |

## Load runs on HTTP/1.1

The load program starts a server and clients in one process, on the loopback interface, and
samples the resident memory of the process every 50 ms. The WebSocket options were:
inline limit 65536 octets, pipe 64 MiB, inbound stall 120 s, a message limit of 2 GiB minus 1,
a stream pool of 400 threads, and a limit of 64 GiB for queued WebSocket octets. These runs
ran on 2026-11-18 on commit `ab35d6e`.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| Inbound WebSocket message of 256 MB over HTTP/1.1 to a handler that reads at once | exact octet count, 1.1 s | 18 MB |
| The same message to a handler that sleeps 20 ms after each chunk | the session closed with 1009, reason `the handler reads too slowly`, after 0.4 s and after 1.1 s in two runs | 83 MB and 193 MB |
| 200 parallel inbound WebSocket sessions of 2 MB each | all 200 completed in 1.4 s | 299 MB |
| `SendStream` of a producer, 128 MB to a client that grants demand one message at a time | all octets arrived in 0.5 s | 17 MB |

The inbound results show the rule of an HTTP/1.1 channel: the channel has no flow control,
so the pipe cap bounds the memory and a handler that reads too slowly loses its session.

## HTTP/2 cleartext runs

These runs used HTTP/2 with prior knowledge. The client and the server are in one process.
They ran on 2026-11-18 on commit `ab35d6e`.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| Download of 64 MB, producer | all octets arrived in 5121 reads, 585 ms | 17 MB |
| Download of 64 MB, pull writer | all octets arrived in 4149 reads, 666 ms | 17 MB |
| Upload of 64 MB, pull writer | status 200, all octets seen, 406 ms | 18 MB |
| Upload of 64 MB, producer | status 200, all octets seen, 426 ms | 18 MB |

## WebSocket over HTTP/2 runs

These runs used the raw HTTP/2 test client against the server of the load program, on commit
`a8da965`. Each scenario ran 3 times. All runs passed.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| H: inbound message of 256 MB on one stream to a handler that reads at once | exact octet count, close code 1000, 1.7 s to 2.2 s | 12 MB to 13 MB |
| I: inbound message of 64 MB to a handler that sleeps 5 ms after each chunk | exact octet count, close code 1000, about 97 s. The flow control of the stream slowed the sender, and the session stayed open | 11 MB to 12 MB |
| J: the peer stops in the middle of a message, inbound stall 2000 ms | the session closed with 1008, a second stream of 1 MB on the same connection arrived exact, 2.5 s | 10 MB to 12 MB |
| K: outbound producer message of 128 MB, the peer returns credit after 1 ms per DATA frame | all octets arrived, 134232068 octets with the WebSocket frame headers, close code 1000, 14 s to 17 s | 12 MB to 14 MB |
| L: outbound producer message, the peer returns no credit, outbound stall 2000 ms | the session closed with 1008, `RST_STREAM` with code 8 followed 20 ms after `Closed`, a second stream of 1 MB on the same connection arrived exact, 3.0 s | 10 MB to 13 MB |
| M: a message of 256 MB and a message of 64 MB on two streams of one connection | the small message finished as fast as the big message alone: 386 ms to 573 ms against 391 ms to 404 ms, inside the limit of three times plus 2 s | 6 MB to 10 MB |
| N: 50 parallel streams of 8 MB each, round robin | no failed reply, 8.9 s to 9.1 s | 6 MB to 13 MB |

## Findings open

**Possible lock-order conflict with the socket layer.** A code review of the send path found
two locks that two paths can take in opposite orders: the connection lock of the server and
the write lock of the socket layer in mORMot2.

- The IO thread holds the connection lock when it signals the waker, and the signal asks the
  socket layer to write.
- The socket layer holds its write lock while it calls the after-write hook of the
  connection, and the hook takes the connection lock.

No run has shown the conflict. The runs of this record, including the loops and the scenario
with 50 parallel streams, did not stop. The review is the only source of this finding.

## Not covered

- `test:common`, `docs:check` and `version:check` on Linux for this commit.
- A run longer than one pass of each scenario, and a run with the host idle. The scenarios of
  the HTTP/2 runs ran 3 times each.
