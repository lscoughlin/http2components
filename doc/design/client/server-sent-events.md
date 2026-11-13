---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
title: "Server-Sent Events"
aliases:
  - "server-sent-events"
  - "sse"
  - "event-stream"
tags:
  - http2client
  - design
  - api
  - protocol
status: done
up: "[http2components](../../README.md)"
related:
  - "[messages](messages.md)"
  - "[client-api](client-api.md)"
  - "[errors-redirects](errors-redirects.md)"
  - "[transport](transport.md)"
  - "[fallback](fallback.md)"
  - "[testing-observability](testing-observability.md)"
  - "[request-observability](request-observability.md)"
  - "[open-questions](open-questions.md)"
updated: 2026-10-24
notes:
  - Imported from http2client/doc/design/server-sent-events.md at the source commit recorded in the source inventory.
---

# Server-Sent Events

This note describes **Server-Sent Events** (SSE) support. SSE is a
one-way, long-lived HTTP response: the server holds the response body open
and pushes `text/event-stream` events until the client disconnects or the
server closes the stream.

SSE runs over the ordinary client transport. Three pieces sit on top of it: a
**parser**, a **source/loop layer above `IHttpBodyStream`**, and an
**inactivity timeout** distinct from the per-request header timeout. The last
is load-bearing. A body read without a separate deadline raises `EHttpTimeout`
after the lease's `FTimeoutMs` of silence (default `30000`, the header
timeout), and a live SSE stream is quiet between events, so a stream idle for
more than the header timeout would fail.

## Scope

SSE is a **reader layer**, not a transport mode:

| Layer | Unit | Role in SSE |
| --- | --- | --- |
| Socket / TLS | `Http2.Client.Tls` | unchanged |
| Connection + thread | `Http2.Client.Connection` | unchanged; supplies DATA frames and keeps the receive window open |
| Stream lease / body | `Http2.Client.Stream` | body-read inactivity timeout + cancellation polling |
| Response | `Http2.Client.Messages` (`IHttpResponse`, `IHttpBodyStream`) | the seam SSE reads from |
| Codec | `Http2.Client` (HTTP/2), `Http2.Client.Http1` (fallback) | HTTP/2 fully supported; HTTP/1.1 best-effort (as described in below) |
| **SSE** | `Http2.Client.Sse` | parser, source, reconnect loop |

SSE is codec-agnostic on purpose: it consumes `IHttpResponse.Body` and
therefore inherits HTTP/2 multiplexing (an SSE stream is one HTTP/2 stream
among others on a shared connection) and the HTTP/1.1 fallback (where the
stream occupies the connection for its lifetime — see "Connection
lifetime").

**Supported scope.** The parser, source and reconnect loop
are codec-agnostic and run over either codec. The *transport guarantees*
differ, and the difference is stated rather than papered over:

- **HTTP/2 — full support.** A blocked body read honours the per-request
  body deadline (including "wait indefinitely"), polls the request's
  `ICancellationToken` on a 20 ms slice, and resets the stream with
  `RST_STREAM(CANCEL)` on a caller cancel. Receive window credit is returned
  on frame arrival, so an idle stream is never reaped and never stalls the
  connection.
- **HTTP/1.1 fallback — best-effort.** `THttp1Connection.Create` sets
  `FSocket.ReadTimeoutMs := ATimeoutMs` from the *header* timeout. The body
  reader waits for each body read under the body-read timeout of the request
  (`SseMaxIdleTimeMs`), as HTTP/2 does. `THttp1BodyStream.Read` has no token and
  no cancel path. So over the fallback an idle SSE stream ends after
  `SseMaxIdleTimeMs` and cannot be cancelled mid-read; the parser, event
  delivery and reconnect/resume still work. The fallback is off by default
  and is a single-connection codec, so an event stream monopolizes it for
  its lifetime.

An SSE request is an ordinary GET. It is **not** special-cased in the
transport; the caller builds it with `accept: text/event-stream` and (when
resuming) `last-event-id`.

## Request

An SSE request is `GET` with:

| Header | Value | Required |
| --- | --- | --- |
| `accept` | `text/event-stream` | yes |
| `cache-control` | `no-store` | recommended; stops an intermediary caching the stream |
| `last-event-id` | the last observed id | only on resume (as described in "Reconnection") |
| `accept-encoding` | `identity` | **yes — as described in "Content coding"** |

`Http2.Common.Headers` carries `HeaderAccept`, `HeaderCacheControl`,
`HeaderAcceptEncoding` and `HeaderLastEventId = 'last-event-id'`.

## Response validation

A response is a valid event stream only when the status is `200` and the
`content-type` is `text/event-stream` (case-insensitive media type, optional
parameters allowed). The rules mirror the other readers:

- A non-`200` status raises; the body is the error payload, so the source
  drains at most a bounded prefix for the message and never treats it as
  events.
- A missing or non-`text/event-stream` content-type raises
  `EHttpProtocolError` with `ecProtocolError`.
- A declared `charset` parameter other than `utf-8` raises. The event stream
  is UTF-8 by definition; a declared non-UTF-8 charset is a protocol error,
  not something to transcode.
- A `text/event-stream` body is never buffered whole: the source reads
  incrementally and yields each event as its terminating blank line arrives.

## Wire format and parser

The format is the WHATWG event-stream grammar (HTML Living Standard,
"Interpreting an event stream"). The parser is a **pure, incremental,
byte-in/event-out class** — `TSseEventParser` — with no socket or lease
dependency, so it can be tested by slicing an input at every byte boundary
(as described in "Testing"). It is the SSE analogue of `THpackCodec` in
[protocol](protocol.md): a pure layer the rest of the stack composes.

Grammar, exactly:

| Rule | Behaviour |
| --- | --- |
| Line terminators | CRLF, bare CR, **and** bare LF all end a line. |
| BOM | One leading U+FEFF at stream start is stripped; a later BOM is data. |
| Field line | `field: value` — the field ends at the **first** `:`. |
| Leading space | One single space after the `:` is stripped from the value. |
| No colon | A line with no `:` is a field name with an empty value. |
| Comment | A line whose first character is `:` is ignored (valid keep-alive). |
| `data` | Append the value plus a single `\n` to the data buffer. |
| `event` | The value replaces the event-type buffer. |
| `id` | A value with no NUL replaces the last-event-ID buffer. A value with NUL has no effect. |
| `retry` | An ASCII-digit value sets the reconnection time. Other values have no effect. |
| Other fields | Ignored. |
| End of stream | A partial (unterminated) event is **discarded**, never dispatched: the event fires only on its blank line. A stream that is cut mid-event therefore delivers no half event. |
| Blank line | **Dispatch**: an empty data buffer causes a reset with no event. Otherwise one trailing `\n` is removed, the event type is the buffer or `message` when empty, and the event uses `lastEventId`; the data and event-type buffers are then reset. |

The dispatch condition is the subtle one: `id:`, `retry:`, and `event:`
lines **update state** but must not, by themselves, fire a message event.
Only a blank line with a non-empty data buffer dispatches. `lastEventId`
survives cluster boundaries; the data and event-type buffers do not.

`retry` sets a reconnection **delay**, not a timeout: it is the client's
wait before reconnecting after the stream ends.

The parser's public shape:

```pascal
// client/src/Http2.Client.Sse.pas
type
  TSseEvent = record
    /// event type; 'message' when the stream sent no event: field
    EventType: string;
    /// the data payload with the single trailing newline removed
    Data: string;
    /// the id in force at dispatch time ('' when none was ever set)
    Id: string;
    /// the retry: value in force, in ms (0 = none seen)
    RetryMs: Integer;
  end;

  TSseEventParser = class
  public
    /// feed one chunk; AEvents receives zero or more completed events
    procedure Feed(const AChunk: TBytes; const AEvents: TList<TSseEvent>); overload;
    procedure Feed(const AText: string; const AEvents: TList<TSseEvent>); overload;
    /// the id in force after the last fed byte (survives dispatch)
    function LastEventId: string;
    /// the retry delay in force, in ms (0 = never set)
    function RetryMs: Integer;
    /// abandon any partial line and buffered data (stream boundary)
    procedure Reset;
  end;
```

The parser is UTF-8: a `TSseEvent.Data` is a UTF-8 string. It performs no
transcoding, matching `ReadText`'s byte-verbatim rule in [messages](messages.md). A
multi-byte sequence split across two `Feed` calls is held until complete.

## Timeouts and liveness

**This is the reason SSE needs a transport-level body deadline.** A body read blocks on the lease's inbound frame queue with a deadline.
`TStreamLease.FTimeoutMs` is set from the **header** timeout in
`THttpConnection.AcquireCancellable` (`Lease.TimeoutMs := ATimeoutMs`) and
defaults to `30000`. For a normal request that is correct — the whole body is
expected promptly. For SSE it would be wrong: between events the stream is
idle by design, so the 30 s header deadline would abort a healthy stream.

SSE therefore uses a **body read timeout separate from the header
timeout**:

| Setting | Applies to | Default | `0` means |
| --- | --- | --- | --- |
| `HeaderTimeoutMs` | until response HEADERS/status line | `30000` | `0` = default |
| `IdleTimeoutMs` | reaping an unused pooled connection | `60000` | `0` = never reap |
| **`BodyReadTimeoutMs`** | each blocked body read on an SSE source | unset = fall back to `HeaderTimeoutMs`; SSE sets it to `0` | **`0` = wait indefinitely** |

The default for an SSE source is **wait indefinitely** (`0`): an abrupt
"no event for N seconds" abort is a client policy the caller should opt into,
not a library default that silently truncates streams. A caller who wants a
liveness bound sets `WithSseReadTimeout(ms)` on the request; a `0` value is
explicit and documented.

Independent liveness signals still work and are preferred:

- A **comment line** (`: keep-alive`) is a valid server heartbeat. It
  completes no event but it **does** deliver bytes, so it resets the
  inactivity clock. A server that emits `:` every 15 s keeps the stream alive
  with no client-side timeout at all.
- A server may also send `retry:`; that is the reconnect delay, not a
  liveness bound.

`TStreamLease` therefore carries a **body read timeout**, set from
`THttpRequest.WithSseReadTimeout` and threaded to the lease through
`TStreamRequest.WithBodyReadTimeout`. It is a separate field from
`FTimeoutMs` so header waiting and body waiting can differ, and
`TStreamRequest.BodyReadTimeoutSet` distinguishes "no opinion, keep the
header-timeout deadline" from "explicitly wait indefinitely".

## Size limits and idle time

The client options hold four SSE limits. They are read from the
`TClientSecurityOptions` record that the client was built with. An `IHttpClientOptions`
client reports the record, and the reconnect loop reads it when it opens a stream.
A client that does not implement `IHttpClientOptions` uses the defaults and keeps
the `WithSseReadTimeout(0)` deadline of `SseRequest`.

| Option | Limits | Default | Source of the default | `0` means | Error |
| --- | --- | --- | --- | --- | --- |
| `SseMaxLineBytes` | one line, without its line break | 32 MiB | the line limit of `openai-go` (`packages/ssestream/ssestream.go`) | no limit | `EHttpSseTooLarge` |
| `SseMaxEventBytes` | one event: the `data` values and one line break for each `data:` line | 64 MiB | no reference client sets an event limit; the value is larger than the line limit, so it still stops an endless event | no limit | `EHttpSseTooLarge` |
| `SseMaxIdleTimeMs` | the time with no byte from the server, comment lines included | 600000 ms (10 minutes) | the timeout of `openai-python` (`src/openai/_constants.py`) | wait indefinitely | `EHttpSseIdleTimeout` |
| `SseMaxRetryMs` | the cap on a `retry:` value from the server | 600000 ms | no reference client is cited for this value | not allowed (the value must be 1 or more) | not an error: the value is cut |

The official OpenAI clients are the reference for the defaults. The Python and
Node clients set no line or event limit (`_streaming.py` and `streaming.ts`). A default of 0 turns off a size
limit, which matches those clients.

**Line and event limits.** The parser counts the bytes of the line that it
assembles. A line that passes `SseMaxLineBytes` stops the stream at once. The
parser counts the bytes of the event that it assembles in the same way. An event
that passes `SseMaxEventBytes` stops the stream at once. Both errors reach the
caller from the `ReadEvent` call that found the excess. The reconnect loop does
not catch them, so they reach the caller.

**Retry cap.** The parser cuts a `retry:` value to `SseMaxRetryMs` before the
reconnect loop stores it. A value that is too large for an `Integer` is also cut.

**Idle time.** On HTTP/2, the reconnect loop opens each stream with the body-read
deadline set to `SseMaxIdleTimeMs`. Each read waits for the next byte. A comment
line is a byte, so a keep-alive comment resets the deadline. When the deadline
passes, the body read raises `EHttpTimeout`, and the source raises
`EHttpSseIdleTimeout`. The reconnect loop does not retry this error. The caller
decides whether to open a new stream. The idle time is the bound of the body
read. It does not bound the wait for the response headers, which keep the header
timeout.

**HTTP/1.1 fallback.** The fallback honors the per-request body-read deadline in
the same way as HTTP/2. When the response head is complete, the body reader takes
the body-read timeout of the request. Each body read that waits for the peer waits
at most that time. The socket read timeout returns to its value after each read.
A silent fallback stream therefore ends with an `EHttpTimeout` from the socket,
and the source maps that error to `EHttpSseIdleTimeout`. A request without a
body-read timeout keeps the socket read timeout (the header timeout) as the bound
of each body read.

A body read that times out in the middle of a chunk loses no bytes. The bytes
that the reader already holds stay in its buffer, and the next read continues at
the same position.

## Cancellation

A blocked body read observes the request's `ICancellationToken`. The
header-wait loop (`THttpConnection.AcquireCancellable`,
`cCancelPollSliceMs = 20`) and the body read share one token type and one
slice length, so "cancelled" means the same thing at both points of an
exchange.

- `ICancellationToken`/`TCancellationToken` live in `client/src/Http2.Client.Stream.pas`,
  so the lease's body read polls the token directly. `Http2.Client`
  re-exports them.
- `TStreamLease.ReadBody` calls `WaitForBodyFrame`, which honours the
  request's body-read deadline and, when a token is present, polls it on the
  `cReadCancelPollSliceMs = 20` slice.
- On a cancel the lease posts `RST_STREAM(CANCEL)`, releases the lease, and
  raises `EHttpStreamError('body read cancelled', StreamId, ecCancel)`. The
  stream is reset rather than orphaned, the same rule [errors-redirects](errors-redirects.md)
  applies to a cancelled `Send`.

A caller's `Cancel` therefore unblocks a parked SSE read and half-closes the
stream; `TSseReconnectLoop` stops when the source is closed or cancelled.

During an HTTP/2 header or body wait, the lease releases the pooled
connection lock. A quiet SSE stream therefore does not prevent another
stream on the same connection from receiving its response. The lock is
held again when a caller processes a frame. Shared HPACK decoding occurs
on the connection reader thread in wire order, before stream dispatch. Cancellation closes only the affected stream; other streams remain
usable. HTTP/1.1 keeps the one-request-per-connection restriction below.

## Flow control on a long-lived stream

A slow or paused SSE reader must not starve the connection. The receive
window is replenished by the connection, not by the application read:
`TConnection.TrackReceivedData` credits the connection window and the
per-stream window as each DATA frame arrives, and emits `WINDOW_UPDATE` in
`cWindowUpdateBatchSize = 32768`-byte batches. Because the credit is issued on frame
arrival rather than on consumption, a draining SSE reader keeps the window
open and the stream does not stall.

The bound: the peer may have at most one batch of
unacknowledged bytes in flight per window before a `WINDOW_UPDATE` is due,
and the lease's `FBodyPending` holds at most the frames the parser has not
consumed yet. A slow-consumer test asserts the cadence: it feeds a large SSE body while
reading slowly and confirms `WINDOW_UPDATE` still flows and the stream never
deadlocks.

## Connection lifetime and pool interaction

- An open SSE lease counts as **one active stream**. The pool's idle reaper
  skips a connection with `ActiveStreams > 0`, so an SSE stream is never reaped while it
  is open — correct, but it also means the stream **occupies one slot of
  `MaxStreamsPerConnection` for its whole life**, which can be hours.
- Over **HTTP/2** that is one stream among many; the connection is shared.
- Over the **HTTP/1.1 fallback** the stream limit is 1 by design (see
  [fallback](fallback.md)), so a single SSE stream monopolizes the entire connection
  until it ends. Document this; it is a property of HTTP/1.1, not a defect.
- Calling `IHttpClient.Close` while an SSE source is open stops new leases
  and gracefully closes connections (GOAWAY); the SSE read then fails with
  `EHttpConnectionClosed`. The source surfaces that as a terminal error
  (or, when the reconnect loop is enabled and the failure is transient, as a
  reconnect trigger — as described in "Reconnection and resume").

## Content coding

SSE is incompatible with transparent content decoding.

`WithAcceptEncoding` (as described in [messages](messages.md)) sets `accept-encoding`; a response
that answers with gzip or deflate is wrapped by `WrapDecodingResponse`
so `Body` yields plain bytes. That wrapper
**buffers to the coding's footer** before it can emit anything, which
destroys the defining property of SSE — each event becomes readable only at
stream end, at which point events are no longer "server-sent" in real time.

Rule: **an SSE request sends `accept-encoding: identity` and the source
rejects a `content-encoding` other than `identity` (or absent) with
`EHttpProtocolError`.** No decompression wrapper is applied on the SSE path.
This is a correctness rule, not an optimisation: the whole point of SSE is
incremental delivery.

`WrapDecodingResponse` returns a `text/event-stream` response unchanged.
The media type comparison ignores case, surrounding spaces, and parameters.
The original `content-encoding` and `content-length` headers remain available
to `TSseSource.ValidateResponse`. No body read occurs before that check.
Thus, both valid and malformed gzip or deflate bodies receive the same
`EHttpProtocolError` when the source validates the response. Other media types
retain transparent decoding; a prefix such as `text/event-streaming` does not
select SSE handling.

## Reconnection and resume

SSE's reconnect contract is client-driven: when the stream ends (server
close, transient failure, or a bounded retry), the client reconnects to the
same URL, sends `last-event-id: <last id>`, and the server resumes after that
id.

`TSseReconnectLoop` wraps a source with:

- a **reconnect delay** starting at the implementation default (the WHATWG
  recommendation is implementation-defined; this library uses **3000 ms**),
  overridden by any `retry:` the server sent, and optionally backed off;
- an **echoed `last-event-id`** taken from the parser's `LastEventId`
  ('' means send nothing);
- a **bounded retry count** mirroring the redirect idiom: `MaxRetries`
  (default `10`, `0` = reconnect forever), exceeding which raises
  `EHttpTooManySseRetries` (mirroring `EHttpTooManyRedirects` in
  [errors-redirects](errors-redirects.md));
- a **replay guard**: events are dispatched at most once per observed id, so
  a server that resumes inclusive of `last-event-id` does not duplicate the
  last event.

Reconnect is deliberately a **wrapper, not a transport feature**: keeping it
above the client means a caller can use the `IHttpSseSource` directly and own
its own reconnect policy, while `TSseReconnectLoop` is the batteries-included
default.

## Public API

```pascal
// client/src/Http2.Client.Sse.pas
type
  IHttpSseSource = interface
    ['{8B1C2D3E-4F50-4A61-9C72-00000000E001}']
    /// block until the next event is parsed, or the stream ends.
    /// True = AEvent is set; False = the stream ended cleanly.
    function ReadEvent(out AEvent: TSseEvent): Boolean;
    /// the last-event-id in force ('' when none)
    function LastEventId: string;
    /// the server's last retry: value in ms (0 = none)
    function RetryMs: Integer;
    /// stop the source and release the lease (idempotent)
    procedure Close;
  end;

  /// a source over one IHttpResponse body
  TSseSource = class(TInterfacedObject, IHttpSseSource)
  public
    /// the read deadline is NOT a constructor argument: the lease already
    /// owns the body stream and its deadline was chosen when the request was
    /// built (SseRequest sets it to 0 = wait indefinitely). To bound a read,
    /// use THttpRequest.WithSseReadTimeout before sending.
    constructor Create(const AResponse: IHttpResponse);
    /// True when the media type is text/event-stream (params allowed, a
    /// declared charset must be utf-8)
    class function IsEventStreamContentType(const AValue: string): Boolean;
    /// raises EHttpProtocolError unless AResponse is a 200 event-stream with
    /// no content coding
    class function ValidateResponse(const AResponse: IHttpResponse): Boolean;
    ...
  end;

  /// reconnect + resume wrapper
  TSseReconnectLoop = class
  public
    /// NO transport-observer argument: IHttp2Observer is frame/stream level.
    /// Observation goes through the client's request observer instead
    /// (see "Observability" below)
    constructor Create(const AClient: IHttpClient;
      const ARequest: THttpRequest;
      const AMaxRetries: Integer = cSseDefaultMaxRetries);
    function Next(out AEvent: TSseEvent): Boolean;
    procedure Close;
    /// the reconnect delay in force (server retry: or the 3000 ms default)
    function RetryMs: Integer;
    /// reconnects performed so far; the FIRST connection is not counted
    function Reconnects: Integer;
    /// the id the library gave this loop, shared by every attempt it makes
    property StreamId: Int64 read FStreamId;
  end;

/// build an SSE GET request (accept + cache-control + identity encoding)
function SseRequest(const AUrl: string): THttpRequest;
```

Two consumption styles, matching the two the library already has:

- **Pull** — `ReadEvent` blocks until an event or the stream end; the
  caller's thread loops. This is the primitive.
- **Push** — not provided. "Push" means a caller-owned thread that wraps
  `ReadEvent` (for a UI or a queue). An observer that wants every event as it
  is parsed uses `IHttpMessageObserver` (as described in "Observability").

`TSseSource` reads `IHttpResponse.Body` in chunks, feeds
`TSseEventParser`, and buffers completed events in a bounded queue so a
single `Read` call can produce several events. `Body.Eof` (`END_STREAM`)
ends the source cleanly; `EHttpStreamError` mid-body surfaces from
`ReadEvent`, not from the `Send` that returned the response.

## Observability

A client with a request observer (`WithRequestObserver`) sees an SSE stream as
attempts of kind `akSse`. `SseRequest` marks its request, and
`TSseReconnectLoop` gives the whole loop one `StreamId` and stamps a
`Reconnect` count (0 for the first connection) on each request it sends, so
the connections of one logical stream can be linked. A context attached with
`WithContext` reaches every reconnect. An attempt lasts as long as its stream:
it ends at EOF, on `Close`, on release or on failure. `Close` ends it as a
deliberate stop (`Abandoned = False`); a source dropped without being read to
its end reports `Abandoned = True`.

`TSseSource` counts events and reports them, with the wire arrival stamp of
the chunk that completed each one, to the attempt, so `THttpOutcome` carries
`MessagesIn`, `FirstMessageUs`, `LastMessageUs`, `MaxGapUs` and `SumGapUs` per
event rather than per DATA frame. Events that arrive in one chunk share its
stamp and report no gap between them; the counts and sizes stay exact. The
stamps come from the wire, so a slow consumer does not change them.

An observer that also implements `IHttpMessageObserver` and answers
`[mkSseEvent]` from `WantsMessages` receives one `OnMessage` per event, with
`EventType`, `EventId`, `Size` (the data bytes), `Index`, `ArrivedUs`,
`SinceLastUs` and `Sse`, a pointer to the parsed event that is valid only
during the call. Without that opt-in no per-event record is built. The
transport observer `IHttp2Observer` is unchanged and sees no event. See
[request-observability](request-observability.md).

## Error model

SSE reuses the exception hierarchy of [errors-redirects](errors-redirects.md), with one
SSE-specific type for the retry bound:

| Condition | Error |
| --- | --- |
| Non-`200`, or wrong/missing content-type, or non-utf-8 charset | `EHttpProtocolError` (`ecProtocolError`) |
| `content-encoding` not `identity` | `EHttpProtocolError` (`ecProtocolError`) |
| Idle body read past `SseMaxIdleTimeMs` (the body-read deadline) | `EHttpSseIdleTimeout` (a subclass of `EHttpTimeout`) |
| Line or event past `SseMaxLineBytes` or `SseMaxEventBytes` | `EHttpSseTooLarge` (a subclass of `EHttpError`) |
| Peer `RST_STREAM` / connection loss | `EHttpStreamError` / `EHttpConnectionError` |
| Caller `Cancel` during a blocked read | `EHttpStreamError` (`ecCancel`) |
| `MaxRetries` exceeded | `EHttpTooManySseRetries` |

## Unit layout

| Unit | Content |
| --- | --- |
| `client/src/Http2.Client.Sse.pas` | `TSseEvent`, `TSseEventParser`, `IHttpSseSource`, `TSseSource`, `TSseReconnectLoop`, `SseRequest` |
| `client/src/Http2.Client.Stream.pas` | body read timeout + read-side cancellation |
| `client/src/Http2.Client.pas` | `WithSseReadTimeout` request setter; threads the token and the body deadline to the lease's body read |
| `common/src/Http2.Common.Headers.pas` | `HeaderLastEventId` constant |
| `client/src/Http2.Client.pas` | public client facade; SSE features use the explicit `Http2.Client.Sse` unit |
| `test/client/Http2.Client.Sse.Test.pas` | parser, validation, source, reconnect |
| `examples/sse_stream.pas` | runnable demo against the test server |
| `tools/client/sse_server.py` | a minimal live SSE server for interop (as described in "Testing") |

`Http2.Client.Sse` is a client feature unit. It has no `fcl-json` or
`fcl-xml` dependency. The facade does not re-export this feature unit.

## Testing

- **Parser unit tests** are the core. They feed the WHATWG example byte
  stream, then re-feed it **sliced at every offset** (all chunk boundaries,
  including splits inside a CRLF, inside a field name, inside a value, and
  across a multi-byte UTF-8 sequence) and assert an identical event
  sequence. This is the same "prove the assertion can fail" standard
  [testing-observability](testing-observability.md) uses.
- **Pure parser cases:** comment-only keep-alive fires nothing but resets
  liveness; `id`/`retry`/`event` with no `data` fires nothing but updates
  state; blank-line dispatch removes exactly one trailing `\n`; `retry:`
  non-numeric ignored; `id` with NUL ignored; BOM stripped once.
- **Response validation cases:** non-200, missing content-type, wrong
  content-type, non-utf-8 charset, `content-encoding: gzip` rejected.
- **Timeout/cancellation cases:** with `BodyReadTimeoutMs` set, an idle
  stream raises `EHttpTimeout`; with `0`, an indefinitely quiet stream blocks
  (asserted with a short `Cancel` from another thread, not a long sleep); a
  `Cancel` during a blocked read raises `ecCancel` within one poll slice.
- **Flow-control case:** slow reader over a mock socket still sees
  `WINDOW_UPDATE` and never deadlocks.
- **Live case (opt-in, `SSE_TEST_URL`):** `pytest`-free: `tools/client/sse_server.py`
  serves `text/event-stream` and emits a scripted sequence (comment
  keep-alive, multi-line data, `event:`, `id:`, `retry:`), then closes; the
  example and one integration test consume it. This mirrors the opt-in
  integration gate in [testing-observability](testing-observability.md).

## Design decisions

These choices are also indexed in [open-questions](open-questions.md).

1. **Reconnect policy.** It lives in `TSseReconnectLoop`, not in the
   transport. The loop reconnects after any clean end of stream or transient
   failure unless the caller closes it; a protocol error (non-200, wrong
   content-type, non-identity coding) is terminal and propagates.
   `EHttpTooManySseRetries` bounds the reconnects (`AMaxRetries = 0` retries
   forever).
2. **Observer cardinality.** The transport observer `IHttp2Observer` stays
   frame/stream-level and sees no event. The request observer collects
   per-event aggregates always and delivers one callback per event only to an
   observer that opts in with `IHttpMessageObserver`, so a chatty stream is
   high-cardinality only for a consumer that asked for it.
3. **SSE over the HTTP/1.1 fallback.** Supported but best-effort, not
   rejected. Liveness is bounded by the body-read timeout (`SseMaxIdleTimeMs`,
   set on the request), so an idle fallback stream ends after that time, and
   `THttp1BodyStream.Read` has no cancel path, so a blocked read cannot be
   cancelled. HTTP/2 has no such limit.
