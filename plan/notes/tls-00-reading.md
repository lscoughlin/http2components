# TLS-00 reading and baseline

## Reading

- Current plan: `plan/tls-replacement.md`, full file. TLS-00 owns inventory only. The plan fixes the new roots at `common/src`, `client/src`, `server/src`, `tls/openssl/src` and `tls/tlslib/src`; it puts the shared context in common and requires provider selection per context. The plan excludes Linux, containers, load, long server runs and full conformance through TLS-12.
- Original server plan: `/Users/liamcoughlin/Source/lscoughlin/http2server/plan/tls-replacement.md`, full file. It was a server-only proposal. Its `ITlsContext` binds an mORMot socket, uses process-global `NewNetTls`, and restricts a process to one provider. These choices do not apply to the current components plan. Its blocking stock TlsLib adapter is also not accepted as an async route.
- R0: `AGENTS.md`; `doc/design/common/architecture.md`; root `Makefile`; `Taskfile.yaml`; `tools/build.py`; `tools/packages.py`; `tools/check/repository.py`; package generation logic and current manifests. No `.codegraph/` directory exists in this worktree.
- R4: `doc/design/client/mtls.md`, `transport.md`, `proxy.md`, `fallback.md`, and `open-questions.md`; all current units for identity selection, pool keys, direct TLS, TLS tunnel and socket; TLS, identity, CONNECT/TLS-proxy and mutual-TLS tests. The core client owns direct origin TLS, HTTPS proxy TLS, CONNECT tunnelling, SOCKS routing, WebSocket TLS and HTTP/1.1 fallback selection. The TLS layer owns TLS records and ALPN bytes. The factory selects origin and proxy credentials separately.
- R5: `doc/design/server/tls.md` and `mtls.md`; async accept and first-read paths; server TLS policy, ALPN, TLS options, client certificate reader and identity types; ALPN, policy, mTLS, configuration and TLS protocol tests. `THttp2AsyncServer.Start` binds TLS, and the first read completes the blocking mORMot handshake before ALPN routing and peer identity extraction.
- Read the TLS-00 code and test paths listed in `plan/notes/tls-00-tests.tsv` directly. The source inventory is the evidence for behavior; no baseline test was run for this task.

## Baseline

| Item | Observed value |
| --- | --- |
| Git base | `efe4cf40cc3fedd26b8f39d9979930176663d9fd` |
| Git status before notes | clean; no tracked or untracked worktree changes |
| Plan status | `plan/` is ignored. The copied plan is present in this worktree but is not part of the branch commit. The main worktree status is A plan/tls-replacement.md (intent-to-add, not staged). |
| FPC | `3.2.4` (`fpc -iV`) |
| Lazarus build tool | `lazbuild 4.0` (`lazbuild --version`, `lazbuild -v`) |
| Current package version | `0.30.0` from `VERSION` and the four current `.lpk` manifests |
| Current production units | 135 units under `src/{common,client,server}`; all paths and package assignments are in `tls-00-moves.tsv` |
| Current packages | `http2common`, `http2client`, `http2server`, `http2clientreaders`; Readers is separate and optional |
| mORMot pin | `b2b195da1e0580058672a88620ef71bb47283eb1` in `tools/build.py` (`MORMOT_REV`). No dependency checkout exists in this worktree. The coordinator reports the matching checkout in the main worktree. |
| Client TLS dependency | `mormot.lib.openssl11`, reached directly by client TLS, identity loading and secure random generation. `OPENSSL_LIBPATH` selects a system OpenSSL location. No OpenSSL source pin is present. |
| TLS-00 edits | Notes only. No Pascal, build, package, test, example or documentation source changed. |
| Tests run | None. No new baseline run is required by TLS-00. |

## Current build and package paths

The root `Makefile` dispatches to `tools/build.py`; `Taskfile.yaml` calls the same Python operations. `tools/build.py` compiles the current roots `src/common`, `src/client`, `src/server` and places compiler output under `bin/<cpu>-<os>/<profile>/<component>`. It pins mORMot by revision and sets mORMot search paths for client, server, Readers, examples, API and integration programs. `tools/packages.py` derives current package membership from unit namespace and emits four root `.lpk` and package `.pas` files. The current package manifests use the current three source roots and mORMot paths. `tools/check/repository.py` checks source layout, unit names/dependencies, package inventory, docs and version. It scans `src`, `test`, `examples` and `tools` for Pascal files.

Build, validation, and dependency paths that TLS-01/04/10 must review include:

- Root `Makefile`, `Taskfile.yaml`, `tools/build.py`, `tools/packages.py`, `tools/check/repository.py`, `VERSION`, `NOTICE`, and the four root `.lpk`/generated package-unit pairs.
- `tools/client/validate/` scripts and Python peers, `tools/server/validate/`, `tools/server/certs/`, and `tools/check/local_process.py`.
- `tools/client/container/` and `tools/server/container/` are present but all container work is deferred by the plan; paths still need owner review at TLS-10/TLS-13.
- CI configuration: no `.github/` directory is present in this worktree.
- TLS-bearing examples are under `examples/client/`, `examples/server/` and `examples/integration/`; the server TLS examples include `examples/server/tls_server.pas`, `mtls_server.pas` and `interop_server.pas`.
- Fixtures are under `test/fixtures/client/certs/`; PKI scripts create temporary test material. Existing client validation uses `tools/client/validate/make-mtls-certs.sh`; server validation uses `tools/server/certs/make_mtls_pki.sh`.

## Current ownership and behavior

- Client TLS is OpenSSL-only. `TTlsSocket` owns `PSSL_CTX` and `PSSL`, drives synchronous handshakes and reads/writes, configures SNI, hostname verification, trust, identities and ALPN, and detects client-auth rejection. The CONNECT tunnel wraps an existing byte stream with memory BIOs. Direct sockets use a file descriptor.
- Client trust defaults to system trust: empty CA path calls `SSL_CTX_set_default_verify_paths`. `InsecureTls` defaults to `False`; it sets `SSL_VERIFY_NONE` when true. Client protocol bounds are not explicitly set in this code. Client handshake and socket I/O use the supplied timeout; the default socket timeout is 30,000 ms. HTTP/1.1 fallback defaults off and the default ALPN offer is `h2` only. `http` is rejected by default (`ctReject`).
- Client identities are loaded from PEM files, PEM bytes or PKCS#12 using OpenSSL. Public `IClientIdentity` exposes native `PX509` and `PEVP_PKEY` handles. The selector runs for each new origin dial outside the pool lock; the selector may return nil. Origin credentials are distinct from the one credential for an HTTPS proxy. Identity choice and context are relevant to the pool key. The secure RNG helper calls `RAND_bytes` and has no fallback.
- Client mTLS applies to origin TLS, HTTP/1.1 fallback, SSE and `wss`, including direct and tunnel routes. TLS 1.2 rejection is reported during handshake; TLS 1.3 rejection can be reported on the first read. The error is final and does not trigger fallback.
- Server options default to TLS 1.2 through TLS 1.3, a 10,000 ms configured handshake timeout, no client certificate, no client CA file, system trust off, partial chain off, verify depth 4, and no principal text. mORMot `AfterAccept` clamps the actual handshake to 5,000 ms. Server ALPN defaults to allowing HTTP/1.1 fallback; `h2` wins when offered. The server enforces its TLS policy after bind because mORMot creates `SSL_CTX` in `AfterBind`.
- Server mTLS supports none, optional and required client authentication. Optional mode accepts no certificate, but rejects an invalid presented certificate. Required mode rejects missing and invalid certificates. Trust can use a CA file and/or system store; partial chain and depth are OpenSSL controls. The server reads peer identity from the per-connection SSL object only after the handshake; a presented but unverified certificate is not exposed. Identity data includes subject, issuer, common name, serial, SHA-256, DNS/URI/email SAN, UTC dates, PEM, and configured principal. IP SAN is not currently retained.
- Client creates a fresh SSL_CTX for each TTlsSocket. Project source does not call SSL_set_session or retain a client SSL_SESSION, so no client resumption path is implemented. mORMot creates a listener SSL_CTX reused by accepted connections. It does not explicitly set session cache mode, session timeout, ticket count or SSL_OP_NO_TICKET; server resumption/ticket behavior is OpenSSL default behavior and is not asserted disabled. The replacement plan explicitly disables resumption and early data in its first shared-session API.

## Baseline check evidence

The coordinator ran read-only repository checks in the main worktree at this base: `python3 tools/check/repository.py source`, `docs`, `version`, and `packages`; all returned exit 0. The check reported 353 Pascal files, 337 active files, 135 production units, 299 unit declarations, 54 documentation files and four packages. TLS-00 did not repeat those checks or run tests. In this worktree, the third-party mORMot checkout is absent, so builds and tests are not runnable without setup and are not attempted.
