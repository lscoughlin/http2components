---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
title: "Architecture"
aliases:
  - "architecture"
tags:
  - http2client
  - design
  - architecture
status: done
up: "[http2components](../../README.md)"
related:
  - "[client-api](client-api.md)"
  - "[transport](transport.md)"
  - "[fpc-runtime](fpc-runtime.md)"
updated: 2026-10-13
notes:
  - Imported from http2client/doc/design/architecture.md at the source commit recorded in the source inventory.
  - API and architecture details await final merged-source review.
---

# Architecture

## Resolved multiplexing model

The pool is capped by total connections and leases queue frames on the
connection they are attached to. The model that reconciles the two, and on
which the rest of the design depends, is:

- **A lease is one HTTP/2 stream, not one TCP connection.** A single
  connection multiplexes many concurrent leases/streams.
- **Two connection caps bound TCP connections**: `MaxConnectionsPerHost`
  caps concurrent connections to one `host:port`, and `MaxTotalConnections`
  caps them across all hosts combined. Neither is a cap on in-flight
  requests.
- **Concurrency of requests is bounded separately** by
  `MaxStreamsPerConnection` (and by the peer's advertised
  `SETTINGS_MAX_CONCURRENT_STREAMS`).
- When a new lease is requested, the client reuses the least-loaded open
  connection for that `host:port` if it has a free stream slot; otherwise it
  opens a new connection (until `MaxConnectionsPerHost` /`MaxTotalConnections`);
  otherwise the lease waits.

```mermaid
flowchart TB
  C["THttpClient · FPool"]
  C --> K1["api.example:443"]
  C --> K2["other.example:443"]
  K1 --> A["Conn 1 · 1 read thread · 1 TLS socket · HPACK"]
  K1 --> B["Conn 2"]
  A --> A1["Stream 1 · Lease A · GET /a"]
  A --> A2["Stream 3 · Lease B · POST /b"]
  A --> A3["Stream 5 · Lease C · GET /c"]
  B --> B1["Stream 1 · Lease D"]
  K2 --> D["Conn 1"]
  C -.-> CAP["caps: MaxConnectionsPerHost · MaxTotalConnections · MaxStreamsPerConnection"]
```

## Component diagram

```mermaid
flowchart TB
  F["THttpClientFactory · pure value record"]
  F -->|"Build: IHttpClient"| C["IHttpClient · THttpClient"]
  C -->|"owns"| P["TConnectionPool · TDictionary origin → TConnectionList"]
  C -.->|"lease acquisition"| L["TStreamLease · one stream"]
  L -->|"attached to"| N["IConnection · TConnection"]
  P --> N
  N -->|"owns"| S["IHttp2Socket · TSSLSocket · ALPN h2"]
  N -->|"owns"| T["TConnectionThread · 1 per connection"]
  N -->|"owns"| H["THpackCodec · encoder + decoder, stateful"]
```

Layering, top down:

1. **`THttpClientFactory`** — immutable builder record; produces a configured
   `IHttpClient`. Details are in [client-api](client-api.md).
2. **`IHttpClient` / `THttpClient`** — public entry point, thread-safe,
   owns the pool, hands out leases. `Send` may be called concurrently.
3. **`TConnectionPool`** — `TDictionary<string, TConnectionList>` guarded by
   a `TCriticalSection`. Enforces the per-host `MaxConnectionsPerHost` budget
   and the global `MaxTotalConnections` budget.
4. **`IConnection` / `TConnection`** — owns one socket, one background
   thread, and all connection-scoped HTTP/2 state (HPACK, settings, windows,
   stream-id counter). Details are in [transport](transport.md).
5. **`TStreamLease` / stream state** — one request/response exchange.

## Unit layout and naming

Twenty units in `src/`, listed roughly in dependency order (`Http2.Client`
depends on the units after it that it re-exports, such as `Http2.Client.Proxy` and
`Http2.Client.WebSocket`):

```pascal
unit Http2.Common.Errors;      // EHttpError hierarchy, THttp2ErrorCode
unit Http2.Common.Frames;      // TFrameType, TFrame, TFrameHeader, TConnectionSettings
unit Http2.Common.Headers;     // IHttpHeaders, THttpHeaders, header-name constants
unit Http2.Common.Hpack;       // THpackCodec (static + dynamic tables)
unit Http2.Common.FlowControl; // TWindow, connection/stream window accounting
unit Http2.Client.Tls;         // IHttp2Socket, ALPN, TLS context, cert validation,
                        // TClearTextPolicy, TNegotiatedProtocol
unit Http2.Client.Messages;    // IHttpResponse, IResponseReader<T> (re-exports TLS enums)
unit Http2.Client.Http1;       // THttp1Connection, HTTP/1.1 codec + h2c upgrade
unit Http2.Client.Connection;  // TConnection, TConnectionThread, IConnectionStream,
                        // IBlockingQueue<T>, TBlockingQueue<T>
unit Http2.Client.Stream;      // TStreamLease, THttpMethod, THttpBody, IBodyWriter,
                        // IHttpBodyStream, TStreamIdAllocator
unit Http2.Client.Observer;    // IHttp2Observer
unit Http2.Client;      // THttpClientFactory, IHttpClient, THttpRequest,
                        // TConnectionPool, IPooledConnection,
                        // THttpConnection, THttp1PooledConnection,
                        // IHttp2SocketFactory, TResponseReader<T>,
                        // WithTextBody / ReadText
unit Http2.Client.Readers;     // optional: JSON/XML readers + send helpers (fcl-json/fcl-xml)
unit Http2.Client.Sse;         // TSseEventParser, TSseSource, TSseReconnectLoop, SseRequest
unit Http2.Client.Encoding;    // content codings (gzip, deflate)
unit Http2.Client.Proxy;       // IProxy, IProxySelector, proxy URLs, no-proxy list,
                        // environment snapshot (RTL + Http2.Common.Errors only)
unit Http2.Client.Socks;       // SOCKS5 client messages and tunnel (RFC 1928, 1929)
unit Http2.Client.WebSocket;   // frame codec, message assembly, handshake rules,
                        // IWebSocket / IWebSocketListener / IWebSocketRequest
                        // (RTL + Http2.Common.Errors only)
unit Http2.Client.WebSocket.Connection; // TWebSocketConnection, OpenWebSocket
unit Http2.Client;             // umbrella: re-exports every unit above EXCEPT Http2.Client.Readers
```

`Http2.Client.Readers` is deliberately **outside** the umbrella and the core: it is the only unit that depends on `fcl-json`/`fcl-xml`, so a caller
links it only by naming it in their own `uses` clause. Details are in [messages](messages.md).

**Dependency direction.** `Http2.Client` and `Http2.Client.Connection` are the
concurrency owners; the layers below them are pure and independently
testable. `Http2.Client.Messages` re-exports `TClearTextPolicy` and
`TNegotiatedProtocol` from `Http2.Client.Tls`, so a caller that only needs the
public message types does not pull in the socket layer's details.

Conventions:

- **Unit names**: `Http2.Client.<Area>`, dotted, one class per unit where practical.
- **Types**: `T` prefix for classes/records, `I` prefix for interfaces,
  `E` prefix for exceptions, `F` prefix for fields.
- **Parameters**: `A` prefix (`ARequest`, `AValue`), `const` for managed
  types (avoids an implicit copy + refcount churn).
- **Header-name constants** are lowercase (`HeaderContentType` = `'content-type'`)
  because HTTP/2 requires lowercase on the wire. Details are in [messages](messages.md).

## RFC references

- [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html), checked 2026-11-11.
