---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, body reader, body writer, producer, WebSocket, streaming, load test, linux
notes:
  - This record holds the results of the streamed bodies and messages of version 0.33.0, and the state at the release of version 0.33.0, tag `v0.33.0`, commit `7137502`.
  - The branch `main` is at version 0.34.0 in development, at commit `bf6589f` of 2026-11-19.
  - The record covers the shared body writer and body reader, the WebSocket send and receive streams, the producers, the cookie and format helpers, and the load runs of 2026-11-18 and 2026-11-19.
  - Three findings are open. A code review found a possible lock-order conflict between the connection lock and the write lock of the socket layer. Two smaller findings come from code review of the stream lock and of the handler pool. No run has shown any of the three.
  - The load programs are not stored in the repository.
  - The record also holds the macOS gate results of commit e3a880b, and of the source tree of commit 3f0ba0a.
  - The record also holds the Linux gate results, the scenario runs and the stop-path loops of commit 3f0ba0a, run on 2026-11-19.
---

# Streamed bodies and messages: Linux verification

This record states the results of the streamed bodies and messages on native Linux. It holds
the results of version 0.33.0 and the state at the release of version 0.33.0, tag `v0.33.0`,
commit `7137502`. The first Linux gate of the record ran on 2026-11-19 on commit `2759ee9` of
the branch `main`. Each later section names the commit of its runs. The record is not release
approval.

## Environment

| Item | Detail |
| --- | --- |
| Host | Linux amd64 Docker container on the host `liam-rzbox`, Ubuntu 24.04, 16 cores, Free Pascal 3.2.4 |
| Host load | The host also runs unrelated containers. The load average was between 0.2 and 2.4 during the runs. The times in this record are not benchmark figures |
| Staging | The tracked files of the commit, with the `third_party` checkouts of the pinned revisions |

## State of the release

The release of version 0.33.0 is a GitHub source release. The record holds no gate run on
commit `7137502` itself. The Linux gate of commit `3f0ba0a` covers the release, because the tree
of the release equals the tree of `3f0ba0a` except `CHANGELOG.md` and this record. The Mac
gate of the same source tree is in the table below.

| Item | Value |
| --- | --- |
| Release tag | `v0.33.0`, on commit `7137502`, dated 2026-11-19 |
| Source version of `main` | 0.34.0, in development, at commit `bf6589f`, dated 2026-11-19. The commit changes only the version numbers, the README and the changelog |
| Last Linux gate commit | `3f0ba0a`, dated 2026-11-19. Its source tree is the same as the tree of the release (see above) |
| Mac gate of the source tree of `3f0ba0a` | `test:server` 1068 tests, no error, no failure. `test:client` 1115 tests, no error, no failure |

## Gate results

| Step | Result |
| --- | --- |
| `build:client`, `build:server` | pass |
| `source:check`, `packages:check` | pass |
| `test:client` | 1114 tests, no error, no failure |
| `test:server` | 1064 tests, no error, no failure |
| `test:integration` | 21 tests, no error, no failure |
| `TCloseStreamTest` | 30 runs, no failure |
| `TAdmissionConnectionsTest` | 30 runs, no failure |
| `TWsHttp2LocksTest` | 30 runs, no failure |
| `TWsPumpTest` | 30 runs, no failure |
| `TWsStreamThreadTest` | 30 runs, no failure |
| `TWsInboundThreadTest` | 15 runs, no failure |
| `TWsProducerThreadTest` | 100 runs, no failure |
| `TConnectionThreadTest` | 30 runs, no failure |

### macOS gate results

The gate ran on the Mac on commit `e3a880b`, the tip of `main` at that time. The Linux results
above are for commit `2759ee9`.

| Step | Result |
| --- | --- |
| `test:server` | 1066 tests, no error, no failure |
| `test:client` | 1115 tests, no failure |

The gate ran on the Mac on the source tree of commit `3f0ba0a`. That tree is the same as the
tree of commit `c84d5c5`, the tip of the stop-path branch.

| Step | Result |
| --- | --- |
| `test:server` | 1068 tests, no error, no failure |
| `test:client` | 1115 tests, no error, no failure |

### Linux gate results of commit 3f0ba0a

The gate ran on 2026-11-19 on commit `3f0ba0a` of the branch `main`, in a Linux amd64
container on the host `liam-rzbox`. The host load average was 0.43 at the start and between
0.4 and 1.2 during the run.

| Step | Result |
| --- | --- |
| `build:client`, `build:server` | pass |
| `source:check`, `docs:check` | pass |
| `packages:check` | not run. The Linux image has no `lazbuild`, and the step fails with `lazbuild is required`. This is a toolchain gap, not a result of the packages |
| `test:common` | 415 tests, no error, no failure |
| `test:client` | 1115 tests, no error, no failure |
| `test:server` | 1068 tests, no error, no failure. The time limit was 1200 s |
| `test:integration` | 21 tests, no error, no failure |

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
`a8da965` and again on `2759ee9`. Each scenario ran 3 times on each commit. All runs passed.
The table shows the results of `a8da965`; the runs of `2759ee9` passed with the same counts.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| H: inbound message of 256 MB on one stream to a handler that reads at once | exact octet count, close code 1000, 1.7 s to 2.2 s | 12 MB to 13 MB |
| I: inbound message of 64 MB to a handler that sleeps 5 ms after each chunk | exact octet count, close code 1000, about 97 s. The flow control of the stream slowed the sender, and the session stayed open | 11 MB to 12 MB |
| J: the peer stops in the middle of a message, inbound stall 2000 ms | the session closed with 1008, a second stream of 1 MB on the same connection arrived exact, 2.5 s | 10 MB to 12 MB |
| K: outbound producer message of 128 MB, the peer returns credit after 1 ms per DATA frame | all octets arrived, 134232068 octets with the WebSocket frame headers, close code 1000, 14 s to 17 s | 12 MB to 14 MB |
| L: outbound producer message, the peer returns no credit, outbound stall 2000 ms | the session closed with 1008, `RST_STREAM` with code 8 followed 20 ms after `Closed`, a second stream of 1 MB on the same connection arrived exact, 3.0 s | 10 MB to 13 MB |
| M: a message of 256 MB and a message of 64 MB on two streams of one connection | the small message finished as fast as the big message alone: 386 ms to 573 ms against 391 ms to 404 ms, inside the limit of three times plus 2 s | 6 MB to 10 MB |
| N: 50 parallel streams of 8 MB each, round robin | no failed reply, 8.9 s to 9.1 s | 6 MB to 13 MB |

## WebSocket over HTTP/2 runs of commit 3f0ba0a

These runs used the raw HTTP/2 test client against the server of the load program, on commit
`3f0ba0a` on 2026-11-19. Each scenario ran 3 times in one process (`loadh2ws all 3`, scale 1).
All 21 runs passed. The table shows the range of the 3 runs.

| Scenario | Result | Peak resident memory |
| --- | --- | --- |
| H: inbound message of 256 MB on one stream to a handler that reads at once | exact octet count 268435456, close code 1000, 1.3 s to 2.9 s | 12 MB to 13 MB |
| I: inbound message of 64 MB to a handler that sleeps 5 ms after each chunk | exact octet count 67108864, close code 1000, 96.8 s to 97.0 s | 13 MB to 14 MB |
| J: the peer stops in the middle of a message, inbound stall 2000 ms | the client saw close code 1008, the second stream of 1 MB arrived exact, 2.1 s | 13 MB to 14 MB |
| K: outbound producer message of 128 MB, the peer returns credit after 1 ms per DATA frame | all octets arrived, 134232064 to 134250496 octets with the WebSocket frame headers, close code 1000, 15.0 s to 17.0 s | 17 MB to 19 MB |
| L: outbound producer message, the peer returns no credit, outbound stall 2000 ms | the client read 65535 octets, `RST_STREAM` with code 8 at the time of `Closed` or 20 ms after it, the second stream of 1 MB arrived exact, 3.0 s. The log line reports close code 1006 for the session. The earlier runs of this scenario reported 1008 | 16 MB to 19 MB |
| M: a message of 256 MB and a message of 64 MB on two streams of one connection | the big message took 384 ms to 408 ms, the small message 402 ms to 412 ms, inside the limit of three times plus 2 s (3152 ms to 3224 ms) | 17 MB to 19 MB |
| N: 50 parallel streams of 8 MB each, round robin | no failed reply, 8.9 s to 9.0 s | 20 MB to 26 MB |

## Repeated WebSocket over HTTP/2 runs

Each scenario of the previous section ran 10 times in one process on commit `a8da965`. The host
load average was between 0.5 and 2.0. All 80 runs passed (scenario L reports two results per
run, and all 20 passed). The peak resident memory is the peak of one run.

| Scenario | Peak of the first run | Peak of the last run | Longest run |
| --- | --- | --- | --- |
| H | 12 MB | 16 MB | 2.7 s |
| I | 11 MB | 15 MB | 97.3 s |
| J | 10 MB | 16 MB | 2.5 s |
| K | 12 MB | 18 MB | 17.0 s |
| L | 10 MB | 19 MB | 3.0 s |
| M | 6 MB | 16 MB | 2.8 s |
| N | 6 MB | 27 MB | 9.0 s |

The peak of the last run is higher than the peak of the first run in every scenario, and no
peak is above 27 MB. The runs do not show whether the growth stops, because 10 runs are too few
to tell a slow leak from the retention of the allocator.

## Scenario Q: both directions on one connection

Scenario Q runs one HTTP/2 connection with two WebSocket streams at the same time: stream 1
carries an inbound message of 64 MB to a handler that reads at once, and stream 3 carries an
outbound producer message of 64 MB. The peer opens the windows to 32 MB first, and the test
client returns credit for the output of stream 3. The plain variant sends the fragments in one
loop. The burst variant sends 32 fragments and then waits 20 ms before it reads. A run passes
when both counts are exact and the client sees no reset, no GOAWAY and no closed socket.

| Run set | Bucket | Result |
| --- | --- | --- |
| 3 sets of 20 runs per variant, commit `a8da965` | default | plain variant 4 failures in 60 runs, burst variant 39 failures in 60 runs |
| 3 sets of 20 runs per variant, commit `a8da965` | window-update bucket widened | 120 runs, no failure |
| 40 sets of 20 plain runs, commit `2759ee9` | default | 720 passes and 80 failures, no run that did not end |
| 40 sets of 20 plain runs of a later Linux run on `main` (tree of commit `7b15754`, scratch program, not in the repository) | default | 742 passes and 58 failures, all 58 the server closing the connection |
| 5 sets of 20 plain runs, commit `3f0ba0a` | default | 92 passes and 8 failures. Set 1: 18 and 2. Set 2: 17 and 3. Set 3: 18 and 2. Set 4: 20 and 0. Set 5: 19 and 1 |

- With the default limits, the server closes the connection when the test client sends window
  updates faster than the window-update bucket allows (capacity 10000, refill 4000 per
  second). The server then reports that a token bucket tripped and resets both streams. The
  client sees a reset of the connection, about 0.3 s to 0.9 s after the start. The widened
  bucket removes these failures. The failures belong to the limit, which works as designed.
- Of the 80 failures on `2759ee9`, 72 are the reset of the connection and 8 are a wait of the
  client for the window of the server, which stayed closed. The output of the 8 was not kept,
  so they were not available for a check.
- The test client of the earlier run reported a connection that ended during a wait for a
  window as a closed window. The 8 cases can therefore be closes by the server.
- All 58 failures of the 800 runs of the later set were the server closing the connection,
  through the window-update bucket trip, which is the designed limit. None was a server that
  withheld credit, a stalled server or another cause. The failures were classified from the
  frames (GOAWAY, RST_STREAM and a closed socket). The explanation fits the 800 runs. It is not
  proved for the 8 cases.
- The scenario did not show the possible lock-order conflict that the finding below names.
  The result is "not observed under scenario Q". It does not show that the conflict cannot
  happen, because the scenario may not create the condition that the conflict needs: a write
  that blocks while the IO thread returns credit.
- The peak resident memory of the runs was at most 32 MB.

The 8 failures of commit `3f0ba0a` have these forms. Stream 1 had no count (count 0) in all 8
runs. The stream 3 data count of the failed runs was between 53457656 and 67125248 octets. Seven
runs ended in a send of the client that failed at 709 ms to 895 ms with `EPIPE` (2 runs) or
`ECONNRESET` (5 runs). The eighth ended with `EH2ConnectionEnded: the socket is closed` at
935 ms. In all 8 runs the connection ended. The output does not hold a GOAWAY frame or a server
counter, so this run does not show the cause of each failure. The explanation of the earlier
runs applies: the server closes the connection through the window-update bucket, which is the
designed limit. This run does not prove that for each of the 8 failures.

## Stop-path loops on commit 3f0ba0a

The runner of the server suite ran two suites 30 times each on commit `3f0ba0a`, with the
options `--suite=NAME --format=plain --sparse`. `TStreamPoolThreadTest` ran 5 tests in each run,
and `TWsEnvironmentStopTest` ran 1 test in each run. All 60 first runs passed, with no error and
no failure. No run needed a rerun.

## Findings open

**Handler pool: stream read after release.** A code review of `THandlerPool.TakeOne` found a
read of the stream identifier for the completion event after the handler released its
reference, so the stream may already be freed. The read happens only when an observer is set.
No run has shown it.

**Stream lock is not safe against an exception.** `LockStream` takes the stream lock outside a
`try` block after it took the connection lock. If the stream lock fails, the connection lock
stays held. A code review found this. No run has shown it.

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

- `version:check` on Linux for commit `3f0ba0a`.
- A run of more than 10 passes of each scenario, which could show whether the growth of the
  peak resident memory stops.
- A run with the host fully idle. The load average stayed between 0.2 and 2.4.
- `packages:check` on Linux. The Linux image has no `lazbuild`.
