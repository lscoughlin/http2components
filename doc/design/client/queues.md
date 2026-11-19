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
updated: 2026-11-13
notes:
  - The audit was made by reading the call sites. The references name the methods and the fields that hold the call sites, not line numbers, because line numbers change with each edit.
  - A queue is classified SPSC only when the call sites prove one producer thread and one consumer thread for the whole life of the queue.
---

# Queues and their thread roles

This document lists every queue of the library. For each queue it names the
threads that put items in, the threads that take items out, the lock that
protects it, its limit, and a verdict on its thread roles. The verdict tells
which queues can have exactly one producer and exactly one consumer (SPSC) and
which queues have more.

The `common/src` directory holds no queue. A search there for
`TBlockingQueue`, `TQueue<`, `TThreadedQueue` and similar names finds nothing.
The check was made on 2026-11-13.

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
| Per-stream receive queue (client) | `TByteBoundedFrameQueue` | SPSC for the producer side. The consumer side is one thread at a time, but one thread for the whole life is not proven. See the section on this queue. |
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

All client queues that block are built on one class:
`TBlockingQueueState<T>` in `client/src/Http2.Client.Connection.Queue.pas`.
It holds a `TQueue<T>`, one `TCriticalSection` and two `PRTLEvent` (not empty,
not full). It has no restriction on the number of producers or consumers: every
method takes the one lock. The interface `IBlockingQueue<T>` and its class
`TBlockingQueue<T>` (`client/src/Http2.Client.Connection.pas`) wrap
the state class and forward each call.

`Pop` and `Push` use a chain wake. A thread that leaves after a `Shutdown` sets
the same event again, so the full set of blocked threads is released. This
chain is needed because an `RTLEvent` wakes one thread at a time. The chain
exists for the case of many waiters. It is not needed when each side has one
thread.

## Client queues

### Per-stream receive queue

| Item | Value |
| --- | --- |
| Class | `TByteBoundedFrameQueue` (`client/src/Http2.Client.Stream.Receive.pas`). It wraps a lock-free single-producer single-consumer ring of frames and an atomic byte counter. On a 32-bit CPU a leaf lock guards the counter. |
| Created by | `TStreamLease.Create` (the overload that takes the encoder and the decoder, `client/src/Http2.Client.Stream.pas`), on the stream thread. |
| Freed by | `TStreamLease.Destroy` (`client/src/Http2.Client.Stream.pas`). The thread that drops the last interface reference runs it. |
| Producers (`Push`) | The reader thread only. |
| Consumers (`TryPop`, `WaitForItem`) | The thread that reads the response of the stream. |
| `IsShutdown` | The consumer. |
| `Shutdown` | The reader thread, the thread of `Start`, and the consumer. See below. |
| Lock outside the queue | None for the pop side. The producer side has no second producer. |
| Limit | The byte cap `MaxReceiveQueueBytes` on DATA and the frame cap `cReceiveQueueFrameCap` (1024, the ring capacity). A `Push` over either cap raises `EHttpStreamError` with a flow-control error and does not block. |
| Verdict | One producer thread. One consumer thread at a time. |

Evidence for the one producer thread. Every path that reaches `Push` starts
on the reader thread:

- `TConnectionWorker.Run` reads a frame and calls `RouteInbound`
  (`client/src/Http2.Client.Connection.Thread.pas`).
- `RouteInbound` calls `TConnection.DispatchStreamFrame`
  (`client/src/Http2.Client.Connection.Thread.pas`).
- `DispatchStreamFrame` calls `S.OnStreamFrame`
  (`client/src/Http2.Client.Connection.pas`).
- `TStreamLease.OnStreamFrame` calls `LeasePushInbound`
  (`client/src/Http2.Client.Stream.Inbound.pas`), which calls `FInbound.Push`.
- `FInbound.Push` has no other call site in `client/src`. Search result for
  `FInbound.Push` and `.Push(` in the units of the stream and the connection:
  one hit, in `LeasePushInbound` (`client/src/Http2.Client.Stream.Inbound.pas`).
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

Open point on the consumer. The response object leaves the thread that called
`Send`. The caller can read the body on another thread. The code does not tie
the reading to the thread that called `Send`. The code also does not stop two
threads from reading the same response at the same time. The queue itself is
protected today: `TByteBoundedFrameQueue.Push` and `.TryPop` take `FLock`, and
the state class takes its own lock. A queue without a lock needs one consumer
at a time, and it needs a memory barrier at every hand-over of the response
between threads. This is not proven by the call sites. The verdict for the
consumer side is therefore "one thread at a time by the use contract, not
proven for the whole life". A queue that has one consumer thread for the whole
life holds only if the use contract is a rule that the library checks.

Other facts that matter for the roles:

- `FLock` of `TByteBoundedFrameQueue` serializes `Push` with `TryPop` for the
  byte count `FQueuedBytes`. A queue without a lock needs an atomic 64-bit
  counter instead.
- `WaitForItem` and `IsShutdown` do not take `FLock`. They go to the state
  class directly (`client/src/Http2.Client.Stream.Receive.pas`, methods
  `TByteBoundedFrameQueue.WaitForItem` and `TByteBoundedFrameQueue.IsShutdown`).
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
| Producers (`Push`) | Many stream threads: `EmitHeaderBlock` and `EmitData` in `client/src/Http2.Client.Stream.Send.pas`. `TConnection.Close` pushes the GOAWAY frame from the thread that closes the connection (`client/src/Http2.Client.Connection.pas`). |
| Consumers (`TryPop`) | The reader thread, in `TConnectionWorker.DrainOutbound` (`client/src/Http2.Client.Connection.Thread.pas`). It is the only consumer call in `client/src`. |
| `Shutdown` | `TConnection.Close` (`client/src/Http2.Client.Connection.pas`) from the closing thread, and `TConnection.FailWith` from the reader thread. |
| Lock outside the queue | Most pushes run while the stream thread holds the connection lock, which is also the HPACK encoder lock of the pooled connection (`Lease.WaitLock := FLock` in `THttpConnection.AcquireCancellable`, `client/src/Http2.Client.Pool.Http2.pas`). The data push in `EmitData` (`client/src/Http2.Client.Stream.Send.pas`) follows `AcquireCredit`, which releases that lock for a wait and takes it again. The GOAWAY push in `TConnection.Close` runs under no lock of this kind. |
| Limit | 128 frames. A full queue blocks the producer in `Push`. |
| Verdict | MPSC |

The consumer is one thread, the reader thread. The producers are many, and a
lock outside the queue serializes only some of their calls. The close path is
a producer that does not hold that lock. The verdict is MPSC.

### Control queue of a connection

| Item | Value |
| --- | --- |
| Class | `TControlFrameQueue` (`client/src/Http2.Client.Connection.Control.pas`). Its own `FLock` and a `TQueue<TFrame>`. |
| Created by | `TConnection.Create` (the overload that takes the local settings, `client/src/Http2.Client.Connection.pas`). |
| Freed by | `TConnection.Destroy` (`client/src/Http2.Client.Connection.pas`), after `Close` has joined the reader thread. |
| Producers (`TryPost`) | All callers of `TConnection.PostFrame` (`client/src/Http2.Client.Connection.pas`): the reader thread (SETTINGS acknowledgement and PING acknowledgement in `TConnectionWorker.RouteInbound`, `client/src/Http2.Client.Connection.Thread.pas`; connection WINDOW_UPDATE through `TrackReceivedData`, `client/src/Http2.Client.Connection.pas`), and the stream threads (stream WINDOW_UPDATE in `DataConsumed` and `SendWindowUpdate`, `client/src/Http2.Client.Connection.pas`; RST_STREAM in `TStreamLease.ReadBody`, `client/src/Http2.Client.Stream.pas`; RST_STREAM in `EmitData`, `client/src/Http2.Client.Stream.Send.pas`; RST_STREAM in `THttpConnection.AcquireCancellable` and `THttpConnection.AcquireUpgraded`, `client/src/Http2.Client.Pool.Http2.pas`). |
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

- A queue without a lock between producer and consumer is safe only where one
  thread produces and one thread consumes. In the client, only the per-stream
  receive queue has one producer thread (the reader thread). Its consumer
  side is one thread at a time by the use contract. A hand-over of the response
  from one thread to another needs a memory barrier that the library does not
  state today.
- The outbound queue and the control queue of a connection have many
  producers. They stay queues with a lock.
- The admission queue, the stream-pool queues and the cancel-hook queue have
  many producers and many consumers. They stay queues with a lock.
- The inbound queue of a connection has no use in the library code.
