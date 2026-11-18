# Examples

Eleven small programs and three adapter units showing use of the client API in `http2components`.
They are smoke builds: the build compiles them, it does not run them.

## Build

```sh
make examples      # or: task examples
```

The binaries land in `bin/<target>/<profile>/examples-client/programs/` (gitignored).

## TLS provider selection

Programs that send HTTPS or WSS requests select the OpenSSL provider and
configure peer and host-name verification. They do not use an implicit TLS
provider. Programs that only send HTTP requests do not load a TLS provider.
OpenSSL must be available at runtime for an HTTPS or WSS request. Set
`OPENSSL_LIBPATH` when the library is outside the system search path.

```sh
export OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib   # macOS / Homebrew
```

Then run any of them:

```sh
bin/<target>/<profile>/examples-client/programs/basic_get      https://nghttp2.org/
bin/<target>/<profile>/examples-client/programs/post_text      https://nghttp2.org/httpbin/post
bin/<target>/<profile>/examples-client/programs/json_request   https://nghttp2.org/httpbin/post
bin/<target>/<profile>/examples-client/programs/xml_request    https://nghttp2.org/httpbin/xml
https_proxy=http://proxy.corp:3128 bin/<target>/<profile>/examples-client/programs/proxy_env https://nghttp2.org/
bin/<target>/<profile>/examples-client/programs/threaded_get   https://nghttp2.org/ 8 25
bin/<target>/<profile>/examples-client/programs/sse_stream     https://example.com/events
bin/<target>/<profile>/examples-client/programs/websocket_echo wss://echo.example/ hello
bin/<target>/<profile>/examples-client/programs/observer_all   http://127.0.0.1:8091 ws://127.0.0.1:8601/echo
make measure-observer
# or against the reference event-stream server (cleartext; an http:// URL
# enables the h2c-upgrade policy automatically):
#   python3 tools/client/validate/sse_server.py --port 8091 &
#   bin/<target>/<profile>/examples-client/programs/sse_stream http://127.0.0.1:8091/events
```

| Program | Shows |
|---|---|
| `basic_get.pas` | The factory, one GET, `StatusCode`, `Headers`, `ReadText`. |
| `post_text.pas` | `WithTextBody` attaches a text body and defaults the content-type. |
| `json_request.pas` | `WithJsonBody` sends JSON; `ReadJsonObject` reads `TJSONObject` directly. Both are wrappers over the common JSON helpers (`Http2.Common.Body.Json`). |
| `xml_request.pas` | `WithXmlBody` / `ReadXmlDocument` for XML. `ReadXmlDocument` parses the body as it arrives, through the common XML helper (`Http2.Common.Body.Xml`). |
| `threaded_get.pas` | Eight threads sharing one client and its connection pool. |
| `sse_stream.pas` | `SseRequest` + `TSseReconnectLoop`: read an event stream and resume from `last-event-id`. |
| `websocket_echo.pas` | `TWebSocketRequest` + a `TWebSocketListener` descendant: open a WebSocket, `Request` demand, send a message, close. |
| `observer_all.pas` | `WithRequestObserver` with the tracing, metrics and logging adapters together: a plain request, an SSE stream with a reconnect and a WebSocket session against the `tools/client/validate` servers; prints one trace, the derived metrics and the log lines. |
| `observer_overhead.pas` | The cost of the observers on a loopback request (no observer, the three adapters, the per-event gate on); starts its own server. Run with `make measure-observer`. |
| `observer_tracing.pas`, `observer_metrics.pas`, `observer_logging.pas` | Adapter units, not programs: a tracer, a metrics registry and a structured logger over `IHttpClientObserver`, with in-memory stand-ins for the tracer and the registry. The tests compile against them. |
| `mtls_get.pas` | Explicit OpenSSL identity loading and selection for a GET or `wss` session, plus `EHttpTlsClientAuthError` when the server rejects the identity. |
| `proxy_env.pas` | `WithProxyEnvironmentVars` + `WithNoProxy`: route a GET by `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy`, with separate explicit OpenSSL contexts for the origin and HTTPS proxy. |

## Notes

- On Unix, `cthreads` must be the first unit in the program's `uses` clause,
  or threads do not start ("no thread support compiled in").
- `Http2.Readers` (JSON and XML) is an optional unit, outside the core
  library. `basic_get`, `post_text`, and `threaded_get` never link it.
- The helpers that read a body return an object **you own** — free it. The
  examples do so in a `finally`.
- The endpoints above are public services used for illustration. Point the
  programs at your own server for anything real.
- HTTPS and WSS examples use OpenSSL with system trust. `mtls_get` also adds
  its optional CA file to the origin and HTTPS proxy trust policy. The TLS
  integration examples show explicit OpenSSL and TlsLib selection, one context
  shared by a client and server, and a separate HTTPS proxy context.
