---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, frame codec, close handshake, heartbeat, origin policy, init, streaming pool, rfc 6455, inbound message, body reader, pipe, inline limit, producer, body producer, chunk sink
notes:
  - This document describes the WebSocket part of the server, which serves a WebSocket on any detached channel, over HTTP/1.1 and over HTTP/2.
  - RFC 6455 (the WebSocket protocol) is the main source. It was checked on 2026-10-22 at https://www.rfc-editor.org/info/rfc6455. The plain-text copy is doc/references/rfc6455.txt. RFC 6454 (the web origin) was checked on the same date at https://www.rfc-editor.org/info/rfc6454.
  - The IANA registry of close codes was checked on 2026-10-22. The copy is doc/references/iana-websocket-registry.xml.
  - RFC 6455 sections 5.4 (fragmentation), 5.5 (control frames) and 5.5.1 (close) were read in the plain-text copy and checked on 2026-11-17 at https://www.rfc-editor.org/info/rfc6455. The streamed message of `SendStream` follows section 5.4.
  - Imported from http2server/doc/design/server/websocket.md at the source commit recorded in the source inventory.
scope: The frame codec, the session contract, the inbound message and its reader, the receive path, the closing handshake, the heartbeat, the limits, the origin policy, the Init hook and the settings.
primary_types:
  - IWsSession
  - IWsHandler
  - IBodyReader
  - TWsInitResult
  - TWsOptions
  - TWsReader
  - TWsMessagePipe
  - TWsMemoryReader
  - IBodyProducer
  - IBodyChunkSink
  - IWsProducerPort
related_docs:
  - seam.md
  - threading.md
  - http1.md
  - sse.md
  - configuration.md
  - lifecycle.md
  - limits.md
  - ../common/body.md
invariants:
  - A session runs on any IDuplexChannel and does not know the protocol under it.
  - The handler is called on a thread of the streaming pool, one call at a time for a session, in the order of the events, and never on an IO thread.
  - A message that ends inside the inline limit reaches the handler as a reader over memory, and a read never waits. A longer message reaches the handler when it passes the limit, and a bounded pipe carries the later octets.
  - The IO thread never waits for the handler. A push into the pipe never blocks, and the lock of the pipe is a leaf lock.
  - The credit of the octets of a pipe returns as the handler reads them. The credit of the inline octets and of every frame header returns when they arrive, except that it waits while the queue is at least half full (the frame headers of a streamed message that is open never wait).
  - The end of the session aborts every pipe whose message still arrives, before the streaming pool stops.
  - Exactly one of Closed or Failed ends the conversation, unless the application calls Abort.
  - The server never puts the close codes 1005, 1006 or 1015 on the wire.
  - A producer that SendStream runs holds one streaming pool thread until it ends. When the channel is full, the sink waits on that thread and holds no lock, and the drain, the end of the session and a poll of 250 ms end the wait. The sink sends the deferred control replies between fragments, and a fragment that the channel refuses for `OutboundStallMs` closes the session with 1008.
  - A message that Send sends is written with one call of the channel, so the frames of two messages never mix. A streamed message is written one fragment at a time, and no other data message is written while its stream runs.
---

# WebSocket

A WebSocket session is a long-lived pair of byte streams on a detached channel (see
[seam](seam.md)). The session parses and builds the frames, answers the control
frames, runs the closing handshake and calls the application. The handshake that
opens the channel depends on the protocol and is described with each protocol. This
document describes the parts that do not depend on it.

## The frame codec

Four units hold the codec. They have no socket and no thread. Two more units serve the
inbound message of a session.

| Unit | Content |
| --- | --- |
| `Ws.Frames` | the opcodes, the close codes, the mask, the frame encoder, the fragmenting message encoder and the Close payload helpers |
| `Ws.Utf8` | a UTF-8 validator with three bytes of state, so a character split across fragments needs no buffer |
| `Ws.Parser` | the resumable frame parser; it pushes the unmasked payload of a data frame to a sink and buffers no data frame |
| `Ws.Reader` | the assembly of frames into messages with the size, fragment and UTF-8 checks; it keeps the first `InlineLimit` octets of a message and then gives the octets to its sink one piece at a time |
| `Ws.Inbound` | `TWsMessagePipe` and `TWsMemoryReader`, the two `IBodyReader` classes that give a message to the handler |
| `Ws.Snapshot` | `TWsRequestSnapshot`, the read-only copy of the handshake request |

The parser enforces the rules of RFC 6455 sections 5.2 to 5.5 that one frame and the
order of the frames allow: reserved bits and opcodes, masking in the right direction,
the shortest form of the length, control frames of at most 125 octets and with FIN,
and the order of a fragmented message. The reader checks the message size before it
buffers a byte, so a peer that declares a large frame and sends nothing costs no
memory. A text message is checked for UTF-8 while the octets arrive.

The sink of the reader has three calls for a data message: `MessageBegin(AText)`,
`MessageData(P, Count)` and `MessageEnd`. A message that ends inside the inline limit
gives the three calls at its end, with one `MessageData` call for its octets. A longer
message gives `MessageBegin` when the octet after the limit arrives, then one
`MessageData` call for the octets that the reader kept (the property `Replaying` is True
during this call), then one `MessageData` call for each later piece, and `MessageEnd` at
its end. The property `Streaming` tells the sink which of the two cases it is in. After
the stream starts, the reader keeps no octet of the message.

The tests of the codec check the frames of RFC 6455 section 5.7, every rule with its
close code, split delivery (whole, one octet at a time and in random pieces) and a
fuzz run of 40,000 random and mutated streams.

### Close codes

The set of codes that a peer may put on the wire follows the IANA registry of
2026-10-22: 1000 to 1003, 1007 to 1014 and 3000 to 4999. The codes 1004, 1005, 1006
and 1015 never appear in a Close frame. The server sends every code of the set
except 1010, which is a client code.

| Code | Use in the server |
| --- | --- |
| 1000 | a normal close |
| 1001 | the server stops (`Stop`) |
| 1002 | a protocol error: a bad frame, a Close payload that RFC 6455 section 5.5.1 forbids, a data frame after a Close frame |
| 1003 | available to an application |
| 1007 | a text message or a Close reason that is not UTF-8, also when the handler has read part of the message already |
| 1008 | a policy limit: a token bucket is empty, too many messages wait for the application, a read of a streamed message waited for `InboundStallMs` (reason `the message stalled`), or the channel refused one fragment of a producer for `OutboundStallMs` (reason `the send stalled`) |
| 1009 | a message or a frame is over its limit, or a streamed message fills the pipe on a channel that returns no credit (reason `the handler reads too slowly`) |
| 1011 | a callback raised, or the Pong did not come |
| 1006 | reported to the application only: the connection ended without a Close frame, or the peer did not answer the Close frame in time |
| 1005 | reported to the application only: the Close frame had no status |

## The session contract

The application gives the server an `IWsHandler` when it accepts an upgrade. The
server creates an `IWsSession` for the connection and calls the handler on a thread
of the streaming pool (as described in [threading](threading.md)). The calls of one session run
one at a time, in the order of the events. A callback can call `Send`, `Ping`,
`Close` and `Abort`.

| Call | Meaning |
| --- | --- |
| `Init` | the first call; it authorises, chooses the subprotocol and may send a greeting |
| `Message` | a message, as an `IBodyReader`; a text message is valid UTF-8 up to the last octet that the handler has read (see [The inbound message](#the-inbound-message)) |
| `Pong` | a Pong arrived |
| `Closed` | the session ended; the code, the reason and whether the closing handshake completed |
| `Failed` | a callback raised an exception; the session closes with 1011 |

`Send` is legal from any thread at any time. It never blocks. It writes all frames of
the message with one call of the channel, so a refusal leaves nothing half written
and the frames of two messages never mix. It answers `srFull` when the outbound queue
is over `ChannelQueueLimit` or while a streamed message runs, and `srClosed` after the
session has ended or the Close frame has gone out. The session does not drop a message
by itself. The sender splits a message into frames of `FrameSize` octets. A Pong and a
Close echo are separate writes, so they do not wait behind a message that is being
built. `SendStream` sends a message that a writer gives in pieces (see
[Streaming a message](#streaming-a-message)).

**The send lock.** One send lock keeps the frames of two writers apart. A writer
encodes its message before it takes the lock, then checks under the lock that the
session is open, and then writes. A Close frame needs the same lock, so no data
frame follows a Close frame (RFC 6455 section 5.5.1).

**The IO thread never waits for the send lock.** A thread that holds the send lock
waits for the connection lock when it writes into the stream, and the IO thread holds
the connection lock while it parses frames. If the IO thread waited for the send
lock, the two threads would wait for each other. The IO thread therefore tries the
lock without waiting. When the lock is busy, or when an earlier reply still waits, the
reply (a Pong, a Close echo or the Close frame of a protocol error) goes to the
streaming pool as a task. The pool sends the replies in order, and a reply that must
close the channel closes it after the frame.

**The size of a sent message.** `Send` builds the message in memory, so the message is
limited by `MaxMessageSize`. `MaxMessageSize` is at most 2147483647, and `MaxFrameSize`
is at most `MaxMessageSize`. A close reason must be UTF-8, and the server cuts a reason
that it builds itself on the boundary of a character.

A streamed message has no such limit on its total size. `MaxMessageSize` limits one
chunk of the writer. The rules are in [Streaming a message](#streaming-a-message).

`Abort` closes the channel at once, with no Close frame and no later callback.
`SetContext` and `Context` keep a value of the application for the life of the
session; the session releases it at the end.

## The inbound message

`IWsHandler.Message(ASession, AMessage, AText)` gives the message as an `IBodyReader`
(see [body](../common/body.md)). `ReadAllBody(AMessage)` gives the whole message as a
`TBytes` in one call. A loop of `AMessage.ReadChunk(Buffer)` gives one chunk at a time, so
a handler that stores or hashes a message does not hold it in memory. The end of the
message is a `Read` that returns 0 or a `ReadChunk` that returns False, and both answers
repeat.

```pascal
// an echo handler that holds the whole message
procedure TMyHandler.Message(const ASession: IWsSession; const AMessage: IBodyReader;
  const AText: Boolean);
begin
  ASession.Send(ReadAllBody(AMessage), AText);
end;
```

**The contract.**

- The reader is valid during the call of `Message` only. When the call returns, the
  session releases the reader: a handler that keeps it gets `EStreamCancelled` on a later
  read.
- A handler need not read the whole message. When `Message` returns early, the session
  drops the octets of the message that wait and the octets that still arrive, and it
  credits them to the channel. The session goes on with the next message.
- A read raises `EStreamCancelled` when the session ends, when a Close frame arrives
  before the message ends, when the message fails (a bad UTF-8 octet, a size limit) and
  when the read stalls. The session catches `EStreamCancelled` that `Message` lets pass,
  and it does not call `Failed`.
- A text message is valid UTF-8 up to the last octet that the handler has read. For a
  message in memory this is the whole message, as before. For a streamed message the
  reader checks the octets as they arrive. A bad octet after the handler has read part of
  the message closes the session with 1007, and the next read raises `EStreamCancelled`.

**Two paths.** The assembler keeps a message in memory until it ends or until it passes
`InlineLimit` (default 65536 octets).

- A message that ends first goes to the handler as a `TWsMemoryReader` over the octets.
  The session starts the handler task when the message ends. No pipe exists, and a read
  never waits.
- A message that passes the limit goes to the handler at once. The session starts the
  handler task when the octet after the limit arrives, and a `TWsMessagePipe` carries the
  octets that the reader kept and all the later octets. The handler reads while the
  message arrives.

**The pipe.** One IO thread writes into the pipe with `Push`, `Finish` and `Abort`. One
handler thread reads.

- `Push` copies the octets into a buffer and never waits. The lock of the pipe is a leaf
  lock: code that holds it takes no other lock, and no call back runs while it is held.
  The IO thread therefore needs no pool task to deliver a fragment.
- `Read` waits on an event with no lock held. `ReadChunk` gives the next chunk as it was
  pushed, or the rest of a chunk that a `Read` began.
- On a channel that returns no credit (an HTTP/1.1 upgrade, a unix socket) the pipe holds
  at most `InboundPipeBytes` octets (default 1 MiB). A push that takes the buffer over the
  cap drops the buffer, aborts the pipe, and the session closes with 1009 and the reason
  `the handler reads too slowly`. On HTTP/2 the pipe has no cap: the credit rule below
  keeps the unread octets at the stream window plus `InlineLimit`, so the window is the
  bound, and a handler that waits before its first read never costs the session. The
  channel tells the session which case it is through the optional interface
  `IChannelFlow`; a channel without it counts as a channel that returns no credit.
- A read that gets no octet for `InboundStallMs` (default 30000) aborts the pipe, raises
  `EStreamCancelled`, and the session closes with 1008 and the reason `the message
  stalled`.

**The credit.** The octets that the session returns as credit to the channel follow these
rules.

- The frame headers and the mask keys of every frame, and the octets that the reader
  keeps inside `InlineLimit`, are credited when they arrive. A message of up to the
  stream window therefore never waits for a credit that only its own end can bring.
- The octets that go to a pipe are credited when the handler reads them. The octets that
  the pipe drops (an abort, an early return of the handler) are credited at the drop.
- The octets that the reader kept before the stream started were credited on arrival, and
  they go into the pipe marked as paid, so the handler's read of them returns no second
  credit. The sum of the credit of a message equals the octets that arrived for it.
- On HTTP/2 a slow handler holds back the credit of its own stream only. The stream
  window is not refilled, so the peer stops when the window is full. Other streams and
  the connection window are not affected, because the connection window is credited when
  a frame arrives. Once the queue of the session reaches `QueuedMessages`, the credit of
  the arriving octets waits in the same way, so the window holds the peer after the
  queue has reached the cap (see [The queue cap](#the-receive-path)).
- An HTTP/1.1 upgrade and a unix socket have no flow control: `ReturnCredit` does nothing
  and the IO layer never pauses its reads. A slow handler does not slow its peer on such a
  channel. The pipe cap bounds the memory, and a handler that falls behind by more than
  the cap loses its session with 1009. The memory bound of a streamed message is
  `InboundPipeBytes` on these channels and the stream window plus `InlineLimit` on HTTP/2.
  The slowing of the peer exists on HTTP/2 only.
- The credit that the queue rule holds back (`QueuedMessages` at least half full) is given back when
  a message starts to stream, so the inline octets of a streamed message never wait for a
  handler that is busy with an earlier message.
- The frame headers of a message that is open never wait under the rule of
  `QueuedMessages` (see [The receive path](#the-receive-path)). A message that follows
  the end of a streamed message in the same receive call is not open, and its octets
  wait while the queue is at least half full. While the session is open, the credit that waits is
  given back as the handler takes messages, and the sum of the credit equals the octets
  that arrived. After the session ends (an abort, a protocol error or a lost transport),
  the stream credit that waits is not returned. The HTTP/2 connection window is credited
  when the frames arrive, so no connection credit is lost.

**Counting.** A streamed message counts once, when it starts: it takes one token of the
message bucket, it counts once in `QueuedMessages`, and it charges the server budget
`MaxWsQueuedBytes` with `InboundPipeBytes`, because its length is not known then. The task
keeps the same number, so the release is equal. A message in memory charges its length
plus `WsQueuedMessageOverhead` (256 octets) when it ends, so that a queue of messages of
one octet uses the budget as well. `wcMessagesIn` counts at the same moment. `wcBytesIn` counts the octets of a
streamed message as they arrive, so a message that ends by an abort, a Close frame, a stall
or an overflow counts the octets that came before it. A streamed message whose pipe was
aborted before its handler started (a Close frame between its fragments, for example) is
not given to the handler: the session drops it and releases its credit, its count and its
charge.

**Limits.** `MaxMessageSize` limits the whole message, as before, and a message over it
closes the session with 1009. A program that streams larger messages raises it. The
assembler limit `MaxFragments` (default 1024) stays and limits the frames of one message.
With the default `MaxFrameSize` it caps a streamed message at 64 MiB, so a program that
streams a larger message raises `MaxFragments` together with `MaxMessageSize`.
`Problems` requires `InboundPipeBytes` of at least `InlineLimit` plus `MaxFrameSize`,
because the kept octets move into the pipe when a message starts to stream and the first
piece follows at once, before the handler has read an octet.

**The threads.**

- A handler that reads a message holds one streaming pool thread for the whole read.
  Unlike a step of a stream writer, a blocked `Read` does not give the thread back
  between chunks.
- The pool runs one task of a session at a time. While `Message` runs, the tick (ping,
  pong timeout, close timeout), a Pong for the handler, `Closed`, the deferred replies
  and the steps of `SendStream` of the same session wait. The IO thread does not wait: it
  parses, checks UTF-8, pushes, credits, answers Ping and Close when the send lock is
  free, and ends the session.
- The default pool has one thread (`StreamPoolSize`, see [threading](threading.md)). An
  application that reads long messages sets `StreamPoolSize` above the number of sessions
  that read at the same time.
- A handler that reads a message and also sends a reply with `Send` does not wait for the
  pool. A reply with `SendStream` starts when `Message` returns.
- The ping timer cannot close a session while the handler reads, because the tick waits
  for `Message`. The stall time of the pipe is the deadline that covers this case.
- The stall deadline covers only a blocked `Read`. A handler that blocks outside `Read`
  holds its pool thread until it returns. On a channel without flow control the pipe then
  fills, and the session closes with 1009.
- The hold rule of `QueuedMessages` exempts the headers of the frames of a streamed
  message that is open. When a receive call carries the end of a streamed message, the
  exempt octets are the octets up to the end of its last frame (the reader counts them
  as it parses). The octets after that frame, such as a whole small message in the same
  call, are under the hold rule. While the call leaves a streamed message open, every
  octet of the call is exempt.

**The end of the session.** `TryEnd` is the one place that every end of a session passes:
a Close frame, a protocol error, a lost transport, an abort, a failure of a callback and
the stop of the server. It aborts the pipe of a message that still arrives, so a read
that waits raises `EStreamCancelled`. The abort comes before the streaming pool stops,
because the stop of the pool waits for the running tasks. A pipe that has its end (the
message arrived whole) is not aborted: a message that arrived before a Close frame is
still delivered, as the receive path describes.

## Streaming a message

`SendStream` sends one message whose octets come from an `IBodyWriter` (see
[body](../common/body.md)). It returns `srQueued` at once. It returns `srClosed` when
the session has ended or the Close frame has gone out, and `srFull` when another stream
of the session runs. It raises `EHttpError` when the writer is nil.

Each chunk of the writer is one fragment of the message (RFC 6455 section 5.4). A chunk
that is longer than `FrameSize` is split into frames of `FrameSize` octets, as a whole
message is. The first fragment has the opcode text or binary. Each later fragment has
the continuation opcode. Only the last fragment has the FIN bit.

The last call of the writer ends the message. When that call returns False with octets,
those octets form the last fragment, and that fragment has the FIN bit. When the last
call returns False with no octets, the session sends one empty continuation frame with
FIN. When the writer gives no chunk at all, the session sends one empty frame with the
opcode and FIN. A call that returns True with no octets is an empty chunk, and the
session skips it.

The streaming pool reads the chunks. One step reads at most 16 chunks. The step then
ends, and the next step waits at the end of the queue of the session. The writer runs
on a streaming pool thread and never on an IO thread. A writer can block. A blocking
writer holds one pool thread, and it delays the other tasks of the session. For example,
a cancel message from the client waits until the writer returns.

When the channel refuses a fragment, the stream keeps the encoded fragment and parks. The
drain of the channel wakes the stream. A parked stream also arms a timer of 250
milliseconds. A refusal in the held bytes of a channel that is not active yet, for
example from a `SendStream` that the `Init` callback starts, gives no drain from the
stream. The channel records the refusal. When `Activate` has moved the held bytes to the
stream, the channel calls `WriteDrained`, and the stream wakes at once. The timer checks
the channel again, so a lost drain signal delays the stream by at most one poll after
room appears.

`SendStream` takes its own reference to the writer. A writer that the caller makes in
the call, and does not keep, is therefore released when `SendStream` refuses it with
`srFull` or `srClosed`.

While a streamed message runs, `Send` and `SendStream` return `srFull`. Ping, Pong and
Close frames can go out between the fragments (RFC 6455 section 5.5). The session never
sends a data frame after a Close frame.

When a Close frame goes out, the session ends, or the session aborts, the stream stops at
its next step. The message then stays incomplete, and no FIN frame follows (RFC 6455
section 5.5.1). The writer is released.

When the writer raises, or when a chunk is longer than `MaxMessageSize`, the session
calls `Fail`. The handler receives `Failed`, and a Close frame with code 1011 follows.
The session ends before any other data frame can go out, so no whole message follows an
unfinished fragment.

The session releases the writer when the stream ends. When the peer closes the session or
a protocol error ends it, the release runs on the thread that ends the session, which can
be an IO thread. The destructor of a writer does not block, and it does not take a lock
that a caller of `Send` can hold.

The counter of payload octets out grows by the payload of each fragment that the channel
takes. The counter of messages out grows by one when the FIN fragment is queued.

The server does not check the UTF-8 of a streamed text message. A text chunk can end
inside a character, and the receiver checks the whole message.

A stream suits one large message. A browser WebSocket gives the page the whole message
only at its end, so a stream does not deliver the pieces to the page one at a time. For
a series of messages, such as rows that are ready one at a time, the application sends
one message for each batch with `Send`.

### SendStream with a producer

A writer that supports `IBodyProducer` (see [body](../common/body.md)), for example the
writer of `BodyWriterFromStream`, is not pulled with `NextChunk`. One pump step runs the
producer with `Produce` on one streaming pool thread. The producer writes to a stream, and
the stream gives each chunk to the sink of the pump. The thread belongs to the producer
until `Produce` returns. The step limit of 16 chunks does not apply, and the pump does
not give the thread back between chunks.

The sink turns each chunk into one fragment and writes it with the same write path as
the pulled stream. The first fragment has the message opcode. Each later fragment has the
continuation opcode. The call of the sink that is the last one gives its fragment the FIN
bit. A chunk is not encoded twice: the sink keeps the encoded fragment until the channel
takes it. The producer stream holds one chunk back, so the last chunk of the body is
known when the producer ends, and no empty frame follows it. A producer that writes
octets therefore ends the message with the FIN bit on its last fragment. A producer that
writes nothing sends one empty frame with the message opcode and the FIN bit, as a writer
that gives no chunk does. A last call with no octets after earlier fragments sends one
empty continuation frame with FIN.

When the channel refuses a fragment, the sink waits. The wait blocks the pool thread of
the producer, so the `Write` of the producer on the stream does not return, and the
producer produces no more octets. The wait holds no lock of the pump and no lock of the
session. Five events end the wait:

- The channel drains. `WriteDrained` wakes the pump, and the pump sets the event of the
  sink.
- The end of the wait of 250 milliseconds passes. The sink then sends the same fragment
  again, so a lost drain signal delays the stream by at most one poll. The sink does not
  use the park timer of the pulled stream here, because the timer is a task of the
  session, and the pool runs one task of a session at a time: the timer task would wait
  behind the blocked producer.
- The session ends, or the Close frame of the application goes out. `TryEnd` and `Close`
  stop the pump, and the stop sets the event.
- The channel answers `srClosed`.
- The channel refuses the same fragment for `OutboundStallMs` (default 30000). The session
  then closes with 1008 and the reason `the send stalled`, and the sink raises
  `EStreamCancelled`. The time starts at the first refusal of a fragment. A drain that
  leaves the channel full does not restart it, and a fragment that the channel accepts
  starts a new time for the next fragment. The Close frame goes out when the channel takes
  it. When the channel takes no frame at all, the close timeout of the session ends the
  session, and the pool thread of the producer is free at once. Without this deadline a
  peer that keeps its connection open and reads no octet would hold the pool thread for
  ever, because the tick of the session is a task behind the producer.

After the end of the session, after `srClosed` or after a stall, the next call of the sink
raises `EStreamCancelled`. The producer stream calls the sink only when a chunk is full
and at the end of the body, so the `Write` that fills the next chunk, or the end of the
producer, raises it. A `Write` that only fills part of a chunk returns normally, and a
producer that waits in its own code sees no cancel. A producer that does not catch the
exception ends, and the session sends no more frames. This end is quiet: the handler gets
no `Failed`. A Close by the application keeps the rule of the pulled stream: the message
stays incomplete, no data frame follows the Close frame, and the closing handshake goes on
with the code that the application gave.

The sink keeps its first failure. When it has raised (a chunk over `MaxMessageSize`, a host
error, a cancel), every later call raises the same failure, so a producer that catches the
exception and writes on cannot complete the message with a missing fragment. When such a
producer ends, the session fails. A call with no octets that is not the last call is
skipped, as the pulled stream skips an empty chunk.

The other rules of the pulled stream stay. While the producer runs, `Send` and
`SendStream` return `srFull`. `MaxMessageSize` limits one chunk of the producer. When the
producer raises, or when a chunk is longer than `MaxMessageSize`, the session calls
`Fail`: the handler receives `Failed` once, and one Close frame with code 1011 goes out.
The pump releases the writer when `Produce` returns or raises, on the pool thread that ran
the producer. A stop that comes before the pump step has entered has no producer to wait
for: the thread that ends the session (an IO thread, for a peer that closes or resets the
stream) releases the writer, as it does for a pulled stream. The destructor of a writer
therefore must not block, and must not take a lock that a caller of `Send` can hold.

A Ping that arrives while the producer runs is answered. The IO thread sends the Pong at
once when the send lock is free. When a fragment write holds the send lock, the IO thread
defers the reply to the session queue, and the queue waits behind the producer. Before it
writes each fragment, and at each wake while it waits, the sink sends the deferred replies
on its own thread, in order. RFC 6455 section 5.4 permits control frames between the
fragments, and no message of `Send` can split the stream. The peer therefore gets its Pong
while the message runs, and a pong timeout of the peer does not close the connection.

A producer holds one streaming pool thread while it runs, and while it waits for room in
the channel. The tick, `Closed` and the messages of the same session wait until `Produce`
returns, and so does the inbound handler of a message that is larger than `InlineLimit`.
A producer that waits for an event that a later inbound `Message` of the same session sets
never gets it, because the `Message` call waits behind the producer. With the default
`StreamPoolSize` of 1, one producer that waits for a slow peer stops every other WebSocket
session and event stream for at most `OutboundStallMs`. An application that streams with
producers sets `StreamPoolSize` above the number of producers that can run at the same
time (see [threading](threading.md)).

## The Init hook

`Init` is the one hook for authorisation and for the first actions of a session. The
upgrade code checks the syntax, the version and the origin, detaches the stream at
once and returns; the handler of the route returns. No response has gone out. `Init`
is the first task of the session, so it runs on a pool thread, never on an IO thread
and never in the route handler. The handler receives a read-only copy of the
whole request, including `Cookie` and `Authorization`, and may access a database.

- **Accept.** The result names a subprotocol, which must be one of those the client
  offered or empty, and may add header fields. The server sends the handshake
  response; then the frames that `Init` queued leave, in order. `Init` can send a
  greeting, and it can call `Close`.
- **Reject.** The result holds a status (403 when it is 0), header fields and a body.
  The server answers the upgrade with an ordinary HTTP response. `Message` and
  `Closed` never run, and the frames that `Init` queued are dropped. The observer
  gets `seWsRejected` with the status.
- An exception in `Init`, or a subprotocol that the client did not offer, answers
  500 and raises `seHandlerException`.
- A peer that resets the stream, or closes the connection, while `Init` runs ends the
  session. The result of `Init` is dropped, and `Closed` does not run.
- A peer that sends WebSocket octets before the response is in error. The session
  ends and the channel is aborted.
- `InitTimeoutMs` bounds the wait. `Init` may hold every thread of the pool, so a
  timer of the pool could not fire. One watchdog thread for the whole server watches
  the time limits. When the limit passes, the upgrade is answered with 503 and the
  result of `Init` is dropped when it comes. The timeout frees the stream. It cannot
  interrupt a thread that is blocked in a call.

## The receive path

The IO thread that delivers octets parses the frames. It answers control frames at
once, under the rule of the send lock above: a Ping is answered with a Pong that has
the same payload, and a Close frame is echoed with the same code. It puts each data
message on the queue of its session. A message that ends inside `InlineLimit` goes on the
queue when it ends. A longer message goes on the queue when it passes the limit, and the
IO thread pushes its later octets into a pipe (see [The inbound
message](#the-inbound-message)).

- **Credit.** Every octet is credited to the channel once. The octets of a frame header,
  of a control frame and of a message in memory are credited when they arrive. The octets
  of a streamed message are credited when the handler reads them, or when the session
  drops them. A message of up to the HTTP/2 window can therefore arrive, and a control
  frame in pieces cannot raise the window above what the server consumed. When the
  queue of a session is at least half full, the credit of the octets that the rule credits
  on arrival waits until the application has taken messages. The credit returns when the
  queue falls below half full. The headers of a streamed
  message that is open do not wait, so a small `QueuedMessages` cannot stall the peer in
  the middle of a message. The octets of a receive call that follow the end of a streamed
  message do wait.
- **Delivery at the end.** The messages that arrived before a Close frame are delivered
  to `Message`, in order, and `Closed` follows the last of them. An abort, a failure of
  a callback and a protocol error drop the messages that still wait. A lost connection
  and a close timeout drop none.
- **The queue cap.** `QueuedMessages` is the count of messages at which the queue of a
  session starts to hold the credit of the peer. On HTTP/2 the cap does not close the
  session. A message past the cap is admitted, the credit of its octets and of the octets
  that follow waits until the application has taken messages, and the stream window
  stops the peer. The count of queued messages on HTTP/2 is therefore bounded by the
  window and by the byte budget, not by `QueuedMessages`. A channel without flow control
  (an HTTP/1.1 upgrade, a unix socket) has no window to hold the peer: a message past
  the cap closes the session with 1008 and the reason `too many messages wait for the
  application`. A peer that sends past the window of HTTP/2 is reset with
  `RST_STREAM` and the error `FLOW_CONTROL_ERROR`, and the session ends. That rule of the
  HTTP/2 layer governs such a peer, not the queue.
- **The byte budget.** The octets of the queued messages of all sessions of a server
  count in one budget, `MaxWsQueuedBytes`. A message in memory charges its length plus
  `WsQueuedMessageOverhead` (256 octets). A streamed message counts `InboundPipeBytes`
  from its start, because its length is not known then. A message that would pass the
  budget closes its session with 1008 and the reason `the queued bytes of the server are
  full`, on every channel. The session gives back its octets when a message leaves the
  queue and when the session ends, so the count returns to zero when the sessions have
  ended. The budget is the memory bound of the queue on HTTP/2.
- **The cost of the hold.** When a streamed message starts, the held credit returns at
  once, because the inline octets of that message may be among the held octets. So a
  session that streams can open its window while the queue is at the cap. The budget
  still bounds the memory.
- **The early bytes.** Before the session takes the channel, the octets that arrive
  wait in the channel. When they pass `WsEarlyBytes`, the connection closes at once.
- **The buckets.** One token bucket counts the control frames that arrive (Ping and
  Pong), and one counts the messages. An empty bucket closes the session with 1008
  and raises `seWsBucketTripped`. A Close frame costs no token.

## The closing handshake

- A Close frame from the peer is echoed at once, with the same code when the server
  may send it and with 1000 otherwise. A Close frame with no status is echoed with no
  status. The application hears `Closed` with the code and the reason of the peer and
  `AClean` true. The channel then closes gracefully.
- `Close` from the application sends a Close frame, stops later sends, and waits for
  the Close frame of the peer for `CloseTimeoutMs`. The reply ends the session with
  `Closed(AClean = true)`. A silent peer ends it with `Closed(1006, AClean = false)`
  and an aborted channel.
- A protocol error sends a Close frame with the code of the error and ends the
  session with `Closed(code, AClean = false)`.
- The loss of the transport calls `Closed` with 1006 and `AClean` false. A half close
  of the peer without a Close frame is the same case.
- A data frame after the Close frame of the peer is a protocol error.

## The heartbeat

When a session has had no inbound traffic for `PingIntervalMs`, the server sends a
Ping and waits `PongTimeoutMs`. A Pong clears the wait. A missing Pong closes the
session with 1011 (reason `ping timeout`), and the close wait then ends the session.
A value of 0 for the interval turns the Ping off. The decision is a pure function
(`WsTimerStep` in `Ws.Close`) that the tests call with numbers.

## Stop

`Stop` sends Close 1001 to every open session and waits up to the graceful stop
timeout for the replies. A session that is still open then is aborted, and the
application hears `Closed(1001, AClean = false)` on the thread that stops the server,
because the pool is going away. A session that waits for `Init` closes with 1001 as
soon as `Init` accepts. The abort of a session aborts the pipe of a message that still
arrives, and this happens before the pool stops. A handler that waits in a read therefore
returns, and the stop of the pool does not wait for it.

## The origin policy

The origin policy decides whether the `Origin` field of an upgrade request passes. RFC
6454 defines the origin, a triple of scheme, host and port, and the field. It gives a
server no rule, so these are policy choices.

| Policy | Rule |
| --- | --- |
| `opSameOrAbsent` (default) | the field is absent, or every origin in it equals the origin of the server |
| `opAllowList` | as above, and an origin in `AllowedOrigins` passes too |
| `opAllowListOnly` | the field is absent, or every origin is in `AllowedOrigins` |
| `opAny` | every origin passes |
| `opNone` | the server makes no check; the application checks in `Init` |

- The origin of the server is built from the scheme of the transport and from the
  `Host` field or the `:authority` value, lowered and with the default port filled
  in. The scheme is never taken from a header. A server that has no usable host
  refuses a request that carries an `Origin` field.
- A request without an `Origin` field passes every policy, because a client that is
  not a browser sends none. The check protects against a browser of another origin.
  It does not identify a client.
- A value is accepted only if it is `null` alone or a list of `scheme "://" host
  [":" port]` separated by single spaces. A path, a query, a fragment, userinfo, a
  comma, an empty member, a port with a leading zero or above 65535, and a host with a
  non-ASCII octet are refused with 400. The literal `null` is refused with 403.
  Upper case in the scheme and the host is lowered before the compare. An explicit
  default port equals the same origin without a port. The compare is of the three
  parts as ASCII text. It does no suffix match, no registered-domain match, no IDNA
  mapping and no IPv6 normalisation.
- More than one `Origin` field is refused with 400.
- A foreign origin is refused with 403. The 81 vectors of the research notes are the
  test list.

## The host allow-list

The default origin policy compares the `Origin` field with the `Host` field or the
`:authority` value of the same request. A DNS rebinding attack makes the browser send
a `Host` value and an `Origin` value that both name the attacker's domain, so the
default policy passes it. The default policy does not close this attack.

The host allow-list `WsAllowedHosts` closes it. The default is an empty list, which
turns the check off, so the server behaves as before. When the list holds entries, the
`Host` field (HTTP/1.1) or the `:authority` value (HTTP/2, extended CONNECT) must match
an entry. The match is exact and case-insensitive on the host and the port. An entry
without a port matches the default port of the scheme of the transport. A value that
is not a usable authority never matches a non-empty list. A request that does not
match is refused with 403. The check runs after the origin policy.

## The HTTP/1.1 handshake

An application accepts an upgrade inside an ordinary handler:
`AcceptWebSocket(ARequest, AResponse, AHandler)`. The function answers True when the
session started and False after an error response; the handler then returns. Routing,
cookies and authentication by header stay in the handler (RFC 6455 section 4.2.2,
steps 2 and 3). The checks run in this order, and a failed check answers an HTTP
error and leaves the connection for the next request:

| Check | Failure |
| --- | --- |
| the method is `GET` | 405 with `Allow: GET` |
| the version is HTTP/1.1 and `Upgrade` and `Connection` hold the tokens `websocket` and `Upgrade`, in any case | 400 |
| exactly one `Sec-WebSocket-Key` that decodes from base64 to 16 octets | 400 |
| exactly one `Sec-WebSocket-Version` with the value 13 | 400 with `Sec-WebSocket-Version: 13` (RFC 6455 section 4.4) |
| the origin policy | 403, or 400 for a value that is not an origin |
| the request has no body and no octets follow the head | 400 |
| the server holds fewer than `MaxDetachedStreams` channels | 503 with `Retry-After` |

After the checks the function detaches the response into a pending channel of raw
bytes, starts the session and returns. The session's first task is `Init`. From that
moment the HTTP/1.1 core sends the octets that arrive on the connection to the
channel, so a client that sends WebSocket octets before the response cancels the
session. No `101` goes out before `Init` accepts.

- **Accept.** The server sends `101 Switching Protocols` with `Upgrade: websocket`,
  `Connection: Upgrade`, `Sec-WebSocket-Accept` (the base64 of the SHA-1 of the key and
  the GUID of RFC 6455 section 1.3) and `Sec-WebSocket-Protocol` when `Init` chose a
  subprotocol. It sends no `Sec-WebSocket-Extensions` field, because it supports no
  extension. The frames that `Init` queued follow the response. The core then
  parses the connection no more: the channel carries raw bytes both ways.
- **Reject.** The channel answers with an ordinary HTTP response, and the core
  resumes HTTP/1.1 on the connection when the response allows keep-alive.
- **The subprotocol.** The client offers tokens in `Sec-WebSocket-Protocol`. The
  names that reach `Init` are those that the server list holds, compared as
  case-sensitive tokens (RFC 7936); an empty server list passes every offer on.
- **The idle time.** An upgraded connection is not closed by the idle timeout of
  HTTP/1.1. The heartbeat of the session keeps it, and a session with the ping
  interval 0 holds its connection until a peer or the server ends it. The
maximum connection age never closes such a connection: the age sweep skips an
upgraded connection (as described in [lifecycle](lifecycle.md)).
- **The close.** The server closes the TCP connection after the closing handshake
  (RFC 6455 section 7.1.1) and does not wait for the client to close first. The write
  side closes first, then the connection, as for any close of HTTP/1.1.
- **No flow control.** HTTP/1.1 has no window. A client that sends a burst of
  messages faster than the application takes them fills the queue of the session,
  and the session closes with 1008 when the queue passes `QueuedMessages`. An
  application that expects bursts of this kind on HTTP/1.1 sets a larger queue. On
  HTTP/2 the same burst waits for the window instead (see [The queue cap](#the-receive-path)). A client that sends one large
  message faster than the handler reads it fills the pipe of the message, and the session
  closes with 1009 when the unread octets pass `InboundPipeBytes`. This cap exists on a
  channel that returns no credit only; on HTTP/2 the stream window bounds the pipe.


## The HTTP/2 handshake

A client opens a WebSocket on one HTTP/2 stream with the extended CONNECT method of
RFC 8441 (checked on 2026-10-22 at https://www.rfc-editor.org/info/rfc8441). The
handler code is the same: `AcceptWebSocket(ARequest, AResponse, AHandler)` picks the
handshake from the response it receives.

- **The setting.** The server sends `SETTINGS_ENABLE_CONNECT_PROTOCOL` (code 8) with the
  value 1 in its first `SETTINGS` frame when the factory ran `WithWebSockets`. Without
  the call the frame holds no such entry, and a request with `:protocol` is a stream
  error of the type `PROTOCOL_ERROR` (RFC 8441 section 4). The server never sends the
  value 0 after the value 1. The server reads the setting of a client and ignores it
  (RFC 8441 section 3).
- **The request.** The method is `CONNECT`, `:protocol` is `websocket`, and `:scheme`,
  `:path` and `:authority` are present. The pseudo-header `:protocol` is legal once, with
  a value that is not empty, and only on `CONNECT`. The request holds neither a key nor
  `Upgrade` and `Connection` fields, because the stream carries the semantics (RFC 8441
  section 5). A `CONNECT` without `:protocol` keeps the behaviour it had.
- **The checks.** After the request validation the function checks, in this order: the
  method (405, `Allow: CONNECT`), the protocol value (501 for a value other than
  `websocket`), the version (400 with `sec-websocket-version: 13`), the origin policy
  (403 or 400) and the detach limit (503 with `Retry-After`). An answer is an ordinary
  response with `END_STREAM`, and the HTTP/2 connection stays open.
- **Accept.** The response is `:status 200` with `sec-websocket-protocol` when `Init`
  chose a subprotocol, and without `END_STREAM`. The stream is detached before `Init`
  runs, so no `200` goes out before `Init` accepts. A reject from `Init` is an
  ordinary response with `END_STREAM`.
- **After the head.** The stream accepts `DATA`, `RST_STREAM`, `WINDOW_UPDATE` and
  `PRIORITY`. A second `HEADERS` block, a trailer for example, is a stream error.
- **The handler time limit.** When the option `MaxHandlerTimeMs` is set (its default
  is 0, which turns the limit off), the limit applies to the checks and the detach of
  the handshake, because they run in the handler thread. The session does not run in
  that thread, so the limit does not bound it. The answer to a handler that passes the
  limit is in [limits](limits.md).

### The close mapping

| Event | Action on the stream |
| --- | --- |
| both Close frames are done | the server ends its half with `END_STREAM` |
| the client ends its half with no Close frame | `Closed(1006, clean = False)`, then `END_STREAM` from the server |
| the parser finds a protocol error | Close 1002, then the server ends the stream |
| `RST_STREAM` from the client | `Closed(1006)`, and no frame goes out |
| `GOAWAY` or the loss of the connection | `Closed(1006)` |
| `Stop` | Close 1001, then `END_STREAM` after the close timeout |

The HTTP/2 connection stays open in each row except the last two.

### Flow control

The `DATA` frames of a WebSocket stream use the usual windows of the stream and of the
connection. The connection window is credited when a frame arrives. The session returns
credit to the stream when the parser takes the octets of a frame header, of a control
frame and of a message in memory. For a streamed message it returns the credit of the
payload octets as the handler reads them, so a slow handler slows its own stream and no
other. The session holds the credit back while its queue is full. An outbound message
waits in the channel queue, and `Send` answers `srFull` when the queue is full.

### The maximum age

The maximum connection age never closes a WebSocket. The age sweep skips an
HTTP/2 connection while a WebSocket stream is open on it, and the forced close
never cuts such a stream. When the last WebSocket stream ends, the next sweep
checks the age again (as described in [lifecycle](lifecycle.md)). A WebSocket stream counts
as one stream toward the stream cap (as described in [limits](limits.md)).

### The client certificate

When the listener asks for client certificates ([mtls](mtls.md)), the identity of the
TLS client belongs to the connection. The extended `CONNECT` request reads it through
`IServerRequest.ClientCertificate`, as every other stream does. The session snapshot
of the request holds the same reference, so `IWsSession.Request.ClientCertificate`
answers the identity after the handler call of the handshake has returned. The same
rule holds for the HTTP/1.1 upgrade. In the optional mode a client without a
certificate still opens a session, the identity is nil, and `Init` can refuse with a
status such as 401.

### The cost of a refusal

A refused handshake is an ordinary response on a live stream. It is not a reset, and
no abuse bucket counts it. A request that the validator finds malformed, a `:protocol`
without the setting for example, is a stream error and counts as the other resets
of the connection do (as described in [limits](limits.md)).


### The session cap

The server counts its open WebSocket sessions. `MaxWsSessions` is the greatest number
of open sessions; 0 turns the cap off. An upgrade that arrives when the cap is reached
is answered with 503 and no session starts. The slot of a session returns once, when
the session ends: after a Close frame, a protocol error, a lost peer, a refused or
timed out `Init`, or a failed callback.

## Settings

The record `TWsOptions` belongs to the server builder (`WithWebSockets`). The
defaults live in `Create`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `MaxMessageSize` | 1048576 | the greatest message that the server receives, in octets, over all fragments; for a message that `SendStream` sends, the greatest chunk, in octets |
| `MaxFrameSize` | 65536 | the greatest payload of one frame that the server accepts |
| `MaxFragments` | 1024 | the greatest number of frames of one message |
| `QueuedMessages` | 16 | the count of messages that wait for the application at which the queue closes a session with 1008 on a channel without flow control; on HTTP/2 the count at which the credit of the peer waits and the window holds it |
| `FrameSize` | 16384 | the payload size of the frames the server sends |
| `PingIntervalMs` | 30000 | the idle time before a Ping; 0 turns the Ping off |
| `PongTimeoutMs` | 10000 | the wait for the Pong |
| `CloseTimeoutMs` | 5000 | the wait for the Close frame of the peer |
| `InitTimeoutMs` | 10000 | the wait for `Init` |
| `ControlBucket` | 100 tokens, 10 a second | Ping and Pong frames that arrive |
| `MessageBucket` | 10000 tokens, 10000 a second | data messages that arrive |
| `WsEarlyBytes` | 262144 | the octets that the channel holds before the session takes it |
| `InlineLimit` | 65536 | the octets of a message that the server keeps in memory before it gives the message to the handler; a message that ends inside the limit goes to the handler whole, and a longer message streams; from 1 to 16777216 |
| `InboundPipeBytes` | 1048576 | the greatest count of unread octets of a streamed message on a channel that returns no credit; a push over it closes the session with 1009; at least `InlineLimit` plus `MaxFrameSize`; also the budget charge of every streamed message |
| `InboundStallMs` | 30000 | the time that a read of a streamed message waits for an octet; on expiry the session closes with 1008 |
| `OutboundStallMs` | 30000 | the time that the channel may refuse one fragment of a producer that `SendStream` runs; on expiry the session closes with 1008 and the producer ends |
| `OriginPolicy` | `opSameOrAbsent` | as described in above |
| `AllowedOrigins` | none | the allow-list, each entry `scheme://host[:port]` |
| `WsAllowedHosts` | none | the host allow-list, each entry `host[:port]`; an empty list turns the check off |
| `Subprotocols` | none | the subprotocols the server picks from, in order of preference |

The record `TServerLimits` holds `MaxWsQueuedBytes` (default 128 MiB, at least 1 MiB) and
`MaxWsSessions` (default 5000, 0 turns the cap off).

The factory validates each value and the entries of both lists.

## Counters and events

The statistics hold the open sessions, the messages and the payload octets in each
direction, the sessions closed for a protocol error and the sessions closed for a
missing Pong. The observer gets `seWsOpened`, `seWsRejected` (with the status),
`seWsClosed` (with the code), `seWsFailed` and `seWsBucketTripped`.

## RFC references

- [RFC 6454](https://www.rfc-editor.org/rfc/rfc6454.html), checked 2026-11-11.
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html), checked 2026-11-11.
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html) section 5.4 (fragmentation), section 5.5 (control frames) and section 5.5.1 (close), checked 2026-11-17. The plain-text copy is `doc/references/rfc6455.txt`.
- [RFC 7936](https://www.rfc-editor.org/rfc/rfc7936.html), checked 2026-11-11.
- [RFC 8441](https://www.rfc-editor.org/rfc/rfc8441.html), checked 2026-11-11.
