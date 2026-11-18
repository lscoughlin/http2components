---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: text, JSON, XML, body reader, body writer, TReaderStream, EBodyFormatError, fcl-json, fcl-xml, us-ascii, pushback
notes:
  - The text, JSON and XML helpers are in the common units. The client readers and body helpers are wrappers over them.
  - fcl-json parses a whole text. ReadJson reads the whole body into memory before it parses.
  - fcl-xml takes a short Read as the end of its input. TReaderStream gives fcl-xml full reads when its FillReads mode is on.
  - A serialized writer builds its whole document in memory when the first chunk is asked for.
  - The us-ascii declaration rule is in Http2.Common.Body.Xml.
scope: The text, JSON and XML reader and writer helpers, the errors that they raise, the stream that feeds the XML parser, and the memory of each helper. The client wrappers of these helpers are in messages.md.
primary_types:
  - TReaderStream
  - TSerializedBodyWriter
  - TTextBodyWriter
  - TJsonBodyWriter
  - TXmlBodyWriter
  - EBodyFormatError
related_docs:
  - body.md
  - architecture.md
  - ../client/messages.md
  - ../server/public-api.md
invariants:
  - A reader helper raises EBodyFormatError for a body in the wrong format.
  - An exception of the reader passes to the caller unchanged, and it is never an EBodyFormatError.
  - A writer serializes its document on the first NextChunk call, and gives chunks of at most cReadChunkBytes.
  - The last chunk of a writer comes with False. A writer never gives an empty True chunk.
  - A writer frees its serialized octets when the body ends, and it repeats the end on every later call.
  - TReaderStream raises EStreamError on Seek, GetSize and Write.
  - ReadXml reads an XML declaration with encoding us-ascii or ascii as utf-8.
  - The caller owns each value that a reader helper returns.
  - The caller keeps the value or the document that a writer holds until the library ends the body.
---

# Format helpers

## Purpose

The format helpers read a text, JSON or XML body from an `IBodyReader`. They write
a text, JSON or XML body as an `IBodyWriter`. The helpers use the same interfaces
as the server and the client, so a body of any size passes through them one chunk
at a time on the writer side, and one chunk at a time on the reader side up to the
parser.

## Units

| Unit | Routines | Library dependency |
| --- | --- | --- |
| `Http2.Common.Body.Text` | `ReadText`, `TextBodyWriter` | run-time library only |
| `Http2.Common.Body.Json` | `ParseJson`, `ReadJson`, `ReadJsonObject`, `JsonBodyWriter` | fcl-json (the FCL package) |
| `Http2.Common.Body.Xml` | `ParseXml`, `ReadXml`, `XmlBodyWriter` | fcl-xml (the FCL package) |
| `Http2.Common.Body.Streams` | `TReaderStream`, `TSerializedBodyWriter` | run-time library only |

The JSON and XML units are separate. A program that does not use them does not
link fcl-json or fcl-xml. The unit `Http2.Common.Body.Streams` holds the base class
of the serialized writers, and the stream that the XML reader uses.

## Text

`ReadText(AReader, AMax)` reads the body to its end and gives its octets as a
string. The octets pass unchanged. The unit does not convert a charset, so the
caller decodes the string. With `AMax` above 0, a longer body raises
`EBodyTooLarge`. An exception of the reader passes to the caller.

`TextBodyWriter(AText)` writes the octets of `AText` as the body. The writer holds a
reference to the string for as long as the writer exists.

## JSON

`ParseJson(AText)` parses a text and gives a `TJSONData`. The caller owns the value.

`ReadJson(AReader)` reads the body to its end and parses it. fcl-json parses a
whole text, so the body is in memory before the parser starts. The memory of the
body is freed when the call returns. The result is a value that the caller owns.

`ReadJsonObject(AReader)` is `ReadJson` with a check that the value is a
`TJSONObject`. A body that is not a JSON object raises `EBodyFormatError`.

A body that is not JSON raises `EBodyFormatError`, with the text `body is not valid
JSON`. An exception of fcl-json does not leave the unit. An empty body is not JSON.

`JsonBodyWriter(AData)` writes the `AsJSON` text of `AData` as the body. A nil value
raises `EBodyFormatError`.

## XML

`ParseXml(AText)` parses a text and gives a `TXMLDocument`. The caller owns the
document.

`ReadXml(AReader)` parses the body and gives a `TXMLDocument`. The caller owns the
document. The reader works in two steps:

1. The unit reads the first octets of the body, up to 1024 octets or the end of the
   XML declaration, whichever comes first. It applies the us-ascii rule to them.
2. The unit gives the octets to fcl-xml through a `TReaderStream` in its
   `FillReads` mode, with the octets of step 1 pushed back in front of the body.

fcl-xml takes a short `Read` as the end of its input. The `FillReads` mode keeps
reading until the parser gets the count that it asks for, or the body ends. The
parser therefore reads across the chunks of the body. The document is in memory
when the call returns. The body is not in memory before the parser starts.

A body that is not well-formed XML raises `EBodyFormatError`, with the text
`body is not well-formed XML:` and the message of the parser. Only an exception of
the parser is converted. An exception of the reader passes to the caller unchanged,
and the document that the parser has started is freed.

`XmlBodyWriter(ADoc)` writes the serialization of `ADoc` as the body. A nil
document raises `EBodyFormatError`.

### The us-ascii rule

fcl-xml rejects an encoding declaration of `us-ascii` and `ascii`. The units rewrite
such a declaration to `utf-8` before the parser reads it. US-ASCII is a subset of
UTF-8, so the rewrite does not change the meaning of the octets. A declaration that
names another encoding is not changed. A declaration that names `windows-1252` or
`utf-16` still raises `EBodyFormatError`.

## Writers

The writer factories give an `IBodyWriter`:

| Factory | Body |
| --- | --- |
| `TextBodyWriter(AText)` | the octets of `AText` |
| `JsonBodyWriter(AData)` | the `AsJSON` text of `AData` |
| `XmlBodyWriter(ADoc)` | the serialization of `ADoc` |

All three classes derive from `TSerializedBodyWriter`. The base class works in
this way:

- The first `NextChunk` call serializes the whole document into one
  `TMemoryStream`. The serialization is made once.
- Each call gives at most `cReadChunkBytes` octets from the memory stream.
- The call that gives the last octets returns False. The octets of that call are the
  last chunk.
- The writer frees the memory stream when the body ends. A later call gives
  False with no octets.
- A document that serializes to no octets gives one call that returns False with no
  octets.

The writer does not claim to stream a document. The document is in memory when the
first chunk is asked for. The memory that the writer holds is the serialized
document, which is about the size of the text.

The library pulls a writer from one thread at a time. A writer is not thread safe.
The server pulls the writer of a response inside `SetBodyWriter` or `Finish`, on
the handler thread. The client pulls the writer of a request while it sends the
request.

The caller owns the value or the document that a writer refers to. The caller keeps
it until the library ends the body. For a response, that is the return of `Finish`.
For a request, that is the end of the send.

## Errors

| Error | Raised by | Cause |
| --- | --- | --- |
| `EBodyFormatError` | the readers, the writers, `ParseJson`, `ParseXml` | a body or a value of the wrong format, or a nil value of a writer |
| `EBodyTooLarge` | `ReadText` with a limit | a body longer than the limit |
| `EStreamError` | `TReaderStream` | a Seek, a size query or a Write |

An exception of a reader, such as a timeout or a closed connection, passes to the
caller unchanged in every helper. A helper does not convert it into a format error.

The client wrappers of the helpers turn an `EBodyFormatError` into
`EHttpProtocolError` (`ecProtocolError`). The message keeps the text of the common
unit, with the word `response` in front. A `ReadText` with a limit raises
`EHttpResponseTooLarge` where the common unit raises `EBodyTooLarge`. The
client contract is in [messages](../client/messages.md).

## TReaderStream

`TReaderStream` is a read-only stream over an `IBodyReader`:

- `Create(AReader, AFillReads)` selects the read mode. With `AFillReads` False, a
  `Read` makes one reader call, so it does not wait for more octets than the
  reader gives. With `AFillReads` True, a `Read` waits until the count is read or the
  body ends.
- `PushBack(AData)` puts octets in front of the octets that `Read` still gives.
  The pushback is served before the reader, and it never waits for the reader.
- `WireBytes` counts the octets that came from the reader, without the pushback.
- `ReaderFailed` is True after the reader raised an exception during a `Read`.
- `Seek`, `GetSize` and `Write` raise `EStreamError`.

The client uses the stream to decode a body with a content coding. In that use the
mode is single-read, so a decoder receives each chunk as it arrives.

## Memory

| Helper | Memory held at the peak |
| --- | --- |
| `ReadText` | the body octets, and the string of the same size |
| `ReadJson`, `ReadJsonObject` | the body octets, the string of the same size, and the JSON tree |
| `ReadXml` | the prolog of up to 1024 octets, and the document tree; the body is not held whole |
| `TextBodyWriter` | the text, and the memory stream of the same size after the first chunk |
| `JsonBodyWriter` | the JSON text, and the memory stream of the same size after the first chunk |
| `XmlBodyWriter` | the serialized document in the memory stream |

The memory of each writer is freed when the body ends. The memory of each reader
is freed when the call returns.
