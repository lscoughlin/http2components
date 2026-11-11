# C02 client connection queue division

## Changes

The bounded generic queue contract and implementation now live in
`Http2.Client.Connection.Queue`. The connection unit uses concrete
`IFrameQueue` and `TFrameQueue` aliases for its HTTP/2 frame queues. The queue
implementation and wake behavior are unchanged.

The original queue is generic. FPC 3.2.4 rejects aliases of generic type
constructors, so the connection facade exposes the frame specialization.
Other generic queue consumers can use the queue unit directly.

## Validation

The direct FPC client build passed on FPC 3.2.4 for macOS arm64, with
`src/client` on the unit path and pinned dependencies. No queue tests were
run. C02 remains open.
