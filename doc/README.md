---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: documentation, index, map
notes:
  - Imported topic records need final merged API review.
---

# Documentation map

This directory holds the design documents, reference copies, and source
verification records. The source verification records describe earlier
commits. They do not report results for the combined source tree.

## Common design

| Document | Subject |
| --- | --- |
| [Architecture](design/common/architecture.md) | The three public entry units and the separation of common, client, and server units. |
| [Protocol](design/common/protocol.md) | The shared HTTP/2 protocol areas and their RFC references. |

## Client design

The client topic documents came from the client source project. Their unit
names now use the planned `Http2.Client.*` and `Http2.Common.*` names. Details
that depend on final merged source remain under API review.

| Document | Subject |
| --- | --- |
| [Architecture](design/client/architecture.md) | Client layers and connection model. |
| [Client API](design/client/client-api.md) | Factory, client, request, and response contracts. |
| [Messages](design/client/messages.md) | Request, response, headers, and body data. |
| [Transport](design/client/transport.md) | Connections, TLS, ALPN, and transport. |
| [Protocol](design/client/protocol.md) | Frames, HPACK, and flow control. |
| [Fallback](design/client/fallback.md) | Clear-text HTTP/2 and HTTP/1.1 fallback. |
| [Proxy](design/client/proxy.md) | HTTP, HTTPS, and SOCKS proxy routes. |
| [Mutual TLS](design/client/mtls.md) | Client identity and certificate selection. |
| [Errors and redirects](design/client/errors-redirects.md) | Error classes, timeouts, retries, and redirects. |
| [Server-sent events](design/client/server-sent-events.md) | Event parsing and reconnect behavior. |
| [WebSocket](design/client/websocket.md) | Client WebSocket sessions. |
| [Request observability](design/client/request-observability.md) | Request-level events and adapters. |
| [Testing observability](design/client/testing-observability.md) | Test seams and protocol observations. |
| [FPC runtime](design/client/fpc-runtime.md) | Compiler and runtime notes from the client source. |
| [Open questions](design/client/open-questions.md) | Questions in the client source design. |

## Server design

The server topic documents came from the server source project. Their unit
names now use the planned `Http2.Server.*` and `Http2.Common.*` names. Details
that depend on final merged source remain under API review.

| Document | Subject |
| --- | --- |
| [Architecture](design/server/architecture.md) | Server layers, threads, and request path. |
| [Threading](design/server/threading.md) | IO, handler, and cancellation work. |
| [Configuration](design/server/configuration.md) | Server factory options and validation. |
| [Public API](design/server/public-api.md) | Server, handler, and observer contracts. |
| [Lifecycle](design/server/lifecycle.md) | Start, stop, drain, and shutdown. |
| [Connection](design/server/connection.md) | Connection state and frame processing. |
| [Admission](design/server/admission.md) | Bounded request admission and refusal. |
| [Output](design/server/output.md) | Response encoding and frame output. |
| [Protocol](design/server/protocol.md) | Server protocol units and error behavior. |
| [HTTP/1.1](design/server/http1.md) | HTTP/1.1 fallback and parsing. |
| [TLS](design/server/tls.md) | TLS and ALPN. |
| [Mutual TLS](design/server/mtls.md) | Client-certificate policy. |
| [WebSocket](design/server/websocket.md) | Server WebSocket sessions. |
| [Server-sent events](design/server/sse.md) | Event encoding and stream behavior. |
| [Limits](design/server/limits.md) | Request and connection work limits. |
| [IO pool](design/server/io-pool.md) | mORMot2 asynchronous IO integration. |
| [Seam](design/server/seam.md) | Handler-facing stream interfaces. |
| [FPC runtime](design/server/fpc-runtime.md) | Compiler and runtime notes from the server source. |
| [Future coroutines](design/server/future-coroutines.md) | Deferred coroutine design. |
| [Access log](design/server/access-log.md) | Access-log records and writers. |

## References and source history

The [reference index](references/README.md) lists the specification copies,
source URLs, retrieval dates, and SHA-256 hashes. The server reference files
are verbatim copies from its source revision. RFC 1928 and RFC 1929 are the
additional client references.

The [migration table](migration-0.30.0.md) contains all 102 old-to-new unit
names. The source histories are [client 0.23.0](history/client-0.23.0.md)
and [server 0.29.0](history/server-0.29.0.md). Those numbers identify source
package versions; they do not assert that either version was released.

## Verification records

The [client compiler probes](verification/client-probes/README.md) are
historical compiler evidence. The source validation and toolchain records
are grouped by role:

- [Client source records](verification/source/client/)
- [Server source records](verification/source/server/)

The source-record files are listed below for direct access.

- `verification/client-probes/source-notes.md`
- `verification/source/client/README.md`
- `verification/source/client/toolchain.md`
- `verification/source/client/validation.md`
- `verification/source/client/proxy-real.md`
- `verification/source/client/mtls-real.md`
- `verification/source/client/observer-overhead.md`
- `verification/source/client/harness-run-full.log`
- `verification/source/client/harness-expectations.tsv`
- `verification/source/server/README.md`
- `verification/source/server/toolchain.md`
- `verification/source/server/validation.md`

These records do not validate the combined tree. Merged API review, root
command review, and final validation remain separate work.

## RFC references

- [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html), checked 2026-11-11.
- [RFC 1929](https://www.rfc-editor.org/rfc/rfc1929.html), checked 2026-11-11.
