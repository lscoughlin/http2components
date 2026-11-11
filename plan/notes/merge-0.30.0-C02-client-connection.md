# C02 client connection division

## Changes

The connection reader and writer thread, its socket adapter, observer event
delivery, and queue state now use separate units. `Http2.Client.Connection`
retains the connection type, stream routing, flow control, and public generic
queue API. `TBlockingQueue<T>` forwards to the isolated state implementation;
`IBlockingQueue<T>` remains declared by the connection unit.

`TConnectionThread` and the `Thread: TConnectionThread` property remain in
`Http2.Client.Connection`. The thread wrapper runs the moved worker object.
The worker holds a weak class pointer to its connection. Connection shutdown
joins and frees the worker before the connection frees its observer state or
lock. The worker uses narrow connection accessors where it needs internal
state.

## Validation

`build:client` passed on FPC 3.2.4 for macOS arm64, with the pinned mORMot2
checkout and OpenSSL 3 library path. An FPC compile probe confirmed the public
`TConnectionThread.Create`, typed `Thread` property, generic queue class, and
queue interface. `Http2.Client.Connection` has 994 lines.
Its worker, observer, and queue implementation units have 369, 228, and 233
lines. `source:check` confirms these connection units meet the size rule; it
still reports other oversized client and test units owned by C02, C03, C04,
and M08.
