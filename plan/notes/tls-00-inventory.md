# TLS-00 inventory

## Scope
The source base is efe4cf40cc3fedd26b8f39d9979930176663d9fd. The current tree has 135 production units in four packages. tls-00-moves.tsv assigns each unit's current path, planned path, package, and move owner. tls-00-api.tsv records the old TLS API surface, the planned replacement, compatibility decision, and task owner. tls-00-tests.tsv records current test paths, coverage and gates.

TLS-00 makes no implementation changes. All production source stays in its current location until TLS-01. Unit names remain the same when TLS-01 moves source roots. Client TLS and server TLS changes belong to TLS-07 and TLS-08. Shared types belong to TLS-03. Provider implementations belong to TLS-05 and TLS-06. The server async adapter remains gated by TLS-02.

## Production unit ownership

The move table has one row for every .pas unit under src/:

- Http2.Common* moves from src/common/ to common/src/, into http2common.
- Http2.Client* moves from src/client/ to client/src/, into http2client, except Http2.Client.Readers*, which remains in optional http2clientreaders.
- Http2.Server* moves from src/server/ to server/src/, into http2server.
- New Http2.Common.Tls*, Http2.OpenSSL* and Http2.TlsLib* units are assigned by the current plan to TLS-03, TLS-05 and TLS-06. They are not present in the current inventory.

Every current unit moves in TLS-01. The table marks TLS role edits on affected client and server units. It does not assign unrelated units to TLS implementation workers.

## Build and source entry points

| Current entry point | Current behavior | Planned owner |
| --- | --- | --- |
| Root Makefile | Dispatches builds, unit tests, integration, package/source/docs/version checks and validation through tools/build.py | TLS-01, TLS-04, TLS-10 |
| Taskfile.yaml | Calls the same root build driver; currently no separate dependency graph | TLS-01 |
| tools/build.py | Hard-codes current source paths, mORMot include paths, pins mORMot revision, builds and tests components, starts gated validation scripts | TLS-01, TLS-04, TLS-10 |
| tools/packages.py | Derives membership from namespaces; generates four .lpk/package-unit pairs | TLS-01, TLS-10 |
| tools/check/repository.py | Enforces current source roots, namespace dependencies, Pascal size and headers, package inventory, version and docs rules | TLS-01, TLS-10 |
| Root *.lpk, generated *.pas | Four current Lazarus packages; current manifests point at src/common, src/client, src/server | TLS-01 |
| tools/client/validate/, tools/server/validate/, tools/server/certs/ | Client harness, TLS/mTLS/proxy/websocket validation and server validation/fixture generation | TLS-10 records routes; TLS-13 owns deferred platform/load/conformance work |
| tools/client/container/, tools/server/container/ | Container validation paths exist | TLS-13 only; no container run in TLS-00 through TLS-12 |
| examples/client/, examples/server/, examples/integration/ | Client and server use paths; no examples/integration/ directory exists; server TLS options occur in TLS, mTLS and interop examples | TLS-11 owns examples; role workers request needed API test edits through coordinator |
| .github/ | Not present in this worktree | No CI workflow path found |

The complete package/source relation is in the move table. The source checker counts files under src, test, examples and tools; it does not treat package-generated root units as production source inventory.

## Client TLS paths and API

- Direct HTTPS: Http2.Client.SocketFactory calls TTlsSocket.DialWithAlpnVia; TTlsSocket owns OpenSSL state and performs synchronous TLS work.
- HTTP/1.1 fallback: default disabled. Strict TLS offers only h2. When enabled, the client offers h2 and http/1.1; an empty ALPN result also selects HTTP/1.1 only with fallback enabled. Unknown ALPN fails.
- HTTPS proxy: one TLS leg to the proxy, HTTP CONNECT, then a second origin TLS leg over the connected stream. The proxy trust and optional proxy identity are distinct from origin trust and identity.
- HTTP CONNECT proxy: plain proxy transport, CONNECT, then origin TLS. SOCKS5: SOCKS5 CONNECT then origin TLS. TLS inside TLS uses memory BIOs.
- WebSocket wss uses TLS and HTTP/1.1 ALPN behavior; WebSocket routes are separate from HTTP/1.1 fallback flags. SSE and normal HTTP share origin identity behavior.
- Identity selection: fixed factory identity, per-origin selector, per-request identity, and a separate HTTPS proxy identity exist. Selectors run once per new dial, outside the pool lock. Pool keys include the selected identity. A selector returning nil means no certificate.
- SecureRandomCardinal calls OpenSSL RAND_bytes. This is an indirect native dependency even if client TLS imports are removed.
- Public symbols and migration choices are in tls-00-api.tsv. The API includes OpenSSL-bearing client identity getters (PX509, PEVP_PKEY), OpenSSL-backed PEM/PKCS#12 loaders, WithCACertFile, WithInsecureTls, identity selector and proxy identity methods, ALPN helpers, TTlsSocket, and client TLS error classes. TLS-07 must check direct, tunneled, CONNECT, SOCKS, WebSocket, SSE, HTTP/1.1 and fallback paths.

## Server TLS paths and API

- THttp2ServerFactory.WithTls(TTlsServerOptions) attaches server TLS config. THttp2AsyncServer.Start builds a policy and binds the listener with TLS when a certificate exists.
- mORMot2 creates the server SSL_CTX after bind. ApplyTls then sets ALPN, protocol range and mTLS trust/mode. The async accept path calls mORMot TLS AfterAccept at first read; current handshake is blocking and has a 5,000 ms library deadline.
- ALPN selects h2 preferentially. HTTP/1.1 may be selected when server fallback is enabled. With fallback off, the server rejects an unacceptable offer. The server reads selected ALPN from the connection raw TLS pointer.
- Peer identity is read after TLS handshake from the connection INetTls/SSL object. Verified certificate metadata reaches HTTP/2, HTTP/1.1, WebSocket and event request surfaces through per-connection state. Cleartext has no identity.
- TTlsServerOptions contains certificate/key/passphrase, handshake timeout, min/max versions, client-auth mode, CA file, system trust, partial-chain, depth and principal settings. Its defaults and current validation are recorded in tls-00-reading.md.
- Server Http2.Server.Tls, .Tls.Client, .Alpn, .ClientCert, .Mtls.Types, .Config.Tls, .Async.Options, .Async and stream/exchange adapters contain TLS/provider integration. TLS-08 owns role migration. TLS-02 must first prove a non-blocking adapter route.
- tls-00-api.tsv records changed or removed APIs. It includes WithTls, TTlsServerOptions methods, native ALPN and policy functions, client-certificate data and native certificate conversion.

## Current test gates

test/client/Http2.Client.TestRunner.pas includes client TLS, identity, proxy, SOCKS and mTLS tests. python3 tools/build.py test:client compiles and runs the full client unit runner; it also contains unrelated tests and live classes, so this is not a narrow one-file gate. test/server/Http2.Server.TestRunner.pas includes server ALPN, TLS policy, mTLS and configuration tests. python3 tools/build.py test:server is likewise a broad role suite. Do not run either as a baseline under TLS-00.

test/integration/server/Http2.Server.TlsProtocols.Test.pas is a standalone TLS 1.2/1.3 range program. The current root driver does not register this program in test:integration; that runner covers only Http2.Integration.Http.Test and Events.Test. validate:server:tls-live uses Http2.Server.TlsLive.pas; validate:server:mtls-live uses Http2.Server.MtlsLive.pas. Those are separate, loopback, generated-PKI gates. tools/build.py also exposes client mtls and mtls-real gates, and server tls-live/mtls-live gates. Live external peers and environment-gated cases need separate accounting.

Exact source paths and gate notes are in tls-00-tests.tsv. No tests ran for TLS-00. The main-worktree coordinator reports that source, docs, version and package repository checks passed at the base. The mORMot checkout is absent from this worktree, so build and test setup was not attempted.

## Open items for the coordinator

1. TLS-02 must record a proved server adapter route before TLS-08 begins. Current mORMot AfterAccept blocks the accepting I/O thread for up to 5 seconds, and existing server APIs expose raw TLS pointers.
2. TLS-07 must find all indirect OpenSSL dependencies, including identity loaders and RAND_bytes, before accepting provider isolation.
3. Existing no-ALPN/HTTP/1.1 behavior differs by role and fallback setting. Preserve it in tests; do not equate server fallback defaults with client fallback defaults.
4. Client creates a fresh SSL_CTX for each TTlsSocket, and the project does not call SSL_set_session or store sessions; it has no client resumption path. The mORMot server uses one SSL_CTX per listener and does not explicitly set session cache mode, session timeout, ticket count or SSL_OP_NO_TICKET. Resumption and ticket behavior therefore remain OpenSSL defaults on the server and are not asserted disabled. The new plan explicitly disables resumption and early data in the first shared API.
5. Optional Readers remains a distinct package during moves. It must not become a client core dependency.
