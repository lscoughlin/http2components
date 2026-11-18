---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, body_reader, chunk, TChunkBuffer, streaming, upload, response body, ReadAllBody, CopyBody
notes:
  - This document describes the body writer contract that the server and the client share.
  - The reader contract is the inbound partner of the writer contract. See the section Reader.
  - RFC 9112 section 7.1 (chunked transfer coding) was checked on 2026-11-17 at https://www.rfc-editor.org/rfc/rfc9112.html. The plain-text copy is doc/references/rfc9112.txt.
  - RFC 6455 section 5.4 (fragmentation) was checked on 2026-11-17 at https://www.rfc-editor.org/rfc/rfc6455.html. The plain-text copy is doc/references/rfc6455.txt.
scope: The shared interfaces IBodyWriter and IBodyReader, the buffer TChunkBuffer, the helper routines, the end of a body, and the threads and memory of each place that pulls a writer or reads a body.
primary_types:
  - IBodyWriter
  - IBodyReader
  - TChunkBuffer
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

## Reader

An `IBodyReader` gives a body to its caller in pieces. It is the inbound partner
of `IBodyWriter`. A caller reads a body that is larger than the memory of the
process one chunk at a time. The interface is declared in the unit
`Http2.Common.Body`, with the same shared unit as the writer.

```pascal
IBodyReader = interface
  function Read(var ABuffer; const ACount: Integer): Integer;
  function ReadChunk(const ABuffer: TStream): Boolean;
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
chunks overrides `ReadChunk` and keeps the same contract.

### The helpers

| Routine | Meaning |
| --- | --- |
| `ReadAllBody(AReader, AMax)` | reads the body to its end and gives all its octets as a new array; with `AMax` above 0, a longer body raises `EBodyTooLarge` |
| `CopyBody(AReader, ADest)` | copies the body to `ADest` one chunk at a time, with `WriteBuffer` only |

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

## RFC references

- [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html), section 7.1 (chunked
  transfer coding), checked 2026-11-17.
- [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455.html), section 5.4
  (fragmentation), checked 2026-11-17.
