# C02 client connection and stream divisions

## Changes

The connection reader and writer, socket adapter, observer event delivery, and
queue state use separate units. `Http2.Client.Connection` retains the connection
type, stream routing, flow control, the public generic queue API, and the
protected `TConnectionThread` worker methods. `TConnectionThread` retains its
constructor and its typed `Thread` property. Its worker uses a weak connection
pointer. Shutdown joins the worker before connection state is released. A
suspended worker is terminated and started before the thread destructor waits;
the worker checks termination before it writes the preface.

The lease send operations use `Http2.Client.Stream.Send`. Exchange notification
and stream error creation use `Http2.Client.Stream.Exchange`. The Stream facade
retains its public types and methods. Send credit waits release the lease wait
lock while they block, then reacquire it in a `finally` block. The connection
settings path releases the encoder lock on every exit path. The HTTP/1 body
framing enum values remain exported by the facade.

## Validation

`build:client` passed with FPC 3.2.4, the pinned mORMot2 checkout, and OpenSSL
3.5.9. A standalone API probe constructs and frees a suspended
`TConnectionThread` under a 10-second process limit. The probe is retained as
`test/api/Http2.Client.Connection.Lifetime.ApiProbe.pas`. The constructor and
free probe passed. The source sizes are 998 lines for Connection and 999 lines
for Stream. WebSocket divisions remain in C03.

Parent review keeps the atomic end-notification guard before error creation,
as in the original stream method. This prevents repeated delivery attempts
from reading connection error state after the first notification. The helper
only delivers the callback and releases the temporary exception. The public
WebSocket constants now refer to the protocol constants instead of repeating
the values. The retained thread constructor/free probe has the required
header and runs with the API probes. Six probes and all 16 API cases pass
in bin/review-c02-c03-api.log.

The final C03 review retained TWsReaderThread in its original public unit.
The HTTP/1.1 opening handshake, session contracts, and notification helper
are separate units. The temporary ReaderThread helper was removed. All
owned production files are below 1000 lines. The source agent reported
build and constructor/free checks through tool output; it created no durable
raw log files. Parent API logs provide retained probe evidence. The source
worktree was clean at acb98cc and was removed after review and merge.
