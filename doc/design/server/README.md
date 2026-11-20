---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: documentation, index, server, design
scope: The server design pages, which describe the merged Http2.Server.* and Http2.Common.* units.
---

# Server design

This directory holds the design pages of the server. The pages describe the
merged `Http2.Server.*` and `Http2.Common.*` units.

| Document | Subject |
| --- | --- |
| [Architecture](architecture.md) | Server layers, threads, and request path. |
| [Threading](threading.md) | IO, handler, and cancellation work. |
| [Configuration](configuration.md) | Server factory options and validation. |
| [Public API](public-api.md) | Server, handler, and observer contracts. |
| [Unix socket](unix-socket.md) | Unix domain socket listener, path checks, file mode and peer address. |
| [Lifecycle](lifecycle.md) | Start, stop, drain, and shutdown. |
| [Connection](connection.md) | Connection state and frame processing. |
| [Admission](admission.md) | Bounded request admission and refusal. |
| [Output](output.md) | Response encoding and frame output. |
| [Protocol](protocol.md) | Server protocol units and error behavior. |
| [HTTP/1.1](http1.md) | HTTP/1.1 fallback and parsing. |
| [TLS](tls.md) | TLS and ALPN. |
| [Mutual TLS](mtls.md) | Client-certificate policy. |
| [WebSocket](websocket.md) | Server WebSocket sessions. |
| [Server-sent events](sse.md) | Event encoding and stream behavior. |
| [Limits](limits.md) | Request and connection work limits. |
| [IO pool](io-pool.md) | mORMot2 asynchronous IO integration. |
| [Seam](seam.md) | Handler-facing stream interfaces. |
| [FPC runtime](fpc-runtime.md) | Compiler and runtime notes from the server source. |
| [Future coroutines](future-coroutines.md) | Deferred coroutine design. |
| [Access log](access-log.md) | Access-log records and writers. |
