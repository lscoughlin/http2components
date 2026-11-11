---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: migration, units, api
notes:
  - Target API and package details await final source and build review.
---

# Migration to 0.30.0

This table maps all 102 production units in the client and server source
projects. A target with two unit paths is a planned split. The table records
the target map; it does not state that every target has passed compilation.

## Unit names

| Source project | Source unit | Target unit path(s) | Change | Story |
| --- | --- | --- | --- | --- |
| http2client | `Http2.Client` | `Http2.Client`; `Http2.Client.Core` | split | C04 |
| http2client | `Http2.ClientCert` | `Http2.Client.ClientCert` | move | C01 |
| http2client | `Http2.Clock` | `Http2.Client.Clock` | move | C04 |
| http2client | `Http2.Connection` | `Http2.Client.Connection` | split | C02 |
| http2client | `Http2.Encoding` | `Http2.Client.Encoding` | move | C04 |
| http2client | `Http2.Errors` | `Http2.Common.Errors`; `Http2.Client.Errors` | split-and-merge | M02 |
| http2client | `Http2.FlowControl` | `Http2.Common.FlowControl` | merge | M04 |
| http2client | `Http2.Frames` | `Http2.Common.Frames` | merge | M04 |
| http2client | `Http2.Headers` | `Http2.Common.Headers` | merge | M02 |
| http2client | `Http2.Hpack` | `Http2.Common.Hpack` | merge | M03 |
| http2client | `Http2.Http1` | `Http2.Client.Http1` | split | C02 |
| http2client | `Http2.IdentityHandle` | `Http2.Client.IdentityHandle` | move | C01 |
| http2client | `Http2.Messages` | `Http2.Client.Messages` | move | C02 |
| http2client | `Http2.Observer` | `Http2.Client.Observer` | move | C04 |
| http2client | `Http2.Proxy` | `Http2.Client.Proxy` | split | C01 |
| http2client | `Http2.Readers` | `Http2.Client.Readers` | move | C04 |
| http2client | `Http2.RequestObserver` | `Http2.Client.RequestObserver` | move | C04 |
| http2client | `Http2.SigPipe` | `Http2.Client.SigPipe` | move | C01 |
| http2client | `Http2.Socks` | `Http2.Client.Socks` | move | C01 |
| http2client | `Http2.Sse` | `Http2.Client.Sse` | move | C03 |
| http2client | `Http2.Stream` | `Http2.Client.Stream` | split | C02 |
| http2client | `Http2.Tls` | `Http2.Client.Tls` | split | C01 |
| http2client | `Http2.WebSocket` | `Http2.Client.WebSocket` | split | C03 |
| http2client | `Http2.WebSocketClient` | `Http2.Client.WebSocket.Connection` | split | C03 |
| http2client | `Http2` | `Http2.Client` | replace-umbrella | M10 |
| http2server | `Http2Server.AccessLog.Handler` | `Http2.Server.AccessLog.Handler` | move | M07 |
| http2server | `Http2Server.AccessLog` | `Http2.Server.AccessLog` | move | M07 |
| http2server | `Http2Server.Admission` | `Http2.Server.Admission` | move | M07 |
| http2server | `Http2Server.Alpn` | `Http2.Server.Alpn` | move | M07 |
| http2server | `Http2Server.Async.Counters` | `Http2.Server.Async.Counters` | move | M07 |
| http2server | `Http2Server.Async.Events` | `Http2.Server.Async.Events` | move | M07 |
| http2server | `Http2Server.Async.Options` | `Http2.Server.Async.Options` | move | M07 |
| http2server | `Http2Server.Async.Socket` | `Http2.Server.Async.Socket` | move | M07 |
| http2server | `Http2Server.Async.Sweep` | `Http2.Server.Async.Sweep` | move | M07 |
| http2server | `Http2Server.Async.Waker` | `Http2.Server.Async.Waker` | move | M07 |
| http2server | `Http2Server.Async` | `Http2.Server.Async` | move | M07 |
| http2server | `Http2Server.ClientCert` | `Http2.Server.ClientCert` | move | M07 |
| http2server | `Http2Server.Config.Limits` | `Http2.Server.Config.Limits` | move | M07 |
| http2server | `Http2Server.Config.Socket` | `Http2.Server.Config.Socket` | move | M07 |
| http2server | `Http2Server.Config.Tls` | `Http2.Server.Config.Tls` | move | M07 |
| http2server | `Http2Server.Config` | `Http2.Server.Config` | move | M07 |
| http2server | `Http2Server.Connection.Core` | `Http2.Server.Connection.Core` | move | M07 |
| http2server | `Http2Server.Connection.Flush` | `Http2.Server.Connection.Flush` | move | M07 |
| http2server | `Http2Server.Connection` | `Http2.Server.Connection` | move | M07 |
| http2server | `Http2Server.Duplex` | `Http2.Server.Duplex` | move | M07 |
| http2server | `Http2Server.Encoding` | `Http2.Server.Encoding` | move | M07 |
| http2server | `Http2Server.Errors` | `Http2.Common.Errors`; `Http2.Server.Errors` | split-and-merge | M02 |
| http2server | `Http2Server.FlowControl` | `Http2.Common.FlowControl` | merge | M04 |
| http2server | `Http2Server.Frames` | `Http2.Common.Frames` | merge | M04 |
| http2server | `Http2Server.HandlerJob` | `Http2.Server.HandlerJob` | move | M07 |
| http2server | `Http2Server.Headers` | `Http2.Common.Headers` | merge | M02 |
| http2server | `Http2Server.Hpack` | `Http2.Common.Hpack` | merge | M03 |
| http2server | `Http2Server.HpackConnection` | `Http2.Server.HpackConnection` | move | M07 |
| http2server | `Http2Server.Http1.Channel` | `Http2.Server.Http1.Channel` | move | M07 |
| http2server | `Http2Server.Http1.Core` | `Http2.Server.Http1.Core` | move | M07 |
| http2server | `Http2Server.Http1.Driver` | `Http2.Server.Http1.Driver` | move | M07 |
| http2server | `Http2Server.Http1.Exchange` | `Http2.Server.Http1.Exchange` | move | M07 |
| http2server | `Http2Server.Http1.Guard` | `Http2.Server.Http1.Guard` | move | M07 |
| http2server | `Http2Server.Http1.Host` | `Http2.Server.Http1.Host` | move | M07 |
| http2server | `Http2Server.Http1.Limits` | `Http2.Server.Http1.Limits` | move | M07 |
| http2server | `Http2Server.Http1.Parser` | `Http2.Server.Http1.Parser` | move | M07 |
| http2server | `Http2Server.Http1.ResponseHead` | `Http2.Server.Http1.ResponseHead` | move | M07 |
| http2server | `Http2Server.Http1.Select` | `Http2.Server.Http1.Select` | move | M07 |
| http2server | `Http2Server.Http1.SocketChannel` | `Http2.Server.Http1.SocketChannel` | move | M07 |
| http2server | `Http2Server.Http1.Status` | `Http2.Server.Http1.Status` | move | M07 |
| http2server | `Http2Server.Http1.Upgrade` | `Http2.Server.Http1.Upgrade` | move | M07 |
| http2server | `Http2Server.Limits` | `Http2.Server.Limits` | move | M07 |
| http2server | `Http2Server.Mtls.Types` | `Http2.Server.Mtls.Types` | move | M07 |
| http2server | `Http2Server.Observer` | `Http2.Server.Observer` | move | M07 |
| http2server | `Http2Server.OutboundBudget` | `Http2.Server.OutboundBudget` | move | M07 |
| http2server | `Http2Server.Output` | `Http2.Server.Output` | move | M07 |
| http2server | `Http2Server.RequestValidation` | `Http2.Server.RequestValidation` | move | M07 |
| http2server | `Http2Server.ResponseWriter` | `Http2.Server.ResponseWriter` | move | M07 |
| http2server | `Http2Server.Seam` | `Http2.Server.Seam` | move | M07 |
| http2server | `Http2Server.Server` | `Http2.Server.Runtime` | move | M07 |
| http2server | `Http2Server.Sse.Encoder` | `Http2.Server.Sse.Encoder` | move | M07 |
| http2server | `Http2Server.Sse` | `Http2.Server.Sse` | move | M07 |
| http2server | `Http2Server.Stream.Meta` | `Http2.Server.Stream.Meta` | move | M07 |
| http2server | `Http2Server.Stream` | `Http2.Server.Stream` | move | M07 |
| http2server | `Http2Server.StreamAdapters` | `Http2.Server.StreamAdapters` | move | M07 |
| http2server | `Http2Server.StreamChannel` | `Http2.Server.StreamChannel` | move | M07 |
| http2server | `Http2Server.StreamHost` | `Http2.Server.StreamHost` | move | M07 |
| http2server | `Http2Server.StreamIdSet` | `Http2.Server.StreamIdSet` | move | M07 |
| http2server | `Http2Server.StreamPool` | `Http2.Server.StreamPool` | move | M07 |
| http2server | `Http2Server.Tls.Client` | `Http2.Server.Tls.Client` | move | M07 |
| http2server | `Http2Server.Tls` | `Http2.Server.Tls` | move | M07 |
| http2server | `Http2Server.Waiter` | `Http2.Server.Waiter` | move | M07 |
| http2server | `Http2Server.Ws.Accept` | `Http2.Server.WebSocket.Accept` | move | M07 |
| http2server | `Http2Server.Ws.Close` | `Http2.Server.WebSocket.Close` | move | M07 |
| http2server | `Http2Server.Ws.Environment` | `Http2.Server.WebSocket.Environment` | move | M07 |
| http2server | `Http2Server.Ws.Frames` | `Http2.Server.WebSocket.Frames` | move | M07 |
| http2server | `Http2Server.Ws.Handshake` | `Http2.Server.WebSocket.Handshake` | move | M07 |
| http2server | `Http2Server.Ws.Http2` | `Http2.Server.WebSocket.Http2` | move | M07 |
| http2server | `Http2Server.Ws.Options` | `Http2.Server.WebSocket.Options` | move | M07 |
| http2server | `Http2Server.Ws.Origin` | `Http2.Server.WebSocket.Origin` | move | M07 |
| http2server | `Http2Server.Ws.Parser` | `Http2.Server.WebSocket.Parser` | move | M07 |
| http2server | `Http2Server.Ws.Reader` | `Http2.Server.WebSocket.Reader` | move | M07 |
| http2server | `Http2Server.Ws.Session` | `Http2.Server.WebSocket.Session` | move | M07 |
| http2server | `Http2Server.Ws.SessionCore` | `Http2.Server.WebSocket.SessionCore` | move | M07 |
| http2server | `Http2Server.Ws.Types` | `Http2.Server.WebSocket.Types` | move | M07 |
| http2server | `Http2Server.Ws.Utf8` | `Http2.Server.WebSocket.Utf8` | move | M07 |
| http2server | `Http2Server` | `Http2.Server` | adapt-facade | M10 |

## Umbrella and entry units

The client source unit `Http2` is the retired umbrella. Its planned replacement
is `Http2.Client`. A client that uses features from other groups names those
units explicitly. The server facade becomes `Http2.Server`; the common facade
is `Http2.Common`. No wrapper unit preserves every former `uses` clause.

The client public entry unit keeps the name `Http2.Client`. The design splits
its implementation into the facade and `Http2.Client.Core`. The server
`Http2Server` facade becomes `Http2.Server`. The former runtime unit
`Http2Server.Server` becomes `Http2.Server.Runtime`.

## API qualification

| Case | Target use |
| --- | --- |
| Common error classes | `Http2.Common.Errors` owns common error types. Client and server error units use those shared identities. |
| Common header API | `Http2.Common.Headers` owns shared header types and operations. |
| Client and server body writers | The contracts remain distinct. Combined code names `Http2.Client.IBodyWriter` or `Http2.Server.IBodyWriter`. |
| Client Readers | JSON and XML helper units are optional and remain in the Readers package. Core client consumers do not require that package. |
| Server WebSocket units | `Http2Server.Ws.*` becomes `Http2.Server.WebSocket.*`. |
| Client WebSocket connection | `Http2.WebSocketClient` becomes `Http2.Client.WebSocket.Connection`. |
| Facade aliases | Common names use aliases to the common unit; an interface uses the same type identity and GUID. |
| Legacy client umbrella | The old `Http2` umbrella is removed; callers use `Http2.Client` and explicit feature units. |

## Package and version map

| Source package/version | Planned target | Status |
| --- | --- | --- |
| Client package 0.23.0 | `http2client.lpk`, version 0.30.0 | Package metadata review pending. |
| Server package 0.29.0 | `http2server.lpk`, version 0.30.0 | Package metadata review pending. |
| Shared units | `http2common.lpk`, version 0.30.0 | Package membership review pending. |
| JSON/XML readers | Optional `http2clientreaders.lpk`, version 0.30.0 | Optional package review pending. |
| Combined release | `VERSION` 0.30.0 | Build and release review pending. |

The source package numbers identify source metadata. They do not establish
that versions 0.23.0 or 0.29.0 were published. The combined 0.30.0 version
is the planned target, not a release claim.

## Review status

The migration table follows the source unit map. Final API checks, package
builds, and command availability remain pending. The documented types and
facades require comparison with the merged source before acceptance.
