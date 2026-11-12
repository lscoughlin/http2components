---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, listener, path check, stale socket, peer pid, server
notes:
  - This document describes the Unix domain socket listener of the server.
  - The path rule that the server and the client share is in common/src/Http2.Common.UnixPath.pas.
  - The checks in this document were read from the merged server sources at the time of writing.
scope: The Unix domain socket listener of the server. The path rules, the checks before the bind, the file mode, the removal of the file, the peer address and the socket options that do not apply.
primary_types:
  - TUnixSocketOptions
  - TUnixPathState
  - THttp2AsyncServer
  - THttp2Server
db_tables: None.
related_docs:
  - doc/design/server/configuration.md
  - doc/design/server/public-api.md
  - doc/design/server/lifecycle.md
  - doc/design/server/io-pool.md
  - doc/design/server/access-log.md
  - doc/design/server/tls.md
invariants:
  - A factory with a non-empty Unix path listens on the socket file, and Host and Port do not apply.
  - The path rule allows only an absolute path of at most 103 UTF-8 bytes without a NUL byte.
  - The server refuses a path that holds a colon, because the bind text splits at the last colon.
  - The check before the bind refuses a regular file, a directory, a live listener and a path that cannot be read, and it does not change the path.
  - A stale socket file passes the check, and the bind replaces it.
  - The server removes the socket file that it bound when it stops.
  - A Unix connection has the remote address unix:pid=<pid>, or unix when the pid is not known.
  - The TCP no-delay and keep-alive options do not apply to a Unix connection. The buffer sizes still apply.
---
# Unix domain socket listener

The server listens on a socket file in place of a TCP address when the factory
holds a Unix path. The byte stream of the listener is the same for both
kinds. HTTP/2 with prior knowledge, HTTP/2 over TLS, HTTP/1.1, server-sent
events and WebSocket run over the socket with no change to the protocol units.

## The listener

`WithUnixSocket(path)` sets the path (`server/src/Http2.Server.Config.pas`). A
non-empty path selects the Unix listener. The option record
`TUnixSocketOptions` (`server/src/Http2.Server.Config.Unix.pas`) holds the path
and the file mode. The factory holds one record, and each `WithX` call answers
a copy of the factory.

In Unix mode `Host` and `Port` do not apply. The validation does not check the
port. The bind text is `unix:` followed by the path
(`ListenerBindText` in `server/src/Http2.Server.Async.Options.pas`). The
underlying mORMot2 listener reads this text and binds the socket file.

`WithUnixSocketMode(mode)` sets the file mode of the socket file. The default
value of -1 keeps the mode that the umask gives.

`Build` runs the checks of this document before it builds the server object.
The start of the server then binds the socket file on its own thread, as for a
TCP listener (see [lifecycle](lifecycle.md)).

## The path rules

The rule for a path is the same for the server and the client. It lives in
`common/src/Http2.Common.UnixPath.pas`, in the function `UnixPathProblem`. The
function gives one of these texts for a path that is not usable:

| Condition | Problem text |
|---|---|
| the path is empty | the Unix socket path is empty |
| the first byte is not `/` | the Unix socket path is not absolute |
| the path holds a NUL byte | the Unix socket path holds a NUL byte |
| the path is longer than 103 UTF-8 bytes | the Unix socket path is N bytes long; the limit is 103 |

The limit of 103 bytes is below the length of the `sun_path` field on both
macOS and Linux, and the same value applies on both. The problem text never
holds the path itself.

The server option record adds one more rule. The path holds no colon, because
the bind text splits at the last colon. The problem text is `the Unix socket
path holds a colon`.

The mode is checked with the path. A mode outside the range -1 to 511 gives
the text `the Unix socket mode is out of range`. The check applies when no
path is set.

The `Validate` call of the factory collects these texts with the other
problems of the settings (see [configuration](configuration.md)).

## The checks before the bind

`CheckUnixPath` (`server/src/Http2.Server.Unix.Path.pas`) reads the path and
answers one of five states. It never changes the path.

| State | Meaning |
|---|---|
| `upFree` | nothing exists at the path |
| `upStale` | a socket exists and no listener answers it |
| `upNotSocket` | the path names a file that is not a socket |
| `upInUse` | a live listener answers at the path |
| `upUnreadable` | the path cannot be read, or the target has no Unix socket support |

The check reads the file status without following a link. A missing path is
`upFree`. A path that is not a socket is `upNotSocket`. A socket is tested with
connect attempts. Each attempt uses a new socket with a non-blocking connect.
The check makes up to three attempts, with 50 ms between them:

- A connect that succeeds, or that answers `EAGAIN` or `EINPROGRESS`, gives
  `upInUse`.
- A connect that answers `ECONNREFUSED` on every attempt gives `upStale`.
- Any other error gives `upUnreadable`.

The retries exist because a live listener with a full queue refuses new
connects on macOS. A single refusal would then look like a stale socket. A
listener that never accepts is judged stale.

`Build` accepts `upFree` and `upStale`. For the other three states it raises
`EHttpConnectionError` with one of these texts:

- `the Unix socket path names a file that is not a socket`
- `the Unix socket path is in use by a live listener`
- `the Unix socket path cannot be checked`

The check runs after the settings pass `Validate`, and before the server object
is built. A refusal therefore never runs the destructor of a half-built server.

A stale socket is replaced by the bind. The mORMot2 bind removes the file at
the path before it creates the new socket. The checks above prevent the bind
from replacing a file that is not a stale socket.

## The file mode

When the mode is not -1, `THttp2Server.Start` sets the mode with `chmod` after
the bind succeeds (`ApplyUnixSocketMode`, `server/src/Http2.Server.Unix.Path.pas`).
A failed `chmod` raises `EHttpConnectionError` with the text `the Unix socket
mode cannot be set`. The `Start` call then runs the stop path, so the
listener closes and the socket file is removed.

A short window exists between the bind and the `chmod`. The socket file has
the mode of the umask during that window. A private parent directory limits the
window, because only the owner of the directory can reach the path. A mode of
-1 keeps the umask for the whole life of the file.

## Removal on stop and after a crash

The mORMot2 shutdown of the listener removes the socket file that the process
bound. `THttp2Server.Stop` runs the shutdown, so the file is gone when `Stop`
returns. This holds also when a connection is open at the time of the stop.

The server does not remove the file when the process ends without a stop. The
file remains on disk. The next start finds a socket that no listener answers,
so the check gives `upStale` and the bind replaces the file.

## What does not change

- The framing, the flow control, the header compression and the stream
  handling are the same as for TCP.
- The TLS rules are the same. TLS is selected by the factory context. A Unix
  listener without a certificate needs the cleartext option, as for TCP.
- The limits, the timeouts and the queue are the same as for TCP.

## The peer address

Each accepted Unix connection has the remote address `unix:pid=<pid>`. The
pid is the process that opened the connection. The address appears in the
access log and in the events that carry the peer address
(`UnixPeerText`, `server/src/Http2.Server.Unix.Path.pas`).

The pid comes from a platform call:

- On macOS, `getsockopt` with level 0 (`SOL_LOCAL`) and option 2
  (`LOCAL_PEERPID`) gives a 4-byte pid.
- On Linux, `getsockopt` with level 1 (`SOL_SOCKET`) and option 17
  (`SO_PEERCRED`) gives a record of three 32-bit integers. The server reads the
  first integer, the pid.
- On other targets, and when the call fails or gives a pid of zero or less, the
  address is the plain text `unix`.

The server does not read the user id or the group id of the peer.

For a TCP listener, `UnixPeerText` answers an empty text, and the address
text is the one that the TCP peer gives.

## The socket options that do not apply

`ApplySocketOptions` (`server/src/Http2.Server.Async.Socket.pas`) applies the
factory `TSocketOptions` to each accepted socket. For a Unix socket it skips two
steps:

- The TCP no-delay option. The call raises on a Unix socket, so the server
  does not make it.
- The TCP keep-alive options: the keep-alive switch and the idle time, the
  interval and the count. The TCP options do not apply to a Unix socket.

The send buffer size and the receive buffer size still apply to a Unix socket
when they are above zero.

## The reuse-port option

The reuse-port option does not apply to a Unix socket. The validation refuses
the combination with the text `the reuse-port option does not apply to a Unix
socket`.

## Limits

These items are outside the Unix listener. Each one is a fact of the current
design.

- Linux abstract sockets, which have a name that starts with `@` or a NUL byte,
  are not supported. The path rule refuses the NUL byte, and the path must
  start with `/`.
- Peer credentials other than the pid are not read.
- Socket activation is not supported.
- Windows is not a supported target for the Unix listener.
