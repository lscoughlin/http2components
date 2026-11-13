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

Counts on the integration branch. All runs had 0 errors and 0 failures.

- macOS: common 282 tests, client 1032 tests.
- Linux x86-64 (Ubuntu 24.04, FPC 3.2.4, idle host): common 282, client 1032, API 16,
  integration 19, full server suite 877 (232 s, so `TEST_TIMEOUT` above the default 180 s is
  needed for the server suite).
- Linux, 14 busy loops on a 16-core host: every client and server test class was run alone in
  three passes. Passes 1 and 3 were clean. Pass 2 showed one test that depended on thread order
  (fixed) and one server stall of a new connection, which also exists in the code from before this
  work (see the notes below). The loaded passes have not been repeated since that fix.
- Validation gates on Linux (a throwaway container with the host Docker socket, an open-file limit
  of 65536 and the repository mounted at the same path as on the host): sanity, interop (13 passed,
  1 skipped), SSE, proxy, WebSocket, Autobahn (296 OK, 3 informational, 2 non-strict, as the gate
  expects), cleartext, mTLS, server conformance, server fast, server TLS live, server mTLS live,
  server WebSocket over HTTP/1 and over HTTP/2, server SSE and server abuse passed. Two gates were
  not run: `validate:client:proxy:real` and `validate:client:mtls-real` need an `ssh` client and a
  remote host. The harness gate (`validate:client:harness`) needs more than 25 minutes on this
  host (it ran 33 minutes) and passed: PASS=72, FAIL=0, CLASS-DIFF=12, UNKNOWN=62,
  INFRASTRUCTURE=0. A CLASS-DIFF case is one where the reference client gives no verdict and the
  client reports a connection error; an UNKNOWN case has no verdict from the reference either.
  17 of the 19 gates passed.

### Fixes found by the Linux load runs

These two faults exist in the code from before this work.

- Client: a read that timed out after it had consumed some bytes lost those bytes, and the reader
  then continued in the middle of a frame. A frame that arrived with a gap of more than the 20 ms
  poll could break the connection. A read now returns the bytes it has, and a frame that does not
  complete within the socket read timeout fails the connection. Readers of the client
  socket interface now see a short count where they saw a timeout.
- Client WebSocket: a peer close frame that arrived between the local close frame and the local
  state change made the close look remote. The reader now reads the state under the send lock.

### Known open items

- A new connection of the async server gets no answer for more than 6 s about 1 time in 20 on a
  heavily loaded host. The code from before this work shows the same stall.

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
