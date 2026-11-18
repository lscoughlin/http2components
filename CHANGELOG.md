# Changelog

## 0.33.0 — in development

- Version bump after the 0.32.0 source release. No other change yet.

### WebSocket

- **Behavior change.** `IWsSession.SendStream` sends each chunk of the writer as one
  fragment of the message, and it returns at once. A full channel parks the stream
  until the channel drains. While a stream runs, `Send` and `SendStream` return
  `srFull`. `MaxMessageSize` limits one chunk, not the whole streamed message.
- A `SendStream` that a pending channel refuses (for example from `Init`) wakes at once
  when `Activate` has moved the held bytes. It no longer waits for the park timer.
- `SendStream` releases a writer that it refuses with `srFull` or `srClosed`. Before,
  a writer that the caller made in the call leaked.

### Client

- The HTTP/1.1 client sends a request body from an `IBodyWriter` chunk by chunk, with
  chunked transfer coding. It no longer holds the whole body in memory. The other
  `IBodyWriter` paths already stream: the server response, the server WebSocket stream
  and the HTTP/2 client upload. This release adds tests for them.

### Server

- **Breaking change of the API.** `IServerRequest.ReadChunk` takes a `TStream` in place
  of an `out TBytes`: `function ReadChunk(const ABuffer: TStream): Boolean`. The request
  now extends `IBodyReader`, which declares `ReadChunk`. `ReadChunk` appends the next
  buffered chunk to the stream that the caller gives. It blocks while the buffer is
  empty and the body has not ended, as `Read` does, and it raises `EHttpTimeout` at the
  read timeout. Before, it answered True with no octet while the buffer was empty.
  A False answer writes no octet, and the end repeats on each later call.

  Old shape of a handler that reads the body in chunks:

  ```pascal
  procedure TEchoHandler.Handle(const ARequest: IServerRequest;
    const AResponse: IServerResponse);
  var
    Chunk: TBytes;
  begin
    AResponse.SendHeaders(200, nil, False);
    while ARequest.ReadChunk(Chunk) do
      AResponse.Write(Chunk);
    AResponse.Finish;
  end;
  ```

  New shape of the same handler. The loop keeps the octets of a call that returns
  False, because the last chunk can come with that answer. It sends each chunk at
  once, so the handler never holds the whole body:

  ```pascal
  procedure TEchoHandler.Handle(const ARequest: IServerRequest;
    const AResponse: IServerResponse);
  var
    Buf: TChunkBuffer;
    More: Boolean;
  begin
    AResponse.SendHeaders(200, nil, False);
    Buf := TChunkBuffer.Create;
    try
      repeat
        Buf.Reset;
        More := ARequest.ReadChunk(Buf);
        if Buf.Size > 0 then
          AResponse.Write(ChunkBytes(Buf));
      until not More;
    finally
      Buf.Free;
    end;
    AResponse.Finish;
  end;
  ```

  A handler that needs the whole body can call `Body := ReadAllBody(ARequest)`
  instead.

### Common

- **Breaking change of the API.** `IBodyWriter.NextChunk` takes a `TStream` in place of
  an `out TBytes`: `function NextChunk(const ABuffer: TStream): Boolean`. The library
  passes one reusable `TChunkBuffer`, so a long body makes no allocation for each
  chunk. The client and the server share this one interface, declared in
  `Http2.Common.Body`. The names `Http2.Client.IBodyWriter` and
  `Http2.Server.IBodyWriter` stay as aliases of it. A writer that has a `TBytes`
  appends it with `ChunkAppend`. A call that returns False and writes octets sends
  those octets as the last chunk, and then the body ends.

  Old shape of a small writer:

  ```pascal
  function TGreeting.NextChunk(out ABuffer: TBytes): Boolean;
  begin
    Result := not FSent;
    if Result then
      ABuffer := BytesOf('hello');
    FSent := True;
  end;
  ```

  New shape of the same writer:

  ```pascal
  function TGreeting.NextChunk(const ABuffer: TStream): Boolean;
  begin
    Result := not FSent;
    if Result then
      ChunkAppend(ABuffer, BytesOf('hello'));
    FSent := True;
  end;
  ```

- New interface `IBodyReader` in `Http2.Common.Body`, the inbound partner of
  `IBodyWriter`. `ReadChunk(const ABuffer: TStream): Boolean` appends the next chunk to
  the buffer. `Read` gives the octets of the body. The end of a body repeats on each
  later call. The base class `TBodyReaderBase` gives `ReadChunk` for a class that has
  `Read`. The helpers `ReadAllBody` and `CopyBody` read a body to its end. The new
  exceptions `EBodyTooLarge` and `EBodyFormatError` derive from `Exception`. The change
  adds to the API only. No existing routine changes.

## 0.32.0 — 2026-11-16 (source release)

- This release is a source release. It has no binary artifacts.
- Every program in `examples/`, `tools/client/` and `test/` has a Lazarus
  project file (`.lpi`) that `lazbuild` builds.
- The package `http2tlslib` builds with a plain `lazbuild` run. It requires the
  upstream package `TlsLib4PascalPackage`.
- The client, server, OpenSSL, readers and TlsLib packages no longer put
  `common/src` on their unit paths. They use the units of the `http2common`
  package.
- The generated package units are ignored by git: `http2common.pas`,
  `http2client.pas`, `http2clientreaders.pas`, `http2server.pas`,
  `http2openssl.pas` and `http2tlslib.pas`. `task build` compiles the facade
  units `Http2.OpenSSL.pas` and `Http2.TlsLib.pas` instead.

## 0.31.0 — 2026-11-14 (source release)

This release is a source release. It has no binary artifacts. This work fixes
security findings from the security review. The fixes are listed by area. The
behavior changes that a caller can notice follow the list.

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

Follow-up work on the same review:

- Client: a receive queue that overflows ends only its own stream with a flow-control error.
  The queue is a lock-free single-producer single-consumer ring with a frame cap of 1024 frames
  and a byte cap. The consumer side raises an error when a second reader enters.
- Client: `ReadAllBodyBytes`, `ReadText` and `TResponseReader<T>.Read` have overloads with a byte
  cap.
- Client: an HTTP/1.1 or TLS connection that holds unread input is not reused. A TLS 1.3 session
  ticket alone does not count as unread input. Both TLS engines report pending plaintext.
- Client: an HTTP/1 response that needed header unfolding is never reused. A fold in a framing or
  hop-by-hop header is refused. An empty or repeated `Transfer-Encoding` is refused.
- Client: the HTTP/1 SSE idle time (`SseMaxIdleTimeMs`) bounds each body read.
- Client: the pool waits for a dial with a per-origin event and not with sleep polling. The pool,
  the HTTP/2 connection, the HTTP/1 pooled connection and the WebSocket close their sockets with
  no pool, encoder or send lock held. A close that runs on the reader thread of the connection
  does not join that thread. The document of the transport describes the lock levels.
- Client: a TLS alert read after a failed write no longer holds the session lock.
- Server: a handler that returns without `Finish` is answered with a 500 or a reset on HTTP/2, and
  with a 500 and a close, or a cut response, on HTTP/1.
- Server: a detached handler (for example a WebSocket) is not expired by `MaxHandlerTimeMs`.
- Server: the `:path` rule follows Go. Control bytes and DEL are refused. A space and bytes above
  0x7E are accepted. A `%` needs two hexadecimal digits.
- Server: a request with a `Transfer-Encoding` that does not end in `chunked` gets 400.
- Server: the async server no longer drops the first output of a connection when the read thread
  closes the connection while another thread holds output that it took from the connection core.

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
- Handlers: on HTTP/1 a handler that writes its whole body and returns without `Finish` now gets
  its response cut and the connection closed. Before, the server finished the response for it.
- HTTP/1 SSE: a stream ends after `SseMaxIdleTimeMs` of silence. Before, it ended at the socket
  timeout.
- Server `:path`: a space and bytes above 0x7E are accepted, as in Go. A `%` that does not have
  two hexadecimal digits after it is refused.
- Server `Transfer-Encoding`: a value that does not end in `chunked`, such as `gzip`, gets 400
  and not 501.
- Receive queue: a stream that receives more than 1024 frames before the reader takes them gets a
  stream error. A queue that passes its byte cap does the same. Before, the whole connection failed.
- Pool: a waiter on a full connection cap can wait up to one 50 ms slice for a wake-up.

### Test counts

Counts on the integration branch. All runs had 0 errors and 0 failures.

- macOS: common 301 tests, client 1080 tests (the server suite has 899 tests).
- Linux x86-64 (Ubuntu 24.04, FPC 3.2.4, idle host): common 301, client 1080, API 16, full
  server suite 899 (about 255 s, so `TEST_TIMEOUT` above the default 180 s is needed for the
  server suite), TLS client 22 cases, OpenSSL session 140 cases, tlslib session 88 cases, TLS server
  13. The source check and the documentation check pass.
- Linux, ring stress: the lock-free ring passes 20 million items, on an idle host and under 14 busy
  loops.
- Linux, 14 busy loops on a 16-core host: 200 runs of the abuse test class all passed. Before the
  fix of the server stall, about 3 runs in 100 failed.
- Validation gates on Linux (a throwaway container with the host Docker socket, an open-file limit
  of 65536 and the repository mounted at the same path as on the host): sanity, interop (13 passed,
  1 skipped), SSE, proxy, WebSocket, Autobahn (296 OK, 3 informational, 2 non-strict, as the gate
  expects), cleartext, mTLS, server conformance, server fast, server TLS live, server mTLS live,
  server WebSocket over HTTP/1 and over HTTP/2, server SSE and server abuse passed. The gates
  `validate:client:proxy:real` (65 pass, 0 fail, 3 skip) and `validate:client:mtls-real` (nginx,
  Apache httpd and Caddy) ran from the macOS host. They copy the tree to the Linux host over `ssh`
  and run their containers there. Both passed. The interop and Autobahn gates need a container
  with host networking. The harness
  gate (`validate:client:harness`) ran 32 minutes and passed: PASS=69, FAIL=0, CLASS-DIFF=15,
  UNKNOWN=62, INFRASTRUCTURE=0. A CLASS-DIFF case is one where the reference client gives no
  verdict and the client reports a connection error; an UNKNOWN case has no verdict from the
  reference either. Between two full runs a few cases moved between BETTER and CLASS-DIFF. Run alone,
  those cases give the same result on the code from before the follow-up work and on the final code,
  so the movement comes from the interaction of the cases in a full run. All 19 gates passed.

### Fixes found by the Linux load runs

These three faults exist in the code from before this work.

- Client: a read that timed out after it had consumed some bytes lost those bytes, and the reader
  then continued in the middle of a frame. A frame that arrived with a gap of more than the 20 ms
  poll could break the connection. A read now returns the bytes it has, and a frame that does not
  complete within the socket read timeout fails the connection. Readers of the client
  socket interface now see a short count where they saw a timeout.
- Client WebSocket: a peer close frame that arrived between the local close frame and the local
  state change made the close look remote. The reader now reads the state under the send lock.
- Server (async): a connection that received a flood right after its preface could lose its
  SETTINGS and GOAWAY frames and get a reset. A thread of the handler pool took the output from the
  connection core to send it, and the read thread decided at the same moment that the drained
  connection was finished and closed it. The bytes were in neither queue. The close is now
  deferred while a send holds output. About 3 in 100 loaded runs of the abuse tests failed
  before the fix, and 200 of 200 passed after it.

### Known open items

- A handler that is detached on HTTP/1 in the same moment as the handler time limit can still get
  a 503 in the window between two lock sections. A detached handler past the limit still counts in
  the stuck count until it returns.
- A deferred close of the async server goes through `ConnectionRemove`, so it emits no close trace
  line and no `ConnectionLost` event.
- `TResponseReader<Int64>.Read` with a plain `Int64` variable may be ambiguous between the value
  overload and the byte cap overload. No test covers an `Int64` specialization.

The follow-up recommendations are listed in the project notes.

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
