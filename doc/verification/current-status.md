---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, status, linux, index
scope: The summary of the current verification results, with links to the records that state them.
related_docs:
  - doc/verification/linux-validation-2026-11-20.md
  - doc/verification/linux-performance-2026-11-20.md
  - doc/verification/websocket-http2-client-2026-11-20.md
  - doc/verification/client-probes/README.md
notes:
  - This page is the index of the current results. The three records hold the details and the numbers.
---

# Current verification status

The current results come from the full validation run on Linux x86_64 on
2026-11-20. The run covers version 0.34.0. All stages ran on commit
`ff2d62191a7a9675466d70834ef0a07cc5df54c3`, except the load stage of 10,000
WebSocket sessions and 10,000 server-sent event streams. That stage ran on commit
`531b3ebb149230abed247b88f40622d06bf3962e`. The only difference between the two
commits is the `load` mode of `examples/server/ws_echo.pas`, which raises the
WebSocket session limit to 30000.

## Records

| Record | Content |
| --- | --- |
| [Linux validation record](linux-validation-2026-11-20.md) | The host, the image, the commits, every stage with its result and counts, the peers and their limits, and the open items. |
| [Linux performance record](linux-performance-2026-11-20.md) | The numbers of the admission, connection load, million-request, combined WebSocket and server-sent event, and large-message stages. |
| [WebSocket over HTTP/2 client record](websocket-http2-client-2026-11-20.md) | The tests of the WebSocket over HTTP/2 client (RFC 8441), the loop results, the volume results and the open items of the client. |
| [Client compiler probes](client-probes/README.md) | The compiler probes of the client source project, kept as historical evidence. |

## Result

The following stages passed:

- Five production builds and 25 examples compiled.
- The unit suites passed with 0 errors and 0 failures: common 415 tests, client
  1239 tests, server 1086 tests, API 16 tests and integration 55 tests.
- The TLS tasks passed: contract 23 cases, OpenSSL 140, TlsLib 88, client 23,
  server 13 tests with the lifecycle runner, and integration 29 cases with the
  security runner. The local-process exchange passed.
- The source, documentation and version checks passed.
- The client interoperation gate passed 13 cases and skipped 1. The client
  sanity gate passed 5 cases.
- The server conformance gate passed: h2spec `http2` 94 of 94 and `hpack` 8 of 8.
- The independent checks passed: independent client 12 of 12, server identity
  32 of 32, and abrupt and graceful close 20 of 20.
- The WebSocket checks passed: client 18 tests, server, and server over HTTP/2
  32 of 32. The Autobahn run has OK 296, NON-STRICT 2 and INFORMATIONAL 3.
- The live gates passed: client cleartext, mutual TLS, proxy and server-sent
  events; server fast, server-sent events, TLS 21, mutual TLS 40 and abuse.
- The real proxy matrix passed 65 cases and skipped 3. The real mutual TLS
  matrix passed 54 rows natively and 54 rows with host-local peers.
- The Unix socket gate passed on the Linux host.
- The load stages passed: admission 4 of 4, connection load, four runs of one
  million requests over TLS, and 3 of 3 runs of 10,000 WebSocket sessions with
  10,000 server-sent event streams.
- The loops of the WebSocket over HTTP/2 suites and of the handler exception
  suite passed in 30 of 30 runs each.

The independent harness has 146 classified identifiers: MATCH 36, BETTER 16,
WORSE 0, CLASS-DIFF 32, UNKNOWN 62 and INFRASTRUCTURE 0. These are not 146
strict passes.

## Open and not run

- No test has run on Windows.
- The task `packages:check` did not run on Linux, because the image has no
  `lazbuild`.
- The peer limitations remain: three Squid cases and the `nghttpd` case A.8 are
  skipped.
- Other open limits of the WebSocket client are in the
  [Linux validation record](linux-validation-2026-11-20.md).

No release approval or publication is recorded.

The [repository README](../../README.md) describes the build and validation
commands.
