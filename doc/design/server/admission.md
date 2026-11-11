---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, admission, queue, handler-pool, refusal, backpressure
notes:
  - This document describes the admission queue and the handler pool.
  - Imported from http2server/doc/design/server/admission.md at the source commit recorded in the source inventory.
scope: The bounded request queue, the handler pool, the refusal modes, the queue wait limit, the reset-before-dispatch rule, the counters and the shutdown.
primary_types:
  - TRequestQueue
  - THandlerPool
  - TServerStreamRequest
  - TServerStreamResponse
  - TQueueOptions
db_tables: []
related_docs:
  - doc/design/server/configuration.md
  - doc/design/server/threading.md
  - doc/design/server/limits.md
  - doc/design/server/seam.md
invariants:
  - The queue never holds more entries than its depth.
  - A stream that a peer cancels while it waits in the queue leaves the queue at once and its handler never runs.
  - The handler pool runs one synchronous handler per worker thread.
  - The queue is the only admission point of a request.
  - The HPACK codec runs only on an IO thread, so a response header block is queued, not encoded, on the handler side.
---

# Admission and the handler pool

A request that the IO side completes does not run on an IO thread. The IO side
offers the stream to a queue, and a handler thread takes the stream from the
queue. The unit `server/src/Http2.Server.Admission.pas` holds the queue and the pool.
The unit `server/src/Http2.Server.StreamAdapters.pas` holds the request and response
adapters (`TServerStreamRequest` at line 37 and `TServerStreamResponse` at line
59), which the pool builds for each dispatch.

An HTTP/1.1 request enters the same queue as a job. A job is an `IHandlerJob`
(`server/src/Http2.Server.HandlerJob.pas`): the pool runs it with `Run`, answers a refusal
with `Refuse` (queue full, wait limit passed, pool stopped) and cancels it at
`Stop` with `Cancel`. A job counts against the depth and the wait limit like a
stream, and the refusal is a 503 with `Retry-After: 1` followed by a close. The
document [http1](http1.md) describes the HTTP/1.1 side.

The tasks of a WebSocket session do not use this queue. They run on the streaming
pool (as described in [threading](threading.md)), so a burst of WebSocket traffic cannot delay or
refuse an ordinary request. A session bounds its own work with the cap of queued
messages and the credit rule (as described in [websocket](websocket.md)).

## The bounded queue

`TRequestQueue` (`server/src/Http2.Server.Admission.pas`) is a FIFO of entries. An
entry holds one `TServerStream` and the value of the monotonic clock at the
enqueue instant (`server/src/Http2.Server.Admission.pas`). The queue takes its depth
and its wait limit from `TQueueOptions` (`server/src/Http2.Server.Config.pas`).

`TryEnqueue` answers `asQueued` or `asRefused` (`server/src/Http2.Server.Admission.pas`).
A refused answer comes from two states: the queue no longer accepts work, or the
queue holds its full depth (`server/src/Http2.Server.Admission.pas`). The count test
is the whole bound, so the queue never holds more entries than its depth.

The queue guards its entry list with a `TCriticalSection` and an `RTLEvent`
(`server/src/Http2.Server.Admission.pas`). FPC 3.2.4 has no `TThreadedQueue` and no
`TMonitor`, and a `TEvent` fails on macOS. A consumer that finds an empty queue
parks on the event for a short bound (`server/src/Http2.Server.Admission.pas`), so
the wait limit and the stop path take effect quickly.

## Occupancy

The stream count does not bound handler occupancy. A peer can cancel a stream,
which frees the stream slot of the connection, while the handler of that stream
keeps running. A peer that repeats this cancel at a high rate holds as many
handlers as its frame rate allows, and the stream limit of the connection never
objects. This attack class is CVE-2023-44487, Rapid Reset.

The queue is the answer. Depth bounds the wait, and the handler thread count
bounds the work that runs at one time. A request beyond the free handlers and
the queue depth is refused, so the memory and the handler count stay bounded
under a flood.

`THandlerPool` (`server/src/Http2.Server.Admission.pas`) creates `N` worker threads,
where `N` is `THttp2ServerFactory.HandlerThreads`
(`server/src/Http2.Server.Config.pas`). Each worker takes one entry and calls
`IHttp2Handler.Handle` on it. A worker takes no second entry until the first
handler returns.

## The queue wait limit

Each entry records the clock value of its enqueue. At dequeue the queue compares
that value with the current clock value (`server/src/Http2.Server.Admission.pas`).
An entry that waited longer than `MaxWaitMs` is a timeout, not a dispatch. The
caller answers the request as a refusal, so a request that waited too long
never runs on a handler.

## The refusal modes

`TQueueRefusalMode` (`server/src/Http2.Server.Config.pas`) holds the two refusal
answers. `rmRefuseStream` resets the stream with `REFUSED_STREAM`.
`rmHttp503` holds an HTTP 503 response header block for the IO side
(`server/src/Http2.Server.Admission.pas`). One mode serves both the full-queue
refusal and the timed-out refusal.

The handler side never encodes a header block. The HPACK encoder is connection
state and runs on an IO thread only, so a 503 refusal becomes a stream response-header operation. The IO side
encodes the block later. This rule follows the seam note in
[seam](seam.md).

## Reset before dispatch

A peer can reset a queued stream before a handler takes it. The IO side calls
`THandlerPool.RemoveStream` with the stream id. The queue removes the matching
entry at once (`server/src/Http2.Server.Admission.pas`), and the dropped total
increases. A worker that takes an entry whose stream is already cancelled
discards the entry without a handler call. In both paths the handler of the
cancelled stream never runs.

## The handler error hook

A handler that raises `EStreamCancelled` ends quietly. The cancellation is the
expected end of a stream that the peer or the connection stopped. Any other
exception reaches `OnHandlerError` (`server/src/Http2.Server.Admission.pas`). The
hook receives the stream and a flag. The flag is `True` when the handler had
not sent the response headers, and `False` after a header send. The core later
answers with a 500 before the headers and with `RST_STREAM` after them. The
pool records the error and does not build the 500 or the reset itself.

## Counters and shutdown

`THandlerPool` exposes five read-only counters: the busy handlers, the queue
length, the refused total, the timed-out total and the dropped-before-dispatch
total (`server/src/Http2.Server.Admission.pas`). A test reads them to check the
bound under load.

`THandlerPool.Stop` runs in four steps. The pool stops acceptance, so a later
`Admit` refuses at once. The queue drains and every waiting entry is refused per
the refusal mode. The pool waits for the running handlers up to
`GracefulStopTimeoutMs`. A handler that still runs after that wait is cancelled
on its stream or its job, which raises `EStreamCancelled` in the handler thread.
The pool then waits for the worker threads one more time, with the same bound.
A worker that still runs after this wait ignores the cancellation. The pool
counts it in `StuckThreads`, lets it end alone and keeps the state that it may
read, so the stop never waits for a handler without end.

The server calls `Stop` with a short bound after its own drain wait. The drain
wait used the graceful time already, so the first wait of the pool is skipped and
the whole stop keeps one deadline.

**The observer rule.** The server catches every exception of
`IHttp2ServerObserver.OnEvent` and drops it. An observer that raises does not end
a handler thread or an IO thread, so the pools keep their size.
