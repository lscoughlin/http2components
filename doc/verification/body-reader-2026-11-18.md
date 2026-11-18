---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, body reader, body writer, producer, WebSocket, streaming, load test, linux
notes:
  - This record holds the Linux results of the streamed bodies and messages of version 0.33.0.
  - The record covers the shared body writer and body reader, the WebSocket send and receive streams, the producers, the cookie and format helpers, and the load runs of 2026-11-18.
  - One defect is open. A lock-order deadlock of the server can stop a connection that carries WebSocket messages over HTTP/2.
  - The load programs are not stored in the repository.
---

# Streamed bodies and messages: Linux verification

This record states the results of the streamed bodies and messages on native Linux. The
checks ran on 2026-11-18 on commit `ab35d6e` of the branch `main`. The record
is not release approval.

## Environment

| Item | Detail |
| --- | --- |
| Host | Linux amd64 Docker container on the host `liam-rzbox`, Ubuntu 24.04, 16 cores, Free Pascal 3.2.4 |
| Host load | The host also runs unrelated containers. The load average was between 17 and 23 during the runs, so the times in this record are not benchmark figures |
| Staging | The tracked files of the commit, with the `third_party` checkouts of the pinned revisions |

## Gate results

| Step | Result |
| --- | --- |
| `build:client`, `build:server` | pass |
| `source:check`, `packages:check` | pass |
| `test:client` | 1114 tests, no error, no failure |
| `test:server` | 1059 tests, no error, no failure |
| `test:integration` | 21 tests, no error, no failure |
| `TWsPumpTest` | 30 runs, no failure |
| `TWsStreamThreadTest` | 30 runs, no failure |
| `TWsInboundThreadTest` | 15 runs, no failure |
| `TWsProducerThreadTest` | 100 runs, no failure |
| `TConnectionThreadTest` | 30 runs, no failure |

## Load runs

The load program starts a server and clients in one process, on the loopback interface, and
samples the resident memory of the process every 50 ms. The WebSocket options were:
inline limit 65536 octets, pipe 64 MiB, inbound stall 120 s, a message limit of 2 GiB minus 1,
a stream pool of 400 threads, and a limit of 64 GiB for queued WebSocket octets.

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

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| Download of 64 MB, producer | all octets arrived in 5121 reads, 585 ms | 17 MB |
| Download of 64 MB, pull writer | all octets arrived in 4149 reads, 666 ms | 17 MB |
| Upload of 64 MB, pull writer | status 200, all octets seen, 406 ms | 18 MB |
| Upload of 64 MB, producer | status 200, all octets seen, 426 ms | 18 MB |

## WebSocket over HTTP/2 runs

The raw HTTP/2 test client sent one inbound message of 4 MB on one stream to a handler that
reads at once. In six runs on Linux, five finished in 0.45 s to 0.7 s with the exact octet
count. One run did not finish within 30 s (see the open defect). A message of 32 MB finished
in 0.9 s in one run. A message of 256 MB did not finish in 20 minutes in the one run that was
made.

## Defects open

**Lock-order deadlock of the server.** Two locks of an HTTP/2 connection are taken in opposite
orders by two paths.

- A thread that sends output takes the send lock. At the end of its loop it asks whether
  output is pending, and that call takes the connection lock
  (`Http2.Server.Async`, `SendPendingOutput`).
- The IO thread takes the connection lock when it processes received frames. A WebSocket
  session returns stream credit from this path, and the credit call wakes the sender, which
  waits for the send lock (`Http2.Server.WebSocket.Session`, `BytesReceived`).

When both paths run at the same time, each thread waits for the lock of the other. All other
threads of the connection then wait for the connection lock, and `StopServer` does not return.
Two stack samples 5 s apart showed identical stacks and no CPU use.

- The defect shows on a connection that carries inbound WebSocket messages over HTTP/2. On
  the Mac, one stream with a message of 16 MB stopped 2 times in 30 runs, 24 streams of 1 MB
  stopped in 3 of 3 runs, and 6 streams stopped in 2 of 20 runs. On Linux, one stream with a
  message of 4 MB stopped once in six runs.
- Both locking paths exist in version 0.32.0, so a released version can show the defect.
- A change that reads the pending-output state before the send lock is taken removed the stops
  in a test on the Mac (24 streams, 10 of 10 runs; one stream with 16 MB, 100 of 100 runs).
  The repository test suites did not run with that change.

## Not covered

- The WebSocket scenarios over HTTP/2 for a slow handler, a peer that stops in the middle of a
  message, outbound producers, many streams on one connection, and the credit balance across
  messages. These ran on the Mac with small sizes only, and the scenario with 24 or more
  streams does not finish while the defect is open.
- `test:common`, `docs:check` and `version:check` on Linux for this commit.
- A run longer than one pass of each scenario, and a run with the host idle.
