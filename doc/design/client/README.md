---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: documentation, index, client, design
scope: The client design pages, which describe the merged Http2.Client.* and Http2.Common.* units.
---

# Client design

This directory holds the design pages of the client. The pages describe the
merged `Http2.Client.*` and `Http2.Common.*` units.

| Document | Subject |
| --- | --- |
| [Architecture](architecture.md) | Client layers and connection model. |
| [Client API](client-api.md) | Factory, client, request, and response contracts. |
| [Messages](messages.md) | Request, response, headers, and body data. |
| [Transport](transport.md) | Connections, TLS, ALPN, and transport. |
| [Queues](queues.md) | Every queue, its threads, and its producer and consumer roles. |
| [Protocol](protocol.md) | Frames, HPACK, and flow control. |
| [Fallback](fallback.md) | Clear-text HTTP/2 and HTTP/1.1 fallback. |
| [Proxy](proxy.md) | HTTP, HTTPS, and SOCKS proxy routes. |
| [Mutual TLS](mtls.md) | Client identity and certificate selection. |
| [Errors and redirects](errors-redirects.md) | Error classes, timeouts, retries, and redirects. |
| [Server-sent events](server-sent-events.md) | Event parsing and reconnect behavior. |
| [WebSocket](websocket.md) | Client WebSocket sessions. |
| [Request observability](request-observability.md) | Request-level events and adapters. |
| [Testing observability](testing-observability.md) | Test seams and protocol observations. |
| [FPC runtime](fpc-runtime.md) | Compiler and runtime notes from the client source. |
| [Open questions](open-questions.md) | Questions in the client source design. |
