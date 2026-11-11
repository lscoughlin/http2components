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
