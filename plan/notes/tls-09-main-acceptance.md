# TLS-09 main acceptance

The coordinator reviewed and merged the security branch as `e53dc45` and
the HTTP integration branch as `8f01bc4` on 2026-11-11. Both branches use
base `f52bdf7`. The runtime checks used macOS 27.2, FPC 3.2.4,
`aarch64-darwin`, and the pinned providers. Each executable had a 30-second
limit. The coordinator ran one executable at a time. No run timed out.

## HTTP integration and facade types

`make test-tls-integration` passed 29 cases on the merged tree in 6.401
seconds. Concurrent worker output interleaved some case labels. The
coordinator moved result printing to the parent after both worker joins.
The corrected program passed all 29 cases in 6.696 seconds, with 29 complete
and unique case-ID lines. The log is
`bin/tls-coordinator/tls09-http-main-02.log`. The earlier merged log is
`bin/tls-coordinator/tls09-http-merged-main.log`.

The final command used `tools.build.compile_file` with component
`tls-integration-test` to compile the public API probe and integration
runner. `tools.build.run_suite` ran the integration binary with OpenSSL
enabled, `timeout=30`, and the binary's isolated directory as `cwd`.
The API probe was a compile check; it did not run a TLS exchange.

The 29 cases comprise eight direct-session metadata cases, eight actual
HTTP/2 exchanges, five fresh listener connections, and eight concurrent
requests. The metadata and HTTP rows cover O/O, O/T, T/O, and T/T at TLS 1.2
and 1.3. The HTTP handlers require a nonzero HTTP/2 stream and a verified
client certificate principal. HTTP/1.1 fallback is disabled.

Direct sessions report negotiated version, cipher, ALPN, verified client
and server identities, and copied peer data after session teardown. These
are direct-session observations, not metadata read from the separate HTTP
transport. Exact version policies, strict h2, and verified request principals
constrain the actual HTTP exchanges.

The shared-context cases pass the exact same dual-role context to both
clients and the listener. Two handler calls meet at a bounded barrier, so
their requests overlap. Caller context variables are cleared before use.
The mixed-provider listener cases create a fresh client for each connection,
stop the OpenSSL listener, and make new connections to the TlsLib listener.

## Cross-provider security

The security runner passed 200 named assertions across 152 handshake
scenarios on main in 0.704 seconds. The log is
`bin/tls-coordinator/tls09-security-merged-main.log`. The coordinator built
common and both providers, compiled `Http2.Tls.Security.Tests.pas` with
component `tls-integration-test`, and used `run_suite` with OpenSSL enabled,
`timeout=30`, and the isolated binary directory as `cwd`.

Each provider pair and TLS version has 19 scenarios. They check trusted and
unknown issuers, expiry with a valid-chain control, DNS and IP identity,
server ALPN preference, absent ALPN, and none/request/require client auth
with missing, valid, and invalid identities. Timeout or an unexpected error
does not count as expected certificate rejection. Owned expired fixtures
contain a complete intermediate chain. PEM normalization retained both DER
hashes and chain order. Fixture CLI checks are not independent TLS peers.

## Failed intermediate checks and limits

The first HTTP child completed 20 assertions, but the driver rejected its
summary format. The second run rejected a fresh client given a server-only
context. The corrected worker run passed 29 cases before the main checks.
The security runner first failed to catch an expected verification error.
Its second run had an incorrect ALPN preference expectation. Review also
corrected the expired-certificate chain and made invalid optional client
authentication require rejection. All intermediate logs remain in
`bin/tls-coordinator/`.

There are no inactive required cases in these two runners. Provider-specific
unsupported capabilities remain in the provider evidence. Existing OpenSSL
CLI protocol tests were migrated and compiled but were not executed. Linux,
load, external proxies, independent conformance, and full timed server suites
remain deferred. TLS-10 owns the final combined named integration target and
build isolation checks.
