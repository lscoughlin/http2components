# TLS-02 server adapter feasibility

## Decision

**The raw socket route is feasible.** The server owns the common TLS session on each connection. mORMot TLS stays disabled for this listener. The adapter uses the existing async socket poll, connection read, connection write, after-write and idle-sweep paths. It does not use global `NewNetTls`, `TNetTlsContext.AcceptCert`, `INetTls.AfterAccept`, or an mORMot dependency patch.

The study proves the route through the actual mORMot TCP accept and poll path with a fake session. It does not prove a real provider session attached to an HTTP/2 listener. The provider engine study has separate evidence. TLS-09 must prove the provider-to-adapter integration.

## Source route

With mORMot `acoEnableTls` disabled, `TAsyncServer.DoExecute` accepts a non-blocking socket. The accepted connection has `fSecure = nil`. `TPollAsyncSockets.ProcessRead` places raw ciphertext in `TPollAsyncConnection.fRd` and calls the connection's `OnRead`. The HTTP/2 server connection already owns `OnRead`, `SendPendingOutput`, `AfterWrite`, `OnLastOperationIdle`, `ReleaseState`, and `Recycle`.

The planned adapter flow is:

1. At accepted connection creation, the listener binding creates one server session. The connection retains the session and binding. The session has a monotonic deadline set from the accept time.
2. `THttp2AsyncConnection.OnRead` passes the raw `fRd` ciphertext to the session. It advances the session until it needs more read or write readiness. It passes session plaintext to the current cleartext protocol selector or HTTP core only after the TLS handshake succeeds.
3. The server makes the ALPN and mTLS decision only after session completion. It does not call the HTTP parser with handshake ciphertext or with plaintext from an unverified peer.
4. `SendPendingOutput` removes core plaintext once and submits it to the session's bounded plaintext queue. The adapter keeps any session output that is not yet encrypted. It drains encrypted bytes into mORMot's raw `fOwner.Write` path. mORMot then owns the accepted ciphertext in its socket buffer.
5. `AfterWrite` drains the next encrypted chunk into `fWr` after a partial raw socket write. It also drains TLS alerts and other control output when the application has no write. It does not call the session while holding the session lock across `fOwner.Write`; mORMot can call `AfterWrite` from inside that write.
6. A per-connection recursive lock serializes `FeedCiphertext`, session advancement, application input/output, and encrypted-output draining. The lock is released before calls that can re-enter the mORMot write path.
7. The server's `IdleEverySecond` sweep checks each pending session against its fixed accept-time deadline. It snapshots connection handles, checks each session while holding the connection lookup lock, releases the lock, and then calls `ConnectionRemove(handle)`. The remove operation looks up the handle again. New input does not reset the deadline.
8. `OnClose`, `ReleaseState`, `Recycle`, and `BeforeDestroy` clear the session and binding once. No TLS session outlives its listener-owned context.

This route avoids mORMot's plaintext-credit behavior. The adapter does not pass HTTP plaintext through `INetTls.Send`, so it does not report `Length = 0` on `nrRetry` or retry plaintext at that interface. The adapter owns a bounded plaintext queue until the TLS engine accepts the bytes. It advances its queue only by the engine's reported plaintext credit. Once the engine accepts bytes, the session owns them. The adapter drains encrypted bytes into mORMot's raw output queue, which owns those bytes after `Write` returns success. The study verifies the resulting ciphertext stream byte-for-byte and checks for loss, repetition or change.

The accepted connection and timer paths are already used by the server. The deadline sweep pattern matches the existing server age sweep in `THttp2AsyncServer.IdleEverySecond` and its connection-handle removal path. The study uses `ConnectionRemove(handle)` so a stale handle cannot close a recycled connection.

## Required TLS-08 file and symbol changes

TLS-08 owns these server files after TLS-01 moves the source roots:

| File or symbol | Required change |
| --- | --- |
| `Http2.Server.Async.pas`, `THttp2AsyncServer` construction | Keep mORMot `acoEnableTls` disabled. Bind an immutable `ITLSContext` to this listener. Create server sessions from this listener binding. |
| `Http2.Server.Async.pas`, `THttp2AsyncConnection.AfterCreate` | Record the monotonic accept time and create the per-connection session from the retained binding. |
| `Http2.Server.Async.pas`, `THttp2AsyncConnection.OnRead` | Feed raw ciphertext, advance the session, and route only authenticated plaintext after handshake completion. Move ALPN routing and peer identity reads after completion. |
| `Http2.Server.Async.pas`, `THttp2AsyncConnection.SendPendingOutput` | Submit each core plaintext buffer to the session once. Preserve bounded pending plaintext until the session reports credit. Drain only encrypted bytes to the raw mORMot writer. |
| `Http2.Server.Async.pas`, `THttp2AsyncConnection.AfterWrite` | Continue the encrypted-output pump after short writes and for TLS control output without application plaintext. Keep the session lock out of nested `fOwner.Write` calls. |
| `Http2.Server.Async.pas`, `THttp2AsyncServer.IdleEverySecond` | Sweep pending handshakes against the fixed accept deadline. Snapshot handles and remove by handle after releasing the connection-list lock. |
| `Http2.Server.Async.pas`, `THttp2AsyncConnection.ReleaseState`, `Recycle`, `BeforeDestroy`, `OnClose` | Serialize shutdown and release the session and listener binding once. Reset all per-connection TLS state before reuse. |
| `Http2.Server.Tls.Adapter.pas` and `Http2.Server.Tls.Binding.pas` | Add the server-owned adapter and listener binding named by the plan. Keep provider handles private to provider sessions. |

No mORMot source or upstream patch is needed for this route. The target-owned mORMot clone used for source reading is clean at its pinned revision. The discarded hook experiment is not part of the proposal.

## Bounded study

Study source: `tools/studies/tls/adapter/RawPollStudy.pas`. It has no provider dependency. Its fake session tests the event-loop and ownership route; it does not claim a provider handshake.

| Case | Result |
| --- | --- |
| Two listeners with different per-listener context tags in one process | Passed; each listener returned its own tag. |
| Split handshake input | Passed on both listeners. The first octet and the remaining bytes arrived in separate writes. |
| Handshake output without an application write | Passed. The session queued output from handshake input and the poll path drained it through write readiness. |
| Small socket capacity and partial transport output | Passed. The server and client socket buffers were 4,096 bytes. Each session emitted 4,194,305 bytes. The observed mORMot pending-write peak was 12,288 bytes per listener. |
| Ciphertext loss, duplication or change | Passed. The client checked every byte and the exact stream length on both listeners. |
| Application input after handshake | Passed on both listeners. |
| Silent peer deadline | Passed at 2,420 ms from accept. The deadline was 1,500 ms; the one-second sweep adds at most one second plus timer scheduling. |
| Trickle input and absolute deadline | Passed at 2,035 ms from accept. The last input was 834 ms old at expiry. The idle-only callback was not yet eligible. |
| Stale handle after deadline removal | Passed. A second removal by the expired handle did not remove another connection. |
| Listener stop and connection lifetime | Passed. Shutdown released two connection objects on each listener. |

The run used two active data sessions plus one silent peer and one trickle peer. One run completed in 5.0 seconds under `timeout --foreground --signal=TERM --kill-after=2s 25s`; no process remained. Compiler output and run output are under ignored `bin/studies/tls-adapter/`. No provider suite was run in this reserved slot.

## Limits and next proof

- The study session is fake. It does not implement RFC 8446, certificate checks, ALPN, client authentication, alerts, or EOF.
- The study does not bind two real providers to concurrent HTTP/2 listeners. TLS-09 owns that integration proof.
- The study's 1,500 ms handshake timeout is checked by a one-second scan. Its observed timeout can be close to 2,500 ms. TLS-08 must document this maximum and ensure the policy accepts that scan bound, or add a more frequent timer.
- The exact retry-credit contract of provider plaintext writes is not exercised here. TLS-08 must preserve the common session's explicit accepted-plaintext count and keep rejected bytes queued once.
- Linux, load, containers, long runs, and full TLS conformance are not tested.

## Check record

- Pinned source read: mORMot `b2b195da1e0580058672a88620ef71bb47283eb1`.
- FPC command: `fpc -B -Mdelphi -Fu./third_party/mORMot2/src/core -Fu./third_party/mORMot2/src/lib -Fu./third_party/mORMot2/src/net -Fu./third_party/mORMot2/src/crypt -FU./bin/studies/tls-adapter/units -FE./bin/studies/tls-adapter/programs tools/studies/tls/adapter/RawPollStudy.pas`.
- Run command: `timeout --foreground --signal=TERM --kill-after=2s 25s ./bin/studies/tls-adapter/programs/RawPollStudy`.
- Result: compiler exit 0; one bounded run exit 0.
- No production, build, package, or sibling source changed.
