# TLS-08 main acceptance

The coordinator reviewed commit `67af46e` and merged it as `9cc1fb9` on
2026-11-11. The server package inventory now has 71 units. Its TLS adapter
and listener binding use the common session API. The raw mORMot transport
has no native TLS session. The dependency revision is unchanged.

## Review corrections

The adapter separates accepted plaintext, pending provider plaintext,
encrypted output, raw output, and completed HTTP credit. A retained
plaintext suffix survives a partial or zero acceptance. Read and write
progress can resume that suffix. The send loop stops when no progress is
possible. Session locks are released before raw writes and their callbacks.

The close path drains fatal alerts and peer close replies. Graceful close
waits for the unaccepted suffix and provider output. A completed handshake
clears its deadline. The header deadline applies to authenticated HTTP/2
input as well as cleartext input. The physical source split has 935 lines in
the async unit and 396 lines in its TLS include. TLS-10 checks the include
as part of the source and dependency inventory.

## Executed checks

All runs used the current macOS host. Each executable had a 30-second
limit. The coordinator ran one executable at a time. No run timed out.

- `make test-tls-server` on the merged tree passed 13 adapter cases in
  0.283 seconds and 12 listener cases in 4.863 seconds. The log is
  `bin/tls-coordinator/tls08-merged-main.log`.
- `make -C server check` passed. It checked 54 documents, 389 Pascal files,
  71 server source units, and one server package. The log is
  `bin/tls-coordinator/tls08-merged-check.log`.
- The worker compiled the full server test runner. The coordinator selected
  eight small suites: ALPN 2, mTLS context 5, factory 25, more configuration
  10, configuration ranges 12, TLS protocol policy 2, facade 2, and deadline
  policy 3. All 61 cases passed in the latest affected runs. The logs are
  `tls08-migrated-units-01.log` through `tls08-migrated-units-05.log` under
  `bin/tls-coordinator/`. The full timed server suite did not run.

## Intermediate failures

The logs retain failed runs. The initial adapter tests had managed-interface
temporary lifetime assumptions and an incorrect fake handshake byte count.
Later adapter runs passed all 13 cases. Listener runs found an incorrect
port-collision assumption on macOS, a deadline test that stopped at the first
closed peer, missing fake lifetime delegation, managed factory temporaries,
and incorrect response/close test assumptions. The final worker listener
run passed all 12 cases in 5.282 seconds. The merged run also passed.

Two migrated unit tests initially failed because of missing handler setup
and an assertion for the removed role-native TLS version option. The tests
now use valid handler setup and check the missing server-role policy.

## Scope

Provider-pair integration and package isolation remain TLS-09 and TLS-10
work. Load, Linux, containers, full timed server tests, and independent
conformance remain deferred. Same-library loopback tests do not establish
independent protocol conformance.
