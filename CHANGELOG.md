# Changelog

## Unreleased

This work fixes security findings from the security review. The fixes are listed
by area. The behavior changes that a caller can notice follow the list.

### Security fixes

Common:

- `TURI` and `ParseURI` follow RFC 3986. They refuse a backslash, a space, a
  control byte, a non-ASCII byte, a zone identifier and a fragment with a number
  sign.
- Header names, header values and request targets pass one byte check.
- The HPACK integer decoder bounds its continuation octets.
- The HTTP/2 wire error codes, raw codes, window increments and PUSH_PROMISE role
  are checked.

Client:

- The redirect policy decides which hosts a redirect can reach. Credential headers
  are removed when a redirect changes the origin. A relative `Location` is resolved
  against the request URI.
- The stream receive queue is bounded. Frames on an idle stream are refused.
- Response sizes and the ratio of decoded bytes to encoded bytes are capped.
- The response header block is bounded, and decoded header values are checked.
- Control bytes are refused at the request call sites.
- The HTTP/1.1 parser is strict. An HTTP/1.1 connection with unread input is retired.
- Server-sent event lines and events are capped. The retry delay is capped and an
  idle time is enforced.
- The pool dials outside its lock.
- Control frames have their own queue. Peer control frames are rate-limited.
- Chunked trailers are capped. The response head and the CONNECT reply have deadlines.
- The client header block limit and the response decode limit are configurable.

Server:

- A handler that raises an error is answered with a 500 response or a reset.
- A request head with END_STREAM and a declared content-length is reset.
- A maximum handler time is enforced (`MaxHandlerTimeMs`).
- The WebSocket byte budget, the session count and the early bytes are bounded.
  A WebSocket host allow-list is checked.
- The chunk size line refuses CR, LF and NUL.
- A server-wide HTTP/1.1 body budget is enforced.
- The rapid reset gaps are closed. The reset bucket costs are checked, and the
  header table size is bounded.
- The request pseudo-headers of RFC 9113 section 8.3.1 are checked.

### Behavior changes

- Redirect policy: the default policy is `rpAnyHost`. Credential headers are
  removed on a change of origin.
- Decoding: the client decodes a response body only when the request has an
  `accept-encoding` header.
- Header limit: the client default limit for a response header list is 128 KiB
  (131072 bytes). The server default is unchanged at 64 KiB (65536 bytes).
- URL parsing: the client refuses a backslash, a space, a control byte and a zone
  identifier. A fragment is not sent on the wire. A query-only URL is sent as
  `/?query`.
- HTTP/1 response parsing: a bare LF or a bare CR is an error. Whitespace before a
  colon is an error. `Content-Length` takes digits only. A `Transfer-Encoding` other
  than `chunked` is an error. A response can carry at most 16 interim (1xx)
  responses. The response head has one deadline. Chunked trailers are limited to
  256 lines and 64 KiB.
- Request validation on the server: a request with an invalid `:path`, `:method`,
  `host` or `:authority` is refused.
- SSE: the default idle time is 10 minutes (`SseMaxIdleTimeMs` 600000). The
  default line limit is 32 MiB and the default event limit is 64 MiB. The default
  retry cap is 10 minutes.
- New defaults: `MaxDecodeRatio` 1000 (client), `MaxWsSessions` 5000 (server) and
  `MaxBodyBytesInFlight` 256 MiB (server).
- Reset bucket: the reset bucket costs before and after dispatch must be at least 1.
  The header table size is at most 16 MiB (16777216 bytes).
- Pool: one dial in flight is allowed for each origin and route.
- Control frames: the client keeps control frames in their own queue of 1000
  frames. A full queue is a connection error. Peer frames are rate-limited by type.

### Test counts

- Common: 282 tests (macOS).
- Client: about 1026 tests (macOS).
- Server: Linux run: pending.

The follow-up recommendations are listed in the project notes.

## 0.31.0 — in development

- Version bump after the 0.30.0 source release. No other change yet.

## 0.30.0 — 2026-11-12 (source release)

- Client and server source now share one repository and the common protocol
  units.
- The public entry units are `Http2.Common`, `Http2.Client`, and
  `Http2.Server`.
- Client transport, HTTP/1 body, stream types, and API/pool implementation
  have separate units. The `Http2` client umbrella is removed.
- Common, client, server, and optional client Readers Lazarus packages use
  version 0.30.0.
- The root build driver provides component builds, unit and API tests,
  in-process integration checks, examples, package checks, source checks,
  documentation checks, and explicit validation gates.
- Common, API, facade, local integration, server TLS, and server mTLS results
  are recorded in the [current verification record](doc/verification/current-status.md).
- The default client runner passes 854 registered cases on macOS and on Linux,
  with no error and no failure. The full server unit suite passes 775 tests on
  Linux. The full server unit suite has no completed run on macOS, because it
  does not finish in the time limit on the development host.
- The server and the client support Unix domain sockets: `WithUnixSocket` on
  both factories, `WithUnixSocketMode` on the server, and `WithUnixProxy` on the
  client. Results are in the
  [Unix socket verification record](doc/verification/unix-sockets-2026-11-12.md).
- The client inbound queues are unbounded, so a large request body echo no longer
  stalls the connection reader or fails with a flow-control timeout.
- The Unix socket suites and the unfiltered common, client, integration and
  server targets pass on Linux amd64.
- Load checks, independent external conformance checks, and the full server
  unit run on macOS remain open.

This release is a source release. It has no binary artifacts. The client 0.23.0
and server 0.29.0 records remain historical source package histories at
[doc/README.md](doc/README.md).
