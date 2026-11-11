# C02 client connection division

## Changes

The connection reader and writer thread, its socket adapter, observer event
delivery, and queue state now use separate units. `Http2.Client.Connection`
retains the connection type, stream routing, flow control, and public generic
queue API. `TBlockingQueue<T>` forwards to the isolated state implementation;
`IBlockingQueue<T>` remains declared by the connection unit.

The worker holds a weak class pointer to its connection. Connection shutdown
joins and frees the worker before the connection frees its observer state or
lock. The worker calls narrow connection accessors for operations that use
private fields. The `Thread` property uses `TThread`; the worker class and
constructor are available from `Http2.Client.Connection.Thread`.

## Validation

`build:client` passed on FPC 3.2.4 for macOS arm64, with the pinned mORMot2
checkout and OpenSSL 3 library path. `Http2.Client.Connection` has 995 lines.
Its worker, observer, and queue implementation units have 369, 228, and 233
lines. `source:check` confirms these connection units meet the size rule; it
still reports other oversized client and test units owned by C02, C03, C04,
and M08.
