---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: migration, units, api
notes:
  - This map describes the merged 0.30.0 source layout.
---

# Migration to 0.30.0

The unit table maps 102 units from the historical client and server source
projects. A target with several paths records a source split. The table does
not describe the current TLS API; current provider units and migration calls
are listed below. Verification results are in the
[current status record](verification/current-status.md).

The five production roots are `common/src`, `client/src`, `server/src`,
`tls/openssl/src`, and `tls/tlslib/src`. Common owns the TLS contract. Client
and server depend on common and do not import either provider.

## Unit names

| Source project | Source unit | Target unit path(s) | Change |
| --- | --- | --- | --- |
| http2client | `Http2.Client` | `Http2.Client`; `Http2.Client.Api`; `Http2.Client.Attempt`; `Http2.Client.BodyReader`; `Http2.Client.Core`; `Http2.Client.Defaults`; `Http2.Client.Factory`; `Http2.Client.Pool`; `Http2.Client.Pool.State`; `Http2.Client.Pool.Types`; `Http2.Client.Pool.Http1`; `Http2.Client.Pool.Http2`; `Http2.Client.Request`; `Http2.Client.Response`; `Http2.Client.SocketFactory`; `Http2.Client.SocketFactory.Types`; `Http2.Client.Url`; `Http2.Client.Upgrade` | split |
| http2client | `Http2.ClientCert` | `Http2.Client.ClientCert` | move |
| http2client | `Http2.Clock` | `Http2.Client.Clock` | move |
| http2client | `Http2.Connection` | `Http2.Client.Connection`; `Http2.Client.Connection.Observer`; `Http2.Client.Connection.Queue`; `Http2.Client.Connection.Thread` | split |
| http2client | `Http2.Encoding` | `Http2.Client.Encoding` | move |
| http2client | `Http2.Errors` | `Http2.Common.Errors`; `Http2.Client.Errors` | split-and-merge |
| http2client | `Http2.FlowControl` | `Http2.Common.FlowControl` | merge |
| http2client | `Http2.Frames` | `Http2.Common.Frames` | merge |
| http2client | `Http2.Headers` | `Http2.Common.Headers` | merge |
| http2client | `Http2.Hpack` | `Http2.Common.Hpack` | merge |
| http2client | `Http2.Http1` | `Http2.Client.Http1`; `Http2.Client.Http1.Body` | split |
| http2client | `Http2.IdentityHandle` | `Http2.Client.IdentityHandle` | move |
| http2client | `Http2.Messages` | `Http2.Client.Messages` | move |
| http2client | `Http2.Observer` | `Http2.Client.Observer` | move |
| http2client | `Http2.Proxy` | `Http2.Client.Proxy`; `Http2.Client.Proxy.Environment`; `Http2.Client.Proxy.Match`; `Http2.Client.Proxy.Types` | split |
| http2client | `Http2.Readers` | `Http2.Client.Readers` | move |
| http2client | `Http2.RequestObserver` | `Http2.Client.RequestObserver` | move |
| http2client | `Http2.SigPipe` | `Http2.Client.SigPipe` | move |
| http2client | `Http2.Socks` | `Http2.Client.Socks` | move |
| http2client | `Http2.Sse` | `Http2.Client.Sse` | move |
| http2client | `Http2.Stream` | `Http2.Client.Stream`; `Http2.Client.Stream.Types`; `Http2.Client.Stream.Exchange`; `Http2.Client.Stream.Send` | split |
| http2client | `Http2.Tls` | `Http2.Client.Tls`; `Http2.Client.Tls.Types`; `Http2.Client.Tls.Plain`; `Http2.Client.Tls.Socket`; `Http2.Client.Tls.Tunnel` | split |
| http2client | `Http2.WebSocket` | `Http2.Client.WebSocket`; `Http2.Client.WebSocket.Protocol` | split |
| http2client | `Http2.WebSocketClient` | `Http2.Client.WebSocket.Connection`; `Http2.Client.WebSocket.Connection.Types`; `Http2.Client.WebSocket.Connection.Open`; `Http2.Client.WebSocket.Connection.Observer` | split |
| http2client | `Http2` | `Http2.Client` | replace-umbrella |
| http2server | `Http2Server.AccessLog.Handler` | `Http2.Server.AccessLog.Handler` | move |
| http2server | `Http2Server.AccessLog` | `Http2.Server.AccessLog` | move |
| http2server | `Http2Server.Admission` | `Http2.Server.Admission` | move |
| http2server | `Http2Server.Alpn` | Retired; ALPN metadata crosses the common session interface. | retired |
| http2server | `Http2Server.Async.Counters` | `Http2.Server.Async.Counters` | move |
| http2server | `Http2Server.Async.Events` | `Http2.Server.Async.Events` | move |
| http2server | `Http2Server.Async.Options` | `Http2.Server.Async.Options` | move |
| http2server | `Http2Server.Async.Socket` | `Http2.Server.Async.Socket` | move |
| http2server | `Http2Server.Async.Sweep` | `Http2.Server.Async.Sweep` | move |
| http2server | `Http2Server.Async.Waker` | `Http2.Server.Async.Waker` | move |
| http2server | `Http2Server.Async` | `Http2.Server.Async` | move |
| http2server | `Http2Server.ClientCert` | `Http2.Server.ClientCert` | move |
| http2server | `Http2Server.Config.Limits` | `Http2.Server.Config.Limits` | move |
| http2server | `Http2Server.Config.Socket` | `Http2.Server.Config.Socket` | move |
| http2server | `Http2Server.Config.Tls` | Retired; provider context policies own TLS configuration. | retired |
| http2server | `Http2Server.Config` | `Http2.Server.Config` | move |
| http2server | `Http2Server.Connection.Core` | `Http2.Server.Connection.Core` | move |
| http2server | `Http2Server.Connection.Flush` | `Http2.Server.Connection.Flush` | move |
| http2server | `Http2Server.Connection` | `Http2.Server.Connection` | move |
| http2server | `Http2Server.Duplex` | `Http2.Server.Duplex` | move |
| http2server | `Http2Server.Encoding` | `Http2.Server.Encoding` | move |
| http2server | `Http2Server.Errors` | `Http2.Common.Errors`; `Http2.Server.Errors` | split-and-merge |
| http2server | `Http2Server.FlowControl` | `Http2.Common.FlowControl` | merge |
| http2server | `Http2Server.Frames` | `Http2.Common.Frames` | merge |
| http2server | `Http2Server.HandlerJob` | `Http2.Server.HandlerJob` | move |
| http2server | `Http2Server.Headers` | `Http2.Common.Headers` | merge |
| http2server | `Http2Server.Hpack` | `Http2.Common.Hpack` | merge |
| http2server | `Http2Server.HpackConnection` | `Http2.Server.HpackConnection` | move |
| http2server | `Http2Server.Http1.Channel` | `Http2.Server.Http1.Channel` | move |
| http2server | `Http2Server.Http1.Core` | `Http2.Server.Http1.Core` | move |
| http2server | `Http2Server.Http1.Driver` | `Http2.Server.Http1.Driver` | move |
| http2server | `Http2Server.Http1.Exchange` | `Http2.Server.Http1.Exchange` | move |
| http2server | `Http2Server.Http1.Guard` | `Http2.Server.Http1.Guard` | move |
| http2server | `Http2Server.Http1.Host` | `Http2.Server.Http1.Host` | move |
| http2server | `Http2Server.Http1.Limits` | `Http2.Server.Http1.Limits` | move |
| http2server | `Http2Server.Http1.Parser` | `Http2.Server.Http1.Parser` | move |
| http2server | `Http2Server.Http1.ResponseHead` | `Http2.Server.Http1.ResponseHead` | move |
| http2server | `Http2Server.Http1.Select` | `Http2.Server.Http1.Select` | move |
| http2server | `Http2Server.Http1.SocketChannel` | `Http2.Server.Http1.SocketChannel` | move |
| http2server | `Http2Server.Http1.Status` | `Http2.Server.Http1.Status` | move |
| http2server | `Http2Server.Http1.Upgrade` | `Http2.Server.Http1.Upgrade` | move |
| http2server | `Http2Server.Limits` | `Http2.Server.Limits` | move |
| http2server | `Http2Server.Mtls.Types` | `Http2.Server.Mtls.Types` | move |
| http2server | `Http2Server.Observer` | `Http2.Server.Observer` | move |
| http2server | `Http2Server.OutboundBudget` | `Http2.Server.OutboundBudget` | move |
| http2server | `Http2Server.Output` | `Http2.Server.Output` | move |
| http2server | `Http2Server.RequestValidation` | `Http2.Server.RequestValidation` | move |
| http2server | `Http2Server.ResponseWriter` | `Http2.Server.ResponseWriter` | move |
| http2server | `Http2Server.Seam` | `Http2.Server.Seam` | move |
| http2server | `Http2Server.Server` | `Http2.Server.Runtime` | move |
| http2server | `Http2Server.Sse.Encoder` | `Http2.Server.Sse.Encoder` | move |
| http2server | `Http2Server.Sse` | `Http2.Server.Sse` | move |
| http2server | `Http2Server.Stream.Meta` | `Http2.Server.Stream.Meta` | move |
| http2server | `Http2Server.Stream` | `Http2.Server.Stream` | move |
| http2server | `Http2Server.StreamAdapters` | `Http2.Server.StreamAdapters` | move |
| http2server | `Http2Server.StreamChannel` | `Http2.Server.StreamChannel` | move |
| http2server | `Http2Server.StreamHost` | `Http2.Server.StreamHost` | move |
| http2server | `Http2Server.StreamIdSet` | `Http2.Server.StreamIdSet` | move |
| http2server | `Http2Server.StreamPool` | `Http2.Server.StreamPool` | move |
| http2server | `Http2Server.Tls.Client` | Retired; provider contexts own client trust and verification. | retired |
| http2server | `Http2Server.Tls` | Retired; the server adapter uses common `ITLSSession`. | retired |
| http2server | `Http2Server.Waiter` | `Http2.Server.Waiter` | move |
| http2server | `Http2Server.Ws.Accept` | `Http2.Server.WebSocket.Accept` | move |
| http2server | `Http2Server.Ws.Close` | `Http2.Server.WebSocket.Close` | move |
| http2server | `Http2Server.Ws.Environment` | `Http2.Server.WebSocket.Environment` | move |
| http2server | `Http2Server.Ws.Frames` | `Http2.Server.WebSocket.Frames` | move |
| http2server | `Http2Server.Ws.Handshake` | `Http2.Server.WebSocket.Handshake` | move |
| http2server | `Http2Server.Ws.Http2` | `Http2.Server.WebSocket.Http2` | move |
| http2server | `Http2Server.Ws.Options` | `Http2.Server.WebSocket.Options` | move |
| http2server | `Http2Server.Ws.Origin` | `Http2.Server.WebSocket.Origin` | move |
| http2server | `Http2Server.Ws.Parser` | `Http2.Server.WebSocket.Parser` | move |
| http2server | `Http2Server.Ws.Reader` | `Http2.Server.WebSocket.Reader` | move |
| http2server | `Http2Server.Ws.Session` | `Http2.Server.WebSocket.Session` | move |
| http2server | `Http2Server.Ws.SessionCore` | `Http2.Server.WebSocket.SessionCore` | move |
| http2server | `Http2Server.Ws.Types` | `Http2.Server.WebSocket.Types` | move |
| http2server | `Http2Server.Ws.Utf8` | `Http2.Server.WebSocket.Utf8` | move |
| http2server | `Http2Server` | `Http2.Server` | adapt-facade |

## Umbrella and entry units

The client source unit `Http2` is the retired umbrella. Its replacement
is `Http2.Client`. A client that uses features from other groups names those
units explicitly. The server facade becomes `Http2.Server`; the common facade
is `Http2.Common`. No wrapper unit preserves every former `uses` clause.

The client public entry unit keeps the name `Http2.Client`. Its facade
re-exports public API types while implementation responsibilities live in
the listed client units. The server
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
| Facade aliases | Common names use aliases to the common unit. Existing interface GUIDs are retained where the source declares them. `IHttpHeaders` has no explicit GUID in either source. |
| Legacy client umbrella | The old `Http2` umbrella is removed; callers use `Http2.Client` and explicit feature units. |

## Packages and version

| Package | Units | Role |
| --- | ---: | --- |
| `http2common` | 11 | Shared HTTP/2 and TLS interfaces. |
| `http2client` | 55 | Client role, without provider units. |
| `http2server` | 71 | Server role, without provider units. |
| `http2openssl` | 6 | OpenSSL provider. |
| `http2tlslib` | 8 | TlsLib provider. |
| `http2clientreaders` | 1 | Optional JSON and XML readers. |

All six Lazarus packages and `VERSION` report 0.30.0. These source values do
not state that version 0.30.0 is published.

## TLS API migration

The common API owns `ITLSContext`, `ITLSSession`, `ITLSIdentity`, policy
records, and copied peer metadata. `Http2.Common` aliases the same context
interface. Role facades do not re-export provider types as role-owned
interfaces.

| Earlier API | Current API |
| --- | --- |
| `THttp2ServerFactory.WithTls(TTlsServerOptions)` | `THttp2ServerFactory.WithTlsContext(ITLSContext)` with identity and policy held by a provider context. |
| Client TLS selected by the default socket factory | `THttpClientFactory.WithTlsContext(ITLSContext)` with `TOpenSSLTlsContextFactory` or `TTlsLibContextFactory`. |
| Client `WithCACertFile` | `TTlsClientPolicy.WithTrustAnchors` with PEM file paths; OpenSSL system trust is an explicit `WithSystemTrust(True)` choice. |
| Client `WithInsecureTls(True)` | `TTlsClientPolicy.WithInsecure(True)` before the provider factory builds the context. The old client method raises a configuration error. |
| Client certificate file loading through the client factory | `TOpenSSLIdentity.FromPemFiles` or `TTlsLibIdentity.FromPemFiles` returns common `ITLSIdentity`. |
| Native `PX509`, `PEVP_PKEY`, or peer certificate getters | `ITLSIdentity.Leaf` and verified `ITLSPeerCertificate` copied metadata. The common API has no native-handle accessor. |
| One TLS policy for proxy and origin | `WithTlsContext` for the origin and `WithProxyTlsContext` for HTTPS proxy TLS. Trust and identity stay separate. |

The client call shape is:

```pascal
ClientPolicy := TTlsClientPolicy.SecureDefault
  .WithTrustAnchors(['/etc/ssl/private/example-ca.pem']);
Context := TOpenSSLTlsContextFactory.Create
  .WithClientPolicy(ClientPolicy)
  .Build;
Client := THttpClientFactory.Create
  .WithTlsContext(Context)
  .Build;
```

The server call shape is:

```pascal
ServerIdentity := TOpenSSLIdentity.FromPemFiles('server-chain.pem', 'server.key');
ServerPolicy := TTlsServerPolicy.SecureDefault
  .WithServerIdentity(ServerIdentity);
Context := TOpenSSLTlsContextFactory.Create
  .WithServerPolicy(ServerPolicy)
  .Build;
ServerFactory := THttp2ServerFactory.Create
  .WithTlsContext(Context);
```

The old client certificate file helper is retired. The new identity comes
from the selected provider, then enters context policy or a client factory or
request identity setting. The old server TLS options record is retired; the
provider context owns its server identity and policy.

One context can contain client and server policies and can be shared between
roles and threads. Every transport creates a separate session; a nil selected
identity suppresses the context default. Neither provider enables session
resumption or early data.

The TlsLib provider does not support system trust, explicit verification
depth including zero, DER identities, distinct SNI and verification names,
or peer verification without hostname verification. Its verification depth
is fixed at four. The OpenSSL provider supports system trust and configurable
depth. Both support TLS 1.2 and TLS 1.3 with PEM and PKCS#12 identities.

## Verification status

Bounded local results and deferred checks are listed in the
[current status record](verification/current-status.md).
