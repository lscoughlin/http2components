# TLS-02 async adapter reading

## Scope and sources

This note records the transport and protocol reading for the server adapter part of TLS-02. The source check date is 2026-11-11.

- R1: RFC 9113 sections 3.2 and 9.2; RFC 8740 sections 2 and 3; RFC 7301 sections 3.1 and 3.2. The local reference copies are `doc/references/rfc9113.txt`, `rfc8740.txt`, and `rfc7301.txt`. Official URLs are <https://www.rfc-editor.org/rfc/rfc9113>, <https://www.rfc-editor.org/rfc/rfc8740>, and <https://www.rfc-editor.org/rfc/rfc7301>.
- R2: RFC 8446 sections 4.1, 4.2, 4.3.2, 4.4, 5, and 6. The local reference copy is `doc/references/rfc8446.txt`. Official URL: <https://www.rfc-editor.org/rfc/rfc8446>.
- R3: RFC 5280 sections 4.1, 4.2.1.6, 4.2.1.9, 4.2.1.12, and 6; RFC 4514 sections 2 and 3. The local copies are `doc/references/rfc5280.txt` and `rfc4514.txt`. Official URLs: <https://www.rfc-editor.org/rfc/rfc5280> and <https://www.rfc-editor.org/rfc/rfc4514>.
- R6: mORMot revision `b2b195da1e0580058672a88620ef71bb47283eb1`, checked out in this worktree at `third_party/mORMot2`. Relevant units and symbols are listed below.
- Project inputs: `plan/tls-replacement.md`, `plan/notes/tls-00-inventory.md`, `plan/notes/tls-00-reading.md`, `doc/design/server/tls.md`, and `doc/design/server/mtls.md`.

## Protocol constraints relevant to the adapter

- RFC 9113 section 3.2 requires HTTP/2 over TLS to use ALPN and to begin HTTP/2 only after successful TLS negotiation. Section 9.2 restricts TLS 1.2 features and cipher suites for HTTP/2. The adapter must defer HTTP parsing and ALPN routing until the session is open.
- RFC 7301 sections 3.1 and 3.2 define ALPN offer and selection in the TLS handshake. The server can select only a protocol offered by the client. The application protocol decision remains in the server role layer.
- RFC 8740 updates the HTTP/2 rules for TLS 1.3 post-handshake authentication. The server does not send a post-handshake `CertificateRequest` for HTTP/2. The adapter reports handshake completion before the HTTP/2 connection preface is processed.
- RFC 8446 sections 4 and 5 define handshake messages and record processing as a sequence that can require more input and can produce output at each step. A handshake step can need read readiness or write readiness. The adapter must drain generated records even when no application plaintext is queued. Alerts and EOF are terminal outcomes, not empty successful requests.
- RFC 5280 path validation and extensions include certificate constraints and subject alternative names. RFC 4514 defines distinguished-name string conversion and parsing. These affect verified peer metadata after the handshake, but do not provide a transport hook.

## mORMot symbols inspected

- `src/net/mormot.net.sock.pas`: `INetTls`, `TNetTlsContext`, `TNewNetTls`, global `NewNetTls`, and `TCrtSocket.DoTlsAfter`.
- `src/net/mormot.net.async.pas`: `TPollAsyncConnection.OnFirstRead`, `TPollAsyncSockets.ProcessRead`, `TPollAsyncSockets.ProcessWrite`, `TPollAsyncSockets.SubscribeConnection`, `TAsyncServer.OnFirstReadDoTls`, `TAsyncServer.DoExecute`, `TAsyncConnections.ConnectionNew`, and `TAsyncServer.ConnectionCreate`.
- `src/lib/mormot.lib.openssl11.pas`: `TOpenSslNetTls.AfterBind`, `TOpenSslNetTls.AfterAccept`, and `TOpenSslNetTls.Send`.

## Findings

- `TCrtSocket.DoTlsAfter` obtains every TLS object from process-global `NewNetTls`. No per-listener session factory exists in the inspected async server API.
- `TAsyncServer.OnFirstReadDoTls` obtains another object from `NewNetTls`, calls `AfterAccept`, and only then calls `MakeAsync`. The first-read callback is synchronous.
- `TPollAsyncSockets.ProcessRead` sets `fFirstRead` before it calls `OnFirstRead`. A `false` return closes the connection. There is no pending result. The same function then calls `Recv` and delivers plaintext to the connection parser.
- `TPollAsyncSockets.ProcessWrite` does not call `AfterWrite` or any TLS callback when `fWr` is empty. It unsubscribes from write readiness when the plaintext output buffer is empty. Thus it cannot flush TLS handshake ciphertext without a separate hook.
- `INetTls.Send` defines `Length = 0` on `nrRetry` so the caller can retry the exact plaintext buffer. The TLS implementation can already hold ciphertext for that retry. An adapter that advances the common session and reports consumed plaintext before mORMot accepts it can duplicate plaintext. The current mORMot call graph does not expose the session's exact plaintext credit.
- `TNetTlsContext.AcceptCert` is a raw borrowed pointer populated by `AfterBind`. The OpenSSL implementation uses it to create each `SSL` in `AfterAccept`; the source comments require the bound context to remain valid during accept. The current lifecycle has no safe common-interface binding for this pointer.
- `ConnectionNew` calls `AfterCreate` after it assigns a handle and before `TPollAsyncSockets.Start`. This can mark an accept deadline, but an idle peer produces no read event. The inspected poll API has no handshake deadline callback for an individual connection. A deadline therefore requires a bounded sweep or timer integration.
- `fRWSafe` can use separate read and write locks. A handshake pump called from both poll paths needs one serialization rule for the TLS session. Existing `ProcessRead` and `ProcessWrite` locks do not prove that rule.

## Reading conclusion

The native mORMot TLS route is unsupported for a readiness-driven common TLS session. `AfterAccept` cannot drive the handshake because it blocks before the socket becomes asynchronous. The raw socket route is feasible without an mORMot extension: mORMot can accept a non-blocking socket with TLS disabled, and the server's async connection can feed ciphertext to its own session. The bounded poll-path proof and remaining provider integration work are in `tls-02-adapter.md`.
