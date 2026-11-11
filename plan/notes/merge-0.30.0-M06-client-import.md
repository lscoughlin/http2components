# M06 client source import

## Source and namespace map

The source input was the tracked Pascal source at client revision
`709336f542cbedf9ce1ab67d83bddcfd560eb1c0`. The source repository remains
unchanged. The import has 19 client-specific units, plus the existing
`Http2.Client.Errors` role unit. It excludes the old `Http2` umbrella.

| Source unit | Target unit |
| --- | --- |
| `Http2.Client` | `Http2.Client` |
| `Http2.ClientCert` | `Http2.Client.ClientCert` |
| `Http2.Clock` | `Http2.Client.Clock` |
| `Http2.Connection` | `Http2.Client.Connection` |
| `Http2.Encoding` | `Http2.Client.Encoding` |
| `Http2.Http1` | `Http2.Client.Http1` |
| `Http2.IdentityHandle` | `Http2.Client.IdentityHandle` |
| `Http2.Messages` | `Http2.Client.Messages` |
| `Http2.Observer` | `Http2.Client.Observer` |
| `Http2.Proxy` | `Http2.Client.Proxy` |
| `Http2.Readers` | `Http2.Client.Readers` |
| `Http2.RequestObserver` | `Http2.Client.RequestObserver` |
| `Http2.SigPipe` | `Http2.Client.SigPipe` |
| `Http2.Socks` | `Http2.Client.Socks` |
| `Http2.Sse` | `Http2.Client.Sse` |
| `Http2.Stream` | `Http2.Client.Stream` |
| `Http2.Tls` | `Http2.Client.Tls` |
| `Http2.WebSocket` | `Http2.Client.WebSocket` |
| `Http2.WebSocketClient` | `Http2.Client.WebSocket.Connection` |

The five shared protocol imports use `Http2.Common.Errors`,
`Http2.Common.FlowControl`, `Http2.Common.Frames`, `Http2.Common.Headers`,
and `Http2.Common.Hpack`. Client-specific errors use `Http2.Client.Errors`.
No server unit is used by client production code.

Incoming SETTINGS frames now decode as deltas over the current peer settings.
The decoder uses local table and header-list limits. The encoder applies the
peer table-size setting with `SetPeerTableSize` while holding the same lock as
stream encoding. Header decoding remains in the connection reader, in wire
order, and the common frame's receive metadata remains present.

## Initial validation

The initial client build passed on FPC 3.2.4 macOS arm64 with the pinned
mORMot2 checkout under the integration worktree and OpenSSL 3 library path.
The imported client test suite is owned by the test worktree and remains a
follow-up gate for this initial source commit.

These units exceed the 1000-line source limit before C01-C04:

- `Http2.Client`
- `Http2.Client.Connection`
- `Http2.Client.Http1`
- `Http2.Client.Proxy`
- `Http2.Client.Stream`
- `Http2.Client.Tls`
- `Http2.Client.WebSocket`
- `Http2.Client.WebSocket.Connection`

C01-C04 own the required divisions.

