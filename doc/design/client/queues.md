---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
title: "Queues and their thread roles"
aliases:
  - "queues"
tags:
  - http2client
  - http2server
  - design
  - concurrency
status: done
up: "[http2components](../../README.md)"
related:
  - "[transport](transport.md)"
  - "[architecture](architecture.md)"
  - "[fpc-runtime](fpc-runtime.md)"
keywords: queue, spsc, mpsc, mpmc, thread
scope: every queue in client/src, server/src and common/src
updated: 2026-11-19
notes:
  - The audit was made by reading the call sites. The references name the methods and the fields that hold the call sites, not line numbers, because line numbers change with each edit.
  - A queue is classified SPSC only when the call sites prove one producer thread. The consumer side is one thread at a time, either enforced by the queue or proven by the call sites.
---

# Queues and their thread roles

This document lists every queue of the library. For each queue it names the
threads that put items in, the threads that take items out, the lock that
protects it, its limit, and a verdict on its thread roles. The verdict tells
which queues can have exactly one producer and exactly one consumer (SPSC) and
which queues have more.

The `common/src` directory holds one ring class, `TSpscRing<T>`
(`common/src/Http2.Common.SpscRing.pas`). The client receive queue of a stream
stores its frames in that ring. The directory holds no other queue class. A
search there for `TBlockingQueue`, `TQueue<`, `TThreadedQueue` and similar names
finds nothing. The check was made on 2026-11-19.

## Terms

- **Reader thread.** The one thread of a client connection (`TConnectionThread`,
  worker `TConnectionWorker`). It reads frames from the socket, writes frames to
  the socket and routes received frames to the streams. It runs
  `TConnectionWorker.Run` (`client/src/Http2.Client.Connection.Thread.pas`).
  The same thread is the writer.
- **Stream thread.** A thread of the caller that sends a request and reads the
  response. `THttpClient.Send` is thread-safe, so many stream threads can use
  one connection at the same time.
- **IO thread.** A thread of the server event loop. It parses frames and calls
  the connection events.
- **Handler thread.** A thread of the server handler pool (`THandlerThread`).
- **Stream-pool thread.** A thread of `TStreamPool` (`TStreamPoolThread`).
- **SPSC, MPSC, SPMC, MPMC.** One or many producers, one or many consumers. A
  producer calls `Push` (or `TryPost`, `Enqueue`, `Post`). A consumer calls
  `Pop`, `TryPop`, `WaitForItem`, `Dequeue` or `NextTask`.
- **Shutdown role.** A call of `Shutdown` or `Stop` is listed apart. It is not a
  producer call or a consumer call, but it can come from a third thread.

## Summary

| Queue | Class | Verdict |
| --- | --- | --- |
| Per-stream receive queue (client) | `TByteBoundedFrameQueue` | SPSC. The ring checks the thread roles at run time. The body read checks that one reader is active at a time. |
| Outbound queue of a connection (client) | `TBlockingQueue<TFrame>` | MPSC |
| Control queue of a connection (client) | `TControlFrameQueue` | MPSC |
| Inbound queue of a connection (client) | `TBlockingQueue<TFrame>` | No producer and no consumer in the library code |
| SSE event buffer (client) | `TQueue<TSseEvent>` in `TSseSource` | Not a queue between threads |
| Admission queue (server) | `TRequestQueue` | MPMC |
| Stream-pool ready queue (server) | `TQueue<IInterface>` in `TStreamPoolCore` | MPMC |
| Stream-pool task queue of a source (server) | `TQueue<TStreamTask>` in `TStreamSource` | MPMC, under the pool lock |
| Cancel-hook queue (server) | `TCancelWorkerPool` | MPMC |
| Output buffer of a server connection | `FOutput` of `TConnectionCoreBase` | Not a queue class. A byte buffer under the connection lock. |

## The queue class of the client

Most client queues that block are built on one class:
`TBlockingQueueState<T>` in `client/src/Http2.Client.Connection.Queue.pas`.
It holds a `TQueue<T>`, one `TCriticalSection` and two `PRTLEvent` (not empty,
not full). It has no restriction on the number of producers or consumers: every
method takes the one lock. The interface `IBlockingQueue<T>` and its class
`TBlockingQueue<T>` (`client/src/Http2.Client.Connection.pas`) wrap
the state class and forward each call. The receive queue of a stream is the
exception. Its ring is described in its own section.

`Pop` and `Push` use a chain wake. A thread that leaves after a `Shutdown` sets
the same event again, so the full set of blocked threads is released. This
chain is needed because an `RTLEvent` wakes one thread at a time. The chain
exists for the case of many waiters. It is not needed when each side has one
thread.

## Client queues

### Per-stream receive queue

| Item | Value |
| --- | --- |
| Class | `TByteBoundedFrameQueue` (`client/src/Http2.Client.Stream.Receive.pas`). It wraps a `TSpscRing<TFrame>` (`common/src/Http2.Common.SpscRing.pas`), a lock-free single-producer single-consumer ring of frames, and the byte count `FQueuedBytes`. The ring takes no lock. On a 32-bit CPU a leaf lock `FCounterLock` guards the byte count. |
| Created by | `TStreamLease.Create` (the overload that takes the encoder and the decoder, `client/src/Http2.Client.Stream.pas`), on the stream thread. |
| Freed by | `TStreamLease.Destroy` (`client/src/Http2.Client.Stream.pas`). The thread that drops the last interface reference runs it. |
| Producers (`Push`) | The reader thread only. |
| Consumers (`TryPop`, `WaitForItem`) | The thread that reads the response of the stream. |
| `IsShutdown` | The consumer. |
| `Shutdown` | The reader thread, the thread of `Start`, and the consumer. See below. |
| Lock outside the queue | None. The producer side has no second producer. The consumer side is one thread at a time, checked by the body read (see below). |
| Limit | The byte cap `MaxReceiveQueueBytes` on DATA and the frame cap `cReceiveQueueFrameCap` (1024, the ring capacity). A `Push` over either cap raises `EHttpStreamError` with a flow-control error and does not block. |
| Verdict | One producer thread. One consumer thread at a time, enforced for the ring and for the body read. |

Evidence for the one producer thread. Every path that reaches `Push` starts
on the reader thread:

- `TConnectionWorker.Run` reads a frame and calls `RouteInbound`
  (`client/src/Http2.Client.Connection.Thread.pas`).
- `RouteInbound` calls `TConnection.DispatchStreamFrame`
  (`client/src/Http2.Client.Connection.Thread.pas`).
- `DispatchStreamFrame` calls `S.OnStreamFrame`
  (`client/src/Http2.Client.Connection.pas`).
- `TStreamLease.OnStreamFrame` calls `LeasePushInbound`
  (`client/src/Http2.Client.Stream.Inbound.pas`), which calls `Push` on the
  queue `FInbound`.
- The `Push` of the queue `FInbound` has no other call site in `client/src`.
  Search result for `.Push(` on a `TByteBoundedFrameQueue` in the units of the
  stream and the connection: one hit, `AInbound.Push` in `LeasePushInbound`
  (`client/src/Http2.Client.Stream.Inbound.pas`).
- `DispatchStreamFrame` and `OnStreamFrame` have no other caller in
  `client/src`.

Evidence for the consumer calls. All calls are in `TStreamLease`:
`FInbound.WaitForItem` in `WaitForInbound` (`client/src/Http2.Client.Stream.pas`),
and `FInbound.TryPop` and `FInbound.IsShutdown` in `PopInbound` and
`WaitForBodyFrame`. The callers are `WaitForResponseHeader` (through
`PopInbound`, called by the stream thread inside
`THttpConnection.AcquireCancellable`, `client/src/Http2.Client.Pool.Http2.pas`)
and the body read (through `WaitForBodyFrame` in `ReadBody`, called by whatever
thread reads the body of the response).

Evidence for the `Shutdown` calls:

- `TStreamLease.OnConnectionFailed` (`client/src/Http2.Client.Stream.pas`).
  It is called by the reader thread through `TConnection.FailWith`
  (`client/src/Http2.Client.Connection.pas`). It is called by the thread of
  `TStreamLease.Start` through `TConnection.RegisterStream` when the connection
  is already closed (`client/src/Http2.Client.Connection.pas`). This is the
  consumer thread of the first phase of the stream.
- `TStreamLease.OnConnectionGoAway` (`client/src/Http2.Client.Stream.pas`).
  The reader thread calls it (`client/src/Http2.Client.Connection.pas`, method
  `TConnection.MarkGoAway`).
- `TConnection.Close` and `TConnection.FailWith` shut down the connection
  queues. They do not call `Shutdown` on a stream queue. They reach the stream
  queues only through `OnConnectionFailed`.

Evidence for the thread that frees the queue. `TStreamLease` is held through
the interface `IConnectionStream`. `DispatchStreamFrame` holds a local
reference `S` while `OnStreamFrame` runs
(`client/src/Http2.Client.Connection.pas`), and the stream table
`FStreams` holds a reference. The object is destroyed only after the last
reference leaves. Interface reference counting uses atomic increments and
decrements, so no producer call and no consumer call is in progress when
`Destroy` runs. The freeing thread can be the reader thread or any thread of
the caller.

Consumer side. The response object leaves the thread that called `Send`. The
caller can read the body on another thread. The code does not tie the reading
to the thread that called `Send`. Two readers of one response are kept apart by
the body read (see the last paragraphs of this section). The ring has two checks,
and neither is a lock:

- `TSpscRing<T>` (`common/src/Http2.Common.SpscRing.pas`) keeps one busy flag
  for each side. `EnterProducer` and `EnterConsumer` set the flag with
  `InterlockedExchange`. A call that finds the flag already set raises
  `EInvalidOperation` before it reads or writes an index. An overlap therefore
  fails with an exception. It does not corrupt the ring, and the second call
  does not wait for the first.
- The consumer role can pass from one thread to another. `TryPop`, `Pop` and
  `WaitForItem` set the consumer flag on entry, and `LeaveConsumer` clears it
  with `InterlockedExchange`. Both exchanges are full barriers. The head index
  that one consumer writes is visible to the next consumer that sets the flag.
  The ring needs no barrier of its own for the hand-over.

A waiting consumer holds the consumer flag for the whole wait. A `TryPop` from a
second thread during that wait raises `EInvalidOperation`.

The lease above the ring has its own check. `TStreamLease.ReadBody`
(`client/src/Http2.Client.Stream.pas`) changes the lease fields `FBodyPending`,
`FBodyPendingOfs` and the stamp fields, which the ring does not cover. The flag
`FBodyReading` is set with `InterlockedExchange` on entry. A call that finds the
flag set raises `EInvalidOperation` before it reads or writes a field, so a second
reader fails and does not wait. The owner clears the flag in a `finally` block. The
second reader therefore cannot take the frames that the first reader waits for. The
verdict for the consumer side is "one thread at a time, enforced by the lease and by
the ring".

The response object of the pool (`THttpResponse`, `client/src/Http2.Client.Response.pas`)
wraps the body in `TGuardedBody`. That wrapper holds the connection lock during each
read. A second reader that uses `IHttpResponse.Body` therefore waits for the first
one and does not reach the lease check. The lease check covers the direct callers of
the lease.

Other facts that matter for the roles:

- The byte count `FQueuedBytes` (`client/src/Http2.Client.Stream.Receive.pas`)
  is updated with atomic operations on a 64-bit CPU. `TryReserve` is a
  compare-and-exchange loop that checks the cap and adds the bytes in one step.
  `ReleaseBytes` is an atomic add. The producer reserves the bytes before the
  frame enters the ring. The consumer releases them after the frame leaves the
  ring. The count therefore never reads less than the bytes in the ring. On a
  32-bit CPU the leaf lock `FCounterLock` makes the same steps. It guards the
  count only, never the ring.
- On a 64-bit CPU, `Push`, `TryPop`, `WaitForItem`, `IsShutdown` and `Shutdown`
  take no lock of the queue. On a 32-bit CPU `Push` and `TryPop` take
  `FCounterLock` for the count. `WaitForItem`, `IsShutdown` and `Shutdown` take
  no lock on any CPU. `WaitForItem` waits on an event of the ring in slices of
  at most `cSpscMaxWaitSliceMs` (100 ms) and checks the ring again after each
  slice.
- `TStreamLease.WaitForInbound` releases the connection lock `FWaitLock`
  during the wait and takes it again after it
  (`client/src/Http2.Client.Stream.pas`). The connection lock is not a lock
  of the queue.

### Outbound queue of a connection

| Item | Value |
| --- | --- |
| Class | `TBlockingQueue<TFrame>` through `IBlockingQueue<TFrame>` (`client/src/Http2.Client.Connection.pas`, field `FOutbound` of `TConnection`). |
| Created by | `TConnection.Create` (the overload that takes the local settings, `client/src/Http2.Client.Connection.pas`), capacity `cDefaultQueueCapacity` (128). |
| Freed by | The interface reference. The connection, every stream lease and the worker hold it. |
| Producers (`Push`) | Many stream threads: `EmitHeaderBlock` and `EmitData` in `client/src/Http2.Client.Stream.Send.pas`. `TConnection.Close` pushes the GOAWAY frame when it runs on a thread other than the reader, and only when it is the first close, the connection has a reader thread and the state is `csOpening` or `csOpen` (`client/src/Http2.Client.Connection.pas`). |
| Consumers (`TryPop`) | The reader thread, in `TConnectionWorker.DrainOutbound` (`client/src/Http2.Client.Connection.Thread.pas`). It is the only consumer call in `client/src`. |
| `Shutdown` | `TConnection.Close` (`client/src/Http2.Client.Connection.pas`) from the closing thread, and `TConnection.FailWith` from the reader thread. |
| Lock outside the queue | Most pushes run while the stream thread holds the connection lock, which is also the HPACK encoder lock of the pooled connection (`Lease.WaitLock := FLock` in `THttpConnection.AcquireCancellable`, `client/src/Http2.Client.Pool.Http2.pas`). The data push in `EmitData` (`client/src/Http2.Client.Stream.Send.pas`) follows `AcquireCredit`, which releases that lock for a wait and takes it again. The GOAWAY push in `TConnection.Close` runs under no lock of this kind. |
| Limit | 128 frames. A full queue blocks the producer in `Push`. |
| Verdict | MPSC |

The consumer is one thread, the reader thread. The producers are many, and a
lock outside the queue serializes only some of their calls. A `Close` from a
thread other than the reader is a producer that does not hold that lock. The
verdict is MPSC.

### Control queue of a connection

| Item | Value |
| --- | --- |
| Class | `TControlFrameQueue` (`client/src/Http2.Client.Connection.Control.pas`). Its own `FLock` and a `TQueue<TFrame>`. |
| Created by | `TConnection.Create` (the overload that takes the local settings, `client/src/Http2.Client.Connection.pas`). |
| Freed by | `TConnection.Destroy` (`client/src/Http2.Client.Connection.pas`), after `Close` has joined the reader thread. |
| Producers (`TryPost`) | All callers of `TConnection.PostFrame` (`client/src/Http2.Client.Connection.pas`): the reader thread (SETTINGS acknowledgement and PING acknowledgement in `TConnectionWorker.RouteInbound`, `client/src/Http2.Client.Connection.Thread.pas`; connection WINDOW_UPDATE through `TrackReceivedData`, `client/src/Http2.Client.Connection.pas`; RST_STREAM with FLOW_CONTROL_ERROR in `LeasePushInbound`, `client/src/Http2.Client.Stream.Inbound.pas`, when the receive queue of a stream refuses a frame). The reader thread also pushes the GOAWAY frame of `TConnection.Close` (`client/src/Http2.Client.Connection.pas`) with a direct `TryPost`, when `Close` runs on the reader thread and under the same conditions as the outbound queue. The stream threads (stream WINDOW_UPDATE in `DataConsumed` and `SendWindowUpdate`, `client/src/Http2.Client.Connection.pas`; RST_STREAM in `TStreamLease.ReadBody`, `client/src/Http2.Client.Stream.pas`; RST_STREAM in `EmitData`, `client/src/Http2.Client.Stream.Send.pas`; RST_STREAM in `THttpConnection.AcquireCancellable` and `THttpConnection.AcquireUpgraded`, `client/src/Http2.Client.Pool.Http2.pas`; RST_STREAM in `TLeaseTunnel.ResetLocked` and `TLeaseTunnel.StopAndRelease`, `client/src/Http2.Client.WebSocket.LeaseTunnel.pas`, once per tunnel and only when the stream is open on the wire and no parked send posted it). |
| Consumers (`TryPop`) | The reader thread, in `DrainOutbound` (`client/src/Http2.Client.Connection.Thread.pas`). |
| `Overflowed` | The reader thread (`TConnectionWorker.Run`, `client/src/Http2.Client.Connection.Thread.pas`). |
| `Count` | No call in `client/src`. |
| `Shutdown` | The class has no `Shutdown`. |
| Lock outside the queue | None. The calls come from the reader thread and from threads that hold no common lock. |
| Limit | `cControlQueueLimit` (1000 frames). `TryPost` never blocks. It returns False and sets a sticky flag when the queue is full. |
| Verdict | MPSC |

The stream threads call `DataConsumed` and `SendWindowUpdate` after the stream
lease has released its lock. These calls and the calls of the reader thread
come from more than one thread at one time. The verdict is MPSC.

### Inbound queue of a connection

| Item | Value |
| --- | --- |
| Class | `TBlockingQueue<TFrame>` (`client/src/Http2.Client.Connection.pas`, field `FInbound` of `TConnection`). |
| Created by | `TConnection.Create` (the overload that takes the local settings, `client/src/Http2.Client.Connection.pas`). Capacity 0. |
| Producers | None in `client/src` or in `server/src`. |
| Consumers | None in `client/src`. The test unit `test/client/Http2.Client.ConnectionThread.Test.pas` calls `Pop` on it in `TInboundWaiter.Execute` and in `TConnectionThreadTest.TestErrorPropagationUnblocksWaiters`. |
| `Shutdown` | `TConnection.Close` and `TConnection.FailWith` (`client/src/Http2.Client.Connection.pas`). |
| Verdict | No producer and no consumer in the library code. Its thread roles are not used. |

The comment at the creation line says that only the reader fills the queue.
The reader routes frames to the stream queues, and no code puts a frame in this
queue. The property `Inbound` (`client/src/Http2.Client.Connection.pas`) is
read only by a test.

### SSE event buffer

`TSseSource.FQueue` (`client/src/Http2.Client.Sse.pas`) is a `TQueue` with
no lock. `Fill` enqueues and `Dequeue` takes out. Both run in
`ReadEvent` on the one thread that reads the events. The source is not a queue
between threads. It has no thread-safety claim. It is not a candidate for a
queue with thread roles.

### Other client containers

`TSendCreditWaiterRegistry` (`client/src/Http2.Client.Connection.SendCredit.pas`)
holds a `TList` of waiters under a lock. It is a set of waiters, not a queue of
items. The WebSocket client of `client/src` has no queue class of its own.

## Server queues

### Admission queue

| Item | Value |
| --- | --- |
| Class | `TRequestQueue` (`server/src/Http2.Server.Admission.pas`). Its own `FLock`, an `FWake` event and a `TQueue<TQueueEntry>`. |
| Created by | `THandlerPool.Create` (`server/src/Http2.Server.Admission.pas`). `THttp2AsyncServer.Create` creates the pool (`server/src/Http2.Server.Async.pas`). One queue serves all connections. |
| Producers | IO threads. HTTP/2: `THttp2ConnectionEvents.RequestReady` calls `Admit` (`server/src/Http2.Server.Async.Events.pas`). HTTP/1: `THttp1ConnectionEvents.Admit` calls `AdmitJob` (`server/src/Http2.Server.Async.Events.pas`). |
| Consumers | The handler threads: `THandlerThread.Execute` calls `TakeOne` (`server/src/Http2.Server.Admission.pas`), which calls `DequeueEntry`. |
| `RemoveStream` | An IO thread, on a reset stream (`THttp2ConnectionEvents.StreamReset`, `server/src/Http2.Server.Async.Events.pas`). It takes entries out, so it is a second kind of consumer. |
| `DrainEntries`, `Stop` | The thread that stops the pool (`THandlerPool.Stop`, `server/src/Http2.Server.Admission.pas`). |
| `Count` | The thread that asks for statistics (`THandlerPool.QueueLength`, `server/src/Http2.Server.Admission.pas`). |
| Lock outside the queue | None. Each call takes `FLock`. |
| Limit | `Depth` entries (`TQueueOptions`). A full queue refuses the entry. The wait of an entry is limited by `MaxWaitMs`. |
| Verdict | MPMC |

### Stream-pool queues

| Item | Value |
| --- | --- |
| Classes | `TQueue<IInterface>` `FReady` in `TStreamPoolCore` (`server/src/Http2.Server.StreamPool.pas`) and one `TQueue<TStreamTask>` `FTasks` in each `TStreamSource` (`server/src/Http2.Server.StreamPool.pas`). |
| Created by | `TStreamPoolCore.Create` (`server/src/Http2.Server.StreamPool.pas`) for `FReady`. `TStreamSource.Create` for `FTasks`. `THttp2AsyncServer.Create` creates the pool (`server/src/Http2.Server.Async.pas`). `TStreamPool.NewSource` makes each source. |
| Producers | Any thread that owns an `IStreamSource` and calls `Post` or `PostAfter`: for example the server-sent-events tick (`TSseStream.Arm`, `server/src/Http2.Server.Sse.pas`) and the WebSocket session (`TWsSession.Post`, `server/src/Http2.Server.WebSocket.Session.pas`; `TWsSessionCore.Arm`, `TWsSessionCore.PumpSchedule` and `TWsSessionCore.PumpScheduleAfter`, `server/src/Http2.Server.WebSocket.SessionCore.pas`). The timer entries move into the queues on a stream-pool thread (`FireDueTimersLocked`). `FinishTask` puts a source back in `FReady` from a stream-pool thread. |
| Consumers | The stream-pool threads, in `RunStep` and `NextTask` (`server/src/Http2.Server.StreamPool.pas`). `TStreamPool.RunOne` runs a ready task on the calling thread (a test seam). |
| `Stop`, `CloseSource` | The thread that stops the server. The owner of a source. |
| Lock outside the queue | `FLock` of the pool core protects both queue kinds. It is the pool lock, not a lock of one queue. |
| Limit | None. |
| Verdict | MPMC, serialized by one pool lock. |

A source runs one task at a time (`FQueued`), so the tasks of one source run in
order. The thread that runs them can change from task to task.

### Cancel-hook queue

| Item | Value |
| --- | --- |
| Class | `TCancelWorkerPool` (`server/src/Http2.Server.Waiter.pas`). Its own `FLock`, an `FWake` event and a `TQueue<TCancelHook>`. |
| Created by | `server/src` has no call that creates it. The unit test `test/server/Http2.Server.Seam.Test.pas` creates it in `TBlockingWaiterTest.SetUp`. `TBlockingWaiter.AttachCancelPool` has no caller in `server/src`. A waiter made in `TServerStream.Create` (`server/src/Http2.Server.Stream.pas`) has no pool, so `Cancel` queues no hook. |
| Producers | `TBlockingWaiter.Cancel` calls `QueueHook` (`server/src/Http2.Server.Waiter.pas`). `Cancel` is called from any thread that cancels a stream: IO threads, handler threads, the stopping thread. |
| Consumers | The cancel workers (`TCancelWorker.Execute` calls `TakeHook`, `server/src/Http2.Server.Waiter.pas`). The pool has one worker or more. |
| Lock outside the queue | None. |
| Limit | None. |
| Verdict | MPMC, when a pool exists. In the production code of this version no pool exists. |

### Output buffer of a server connection

`TConnectionCoreBase.FOutput` (`server/src/Http2.Server.Connection.Core.pas`)
is a byte array, not a queue class. `QueueBytes` appends. The take
function, `TakeOutput`, copies and clears it. Callers take the connection
lock first (`LockConn`). The threads are the handler threads and the IO thread.
The lock is the connection lock, so the buffer has many producers and one
consumer, and the lock decides the order. It is outside the scope of the
queue classes and is listed to complete the list.

## What the verdicts allow

- A queue without a lock is safe only where the thread roles hold, or where the
  queue checks them. In the client, only the per-stream receive queue has one
  producer thread (the reader thread). Its ring checks the roles: a second
  producer, or a second consumer that overlaps the first, raises
  `EInvalidOperation`. The exchanges of the ring order a hand-over of the
  consumer role between threads. The lease above the ring checks its readers
  with the flag `FBodyReading`, as described in the section on this queue.
- The outbound queue and the control queue of a connection have many
  producers. They stay queues with a lock.
- The admission queue, the stream-pool queues and the cancel-hook queue have
  many producers and many consumers. They stay queues with a lock.
- The inbound queue of a connection has no use in the library code.
