---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
title: "Cleartext h2c and HTTP/1.1 Fallback"
aliases:
  - "fallback"
tags:
  - http2client
  - design
  - transport
  - protocol
status: done
up: "[http2components](../../README.md)"
related:
  - "[transport](transport.md)"
  - "[protocol](protocol.md)"
  - "[client-api](client-api.md)"
  - "[errors-redirects](errors-redirects.md)"
  - "[open-questions](open-questions.md)"
updated: 2026-10-13
notes:
  - Imported from http2client/doc/design/fallback.md at the source commit recorded in the source inventory.
---

# Cleartext h2c and HTTP/1.1 Fallback

This note describes cleartext HTTP/2 (`h2c`) and HTTP/1.1 fallback, which
the client supports when the caller enables them.

## Scope

The client supports five protocol modes. The client selects one mode for
each origin.

| Mode | URL scheme | Transport | How the client selects it |
| --- | --- | --- | --- |
| `h2` over TLS | `https` | TCP + TLS | ALPN selects `h2` |
| `h2c` prior knowledge | `http` | TCP, cleartext | The caller sets the policy |
| `h2c` upgrade | `http` | TCP, cleartext | The client sends an `Upgrade: h2c` request |
| HTTP/1.1 | `https` or `http` | TLS or cleartext | ALPN selects `http/1.1`, or the upgrade fails |
| HTTP/1.1, no probe | `http` | TCP, cleartext | The caller sets the policy |

The default stays strict. The client uses `h2` over TLS only. Cleartext and
HTTP/1.1 fallback are off until the caller enables them. The [client API](client-api.md)
document defines these settings.

The source tests and interop cases A.10–A.13 cover all five modes. The source
validation record describes their results.

WebSocket connections ([websocket](websocket.md)) sit outside these modes. They always
speak HTTP/1.1 for the opening handshake and take no part in the fallback and
cleartext switches: a `ws://` URL connects under the default cleartext policy.

## Terms

- **Origin.** The form `scheme://host:port`. The default port follows the
  scheme. The origin is the connection pool key. Details are in [architecture](architecture.md).
- **Strict mode.** The default. The client requires `h2` over TLS.
- **Fallback.** The client accepts HTTP/1.1 when the peer does not offer
  `h2`.
- **h2c prior knowledge.** The client sends the HTTP/2 connection preface at
  once on a cleartext TCP connection. The client does no negotiation.
- **HTTP/1.1 without a probe.** The client speaks HTTP/1.1 on a cleartext
  connection from the first byte. It sends no `Upgrade` header and never tries
  HTTP/2 on that connection. This suits a server that only speaks HTTP/1.1,
  where an upgrade can never succeed.
- **h2c upgrade.** The client sends one HTTP/1.1 request. That request
  carries an `Upgrade: h2c` header. The peer answers with `101 Switching
  Protocols`. Then both peers use HTTP/2 on the same connection.

## Negotiation

The client follows one algorithm for each request. The pool caches the
result for the origin. Details are in [client-api](client-api.md) for lease acquisition.

### `https` origins

1. The client opens TCP and starts TLS.
2. The ALPN offer includes `h2` and `http/1.1` when fallback is on. It includes
   only `h2` when fallback is off.
3. The client reads the ALPN result.
4. If ALPN is `h2`, the client uses HTTP/2 and writes the connection preface.
   The [transport](transport.md) document describes the next steps.
5. If ALPN is `http/1.1` and fallback is on, the client uses the HTTP/1.1 codec.
6. If ALPN is empty and fallback is on, the client uses HTTP/1.1. RFC 7301 says that an
   empty ALPN result means HTTP/1.1.
7. If ALPN is `http/1.1` or empty and fallback is off, the client raises
   `EHttpProtocolError`. The message names the selected protocol. This
   matches test A.9.
8. If ALPN names an unknown protocol, the client raises `EHttpProtocolError`.

### `http` origins

1. The client opens TCP without TLS.
2. The client reads the cleartext policy.
3. If the policy is **reject**, the client raises `EHttpProtocolError`. The default
   policy is reject.
4. If the policy is **prior knowledge**, the client writes the HTTP/2 connection
   preface and uses HTTP/2. It sends no `Upgrade` header.
5. If the policy is **upgrade**, the client follows the h2c upgrade procedure
   in the next section.
6. If the policy is **HTTP/1.1**, the client uses the HTTP/1.1 codec on the
   connection. It sends no `Upgrade` header.

```mermaid
flowchart TB
  S["request for an origin"] --> SC{"URL scheme?"}
  SC -->|"https"| T["dial TCP · start TLS"]
  SC -->|"http"| P{"ClearTextPolicy?"}
  P -->|"ctReject"| REJ["raise EHttpProtocolError"]
  P -->|"ctPriorKnowledge"| PK["write HTTP/2 preface at once"]
  P -->|"ctUpgrade"| UP["HTTP/1.1 request with Upgrade: h2c"]
  P -->|"ctHttp1"| H1P["HTTP/1.1 request, no Upgrade"]
  T --> A{"ALPN result"}
  A -->|"h2"| H2["HTTP/2 · write preface"]
  A -->|"http/1.1 or empty"| FB{"Http1Fallback?"}
  A -->|"unknown"| REJ
  FB -->|"on"| H1["HTTP/1.1 codec"]
  FB -->|"off"| REJ
  UP --> R{"response code"}
  R -->|"101"| HU["switch to HTTP/2 on the same socket<br/>response to the request is the 101 body"]
  R -->|"other"| H1U["stay HTTP/1.1 on the same socket · that response answers the request"]
```

## h2c upgrade procedure

Each connection follows these steps:

1. The client builds an HTTP/1.1 request.
2. The request contains the header `Upgrade: h2c`.
3. The request contains the header `HTTP2-Settings: <value>`. The value is the base64url
   encoding of the SETTINGS payload, with no padding. Details are in [protocol](protocol.md).
4. The request contains the header `Connection: Upgrade, HTTP2-Settings`.
5. The client sends the request and waits for the response.
6. If the response code is `101`, the client switches to HTTP/2 and writes the
   connection preface. The `101` response is the response to the request.
7. If the upgrade fails, the client keeps the HTTP/1.1 connection and uses the
   received response for the request. The HTTP/1.1 codec then handles
   all later requests on that connection.

The upgrade adds one round trip. Prior knowledge does not. The client uses
prior knowledge only when the caller sets that policy.

### The request is sent once

The upgrade request is a complete HTTP/1.1 request. It carries the caller's
method, target, headers, and three extra headers: `Upgrade`, `Connection`, and
`HTTP2-Settings`. A server that does not upgrade processes it like any other
request and answers it. That answer is the response to the caller's request.
The client reads it from the same socket and does not send the request again.

The rule exists because sending a request twice repeats its effects. A bodyless `POST`, `PUT`, or `DELETE` can change server state. A retry can
repeat that state change. The same rule explains why a request with a body does not use
the upgrade at all: the client would send the body in the probe and again over
HTTP/2. A request with a body uses plain HTTP/1.1.

The connection that carried a declined upgrade stays in the pool. It serves
later requests to the same origin as an ordinary HTTP/1.1 connection, until
the server closes it or a response carries `Connection: close`. The next
connection to that origin starts with a new upgrade request.

The client re-sends a request in one other case: the peer refused the stream
or sent `GOAWAY` for it, so the request was never processed, and the method is
idempotent (as described in [transport](transport.md)).


Rule: the client does not send a later SETTINGS frame that conflicts with
the `HTTP2-Settings` value. The client applies the `HTTP2-Settings` value as
its first SETTINGS frame.

## HTTP/1.1 codec

The HTTP/1.1 codec is small. It is not a general HTTP/1.1 client. It has
this scope:

- Request line: `METHOD SP request-target SP HTTP/1.1 CRLF`.
- Headers: one `Host` header is mandatory. Header names are
  case-insensitive on the wire.
- Header-size limit: the request head, the response head, and accumulated
  chunked trailers are each bounded by `cHttp1MaxHeaderBytes = 64 * 1024`;
  exceeding it raises `EHttpProtocolError`
  (`ecProtocolError`).
- Body: `Content-Length` or `Transfer-Encoding: chunked`.
- Writer body: a request with an `IBodyWriter` is sent with chunked transfer
  coding (RFC 9112 section 7.1). The head goes out first. Each chunk of the
  writer goes out as one HTTP chunk, in one socket write, before the next chunk
  is pulled. The client never holds the whole body. A chunk of length 0 is
  skipped, because it would end the body on the wire. The octets that the last
  call returns with `False` go out as the last chunk. The last-chunk marker `0`
  and the empty trailer follow.
- Producer body: a writer that is a producer (see [messages](messages.md),
  "Request body from a producer") is run on the thread of the call. The
  producer writes to a stream, and each chunk that the stream sends is one HTTP
  chunk, in one socket write, when the producer writes it. The last chunk and the
  last-chunk marker `0` go out when the producer ends. When the producer raises,
  the connection is marked not reusable, and the exception goes to the caller of
  `Send`. The pool then closes the socket. A cancelled call raises
  `EHttpStreamError` with `ecCancel` in the producer's `Write`, and the connection
  is not reused either.
- Response: status line, headers, and body. The body uses
  `Content-Length`, chunked coding, or connection close.
- Connection reuse: `keep-alive` is the default in HTTP/1.1. The codec takes
  the bytes that have arrived rather than waiting for a full read buffer, so
  a response on a connection the server keeps open is delivered at once. A
  transport signals this through `IPartialReader`.
- Response transfer coding: the codec accepts a response whose `Transfer-Encoding` is
  a single `chunked`. Any other value raises `EHttpProtocolError`: a list such as
  `gzip, chunked`, `gzip`, `identity`, an empty value and a repeated `chunked`. Go
  refuses the same values. A response with both `Transfer-Encoding` and
  `Content-Length` closes the connection after the response.
- Response field syntax: white space before the colon, a space or a control byte inside
  a field name, and an empty field name raise `EHttpProtocolError`. A line that starts
  with a space or a tab continues the previous field (obsolete line fold, RFC 9112
  section 5.2), and the codec replaces the fold with one space. A fold in the first field
  line raises. A fold in a framing or hop-by-hop field (`Content-Length`,
  `Transfer-Encoding`, `Connection`, `Upgrade`, `Keep-Alive`, `Proxy-Connection` and the
  `Sec-WebSocket-` fields) raises. A response that needed a fold, in its head or in its
  trailers, is delivered and its connection is not reused.
- The client WebSocket handshake reads the response head with the same field rules.
- The codec does not do request pipelining.

HTTP/1.1 has no multiplexing. One connection carries one request at a time.
For HTTP/1.1 origins the client sets the effective stream limit to 1. The
pool opens more connections when it needs more concurrency, bounded by
`MaxConnectionsPerHost` and `MaxTotalConnections` (as described in [client-api](client-api.md)).

The codec reuses the public surface. `IHttpClient.Send` and
`IHttpResponse` do not change. Redirects, timeouts, cancellation, and the
observer apply to HTTP/1.1 in the same way. Details are in [errors-redirects](errors-redirects.md) and
[testing-observability](testing-observability.md).

## Factory surface

The factory is a pure value record. Each method returns a new record.
Client API details are in [client-api](client-api.md).

```pascal
type
  /// how the client treats a cleartext ("http") origin
  TClearTextPolicy = (
    ctReject,           // default: raise EHttpProtocolError
    ctPriorKnowledge,   // send the HTTP/2 preface at once
    ctUpgrade,          // send an HTTP/1.1 Upgrade: h2c request
    ctHttp1             // speak HTTP/1.1 with no Upgrade request
  );

  THttpClientFactory = record
  private
    // ... other fields ...
    FHttp1Fallback: Boolean;
    FClearTextPolicy: TClearTextPolicy;
  public
    // ... other methods ...

    /// allow HTTP/1.1 when the peer does not offer h2 (https origins)
    function WithHttp1Fallback(const AEnable: Boolean): THttpClientFactory;

    /// set the policy for cleartext "http" origins
    function WithClearText(const APolicy: TClearTextPolicy): THttpClientFactory;
  end;
```

Defaults:

| Setting | Default | Meaning |
| --- | --- | --- |
| `Http1Fallback` | `False` | the client requires `h2` |
| `ClearTextPolicy` | `ctReject` | the client rejects `http` origins |

`ctHttp1` is the policy for a cleartext server that only speaks HTTP/1.1, such
as a local development server or a model runtime. `ctUpgrade` suits a server
that may or may not accept `h2c`. `ctPriorKnowledge` suits a server known to
speak `h2c`.

## Pool keys

The pool key is the origin, and the origin includes the scheme. The client
does not mix a TLS connection with a cleartext connection. The client does
not mix an HTTP/2 connection with an HTTP/1.1 connection. [transport](transport.md) holds
the pool rules.

## WebSocket

A WebSocket ([websocket](websocket.md)) under the default mode `wpmAuto` never dials an HTTP/2
connection. It takes a stream of a live pooled HTTP/2 connection of the origin, when that
connection advertises the extended CONNECT setting. Otherwise it runs the HTTP/1.1 route: a
dial of its own, with the ALPN offer `http/1.1` alone for `wss`, whatever the client fallback
setting is. A pooled connection without the setting is not used, and that case is not an error.

The mode `wpmHttp2` dials with the ALPN offer `h2` alone (over TLS). A peer that selects no
HTTP/2 raises `EHttpWebSocketError`. The h2c `Upgrade` is never used for a WebSocket. A `ws` URL
uses a pooled HTTP/2 connection only with prior knowledge.

## Errors

The client uses the existing exception hierarchy. Details are in [errors-redirects](errors-redirects.md).

| Condition | Exception |
| --- | --- |
| Fallback is off and ALPN is not `h2` | `EHttpProtocolError` |
| Cleartext policy is `ctReject` and the scheme is `http` | `EHttpProtocolError` |
| The `101` response is malformed | `EHttpProtocolError` |
| A transport failure on a cleartext connection | `EHttpConnectionError` |
| An HTTP/1.1 parse failure | `EHttpProtocolError` |
| A response that exceeds a deadline | `EHttpTimeout` |

An HTTP/1.1 status code is not an error. The client returns it in
`IHttpResponse.StatusCode`, in the same way as HTTP/2.

## Security

Cleartext HTTP/2 and HTTP/1.1 give no confidentiality and no integrity.
Anyone on the network path can read and change the traffic.

Rules:

1. The default rejects all cleartext requests. The caller opts in.
2. The client sends a request that carries a secret over cleartext only when
   the caller set the cleartext policy on purpose.
3. The client does not fall back from `h2` to HTTP/1.1 without the caller's
   consent. A silent fallback can hide a downgrade attack.

The observer has no cleartext-warning event, so a cleartext request produces
no warning; as described in "Known gaps".

`ctHttp1` is a cleartext policy like the other two. It gives no
confidentiality and no integrity, and the caller opts in to it on purpose.

## Implementation status

The table maps each area to its code and acceptance check:

| Area | Where | Acceptance |
| --- | --- | --- |
| `TClearTextPolicy` + factory methods | `client/src/Http2.Client.Tls.pas`, `client/src/Http2.Client.pas` | defaults stay strict (`ctReject`, `Http1Fallback=False`) |
| h2c prior knowledge | `client/src/Http2.Client.pas` (`TConnectionPool.TryH2cUpgrade` path, preface at once) | a GET against `nghttpd --no-tls` succeeds (A.10) |
| h2c upgrade | `client/src/Http2.Client.pas` (`AcquireUpgraded`, `BuildH2cUpgradeRequest`, `Http2SettingsBase64Url`) | a GET returns `101` then uses HTTP/2 (A.11) |
| declined upgrade | `client/src/Http2.Client.pas` (`TConnectionPool.OpenForTxn`, `THttp1PooledConnection.Resume`), `client/src/Http2.Client.Http1.pas` (`ResumeResponse`) | the request reaches the server once and the connection serves the next request (`Http2.Client.ClearText.Test`, `task validate:client:cleartext`) |
| HTTP/1.1 without a probe | `client/src/Http2.Client.Tls.pas` (`ctHttp1`), `client/src/Http2.Client.pas` | no `Upgrade` or `HTTP2-Settings` byte on the wire (`Http2.Client.ClearText.Test`, `task validate:client:cleartext`) |
| HTTP/1.1 codec | `client/src/Http2.Client.Http1.pas` (`THttp1Connection`) | GET and POST against a plain HTTP/1.1 server succeed (A.12) |
| ALPN fallback | `client/src/Http2.Client.Http1.pas` + transport selection in `Http2.Client` | an `http/1.1`-only TLS server responds when fallback is on |
| pool keys and limits | `TConnectionPool` selection | stream limit is 1 for HTTP/1.1; origins keep scheme apart |
| interop A.10–A.13 | `test/h2probe.pas`, `tools/client/interop.sh` | part of the green interop gate |

The `http2/http2-test` suite speaks draft-09 plaintext `h2c`; the prior
knowledge path gives that suite a code path to exercise.

## Validation

Four interop cases live in the probe (`test/h2probe.pas`) and
`tools/client/interop.sh`:

| ID | Case | Pass condition |
| --- | --- | --- |
| A.10 | h2c prior knowledge | a GET against `nghttpd --no-tls` returns `200` |
| A.11 | h2c upgrade | `Upgrade: h2c` → `101`, then the response body arrives over HTTP/2 |
| A.12 | HTTP/1.1 fallback | a GET against an HTTP/1.1 server returns `200` |
| A.13 | strict mode | a cleartext request raises `EHttpProtocolError` |

The live cleartext gate (`task validate:client:cleartext`) is separate from the
interop table. It runs `GET`, `POST`, `DELETE` and `HEAD` without a body under
`ctUpgrade` and `ctHttp1` against `tools/client/h1_counter_server.py`, an
HTTP/1.1-only server that logs each request it receives. Every request appears
in the log once. Under `ctHttp1` none carries an `Upgrade` header; under
`ctUpgrade` each carries the probe once.

Result: `interop: PASS=13 FAIL=0 SKIP=1` → `interop gate GREEN`
(as described in [validation](../../verification/source/client/validation.md)).

## Known gaps

1. The observer has no cleartext-warning event, so a cleartext request is
   silent. Details are in [testing-observability](testing-observability.md) and [open-questions](open-questions.md).

## RFC references

- [RFC 7301](https://www.rfc-editor.org/rfc/rfc7301.html), checked 2026-11-11.
