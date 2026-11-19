---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, io-pool, async, tls, wake-up, thread-rule
notes:
  - This document describes the IO pool of the server, the mORMot2 async
    classes it extends, the TLS plug-in of a connection and the write wake-up.
  - The document cites the server code as path:line.  The mORMot2 facts cite
    the pinned revision b2b195da1e0580058672a88620ef71bb47283eb1.
  - Imported from http2server/doc/design/server/io-pool.md at the source commit recorded in the source inventory.
scope: The mORMot2 async subclasses, the per-connection core bridge, the TLS handshake, the write wake-up and the thread rule.
primary_types:
  - THttp2AsyncConnection
  - THttp2AsyncServer
  - THttp2ConnectionWaker
  - THttp2ConnectionEvents
  - TTransport
  - TTlsPolicy
db_tables: None.
related_docs:
  - doc/design/server/threading.md
  - doc/design/server/unix-socket.md
  - doc/design/server/tls.md
  - doc/design/server/connection.md
  - doc/design/server/output.md
  - doc/design/server/configuration.md
  - doc/design/server/lifecycle.md
invariants:
  - The IO pool sweeps connections under the per-connection mORMot lock and never runs a handler.
  - A wake-up reaches the owning IO pool through an edge-triggered flag and one retry after a failed lock.
  - A handler that runs on a marked IO thread raises at once.
  - A TLS connection that did not negotiate h2 is refused.
  - A stalled TLS handshake holds one IO thread for a bounded time only.
---

# The IO pool

The server runs its connection core on the mORMot2 async IO classes. A few IO
threads serve many connections, so the server does not build a poller of its
own and does not need one. The unit `server/src/Http2.Server.Async.pas` holds this
integration.

## The async class set

The server extends four mORMot2 classes. The reading of the pinned revision
`b2b195da1e0580058672a88620ef71bb47283eb1` fixes which method does what.

| Class | Role | The methods the server overrides |
| --- | --- | --- |
| `TPollAsyncConnection` | one non-blocking socket | `OnFirstRead`, `OnRead`, `AfterWrite`, `OnClose` |
| `TAsyncConnection` | one connection of a pool | `AfterCreate`, `BeforeDestroy`, `OnLastOperationIdle` |
| `TAsyncConnections` | one thread pool of connections | none |
| `TAsyncServer` | a listener on a port | none; the constructor supplies the connection class |

`TPollAsyncConnection.OnRead` is abstract, so every pool supplies one
(`mormot.net.async.pas`). The read path calls it from an IO thread after
mORMot2 moved the socket bytes into `fRd` (`mormot.net.async.pas`).
The write path calls `AfterWrite` from an IO thread after it drained `fWr`
(`mormot.net.async.pas`). `TPollAsyncConnection.OnFirstRead` runs once per
connection, just before the first read, and returns False to close the
connection (`mormot.net.async.pas`). `TAsyncConnection.AfterCreate`
runs at the end of `TAsyncConnections.ConnectionNew`, once the handle is set.
That point can come before the subscription: `ConnectionNew` calls
`ConnectionAdd` only when the caller passes `aAddAndSubscribe` or when no
read-poll thread exists. The method is cheaper than the constructor, which
mORMot2 reintroduces with its own signature (`mormot.net.async.pas`,
`TAsyncConnection.Create`).

**The IO thread count.** The server passes the factory value
`IOThreads` as `aThreadPoolCount` to the `TAsyncServer` constructor
(`THttp2AsyncServer.Create` in `server/src/Http2.Server.Async.pas`). A count above one makes one thread do
`atpReadPoll` and the rest `atpReadPending`; a count of one makes a single
thread do `atpReadSingle` (`mormot.net.async.pas`). mORMot2 always
adds one accept thread and one write thread to the count
(`mormot.net.async.pas`).

**The idle event.** `TAsyncConnections` runs `IdleEverySecond`, which calls
`ReleaseMemoryOnIdle` on an idle connection and calls
`OnLastOperationIdle` on a connection that passed
`GetLastOperationIdleSeconds` (`mormot.net.async.pas`). The base
class returns zero from `GetLastOperationIdleSeconds`, so the event is
disabled until a subclass enables it (`mormot.net.async.pas`). The
server overrides that method to return the earlier of the factory idle
timeout and the factory header timeout, so the one callback serves both rules
(`THttp2AsyncServer.GetLastOperationIdleSeconds`). It overrides
`OnLastOperationIdle` to close the connection of a spent timeout
(`THttp2AsyncConnection.OnLastOperationIdle`).

**The backlog.** mORMot2 binds with the global `DefaultListenBacklog`
(`mormot.net.sock.pas`). The server sets it from the factory value
`Backlog` before it binds (`THttp2AsyncServer.Create`).

**The connection cap.** mORMot2 refuses a new socket when the read set holds
more than `MaxConnections` (`mormot.net.async.pas`). The test runs
before the new socket joins the set, and it is strict, so the server maps a
factory value of N to N minus one (`THttp2AsyncServer.Create`). A factory
value of 0 maps to `MaxInt`, which means no cap. A factory value of N then
allows exactly N open connections.

**The refusal.** A refused socket is closed without a reply
(`mormot.net.async.pas`). mORMot2 offers no hook at that point, so
the server counts no refusal and raises no event for it. The gap is
deliberate: the accept loop logs the refusal and waits before the next
accept, and no server counter or observer event covers it.

## The connection core bridge

`THttp2AsyncConnection` owns one `TServerConnectionCore`
(`THttp2AsyncConnection` in `server/src/Http2.Server.Async.pas`). `StartHttp2` builds the
core from the factory values that `THttp2AsyncServer` prepared at its own
construction (`BuildConnectionCoreOptions` in `server/src/Http2.Server.Async.Options.pas`). `AfterCreate` does not build the core,
because the protocol of the connection is not yet known at that time.

The read path is `THttp2AsyncConnection.OnRead`. mORMot2
already decrypted the socket bytes and placed them in `fRd`, so the method
copies that buffer into the core with `Feed` and resets `fRd`. The core keeps
its own partial-frame buffer, so a frame that straddles two reads is
reassembled there. After the feed the method calls `SendPendingOutput`, which
turns handler output into frames.

The write path is `THttp2AsyncConnection.SendPendingOutput`.
It drains the core through `DrainPending`, takes the bytes with `TakeOutput`,
and hands them to the mORMot2 write path. The drain runs under the connection
core lock, which every stream also takes, so the HPACK encoder keeps one owner
per connection. The core calls the drain itself at the end of every `Feed`
(`TServerConnectionCore.Feed`), so the response to one request
leaves in the same IO turn as the request.

## The second core

`THttp2AsyncConnection` serves either protocol. The mode of a connection is
undecided until the ALPN result (TLS) or the first octets (clear text) are known
(as described in [http1](http1.md)). An HTTP/2 connection owns a `TServerConnectionCore`. An
HTTP/1.1 connection owns a `TH1Driver` with a `TH1Core`. The read path, the send
loop, the idle check and the close hooks branch on the mode. The driver keeps the
decisions that depend on time: the staged close, the head deadline and the idle
close. The core of HTTP/1.1 reports the octets that the socket layer holds back
(`PendingWrite`), so a handler write waits for a client that does not read.

## The reuse of connection objects

mORMot2 keeps the object of a closed connection in a pool and gives it to a later
connection (`TAsyncConnections.ConnectionCreate`). It then calls `Recycle` and
`AfterCreate`, and it does not call `BeforeDestroy`. The class `THttp2AsyncConnection`
releases the cores, the waker, the events and the send lock in `ReleaseState`, which
`BeforeDestroy` and `Recycle` both call. After `ReleaseState` the object is in the
undecided mode, as for a new connection, and the next first read chooses the protocol.

## The socket options

mORMot2 leaves an accepted async socket at the operating system defaults. The
`TCP_NODELAY` comment (`mormot.net.sock.pas`) and the Nagle and keep-alive
setup in `SetupConnection`
(`mormot.net.sock.pas`) belong to the `NewSocket` path, which
builds listener and client sockets. The async accept path
(`TNetSocketWrap.Accept` at `mormot.net.sock.pas`) calls neither, so an
accepted socket starts with Nagle on and keep-alive off.

`ApplySocketOptions` (`server/src/Http2.Server.Async.Socket.pas`) applies the factory
`TSocketOptions` to each accepted socket from `AfterCreate`, before the first
read. For a Unix socket the flag `AUnix` is true, and the no-delay and
keep-alive steps are skipped, because the TCP options raise on a Unix socket.
The buffer sizes still apply. For a TCP socket, the chosen no-delay value is
always set, on or off. Keep-alive goes on
with the exact idle time, interval and count when the idle time is above zero,
and it stays off otherwise. A buffer size above zero sets the send or receive
buffer, and zero keeps the operating system default. Each option is guarded,
so the failure of one never closes a good connection.

`ReusePort` adds `acoReusePort` to the server options
(`THttp2AsyncServer.Create`), which sets `SO_REUSEPORT` before the bind
(`mormot.net.async.pas`, `mormot.net.sock.pas`).

**The platform notes.** Darwin and Linux both accept `SO_REUSEPORT` and the
three keep-alive knobs. On Darwin mORMot2 sets `SO_REUSEPORT` on every
listener (`NewSocket` in `mormot.net.sock.pas` calls `SetLinger(5)` before the
bind, and `SetLinger` calls `SetReuseAddrPort` for a positive linger, which
sets the option on BSD and Darwin in `mormot.net.sock.posix.inc`), so two
listeners share a port there even with the option off, and the option decides
the sharing on Linux.

## The Unix listener

The bind text of a Unix listener is `unix:` followed by the socket file path
(`ListenerBindText`, `server/src/Http2.Server.Async.Options.pas`). The IO pool
does not read a bound port for a Unix listener. `THttp2AsyncServer.Start`
skips the port read, and the shutdown wakes the accept by the path instead of
by a port. The checks that run before the bind, and the socket file removal,
are described in [unix-socket](unix-socket.md).

## The write wake-up

The write wake-up follows the mORMot2 pattern. A handler write reaches the
stream host callback (`TServerStream.DoWrite`), the core raises one
edge-triggered flag per transition from "no output" to "output"
(`TConnectionCoreBase.NotifyWantsWrite`), and the waker (`TMethodWaker` in
`server/src/Http2.Server.Async.Waker.pas`) drains the core and calls the mORMot2 write
path.

An IO thread that blocks in `epoll_wait` on Linux or `poll` on macOS sleeps
until a socket event arrives. New output on an already writable socket is not
such an event, so without a signal that thread never sends the response. This
is the reason the wake-up exists.

A lost wake-up is the risk of the pattern. The mORMot2 wake-up of a poll
thread sets a counter, tries the guard lock, and runs the wake-up itself when
the lock is free; a request that loses the lock to the running thread is
picked up by the retry at the end of the lock owner
(`mormot.net.async.pas`, `TAsyncConnections.ThreadPollingWakeupLocked`).
The server follows the same rule: the send loop records a wake-up that arrives while it runs, and it
repeats until no late wake-up and no queued output remain
(`THttp2AsyncConnection.SendPendingOutput`). A second call of the mORMot2 write
path covers the case where the write lock went to the IO thread (the same method).

The stream host callback is the bridge between the two sides
(`TCoreStreamHost` in `server/src/Http2.Server.Connection.Core.pas`). The host holds the core as a raw
pointer and not as an interface, so the core and the host form no reference
cycle.

## TLS session progress

The async accept path creates a common TLS session from the listener context.
The connection moves ciphertext between the socket and the session buffers.
Session calls do not perform socket I/O or block an IO thread. Each connection
serializes its own session calls, while the context is immutable and shared.
The absolute monotonic handshake deadline does not restart when input arrives.
The TLS design and ALPN routing are described in [TLS](tls.md).

## The thread rule

A handler must never run on an IO thread. Such a handler would hold the
connection lock for the length of its work and would stall every other
connection on that IO thread. The seam carries the rule
(`server/src/Http2.Server.Seam.pas`). The IO callbacks mark their thread at
entry (`OnRead` and `AfterWrite` of `THttp2AsyncConnection`), and the handler
pool checks the mark before it calls a handler (`THandlerPool` in
`server/src/Http2.Server.Admission.pas`). The check raises in every build,
so a violation fails loudly and never reaches production silently.

## The idle and header timeouts

`THttp2AsyncConnection.OnLastOperationIdle` runs once per second on a quiet
connection. It closes a connection whose
first header block did not complete within the factory `HeaderTimeoutMs`, and
it closes an idle connection with no open stream and no queued output. The
close is `TAsyncConnections.ConnectionRemove` (`mormot.net.async.pas`),
because a write to an idle connection would itself need the write lock.

## The age sweep

mORMot2 calls `OnLastOperationIdle` only for a connection that did no read
and no write in the last second. An active connection gets its activity flag
cleared instead and no call (`mormot.net.async.pas` declares the virtual
`IdleEverySecond`, and the walk at `mormot.net.async.pas` skips the
flagged connections). A busy connection therefore never reaches the idle rule.

Every successful lock of a connection marks it active
(`TPollAsyncConnection.TryLock` in `mormot.net.async.pas`, read
2026-11-06). A handler write takes that lock, so a connection with a running
handler looks active even when the peer reads nothing. A peer that sends PING
frames but never reads looks active as well. The idle callback cannot see
such a peer, so the sweep judges the write progress itself.

The server overrides `IdleEverySecond`
(`THttp2AsyncServer.IdleEverySecond` in `server/src/Http2.Server.Async.pas`). The
override calls the inherited walk first and returns at once when
`MaxConnectionAgeMs` is 0 and `ServerLimits.WriteTimeoutMs` is 0, so a server
without either limit pays no sweep cost. Otherwise it walks every live
connection once per second and runs the age decision for its mode: retire,
drain, finalise or force-close (as described in [lifecycle](lifecycle.md)).

The same walk runs the write-stall decision
(`THttp2AsyncConnection.CheckWriteStall` in
`server/src/Http2.Server.Async.pas`). The pure rule is `WriteStalled` in
`server/src/Http2.Server.Async.Sweep.pas`: the timeout is above 0, the backlog is
above 0, and the time since the last progress is at least the timeout. The
last progress moves when the backlog shrinks or when the backlog first
appears after an empty backlog. A drain that empties the write buffer reports
through `AfterWrite`, and the sweep compares the backlog with the last sweep,
so a partial drain counts as progress too. A stalled HTTP/2 connection is
removed; an HTTP/1.1 connection keeps its idle rule, fed with the write
timeout in whole seconds.

The sweep takes the mORMot2 tick count (`mormot.core.os.GetTickCount64`,
the same source as the accept time and the write progress,
`server/src/Http2.Server.Async.Sweep.pas`). The SysUtils tick follows the wall
clock on Darwin, while the accept time and the write progress count uptime,
so a wall-clock reading misjudges every connection. The earlier SysUtils
tick retired any age above 0 at once; the mORMot2 tick counts the age correctly.

## The poller of each platform

mORMot2 uses `epoll` on Linux and forces the `poll` API on BSD and Darwin
(the `USEPOLL` define under `OSBSDDARWIN` in `mormot.net.sock.posix.inc`,
read 2026-11-19). `poll` costs time in proportion to the number of sockets in the set, because the kernel scans the
whole set on every call, while `epoll` reports only the ready descriptors. The
relative cost of the two pollers under load is the subject of the load-testing
work, and this document records no measurement, because this host is macOS
aarch64 and the comparison needs a Linux host as well.

## TLS validation boundary

The current server uses common buffer sessions for TLS. The bounded TLS and
integration targets cover handshake scheduling, ALPN routing, transport
backpressure, shutdown, provider pairing, and verified peer metadata. The
current verification record lists each executed target and its limits. Linux,
external-peer conformance, load, and long-duration checks remain separate
validation work. This source design document does not claim those results.

## Sources

| Claim | Source | Read |
|---|---|---|
| The async class set, its virtual methods and the thread roles | `third_party/mORMot2/src/net/mormot.net.async.pas` (pinned revision) | 2026-10-07 |
| The `DefaultListenBacklog` global | `third_party/mORMot2/src/net/mormot.net.sock.pas` | 2026-10-07 |
| The connection cap test and the refusal without a reply | `third_party/mORMot2/src/net/mormot.net.async.pas` | 2026-11-06 |
| The socket defaults of the `NewSocket` path and of the accept path | `third_party/mORMot2/src/net/mormot.net.sock.pas`, `TNetSocketWrap.SetupConnection` and `TNetSocketWrap.Accept` | 2026-11-19 |
| The keep-alive knobs and `SO_REUSEPORT` on each platform | `third_party/mORMot2/src/net/mormot.net.sock.posix.inc`, `TNetSocketWrap.ReusePort`, `TNetSocketWrap.SetKeepAliveTcp`, `TNetSocketWrap.SetReuseAddrPort` and `TNetSocketWrap.SetLinger` | 2026-11-19 |
