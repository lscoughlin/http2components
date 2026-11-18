---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, body_reader, chunk, TChunkBuffer, streaming, upload, response body, ReadAllBody, CopyBody, GetStream, GetStreamReader, TReaderStream, TStreamReader, producer, IBodyProducer, IBodyChunkSink, TProducerStream, BodyWriterFromStream, BodyWriterFromTextWriter, look-ahead, ALast
notes:
  - This document describes the body writer contract that the server and the client share.
  - The reader contract is the inbound partner of the writer contract. See the section Reader.
  - A reader gives a TStream (GetStream) and a TStreamReader (GetStreamReader) over its body. The caller owns both.
  - RFC 9112 section 7.1 (chunked transfer coding) was checked on 2026-11-17 at https://www.rfc-editor.org/rfc/rfc9112.html. The plain-text copy is doc/references/rfc9112.txt.
  - RFC 6455 section 5.4 (fragmentation) was checked on 2026-11-17 at https://www.rfc-editor.org/rfc/rfc6455.html. The plain-text copy is doc/references/rfc6455.txt.
scope: The shared interfaces IBodyWriter, IBodyReader, IBodyChunkSink and IBodyProducer, the buffer TChunkBuffer, the producer stream, the helper routines, the end of a body, and the threads and memory of each place that pulls a writer, runs a producer or reads a body.
primary_types:
  - IBodyWriter
  - IBodyReader
  - IBodyChunkSink
  - IBodyProducer
  - TChunkBuffer
  - TReaderStream
  - TProducerStream
related_docs:
  - ../server/seam.md
  - ../server/websocket.md
  - ../client/messages.md
invariants:
  - The library owns the chunk buffer and resets it before each call.
  - A writer does not keep the buffer after the call returns.
  - The library never calls NextChunk on an IO thread.
  - The library sends the octets of the last call before it ends the body.
  - A reader returns True only with at least one octet written.
  - The end of a body repeats on every later call of a reader.
  - A stream from GetStream holds a reference to its reader until the stream is freed.
  - A TStreamReader from GetStreamReader owns its stream, so freeing it frees the stream.
  - A producer writes its chunks to a sink. The producer stream keeps one chunk back, so the call that ends the body has ALast True.
  - A sink call with ALast False has at least one octet.
  - A producer body runs once. A second run raises EBodyFormatError.
  - A producer that raises sends no last chunk.
  - A Write of a producer stream blocks while the sink blocks.
---

# Body writer

## Purpose

An `IBodyWriter` gives a body to the library in pieces. The library pulls one
chunk at a time, so a body or a WebSocket message can be larger than the memory
of the process. The server and the client use one interface, declared in the
unit `Http2.Common.Body`.

## The interface

```pascal
IBodyWriter = interface
  function NextChunk(const ABuffer: TStream): Boolean;
end;
```

`Http2.Server.IBodyWriter` and `Http2.Client.IBodyWriter` are aliases of
`Http2.Common.Body.IBodyWriter`. A program that uses both units uses one type.

The library calls `NextChunk` until the call returns False. A call that returns
True gives a chunk. A call that returns False ends the body.

## The buffer

The library passes a `TChunkBuffer`. It is a `TMemoryStream`. Its `Reset` method
sets `Size` and `Position` to 0 and keeps the allocated memory. A long body
therefore makes no new allocation after the first few chunks.

A buffer lives for one body only. The library frees it when the body ends. A
buffer is not thread safe. One thread uses one buffer at a time, and the buffer
does not leave that thread.

## The contract of one call

- On entry the stream is empty: `Size` is 0 and `Position` is 0.
- The writer writes the chunk at the current position. It can use `WriteBuffer`,
  or `CopyFrom` a file stream. After the call, the octets in `[0, Size)` form
  the chunk.
- A writer does not keep a reference to the stream after the call returns.
- A writer does not seek to a place before the position where the call began.
- The library reads a chunk through `Size`. It never reads through `Position`.
- A call that returns True with `Size` of 0 gives an empty chunk. The library
  skips the empty chunk. Where the protocol needs a zero-length frame or chunk
  to mark the end, the library does not treat the empty chunk as that marker.
- A call that returns False with octets written gives the last chunk of the
  body. The library sends those octets, and then it ends the body.
- A call that returns False with no octets ends the body. Where the protocol
  needs a final frame or marker, the library sends it at that point.
- A writer can block in a call. The library calls `NextChunk` only on a thread
  that can wait (see "Threads and memory").
- A place with a limit on one chunk ends the body as a failure when a chunk is
  over that limit. The WebSocket stream has such a limit (`MaxMessageSize`).
- An exception that `NextChunk` raises ends the body as a failure. The place that
  pulls the writer reports the failure to its caller (see
  [errors and redirects](../client/errors-redirects.md) for the client).

## Helpers

The unit `Http2.Common.Body` has three helper routines.

| Routine | Meaning |
| --- | --- |
| `ChunkAppend(ABuffer, AData)` | writes the octets of a `TBytes` at the current position; an empty array writes nothing |
| `ChunkAppendText(ABuffer, AText)` | writes the octets of a UTF-8 string at the current position; an empty text writes nothing |
| `ChunkBytes(ABuffer)` | returns the octets in `[0, Size)` as a new array |

A writer that already has a `TBytes` appends it with `ChunkAppend`. A place that
needs an array for a frame or for a channel write takes the chunk with
`ChunkBytes`. That call copies the chunk once into an array of the exact size.

## Threads and memory

Each place that pulls a writer runs `NextChunk` on the thread named below.

| Place | Thread of `NextChunk` | Buffers | Behavior |
| --- | --- | --- | --- |
| Server HTTP/2 response (`Finish`) | the handler thread that calls `Finish` | one | each chunk goes to `Write`, which waits while the outbound buffer is over its limit |
| Server HTTP/1.1 response (`SetBodyWriter`) | the handler thread that calls `SetBodyWriter` | one | each chunk goes to `Write`, which waits for room in the outbound buffer |
| Server compressing writer (`TCompressingBodyWriter`) | the thread that pulls the compressing writer | one, owned by the compressing writer | pulls one inner chunk at a time, and pulls the next one when the coder gives no octets |
| WebSocket stream (`SendStream`) | a streaming pool thread | one | reads at most 16 chunks in one step, then ends the step; parks when the channel is full |
| Client HTTP/2 request body | the thread of the client call that sends the request | two, swapped | pulls the next chunk before it sends the chunk in hand |
| Client HTTP/1.1 request body | the thread of the client call that sends the request | two (`Body` and `Wire`) | each chunk goes out in one socket write with its chunk header and CRLF |

No place calls `NextChunk` on an IO thread. The IO thread never waits for a
writer.

Memory follows one rule. The library writes a chunk before it calls `NextChunk`
again, so a body holds one chunk at a time. Two exceptions exist. The HTTP/2
client keeps one chunk of look-ahead, so that it knows which chunk carries the
end of the body. The WebSocket stream keeps the encoded fragment while the channel
refuses it. The HTTP/1.1 client also holds the framed copy of a chunk while it
writes that copy.

The memory of a buffer is at most the greatest chunk that the writer chose. A
buffer keeps its allocation after a smaller chunk, and it frees the allocation
when the body ends. The limit of a place (for example `MaxMessageSize` for one
WebSocket chunk) bounds the greatest chunk where such a limit applies.

The library releases a writer when its body ends, and for a WebSocket stream
that can be on an IO thread. A WebSocket stream ends when the peer closes the
session or when the session fails, and the release then runs on the thread that
ends the session. The destructor of a writer therefore does not block, and it
does not take a lock that a caller of `Send` can hold.

## The end of a body

The octets of the last call are part of the body. A writer can return its final
chunk and False in one call. The library sends those octets, and then it ends the
body. Each place marks the end in its own protocol:

- The WebSocket stream sends the last chunk as the last fragment, with the FIN bit
  (RFC 6455 section 5.4). When the last call has no octets, the stream sends one
  empty continuation frame with FIN. When no chunk was sent at all, the stream
  sends one empty frame with the message opcode and FIN.
- The HTTP/1.1 client sends the last chunk, then the last-chunk marker `0` and the
  empty trailer (RFC 9112 section 7.1).
- The HTTP/2 client sets END_STREAM on the DATA frame of the last chunk. When the
  body has no octets, the client sets END_STREAM on an empty DATA frame.

## Producers

A producer is code that writes its body to a `TStream` or to a `TStreamWriter`.
The unit `Http2.Common.Body.Producers` turns such code into the body of an
`IBodyWriter`. The body streams, and the producer runs on the thread of the place
that sends the body. The unit creates no thread.

### The interfaces

Both interfaces are declared in `Http2.Common.Body`.

```pascal
IBodyChunkSink = interface
  procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
end;

IBodyProducer = interface
  procedure Produce(const ASink: IBodyChunkSink);
end;
```

- `IBodyChunkSink` is the place that receives the chunks. A call of `Chunk` blocks
  until the place accepts the chunk. This is the backpressure. `Chunk` raises when the
  body can not go on, for example when the peer resets the stream.
- A call of `Chunk` with `ALast` False has `ACount` above 0.
- The last call has `ALast` True. The last call can have `ACount` of 0. Then the call
  only ends the body.
- `IBodyProducer` runs the producer to its end on the calling thread. `Produce`
  gives each chunk to the sink. An exception of the producer or of the sink passes to
  the caller.
- A writer made by the factories supports `IBodyProducer`. A place that supports
  producers asks the writer for `IBodyProducer`, and it calls `Produce` with its own
  sink. A place that does not support producers pulls the writer with `NextChunk`.

### The factories

| Factory | Producer method | Encoding |
| --- | --- | --- |
| `BodyWriterFromStream(AProducer, AChunkBytes)` | `TStreamProducer = procedure(const AOut: TStream) of object` | none; the octets of the producer are the octets of the body |
| `BodyWriterFromTextWriter(AProducer, AEncoding, AChunkBytes)` | `TTextProducer = procedure(const AOut: TStreamWriter) of object` | `AEncoding`; nil means UTF-8 without a byte order mark |

`AChunkBytes` is the largest chunk. Its default is `cReadChunkBytes` (16384). A nil
producer raises `EBodyFormatError`. The producer is a method pointer, because FPC 3.2.4
has no anonymous methods.

The caller owns the object of the producer. The caller keeps it until the body
ends. The text factory does not free `AEncoding`. The caller keeps the encoding
until the body ends.

### The producer stream

`TProducerStream` is a write-only `TStream` that the factories give to the
producer. Its behavior is as follows.

- `Write` appends the octets to the current chunk. A chunk never holds more than
  `AChunkBytes` octets. A write of more octets gives several chunks.
- A full chunk becomes the pending chunk. When another chunk becomes full, the
  pending chunk goes to the sink with `ALast` False. The stream therefore keeps one
  chunk back. When the producer ends, the stream knows which chunk is the last one.
- `Finish` sends the octets that the stream holds. The last call that holds octets
  carries `ALast` True. When the body ends on a chunk boundary, the pending chunk is that
  call, and no empty call follows. When no octet was written at all, `Finish` sends one
  empty call with `ALast` True.
- A call of the sink blocks, so a `Write` blocks while the place does not accept the
  chunk. This is the rule of `IServerResponse.Write`. A producer that writes faster
  than the place sends waits.
- `Read`, `SetSize` and `Seek` raise `EStreamError`. `Seek(0, soCurrent)` gives the
  count of the octets written.
- A second call of `Finish` does nothing. A `Write` after `Finish` raises `EStreamError`.
- After a sink failure, a `Write` drops its octets, and `Finish` raises
  `EStreamError`. The factories never send a last chunk after a producer failure.
- `Destroy` never calls the sink.

The text factory writes through a `TStreamWriter` over the producer stream. The
writer flushes its buffered octets before the last chunk is sent. The writer writes
no preamble. The unit uses a subclass of `TStreamWriter`, because the `Flush` of
FPC 3.2.4 passes the array of its buffer to `WriteBuffer`. The octets that reach the
stream are then the bytes of the array reference, not the text. The subclass
writes its buffered octets itself.

### The end of a producer body

The body ends with the last call of the sink, with `ALast` True. A producer that
raises an exception passes it to the caller unchanged. The factory sends no last
chunk after that exception. The chunks that the sink already got stay sent, with
`ALast` False. A place that receives such a body therefore sees a body without a
last chunk. The place reports that body as failed, in the protocol that it uses.

A sink that raises an exception in `Chunk` passes that exception out of the `Write`
of the producer. When the producer does not catch it, the exception passes out of
`Produce`.

### The threads that run a producer

`Produce` runs the producer on the calling thread. The place that calls `Produce`
decides that thread, and the producer blocks that thread when the sink blocks. The
unit does not start a thread.

### The buffered fallback

A writer that a place pulls with `NextChunk` runs the producer on the first call.
The producer writes into one `TMemoryStream`. Then each call gives at most
`cReadChunkBytes` octets of that memory. The call that gives the last octets returns
False. The memory is freed when the body ends. A body without octets gives False at
once. A later call gives False with no octet.

This path holds the whole body in memory. A place that supports producers calls
`Produce` and does not use this path.

### Single use

A producer body runs once. The first `Produce`, or the first `NextChunk`, starts the
run. These calls raise `EBodyFormatError`:

- a second `Produce`;
- a `NextChunk` after a `Produce`;
- a `Produce` after a `NextChunk`.

A producer that raised leaves its body in a failed state. A later call raises
`EBodyFormatError` too.

## Reader

An `IBodyReader` gives a body to its caller in pieces. It is the inbound partner
of `IBodyWriter`. A caller reads a body that is larger than the memory of the
process one chunk at a time. The interface is declared in the unit
`Http2.Common.Body`, with the same shared unit as the writer.

```pascal
IBodyReader = interface
  function Read(var ABuffer; const ACount: Integer): Integer;
  function ReadChunk(const ABuffer: TStream): Boolean;
  function GetStream: TStream;
  function GetStreamReader: TStreamReader;
end;
```

### The contract of ReadChunk

- `ReadChunk` appends the next chunk to the buffer at its current position. The
  call does not clear the buffer.
- A call that returns True writes at least one octet. A chunk is never empty.
- A call that returns False ends the body. The octets that this call writes are
  the last chunk of the body, and they are part of the body.
- Every later call returns False and writes no octet.
- The reader does not keep the buffer after the call returns. The caller owns
  the buffer and can reuse it for the next call.
- The reader does not seek to a place before the position where the call began.

### The contract of Read

- `Read` gives at most `ACount` octets into `ABuffer`, and it answers the count
  that it wrote.
- `Read` blocks until one octet arrives or the body ends. A count below `ACount`
  is a short read. It is not the end.
- A count of 0 means that the body has ended. Every later call answers 0 too.

### The base class

`TBodyReaderBase` implements `IBodyReader`. A descendant implements `Read`. The
inherited `ReadChunk` makes one `Read` call of at most `cReadChunkBytes` (16384
octets). It appends the octets that the call wrote. A reader that has natural
chunks overrides `ReadChunk` and keeps the same contract. The inherited
`GetStream` and `GetStreamReader` give the stream and the text reader of the
next section.

### The stream and the text reader

`GetStream` gives a `TStream` over the body. `GetStreamReader` gives a
`TStreamReader` (the class of the FCL unit `streamex`) over that stream. The
caller owns the object that it gets, and the caller frees it.

- The stream is a `TReaderStream` in the one-call mode. Each `Read` of the stream
  makes one `Read` call of the reader. A short read is not the end of the body.
- The stream is read only and not seekable. `Seek` and `Write` raise
  `EStreamError`. `GetSize` raises too.
- The stream holds a reference to the reader. The reader lives while the stream
  lives, even when the caller has released its own reference.
- The reader is held by an interface reference when the caller calls `GetStream`.
  The stream adds one reference. When the stream is freed and no other reference
  exists, the reader is freed too.
- The stream is for one pass. A `Read` after the end gives 0, and every later
  `Read` gives 0 too.
- The `TStreamReader` owns its stream: `OwnsStream` is True. Freeing the
  `TStreamReader` frees the stream, and the stream releases the reader.
- A stream and its text reader are not thread safe. One thread uses them at a time.

The one-call mode suits a consumer that takes each short read as a part of the
body. The XML parser of the FCL takes a short read as the end of its input.
`ReadXml` therefore keeps its own stream in the filling mode (`FillReads` True).
A consumer with a parser of its own can use `GetStream` when the parser accepts
short reads.

### The helpers

| Routine | Meaning |
| --- | --- |
| `ReadAllBody(AReader, AMax)` | reads the body to its end and gives all its octets as a new array; with `AMax` above 0, a longer body raises `EBodyTooLarge` |
| `CopyBody(AReader, ADest)` | copies the body to `ADest` one chunk at a time, with `WriteBuffer` only |
| `BodyStream(AReader)` | gives a new `TReaderStream` in the one-call mode; the caller frees it |
| `BodyStreamReader(AReader)` | gives a new `TStreamReader` over `BodyStream(AReader)`, with `OwnsStream` True; the caller frees it |

`GetStream` and `GetStreamReader` of `TBodyReaderBase` return the results of
`BodyStream` and `BodyStreamReader`. A class that implements `IBodyReader` with
its own methods gives the two methods with the same one-line delegates.

The limit of `ReadAllBody` applies after each chunk. A longer body therefore stops
at the first chunk over the limit. The octets of the last call count toward the
limit too.

`CopyBody` does not seek or size the destination. The destination can be a stream
that cannot seek.

### Threads and memory

- A reader is not thread safe. One thread reads one body at a time.
- A call of a reader can block the thread that makes it, until an octet arrives
  or the body ends.
- The base `ReadChunk` allocates the array of one `Read` call and frees it when the
  call returns. The buffer of the caller holds the chunk.
- `ReadAllBody` holds the whole body in one buffer. `CopyBody` holds one chunk at
  a time, and the buffer keeps its memory for the next chunk.

### The end of a body

The end of a body is a `Read` that answers 0, or a `ReadChunk` that returns False.
Both answers repeat on every later call. A reader that fails raises an exception
from `Read` or `ReadChunk`, and the exception passes to the caller. A reader that
answers a count outside of its range raises `EBodyFormatError`.

## Format helpers

The text, JSON and XML helpers read a body through `IBodyReader` and write a body
through `IBodyWriter`. They are in the units `Http2.Common.Body.Text`,
`Http2.Common.Body.Json` and `Http2.Common.Body.Xml`. The read-only stream
`TReaderStream` is declared in `Http2.Common.Body`, so that `GetStream` can give
it. The unit `Http2.Common.Body.Streams` keeps the name as an alias. The contract
of each helper is in [formats](formats.md).

## RFC references

- [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), section 7.1 (chunked
  transfer coding), checked 2026-11-17.
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html), section 5.4
  (fragmentation), checked 2026-11-17.
