---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, protocol, frames, hpack, flow-control
notes:
  - This document describes the shared wire protocol units.
scope: The shared protocol units and server-specific behavior.
primary_types:
  - THttp2ErrorCode
  - TFrameHeader
  - TFrame
  - TConnectionSettings
  - THpackCodec
  - TWindow
  - TFlowControl
db_tables: None.
related_docs:
  - doc/design/server/fpc-runtime.md
invariants:
  - A received frame larger than the advertised SETTINGS_MAX_FRAME_SIZE is a
    connection error of type FRAME_SIZE_ERROR.
  - A decoded header list never exceeds SETTINGS_MAX_HEADER_LIST_SIZE.
  - A flow-control window never exceeds 2^31-1 octets.
---
# HTTP/2 Protocol Units

The merged library carries shared HTTP/2 protocol units under
`Http2.Common.*`. Each unit holds one concern, uses no socket or thread, and
is free of the mORMot2 dependency. Source notices and origin hashes are
preserved in the source provenance record.

## Errors

`Http2.Common.Errors` holds the wire error codes and the exception hierarchy.
`THttp2ErrorCode` mirrors the code list of RFC 9113 section 7. An
`EHttpError` carries an `ErrorCode` value, which the connection places in a
`RST_STREAM` or `GOAWAY` frame.

The server adds four classes to the client set:

| Class | Base | Meaning |
|---|---|---|
| `EServerConfigError` | `EHttpError` | The factory rejected its own configuration. |
| `EStreamCancelled` | `EHttpStreamError` | The peer cancelled the stream. |
| `EStreamReset` | `EHttpStreamError` | The server sent `RST_STREAM` for the stream. |
| `EServerStopped` | `EHttpError` | The server stopped, so no stream makes progress. |

`EStreamCancelled` and `EStreamReset` descend from `EHttpStreamError`, so a
catch of the stream error class catches both. A caller that requires the
stream identifier reads the `StreamId` property of the base class
(`src/common/Http2.Common.Errors.pas`).

## Frames

`Http2.Common.Frames` freezes the wire format. A frame is a nine-octet header,
`TFrameHeader`, and a payload, `TFrame`, as RFC 9113 section 4.1 defines.

The unit carries payload builders, payload parsers, and stream operations.
The `ReadFrame` operation enforces the received-frame limit
(`src/common/Http2.Common.Frames.pas`): a frame header that states a length above
the limit raises `EHttpProtocolError` with `ecFrameSizeError` before the
server reads the payload. This check is what stops a peer from asking the
server to allocate an unbounded buffer.

### Client connection preface

A new connection starts with the 24-octet preface of RFC 9113 section 3.4,
`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`. The unit holds the octets in
`ClientPreface` and offers two entry points:

- `CheckClientPreface(const ABuffer: TBytes): Boolean` compares a buffer of
  exactly 24 octets with the constant.
- `ReadClientPreface(const AStream: TStream)` reads 24 octets and raises a
  protocol error when they differ. A stream that ends inside the preface
  raises `EHttpConnectionClosed`.

### Server settings

`BuildServerSettings` builds the `SETTINGS` frame that the server sends as the
first frame of a connection. It takes a `TConnectionSettings` record, so the
frame carries the values that the factory set and not a default. The frame
uses stream 0 and no ACK flag, as RFC 9113 section 6.5 requires.

The record `TConnectionSettings` holds one more value than the six settings of
RFC 9113: `EnableConnectProtocol`, which stands for `SETTINGS_ENABLE_CONNECT_PROTOCOL`
(code 8, RFC 8441 section 9.1). `Encode` writes the entry only when the value is set,
because the value 0 is the default. `Decode` reads the entry and stores the value. The
server reads the entry of a client and does not use it (RFC 8441 section 3).

`Decode` has two forms. `Decode(Payload)` reads the entries onto the protocol
defaults. `Decode(Payload, Base)` reads them as a delta onto `Base`, so an entry
that the frame does not name keeps its value (RFC 9113 section 6.5.3). The
connection uses the second form for every `SETTINGS` frame of the peer.
`HeaderPriorityDependsOn` skips the pad length octet of a PADDED `HEADERS`
frame before it reads the priority field.

## HPACK

`Http2.Common.Hpack` holds the HPACK codec of RFC 7541: the static table, the
dynamic table, the integer and string representations, and the Huffman code.
One `THpackCodec` holds one encoder table and one decoder table; no table is
shared between connections.

### The header-list limit

RFC 9113 section 10.5.1 defines the size of a field list as the sum over the
field of 32 octets, plus the name length, plus the value length. A large list
is a denial-of-service vector, so the decoder stops as soon as the running
total passes the cap. `THpackCodec.MaxHeaderListSize` holds the cap, and a
zero value removes it. The check runs inside the append step
(`src/common/Http2.Common.Hpack.pas`), so the decoder raises
`EHttpProtocolError` with `ecEnhanceYourCalm` part way through a hostile
block instead of building the full list first.

### The two table directions

The `SETTINGS_HEADER_TABLE_SIZE` of a peer describes the decoder of that peer
(RFC 9113 section 6.5.2), so it sizes the response encoder and never the request
decoder:

- The request decoder obeys the value that the server advertised. A dynamic
  table size update above that value is a compression error. A SETTINGS frame of
  the peer does not change the decoder (`THpackCodec.SetDecoderLimit`).
- The response encoder uses the smaller of the value of the peer and a local cap,
  which is the server's own setting (`SetEncoderCap`, `SetPeerTableSize`). The
  peer value starts at the default of 4096 until a SETTINGS frame names another.
- A change of the encoder size is signalled at the start of the next response
  block with a dynamic table size update (RFC 7541 section 4.2). When the size
  changed twice between two blocks, the block starts with the smallest size of
  the interval and then the final size. The encoder sends no update when the size
  did not change.

## Flow control

`Http2.Common.FlowControl` holds the window accounting. A `TWindow` carries a
size, a consumed count and the two directions. `TFlowControl` holds one
connection window and one window per open stream.

A window never exceeds 2^31-1 octets. The constant `MaxWindowSize` holds that
value (`src/common/Http2.Common.FlowControl.pas`), and both `ApplyUpdate` and
`ApplyInitialWindowDelta` checks the new size against this limit and reports
a flow-control error when the size is too large.

## RFC references

- [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html), checked 2026-11-11.
- [RFC 8441](https://www.rfc-editor.org/rfc/rfc8441.html), checked 2026-11-11.
- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html), checked 2026-11-11.
