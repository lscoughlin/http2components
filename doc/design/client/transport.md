---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
title: "Transport, Threads & Connection Lifecycle"
aliases:
  - "transport"
tags:
  - http2client
  - design
  - concurrency
status: done
up: "[http2components](../../README.md)"
related:
  - "[protocol](protocol.md)"
  - "[architecture](architecture.md)"
  - "[fpc-runtime](fpc-runtime.md)"
  - "[fallback](fallback.md)"
  - "[proxy](proxy.md)"
  - "[open-questions](open-questions.md)"
updated: 2026-11-13
notes:
  - Imported from http2client/doc/design/transport.md at the source commit recorded in the source inventory.
---

# Transport, Threads & Connection Lifecycle

## Threading and queues

Free Pascal 3.2.4 primitives (all choices below are probe-verified; see
[fpc-runtime](fpc-runtime.md)):

- `TThread` (unit `Classes`) — one subclass per connection,
  `TConnectionThread`.
- **`TBlockingQueue<T>` — the outbound and inbound frame queues.** FPC 3.2.4
  has **no `TThreadedQueue<T>`** (`Identifier not found "TThreadedQueue"`),
  so the design defines its own bounded, blocking queue from
  `TQueue<T>` (unit `Generics.Collections`), a `TCriticalSection`, and two
  `RTLEvent`s. `probe12.pas` compiles and runs it (a consumer thread drains
  100 items; sum = 5050), including a `Shutdown` that releases blocked
  waiters. **It is held as an interface**
  (`IBlockingQueue<T>`) so a thread and a caller can share one queue by
  refcount rather than by raw pointer.
- **Arrival stamps.** The connection thread reads `Http2.Client.Clock.NowUs` once
  per received frame, right after the frame is read, and the stamp travels
  with the frame through the stream's inbound queue. A stream's queue holds
  a byte count of DATA (`TByteBoundedFrameQueue`), and `Push` on it never
  blocks the connection thread.
  The thread therefore keeps reading connection frames (WINDOW_UPDATE,
  SETTINGS, PING) while a consumer is idle, for example while the client
  still sends a request body and has not yet read the response. The stream
  credit is returned when the application reads, and the connection credit is
  returned on arrival (see "Receive flow control"). The outbound queue keeps
  the bound
  (`cDefaultQueueCapacity`, 128 frames). See
  [request-observability](request-observability.md), "Arrival stamping".
- `TCriticalSection` (unit `SyncObjs`) — the pool guard, and per-connection
  stream-id allocation even though the object is free-threaded
  (`TMonitor` is **not** in FPC 3.2.4; `Identifier not found "TMonitor"`).
- `RTLEvent` (unit `Classes`) — slot signalling and queue wakeups.
  **Use `RTLEvent`, not `TEvent`/`TSimpleEvent`**: on macOS both constructs
  raise `ESyncObjectException: Failed to create OS basic event` (probe6,
  probe11), while `RTLEventCreate`/`RTLEventSetEvent`/`RTLEventWaitFor`
  works (probe7).
- `{$IFDEF UNIX}cthreads,{$ENDIF}` must precede threaded units in any
  program's `uses`; otherwise: `This binary has no thread support compiled
  in ... Runtime error 232`.

```pascal
{$mode delphi}
type
  IBlockingQueue<T> = interface
    procedure Push(const AItem: T);
    function Pop(out AItem: T): Boolean;   // False on shutdown + empty
    procedure Shutdown;                    // releases blocked waiters
  end;

  TBlockingQueue<T> = class(TInterfacedObject, IBlockingQueue<T>)
  private
    FLock: TCriticalSection;
    FNotEmpty: PRTLEvent;
    FNotFull: PRTLEvent;
    FItems: TQueue<T>;
    FCapacity: Integer;
    FShutdown: Boolean;
  public
    constructor Create(const ACapacity: Integer = 128);
    destructor Destroy; override;
    procedure Push(const AItem: T);
    function Pop(out AItem: T): Boolean;
    procedure Shutdown;
  end;

  TConnectionThread = class(TThread)
  private
    FConn: Pointer;             // weak ref to TConnection (no AddRef)
    FOutbound: IBlockingQueue<TFrame>;
    FInbound: IBlockingQueue<TFrame>;
    FSocket: IHttp2Socket;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TConnection);   // does NOT retain AConn
  end;
```

One thread per connection, responsible for *both* directions:

- **Outbound:** a `Send`/`Read` caller never writes to the socket. It pushes
  frames onto `FOutbound` and returns (or blocks on `FInbound`). The
  connection thread writes them in queue order.
- **Inbound:** the thread reads frames and, keyed by `StreamId`, pushes them
  onto that lease's `FInbound`. Frames for unknown/closed streams (late DATA
  after `RST_STREAM`) are discarded and counted.
- **Ordering:** frames for one stream are written in enqueue order;
  `HEADERS`/`CONTINUATION` must be contiguous and `DATA` must follow its
  `HEADERS`. The single writer guarantees this by construction.
- **Backpressure:** `TBlockingQueue` has a bounded depth; a full outbound
  queue blocks (or returns a retryable error) instead of growing unbounded.
  A stream queue never blocks the reader, because a blocked reader could not
  apply WINDOW_UPDATE frames. The window of the stream bounds the queue
  instead (see "Receive flow control"). On
  shutdown, `Shutdown` unblocks waiters and pending calls fail with
  `EHttpConnectionClosed` rather than hanging.
- **Contention:** the HPACK encoder is stateful and shared across streams.
  Encoding is therefore routed through the connection thread (or guarded by
  the connection's critical section); the decoder is touched only by the
  connection thread.
  Complete HEADERS/CONTINUATION blocks are decoded before stream lookup.
  This includes header blocks for a stream whose lease was released. The
  END_HEADERS frame carries decoded fields as internal metadata; those fields
  are not written to the socket. Each lease validates the fields and updates
  its response state on the caller thread. A caller can consume streams in
  any order without changing the HPACK dynamic-table order. Interleaved or
  wrong-stream CONTINUATION frames fail the connection.
- **Header block limit:** The reader caps the sum of the HEADERS and
  CONTINUATION fragments of one block at `MaxHeaderListSize` (default 128
  KiB). A larger block fails the connection with `ENHANCE_YOUR_CALM`. The
  same value is the `SETTINGS_MAX_HEADER_LIST_SIZE` that the client
  advertises. The HPACK decoder refuses a decoded field list that is larger
  than this value, also with `ENHANCE_YOUR_CALM`. A decoded field value that
  holds CR, LF or NUL fails the connection with `PROTOCOL_ERROR`. The reader
  reads each frame with the local `SETTINGS_MAX_FRAME_SIZE` as the limit.
- **ARC hazard:** `TConnectionThread` stores a raw (weak) pointer to avoid
  an interface reference cycle (`TConnection` ↔ thread). `TConnection`
  `Terminate`+`WaitFor`s the thread before releasing `FSocket`/queues.
  The queues themselves are interfaces, so both sides can hold one without
  a raw-pointer lifetime bug.

```mermaid
flowchart TB
  subgraph CALLER["caller thread(s)"]
    SEND["Send(request)"]
    READ["read response body"]
  end
  subgraph CONN["TConnectionThread · sole socket writer"]
    LOOP["read frame → route by StreamId"]
    WRITE["write queued frames in order"]
  end
  SEND --> OQ["FOutbound: IBlockingQueue&lt;TFrame&gt;"]
  OQ --> WRITE
  LOOP --> IQ["lease FInbound: IBlockingQueue&lt;TFrame&gt;"]
  IQ --> READ
  WRITE --> SOCK["IHttp2Socket · TLS + ALPN h2"]
  SOCK --> LOOP
  LOOP -.->|"HPACK decode"| HP["THpackCodec"]
  WRITE -.->|"HPACK encode"| HP
```

## Lock order

A thread that holds several locks of one HTTP/2 connection takes them in this
order. A lock that is later in the list is never held while a thread takes a
lock that is earlier in the list.

1. The header encoder lock. It is the lock of the pooled connection
   (`THttpConnection`, shared with `TConnection.HeaderEncoderLock`). A stream
   thread holds it while it starts a stream, and this includes the wait for
   room in the outbound queue. The thread also holds it while it sends a
   request body. The lease releases it only during the wait for flow-control
   credit (`AcquireCredit` in `Http2.Client.Stream.Send.pas`). A thread that
   reads a response body holds it, except during the wait for the next frame.
   A thread that closes the connection does not hold it. `Drain` and
   `ReleaseIfIdle` of `THttpConnection` decide under the encoder lock, release
   it, and then call `TConnection.Close`, which queues the GOAWAY frame and
   waits for the reader thread to end. A flag that is set under the encoder
   lock lets only one thread close the connection.
   The pool lock (`TPoolState` in `Http2.Client.Pool.State.pas`) is outside
   this order. The pool does not hold its lock while it closes a connection.
   Library code does not take the pool lock while it holds the encoder lock.
2. The connection lock (`TConnection.FLock`). It guards the state, the peer
   settings, the stream table, the flow control windows and the receive
   credit counters. Each section under this lock is short. No section waits,
   pushes to a queue, uses the socket or calls an observer. The only lock that
   a section takes is the lock of the send-credit waiter registry, which
   `AcquireSendCredit` takes to register a waiter.
3. The leaf locks. A leaf lock is held for one operation. The operation takes
   no other lock, except where this list says otherwise.
   - The outbound queue lock (`TBlockingQueueState<T>`, unit
     `Http2.Client.Connection.Queue`). `Push` releases the lock while it waits
     for room, so no thread waits for room while it holds this lock.
   - The control frame queue lock (`TControlFrameQueue`, unit
     `Http2.Client.Connection.Control`). Its operations never wait.
   - The header table hand-off lock (`THeaderTableHandoff`, same unit). It
     guards the pending size only. The encoder is updated after the lock is
     released.
   - The send-credit waiter registry lock (`Http2.Client.Connection.SendCredit`).
     A signal sets an event and does not wait.
   - The stream receive queue lock (`TByteBoundedFrameQueue`, unit
     `Http2.Client.Stream.Receive`). Its push takes the lock of the inner
     `TBlockingQueueState<T>`. The inner queue has capacity zero, so it never
     waits. The order is always this lock, then the inner lock.
   - The socket locks of `TTlsSocket` (unit `Http2.Client.Tls.Socket`): the
     session lock, the read lock and the write lock. A socket read or write
     holds its lock while it waits for the peer. The read lock is taken before
     the session lock. The write lock stays held when the thread takes the
     session lock again after a transport write. The session lock takes the
     read lock and the write lock only with `TryEnter`. Only the connection
     thread reads and writes the socket while the connection is open.

Observer and exchange callbacks run on the stream thread while it holds the
encoder lock. Examples are the stream open and close events, which
`RegisterStream` and `UnregisterStream` emit after they release the connection
lock, and the exchange calls `RouteChosen` and `RequestWritten`. The reader
thread runs observer and exchange callbacks with no lock held.

The reader thread is the only thread that drains the outbound queue, so it
never waits for a lock that a stream thread holds across a wait for queue room.
The header encoder lock is such a lock. When the reader applies the
`SETTINGS_HEADER_TABLE_SIZE` of the peer, it takes the header encoder lock
with `TryEnter`. When the lock is busy, the reader leaves the size in the
header table hand-off, and the stream thread that holds the lock applies the
size to the encoder before it encodes the next header block.

`TConnection.Close` waits for the reader thread to end. The caller of
`TConnection.Close` holds no pool lock and no encoder lock during that wait.
The pool removes the connections that it closes from its tables under the pool
lock and puts them in a list of victims (`ReapIdleLocked`, the eviction of an
idle connection of another identity). `TPoolState.Close` copies the
connections. `CloseVictims` and the loop of `TPoolState.Close` close them after
the pool lock is released. The reader can run exchange callbacks on a
connection failure and on a GOAWAY frame. A callback that waits for the pool
lock or for the encoder lock of the same connection would block such a wait,
and this is why the wait runs with both locks released.

The reader thread can call `TConnection.Close` from a callback, for example
when an observer calls `Close` of the client. The reader thread cannot join
itself. `TConnection.Close` compares the current thread with the reader thread.
On the reader thread it queues the GOAWAY frame in the control frame queue
(the reader is the only thread that drains the outbound queue, so a push
there could wait for ever), sets the closing flag, terminates the thread, sets
the state to closed and emits the close event. It does not join the thread, it
does not shut down the queues and it does not close the socket, because the
reader still uses them until the callback returns. The next `Close` from
another thread, or the destructor, joins the thread and ends the shutdown.

A callback on the reader thread can also drop the last reference to the pooled
connection, for example when it releases the last reference to the client. The
destructor of `THttpConnection` then runs on the reader thread. The reader
thread still uses the connection, the header codecs and the encoder lock when
the callback returns, so the destructor does not free them. It hands them to a
cleanup thread, which closes the connection (this joins the reader thread,
which has returned from the callback by then) and then frees the parts. The
function `PendingConnectionCleanups` in `Http2.Client.Pool.Http2` counts the
cleanup threads that still run. A direct free of a `TConnection` on its own
reader thread is not supported.

The connection thread is the only writer, and it reads and writes in one loop: it
drains the control queue and the outbound queue, and then it blocks in a read for
one poll interval (`cDefaultReadPollMs`, 20 ms). A peer that has used its
window sends no octet until the client writes a `WINDOW_UPDATE` or a `DATA` frame,
so a frame that a stream thread queued in that time would wait for the end of the
interval, once for each flow-control window. Every queue therefore carries a wake.
A socket that implements `IReadInterrupt` gives the connection thread a wake
channel: `TPlainSocket` holds a non-blocking pipe, and its read waits for the
socket and the pipe together. `TTlsSocket` passes the call to its transport. The
worker enables the channel before its thread starts. `TControlFrameQueue.TryPost`
and `IBlockingQueue.Push` call `InterruptRead` after they queue a frame, and the
blocked read ends with `EHttpTimeout`, as an idle poll does. The thread then
drains the queues at once. Input that is already available takes precedence: the
read returns it, and the wake byte is only consumed. A socket without the contract
keeps the timed read, so the poll interval is the longest delay of such a socket.
The poll interval is therefore not the cost of a flow-control round trip.

`TPlainSocket` sets `TCP_NODELAY` on every TCP connection, so the kernel sends a
small segment at once and does not wait for the ACK of the previous one. A
`WINDOW_UPDATE` frame is 13 octets. `WriteFrame` in `Http2.Common.Frames` builds the
header and the payload in one buffer and writes them in one call, so a frame leaves
as one segment. A frame in two writes with Nagle on would wait for a delayed ACK of
the peer, about 40 ms on Linux, for each flow-control window of a body.

A write timeout is not an idle poll. Only a read that returns no byte before
the poll interval ends is an idle poll, and the reader then continues its loop.
A timeout from a frame write can leave a frame partly written, so the
connection fails with `INTERNAL_ERROR` and the stream is not used again.

A read timeout inside a frame is not an idle poll either. The reader socket
times out every poll interval, and a TCP segment gap inside one frame can be
longer than that interval. The partial socket read `SocketReadPartial` and the TLS read of
`TTlsSocket.Read` return the bytes that they already consumed when a timeout
follows some bytes. They raise `EHttpTimeout` only when no byte was read. The
HTTP/1 body reader, the decoder and the response wrappers see that short count
and never see the timeout that ended the read. The reader adapter
`TSocketStream` marks the start of each frame. A timeout before the first byte
of a frame is an idle poll. After the first byte, the adapter keeps the bytes
and reads on until the frame is complete. If the frame is not complete within
the socket read timeout that was set before the poll interval was applied
(30 seconds when none was set), the connection fails with an I/O error and not
with an idle poll. `SocketReadFully` keeps its full-read-or-raise behavior for
the proxy CONNECT reply.

## Lock pattern

The lock pattern lets a thread work on one item of a collection without it
holding the coarse lock of the collection during the work. The pattern has
four steps:

1. The thread takes the coarse lock of the collection, such as the pool lock.
2. The thread takes the fine lock of the item that the work needs, such as
   the encoder lock of one connection.
3. The thread releases the coarse lock.
4. The thread does the work with the item under its fine lock.

### Lock levels

The locks have three levels. A thread takes locks in the order of the levels,
level 1 first and level 3 last. A thread never takes a lock of a lower level
while it holds a lock of a higher level.

- Level 1 is a coarse lock. It guards a collection. The pool lock
  (`TPoolState.FLock`) is the level 1 lock.
- Level 2 is a fine lock. It guards one item of a collection, such as one
  connection. Within one connection, the header encoder lock is taken before
  the connection lock, as the [lock order](#lock-order) section states.
- Level 3 is a leaf lock. A thread holds a leaf lock for one operation. The
  operation takes no other lock, except where the lock order section states
  otherwise.

### Rules of the lock pattern

Step 2 uses TryEnter and never waits. While a thread holds a coarse lock, it
takes the fine lock with TryEnter. A fine lock can be held for a long time. A
stream thread holds the header encoder lock while it waits for room in the
outbound queue. If TryEnter fails, the thread releases the coarse lock. The
thread then either takes another item, or waits for the fine lock outside the
coarse lock. That wait has a deadline and the cancel token of the caller. After
the wait, the thread takes the coarse lock again and checks that the item is
still in the collection.

No blocking call is made under a coarse lock. Under a coarse lock, the code does
not read or write a socket, does not call a queue push that can wait, does not
join a thread, does not call an observer or an exchange callback, and does not
wait for an event. An item that leaves the collection is closed after the
coarse lock is released. The thread removes the item from the collection under
the coarse lock, and closes the item after the release.

A callback never takes a coarse lock. A callback that runs on the reader thread
does not take the pool lock, and does not wait for a header encoder lock.

Fine locks are never taken in pairs by one thread, except in a fixed documented
order. The order of the header encoder lock and the connection lock, in the
lock order section, is such an order.

The fine lock is released before a wait. A thread that waits for an event, such
as the end of a dial that another thread runs, or room in a queue, releases the
fine lock first. The thread that signals the event needs that lock to update
its state. The header encoder lock is the exception that the lock order section
describes: the stream thread holds it across the wait for room in the outbound
queue, and the reader thread never waits for it.

### Locks of the client

| Lock | Level | Scope |
|------|-------|-------|
| Pool lock (`TPoolState.FLock`, unit `Http2.Client.Pool.State`) | 1, coarse | The pooled connections. |
| Header encoder lock (`TConnection.HeaderEncoderLock`, unit `Http2.Client.Connection`) | 2, fine | One connection. Held across the start of a stream and the send of a request body. |
| Connection lock (`TConnection.FLock`, unit `Http2.Client.Connection`) | 2, fine | One connection. Guards the state, the settings, the stream table and the flow control windows. |
| Outbound queue lock (`TBlockingQueueState<T>`, unit `Http2.Client.Connection.Queue`) | 3, leaf | One outbound queue. |
| Control frame queue lock (`TControlFrameQueue`, unit `Http2.Client.Connection.Control`) | 3, leaf | One control frame queue. Its operations never wait. |
| Header table hand-off lock (`THeaderTableHandoff`, unit `Http2.Client.Connection.Control`) | 3, leaf | The pending header table size. |
| Send-credit waiter registry lock (unit `Http2.Client.Connection.SendCredit`) | 3, leaf | The registry of the send-credit waiters. |
| Stream receive queue lock (`TByteBoundedFrameQueue`, unit `Http2.Client.Stream.Receive`) | 3, leaf | One stream receive queue. Taken before the lock of the inner queue. |
| Socket locks of `TTlsSocket` (unit `Http2.Client.Tls.Socket`): session, read and write | 3, leaf | One TLS socket. The read lock is taken before the session lock. |

### Locks of the WebSocket, the HTTP/1 pool and the attempt tracker

Each lock in this table guards one object. None of them guards a collection, so
none is a level 1 lock. The pool lock is never held while a thread takes one of
these locks. The pool does not take the lock of an HTTP/1 pooled connection.

| Lock | Level | Taken in | Runs while the lock is held |
|------|-------|----------|-----------------------------|
| HTTP/1 connection lock (`THttp1PooledConnection.FLock`, unit `Http2.Client.Pool.Http1`) | 2, fine | `Acquire` and `Resume` hold it for the exchange: the write of the request and the read of the response head. `Drain` and `ReleaseIfIdle` hold it to decide. | The exchange of one connection, which is the work of the lock. A flag (`FCloseClaimed`) lets only one thread close the socket. The socket close runs after the lock is released, also when an exchange fails. |
| WebSocket send lock (`TWebSocketConnection.FSendLock`, unit `Http2.Client.WebSocket.Connection`) | 2, fine | Every send, the close frame, the echo of a close frame, and the claim of the transport close. | The write of one frame, so that frames of two threads never mix. The socket close of the transport runs after the lock is released. Observer reports and listener callbacks run after the lock is released. |
| WebSocket state lock (`TWebSocketConnection.FStateLock`) | 3, leaf | Inside the send lock in `Close`, `HandleClose` and `SendCloseQuiet`, and alone in the readers of the flags and in the demand counter. | A change or a read of a flag or of the demand counter. No socket call, no callback and no other lock. |
| WebSocket socket lock (`TWebSocketConnection.FIo`) | 3, leaf | Only when reads and writes share one TLS state. The reader takes it for one read. A sender takes it inside the send lock for one write. | One socket read, which is bounded by the poll time of the reader, or one socket write. The counter `FWriters` lets a waiting sender go before the next read. |
| Attempt progress lock (`TAttemptTracker.FProgressLock`, unit `Http2.Client.Attempt`) | 3, leaf | `ReportMessage` and the build of the outcome. | The update of the message counters and a copy of them. The observer calls run after the lock is released. |

The order of the WebSocket locks is the send lock, then the state lock or the
socket lock. A thread that holds the state lock or the socket lock never takes
the send lock. The reader thread never holds the send lock while it reads from
the socket or while it calls the listener.

The socket close of a WebSocket connection and of an HTTP/1 pooled connection can
wait for the peer, because a TLS close sends a `close_notify` alert. Both close
the socket after they release their lock. A sender that arrives during the close
sees the flag `FSockClosed` and ends at once with a closed error.

### Where the pattern is used

The pool applies the pattern in the wait for a dial in flight, in the close of idle connections, and in the locks of the HTTP/1 pooled connection. The close of a connection (idle reap, eviction, `Close` of the pool, `Drain` and `ReleaseIfIdle`) runs after the pool lock and the encoder lock are released. The sections of the units that apply it name the lock levels that they use.

## Receive flow control

RFC 9113 section 5.2 and section 6.9 give each side a window for the DATA
that it receives. The client keeps two receive windows with different rules.

- **Stream credit follows the read.** When the lease takes a DATA frame out of
  its queue, it tells the connection how many bytes it took
  (`TConnection.DataConsumed`). `TReceiveCreditTracker.OnConsumed` adds the
  bytes to a counter of the stream. The connection sends a stream
  `WINDOW_UPDATE` when the counter reaches the batch size. The batch size is
  32768 bytes, or half of the stream window when that is smaller. A stream
  `WINDOW_UPDATE` is therefore never sent for data that waits in the queue. A
  stream that is closed gets no more credit.
- **Connection credit follows the arrival.** `TConnection.TrackReceivedData`
  returns the connection credit when the frame arrives, in batches of 32768
  bytes. A frame that is dropped (for example DATA on a stream that the
  client reset) also returns its connection credit, as section 6.9 requires.
  The connection window is not tied to the read, so a reader that stalls on
  one stream does not stop the other streams of the connection.
- **The advertised window equals the queue size.** The client puts
  `Security.MaxReceiveQueueBytes` (default 1 MiB) in the
  `SETTINGS_INITIAL_WINDOW_SIZE` of its first SETTINGS frame, and the peer
  applies it to each new stream (section 6.9.2). A peer that follows the
  protocol can send at most that many unread bytes on one stream, so the
  queue of the stream does not pass its byte cap.

The memory that received DATA uses is bounded by (open streams) x
(`MaxReceiveQueueBytes`), plus one frame that the lease holds while the
application reads it. A DATA frame that would pass the cap of a queue is a
violation of the stream window. The queue raises `EHttpStreamError` with
`ecFlowControlError`, and the connection fails with that error. A DATA frame
for a stream that the client never opened, or for an even stream id, is a
connection error with `PROTOCOL_ERROR`. A DATA frame for a stream that the
client closed or reset is discarded.

## Connection lifecycle

1. **Create.** TCP opens, then TLS negotiates ALPN `h2`. When ALPN selects `h2`,
   the client writes the connection preface: the client magic
   `PRI * HTTP/2.0` + CRLF + CRLF + `SM` + CRLF + CRLF, then a `SETTINGS`
   frame. The connection can open streams as soon as the preface is written:
   a request may send `HEADERS` immediately, since HEADERS is not
   flow-controlled. `DATA`, however, is withheld until the peer's `SETTINGS`
   is received and applied, because only then is
   `SETTINGS_INITIAL_WINDOW_SIZE` known — the default is 65535, but a peer
   may lower it, and emitting DATA first would overrun its window
   (RFC 9113 section 6.5.3: `FLOW_CONTROL_ERROR`).
2. **Steady state.** The connection serves streams and maintains HPACK tables, settings, and
   windows.
3. **Keep-alive.** Idle connections may be probed with `PING` and closed
   after `FIdleTimeoutMs`, provided no active streams.
4. **`GOAWAY`.** The connection enters a draining state and stops creating new streams. Streams with ids
   at or below the last-stream-id may complete; **higher streams may be
   safely retried on a fresh connection (the peer guarantees it did not
   process them).** A stream that may have been processed is retried only when
   the request is known to be safe. An unusable connection leaves the pool,
   and the client opens a replacement.
5. **Errors.** A transport/protocol error fails all leases on that
   connection; `ftRstStream` fails only the affected lease.
6. **Shutdown.** `IHttpClient.Close` stops accepting leases, drains or
   cancels in-flight streams, sends `GOAWAY` where possible, stops every
   `TConnectionThread` (`Terminate`+`WaitFor`), and closes sockets.
   Idempotent.

```mermaid
stateDiagram-v2
  [*] --> Dialing: dial TCP + TLS (ALPN h2)
  Dialing --> Preface: ALPN = h2
  Dialing --> Failed: TLS / ALPN failure
  Preface --> Steady: write magic + SETTINGS
  note right of Preface
    HEADERS may be sent immediately;
    DATA is withheld until the peer's
    SETTINGS is received and applied
  end note
  Steady --> Steady: streams, HPACK, windows
  Steady --> Draining: GOAWAY received or sent
  Steady --> Failed: transport / protocol error
  Draining --> Closed: in-flight streams ≤ last-stream-id complete
  Draining --> Failed: error while draining
  Failed --> Closed: all leases on the connection fail
  Closed --> [*]
```

`GOAWAY` semantics: streams with ids **above** the last-stream-id were never
processed by the peer, so they may be retried on a fresh connection; streams
at or below it may have been processed and are only retried if the method is
known safe.

**Reconnect policy**: transparent retry on connection failure only for
idempotent methods (no body writer), and only on `ecRefusedStream` or a
`GOAWAY` that puts the stream above the last-stream-id; bounded by
`cMaxTransparentRetries`. There is no per-request opt-in.

## TLS and ALPN

- HTTPS requires a client-capable `ITLSContext` selected with
  `WithTlsContext`. Without one, a library-owned HTTPS dial fails before DNS
  or socket creation.
- The client offers ALPN `h2`. If the server does not select `h2`, the client
  raises `EHttpProtocolError` by default. HTTP/1.1 fallback requires explicit
  caller policy. `NPN` is not required.
- Cleartext `h2c`, cleartext HTTP/1.1, and HTTP/1.1 fallback remain separate
  transport settings. The strict default remains unchanged. Details are in
  [fallback](fallback.md).
- The context owns trust and hostname verification policy. The secure client
  policy verifies both by default. A nonempty `WithCACertFile` or
  `WithInsecureTls(True)` raises a configuration error.
- Each connection owns a provider-neutral buffer session. The session moves
  ciphertext and plaintext through bounded queues and performs no socket I/O.
  OpenSSL and TlsLib provide the same session contract. A client identity is
  selected as common `ITLSIdentity` metadata; a nil selector result suppresses
  the context default.
- HTTPS proxy TLS uses `WithProxyTlsContext`. Proxy trust and proxy identity
  are separate from the origin context and identity. A `CONNECT` tunnel then
  carries the origin TLS layer. See [proxy](proxy.md) and [mutual TLS](mtls.md).


## Unix domain sockets

A client built with `WithUnixSocket` dials a Unix domain socket file in place of
a TCP address. The socket file path replaces the TCP address for every connection
of that client. TLS, ALPN, HTTP/1.1, HTTP/2, server-sent events and WebSocket
run over the same byte stream, so the protocol code does not change. The option
is described in [client API](client-api.md) and the route rules in [proxy](proxy.md).

### Dial rule

- `Build` gives the client a clone of the default socket factory that holds the
  socket file path. The shared factory stays on TCP.
- The clone sends every dial to the file: the pool, TLS, cleartext, the HTTP/1.1
  dial that a WebSocket uses, and the dial of each redirect hop. The URL host and
  port do not select the destination.
- The client opens an `AF_UNIX` stream socket and connects it without blocking.
  When the connect completes, the descriptor returns to blocking mode.
- A connect that fails at once, or that reports an error through `SO_ERROR`,
  raises `EHttpConnectionError`. The message holds the path and the system error
  text.
- A connect that reports `EAGAIN` is retried every 10 ms until the connect timeout
  ends. A connect that is still pending at the deadline raises `EHttpTimeout`.
  On macOS a full listen queue is reported as `ECONNREFUSED` instead, so that
  case raises `EHttpConnectionError` at once.
- The path rule is checked before the connect. A path that is not absolute,
  holds a NUL byte or is longer than 103 UTF-8 bytes is refused by `Build`
  with `EHttpUnixSocketConfigError`. A leading `@` is therefore refused: the
  client does not use Linux abstract sockets.

### Timeouts

- The connect deadline is the connect timeout of the dial. For a Unix socket it
  covers the connect only.
- The read and write deadlines are fixed at 30 000 ms, as on a direct TCP
  connection. The factory does not change them for a Unix socket.

### Write path and SIGPIPE

- Every write to the socket goes through `SocketWriteFully`, including the
  ciphertext of TLS. That function calls `send` with the flag `cMsgNoSignal`.
- On Linux the flag is `MSG_NOSIGNAL`. A write to a peer that has closed returns
  `EPIPE` and does not raise `SIGPIPE`.
- On macOS the flag is 0. The descriptor carries `SO_NOSIGPIPE`, which the client
  sets when it creates the socket, and the write does not raise `SIGPIPE` for the
  same reason. The return value of that `setsockopt` call is not checked.
- A failed write raises `EHttpConnectionClosed`, and a write that times out raises
  `EHttpTimeout`.
- The OpenSSL provider moves TLS data through memory BIOs. OpenSSL does not write
  the descriptor, so the production client path does not enter the per-call
  SIGPIPE shield of `Http2.Client.SigPipe`. The shield is used by the tests only.
- The client does not install a signal handler and does not change the signal
  disposition of the process.

### Authority rule

- The URL host and port set the `Host` header, the TLS server name and the
  certificate check. The socket file does not change them. For example,
  `http://localhost/x` over a Unix socket sends `Host: localhost`.
- A Unix path replaces the whole route. The proxy check does not apply to a Unix
  dial, and a client with a Unix path refuses every proxy source at `Build`.

## WebSocket connections

A WebSocket ([websocket](websocket.md)) uses a connection of its own rather than a pooled
one. The dial speaks HTTP/1.1 only: for `https` the ALPN offer is `http/1.1`
alone (`IHttp1SocketFactory.DialHttp1`), a server that selects `h2` is
refused, and a server that answers with no ALPN is accepted. The proxy tunnels
of [proxy](proxy.md) apply unchanged. After the `Upgrade` handshake one reader thread
owns every read of the socket; sends from other threads are serialised by a
lock, and on a connection whose reads and writes share one TLS state the
socket itself is guarded by a second lock that the reader takes only for short
polls.

## RFC references

- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html), checked 2026-11-11.
