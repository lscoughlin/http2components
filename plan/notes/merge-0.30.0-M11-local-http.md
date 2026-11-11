# Local HTTP integration

The loopback runner starts the merged server and client in one process.
It uses ephemeral listener ports, two handler threads, one IO thread,
and a separate generated PKI directory for each invocation. The PKI is
removed after the bounded run.

Five cases pass in 2.435 seconds on macOS arm64 with OpenSSL 3:
cleartext HTTP/2 binary echo, cleartext HTTP/1 chunked echo, TLS HTTP/2
binary echo, repeated start/stop, and four concurrent requests. The binary
body is 70,003 bytes and crosses the default HTTP/2 window. Each exchange
also checks connection reuse and HEAD behavior.

The initial run found a real upload deadlock introduced by shared encoder
locking. Commit 126659e releases the lease lock while waiting for send
credit, and reacquires it in a finally block. The retained integration
cases exercise this correction.

The initial concurrent fixture used ReadChunk in a busy loop. ReadChunk
can return True with an empty chunk before the request has ended. The
fixture now uses the blocking Read contract. No library change was made
for that fixture failure. The complete five-case suite passes after this
correction. Logs are bin/review-local-integration-pass.log and the earlier
review-local-integration*.log files. The thread sample is diagnostic
history, not a required artifact.

The full imported client suite compiled after C01 and the upload fix but
reached its 90-second deadline. This result remains under investigation;
it is not a pass. Earlier client baseline and pre-fix import passes remain
separate evidence. No resource-intensive tests or Linux checks ran.

Further M11 cases remain: retained TLS/mTLS programs, protocol range tests,
SSE/WebSocket cases, and separate-process peer checks.

## Local event protocols

The integration runner now includes four event protocol cases. SSE uses a
real response body on HTTP/2 and HTTP/1.1, then sends Last-Event-ID on a
second request and checks the next event. WebSocket uses ws and wss,
checks the selected subprotocol, sends a fragmented text message, and
checks the echo and close status. The peers use ephemeral loopback ports.
The listener wait is five seconds. The whole runner has a process deadline.

On macOS aarch64, all nine integration cases passed in 3.938 seconds on
2026-11-11. The log is `bin/review-events-integration.log`. This is local
agreement between the merged roles. It is not independent conformance
proof. Independent peers, load, and Linux remain deferred.
