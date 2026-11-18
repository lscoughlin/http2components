---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, limits, token-bucket, reset-flood, abuse
notes:
  - This document describes the token buckets that bound the work a peer may ask for.
  - Imported from http2server/doc/design/server/limits.md at the source commit recorded in the source inventory.
scope: The reason for the limit, the clock, the bucket options, the bucket, the limit set and the defaults.
primary_types:
  - TTokenBucket
  - TTokenBucketOptions
  - TConnectionLimits
  - IMonotonicClock
db_tables: []
related_docs:
  - doc/design/server/configuration.md
  - doc/design/server/admission.md
  - doc/design/server/connection.md
invariants:
  - A bucket never holds more tokens than its capacity.
  - A bucket tripped sends GOAWAY with ENHANCE_YOUR_CALM.
  - Every bucket reads the clock through one interface.
---

# Per-connection abuse limits

The server limits client actions per connection with a token bucket. A
bucket holds tokens. A client action takes tokens from the bucket. An empty
bucket tells the caller that the connection must close. The caller sends
`GOAWAY` with `ENHANCE_YOUR_CALM` and closes the connection after the open
streams drain.

## Why the limit exists

Rapid Reset (CVE-2023-44487) lets a client cancel streams at a high rate. A
cancel frees the stream slot, but a handler can keep running. RFC 9113 §10.5
lists other flood techniques: tiny `WINDOW_UPDATE` increments, and `PING` and
`SETTINGS` frames that each need an answer. CERT VU#421644 covers unlimited
`CONTINUATION` frames. One bucket class bounds every one of these actions.

## The clock

A bucket refills from an `IMonotonicClock`
(`server/src/Http2.Server.Limits.pas`). The interface has one method, `NowMs`,
which returns the milliseconds since an unspecified start point.

`TMonotonicClock` is the real implementation
(`server/src/Http2.Server.Limits.pas`). It returns `GetTickCount64`. The value
never decreases, and it wraps only after a very long run time.

`TManualMonotonicClock` is the test implementation
(`server/src/Http2.Server.Limits.pas`). Its value moves only when `Advance` or
`SetNowMs` moves it. A test controls every refill, so a test of a long idle
time needs no real wait.

## The bucket options

`TTokenBucketOptions` is a fluent record
(`server/src/Http2.Server.Limits.pas`). `Create` returns a zeroed record
(`server/src/Http2.Server.Limits.pas`). Each `WithX` method returns a new record
with one field changed. The fields are:

| Field | Meaning |
|---|---|
| `Capacity` | the greatest number of tokens the bucket holds |
| `RefillPerSecond` | the tokens added each second, possibly fractional |
| `CostBeforeDispatch` | the token cost of a reset before a handler runs |
| `CostAfterDispatch` | the token cost of a reset after a handler runs |

`CostBeforeDispatch` and `CostAfterDispatch` apply to the reset bucket. A
reset after dispatch costs more than a reset before it, because the handler
keeps running after the cancel. Every other bucket takes its cost from the
caller of `TryTake`.

The bounds that `Validate` accepts are constants of the unit. The default of
every option comes from the options record.
The configuration unit holds the defaults.

## The bucket

`TTokenBucket` is a class with one method, `TryTake`
(`server/src/Http2.Server.Limits.pas`). The bucket starts full. `TryTake`
refills from the clock (`server/src/Http2.Server.Limits.pas`), then takes
`ACost` tokens when the bucket holds enough. The method returns `True` on a
successful take and `False` on an empty bucket.

The refill has two guards. A repeated or lower clock value adds no token, so
time never runs backwards. A long idle time cannot raise the tokens above
the capacity (`server/src/Http2.Server.Limits.pas`).

The trip state is sticky. The first empty-bucket answer sets `Tripped`, and
every later `TryTake` returns `False` without a refill
(`server/src/Http2.Server.Limits.pas`). The connection is closing, so a later token request cannot succeed.

`TTokenBucket` has no lock. The caller holds the connection lock. Every call
of one bucket runs on one thread at a time.

## The limit set

`TConnectionLimits` holds the set of buckets of one connection
(`server/src/Http2.Server.Limits.pas`). The set holds the reset bucket and one
bucket for each control frame kind. `TLimitKind` names the kinds:
`lkReset`, `lkPing`, `lkSettings`, `lkEmptyData`, `lkWindowUpdate` and
`lkContinuation` (`server/src/Http2.Server.Limits.pas`).

Each control kind carries its own bucket. `CreateByKind` names the options
of a kind whose legitimate rate differs from the fallback
(`server/src/Http2.Server.Limits.pas`). `ControlOptionsOf` reads back the
options in force for one kind. The caller of `CreateByKind` names only the
kinds that it distinguishes, and every other kind keeps the fallback
options.

A shared bucket of one capacity does not serve these kinds. The legitimate
rates are far apart. A peer sends one `WINDOW_UPDATE` frame for each window
that it refills, so a large body needs thousands of them: a measurement of
a 100 MB body sent 6102 such frames, at a steady rate of 2450 frames in
one second ([validation](../../verification/source/server/validation.md)). A `CONTINUATION` frame,
by contrast, follows only a header block that already passed the frame
size. One shared bucket of the least capacity closes a healthy connection
that streams a large body.

`Charge(AKind, ACost)` sends a cost to the bucket of `AKind`
(`server/src/Http2.Server.Limits.pas`). The reset bucket has two costs, so
`ChargeReset(AAfterDispatch)` selects the cost that matches the dispatch
state (`server/src/Http2.Server.Limits.pas`).

The trip state of the set is sticky in the same way as the bucket. The first
empty-bucket answer sets `Tripped`, and every later `Charge` returns `False`
for every kind.

The set raises `OnTrip` once, when a bucket trips, with the kind that
tripped. The server observer receives the event and counts it. The set
holds no observer reference; the connection core assigns the event.

## The caller

The connection core owns one `TConnectionLimits` per connection. It charges
the reset bucket on each client `RST_STREAM` frame, and it charges the
control bucket on each limited control frame. A `False` answer starts the
close sequence. The observer receives the bucket trip, and then the
`GOAWAY` sent event.

The connection core also charges the reset bucket with `CostAfterDispatch`
for each `RST_STREAM` that the server sends for a fault of the peer. These
resets are a refused stream over the stream limit, a request that fails
validation, and a body that passes its declared content-length. A refusal
of a HEADERS frame that arrives after a `GOAWAY` is not charged, because the
peer sent the frame before it saw the `GOAWAY`.

## Bounds of the options

`THttp2ServerFactory.Validate` refuses an option that is outside these
bounds. The bounds are constants of `server/src/Http2.Server.Limits.pas`.

| Option | Accepted values | Default |
|---|---|---|
| `MaxHeaderListSize` | 1024 to 1073741823 | 65536 |
| `HeaderTableSize` | 0 to 16777216 | 4096 |
| `MaxContinuationFrames` | 1 to 1024 | 16 |
| `MaxConcurrentStreams` | 1 to 100000 | 100 |

The cost of each reset bucket field, `CostBeforeDispatch` and
`CostAfterDispatch`, must be 1 or more. A cost of 0 never empties the bucket,
so the rapid-reset limit would be off.

The initial windows must be 1 or more. A window of 1 gives a
`WINDOW_UPDATE` threshold of 1. The server never sends a `WINDOW_UPDATE` with
an increment of 0.

## Three different limits

Three families of limits bound different parts of the server. The table tells
the families apart.

| Family | What it bounds | The answer past the bound |
|---|---|---|
| token buckets (rate) | the rate of resets and control frames per connection, and of control frames and messages per WebSocket session | GOAWAY with `ENHANCE_YOUR_CALM` on HTTP/2 (RFC 9113 section 10.5); Close 1008 on a WebSocket session |
| per-connection caps (streams, frames, bytes) | the open streams, the accepted streams over the life of the connection, the queued outbound frames and the queued octets | `REFUSED_STREAM` past the concurrent limit with the connection open; GOAWAY with `NO_ERROR` at the stream cap; GOAWAY with `ENHANCE_YOUR_CALM` past an outbound cap |
| server caps (connections) | the open connections of the whole server | a refused socket with no reply at accept |

Three limits bound different parts of a connection. The concurrent stream
limit bounds the streams that are open at one time. The stream cap
(`MaxStreamsPerConnection`) counts every accepted stream over the life of the
connection and retires it at the cap. The token buckets bound the rate of
control actions and close the connection with `ENHANCE_YOUR_CALM` when a
bucket trips.

The three answers differ as well. Past the concurrent limit, a new stream is
refused with `REFUSED_STREAM` and the connection stays open. At the stream
cap, the server sends GOAWAY with `NO_ERROR` (RFC 9113 section 6.8) and
refuses later streams the same way. A refused stream never ran, so a client
retries it on a new connection (RFC 9113 sections 5.1.2 and 8.7). On
HTTP/1.1 the cap answers `Connection: close` instead (see
[connection](connection.md) and [http1](http1.md)).

RFC 9113 is the source for the GOAWAY and refusal rules. It was checked on
2026-11-06 at https://www.rfc-editor.org/info/rfc9113. The plain-text copy is
doc/references/rfc9113.txt.

## The outbound frame caps

Two caps bound the answers that wait for the peer, beside the buckets
that bound the rate of the questions. `MaxOutboundFrames` bounds every
queued outbound frame, and `MaxOutboundControlFrames` bounds the queued
`PING`, `SETTINGS` and `RST_STREAM` frames. A peer that forces answers
without reading trips a cap, and the connection ends with a GOAWAY of
`ENHANCE_YOUR_CALM` (RFC 9113 section 10.5). The count falls as the
frames leave the socket, so a large response to a steady reader never
trips a cap. The caps live in `TServerLimits` with the defaults 10000
and 1000, and 0 turns a cap off. The budget and the batch release rule
are in [connection](connection.md).

## WebSocket buckets

A session has two token buckets of the class in this unit. The control bucket
counts the Ping and Pong frames that arrive, and the message bucket counts the data
messages. An empty bucket closes the session with 1008 and raises
`seWsBucketTripped`. The capacities and the refill rates are in `TWsOptions` (see
[websocket](websocket.md)). A Close frame costs no token.

## WebSocket message sizes

Four settings of `TWsOptions` bound the memory that one inbound message can hold (see
[websocket](websocket.md)).

| Setting | Default | What it bounds |
|---|---|---|
| `MaxMessageSize` | 1048576 | the whole inbound message, over all its fragments; a message over it closes the session with 1009 |
| `MaxFragments` | 1024 | the frames of one message; with the default `MaxFrameSize` it caps a streamed message at 64 MiB |
| `InlineLimit` | 65536 | the octets that the reader keeps in memory before it streams the message to the handler |
| `InboundPipeBytes` | 1048576 | the unread octets of a streamed message on a channel that returns no credit; a push over it closes the session with 1009; at least `InlineLimit` plus `MaxFrameSize` |

`MaxMessageSize` keeps its meaning for a streamed message: it limits the whole message,
not the part that waits in memory. A program that streams a message larger than the
default raises `MaxMessageSize`, and it raises `MaxFragments` as well when the message
needs more than 1024 frames. The memory that one streamed message holds is at most
`InboundPipeBytes` on a channel that returns no credit (an HTTP/1.1 upgrade, a unix
socket), and at most the stream window plus `InlineLimit` on HTTP/2. `InboundStallMs`
bounds the time that a read of a streamed message waits for an octet.

A message that a producer writes with `SendStream` has different limits. `MaxMessageSize`
limits one chunk of the producer, not the whole message, as it does for a pulled writer.
The producer stream decides the size of its chunks (the argument `AChunkBytes` of
`BodyWriterFromStream`, 16384 octets by default), so a chunk size above `MaxMessageSize`
fails the session with 1011 at the first chunk. `MaxFragments` and the other inbound limits
do not apply. The memory of the message is one chunk that the producer stream holds, one
chunk that it holds back, and the encoded fragment that waits for the channel. A full
channel blocks the `Write` of the producer, so a slow peer does not make the message grow
in memory. The time that a producer waits has no limit: it holds one streaming pool thread
(see [threading](threading.md)), and the end of the session is the only event that stops it
from the outside.

The server-wide budget `MaxWsQueuedBytes` (default 128 MiB) charges `InboundPipeBytes` for
each streamed message from its start until its handler returns, on every channel kind,
because the length of the message is not known at its start. With the defaults about 128
streamed messages can run at the same time. The 129th closes its session with 1008 and the
reason `the queued bytes of the server are full`. A program with more concurrent streamed
messages raises `MaxWsQueuedBytes` or lowers `InboundPipeBytes`.

## Handshake refusals on HTTP/2

A WebSocket handshake that fails a check of `AcceptWebSocket` is answered with an
ordinary response on its stream (as described in [websocket](websocket.md)). The answer is not a
reset, so it costs no token of the reset bucket. The detach limit and the queue of the
handler pool bound the number of such streams in flight. A request that the validator
refuses is a stream error and costs a token as any other reset does.

## HTTP/1.1 rejections

The HTTP/1.1 core uses no token bucket. A request that breaks a rule of the guard
is answered once and the connection closes, so a sender that floods defective
requests pays one connection for each rejection, and the server holds no state
for the next one. The limits of the parser are in the record `THttp11Limits` (see
[http1](http1.md)).

The field rules of a request are strict. White space before the colon, an obsolete line
fold and a `Transfer-Encoding` whose last coding is not `chunked` each give 400 and close
the connection. A front proxy that unfolds a line in another way would open a smuggling
path, so the server does not unfold.

## The stall timeout of an event stream

An event stream whose outbound queue stays full is a slow reader. The setting
`SseStallTimeoutMs` bounds the time. The server closes a stream that stays full
for that time, with an abort (as described in [sse](sse.md)). The check is a timer of the
streaming pool and uses no token bucket.

## The body budget of HTTP/1.1

The option `MaxBodyBytesInFlight` of `TServerLimits` bounds the body octets that
all HTTP/1.1 exchanges of one server hold together. A body is held until the
handler reads it. The default is 256 MiB. The value 0 turns the budget off, and
a non-zero value is at least 1 MiB.

The budget is the interface `IBodyBudget` (`server/src/Http2.Server.Http1.BodyBudget.pas`).
The handler pool creates it from the factory. An exchange charges each body octet
that it buffers. The exchange releases the octets when the handler reads them, when the
exchange is cancelled or finished, and when the exchange is freed. The count is
exact. The lock of the budget makes the check and the add one step, and the
exchange lock is taken before the budget lock.

When a body does not fit under the budget, the exchange drops the body, and the
server answers 503 and closes the connection. The core sends the answer after it
leaves its own lock, so the budget and the exchange never call the core while
they hold a lock.

HTTP/2 has no budget of this kind. The server returns the flow-control credit of
a stream only when the handler reads. So the unread body of one stream is bounded
by the stream window, and the unread bodies of all open streams are bounded by
the window times the number of open streams.

## The handler time limit

The option `MaxHandlerTimeMs` of `TServerLimits` bounds the time of one handler
call, in milliseconds. The default is 0, which turns the limit off. A negative
value is not valid. The time runs from the start of the handler call.

When a handler passes the limit, the server answers 503 with an empty body if no
response head went out. The server then cancels the handler side of the stream.
When a head already went out, the server resets the stream on HTTP/2 and closes
the connection on HTTP/1.1. A handler thread is not killed. A handler that never
checks for cancel keeps its thread until it returns. The server counts these
handlers and gives the count to the observer with each timeout. The full
description is in [admission](admission.md).

When the limit is set, it also applies to a WebSocket handler that runs in the
handler thread. On HTTP/2, the checks and the detach of the handshake run in
that call, while the session runs on the streaming pool. A detached exchange
is not subject to the handler limit. When the limit passes while the handler
is still in its call after the detach, the server sends no 503, resets no
stream and closes no connection. The handler call and the session continue.
A handler that returns before the limit is not affected.

The same rule applies on HTTP/1.1 to an upgrade handler that detached its
exchange. The server skips the expiry of the detached exchange, so the
handshake still answers 101 after the limit, and the connection stays open.
An exchange that is not detached keeps the rule of the first paragraphs. The
handler that is still in its call at the limit gets a 503 when no head went
out, and the connection closes when a head went out.

The count of stuck handlers includes a detached handler that is still in its
call past the limit, until the call returns. The server sends no timeout
event for that handler.

## The default limits

`THttp2ServerFactory.Create` sets the default of every bucket
(`server/src/Http2.Server.Config.pas`). The reset bucket holds 1000 tokens, with
a refill of 100 tokens a second, a cost of one token before dispatch and
five tokens after it (`server/src/Http2.Server.Config.pas`).

The `SETTINGS`, `empty DATA` and `CONTINUATION` buckets each hold 100 tokens,
with a refill of 10 tokens a second (`server/src/Http2.Server.Config.pas` and `454-456`). The
`PING` bucket holds the same values (`server/src/Http2.Server.Config.pas`). Each
of these kinds is a flood signal with no legitimate high rate, so a small
bucket is the correct default.

The `WINDOW_UPDATE` bucket holds 10000 tokens, with a refill of 4000 tokens
a second (`server/src/Http2.Server.Config.pas`). The capacity admits a whole
burst of a few megabytes, and the refill rate sits above the measured
rate of 2450 frames a second with headroom. A small bucket of 100 tokens
closed a healthy connection on a body of less than two megabytes: 107
control frames arrived before the body ended. The measurement is in
[validation](../../verification/source/server/validation.md).

The queue depth of 64 (`server/src/Http2.Server.Config.pas`) and the IO thread
count of 4 (`server/src/Http2.Server.Config.pas`) come from the same seam
measurement. The listener, stream and timeout values are the chosen protocol
and operational bounds: RFC 9113 section 6.5.2 sets 100 concurrent streams as
the customary value, 16384 is the frame size that RFC 9113 section 4.2
recommends, and a timeout bounds a stalled peer.

## RFC references

- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html), checked 2026-11-11.
