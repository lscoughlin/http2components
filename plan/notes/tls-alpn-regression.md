# OpenSSL ALPN and policy regression notes

The OpenSSL server ALPN callback now uses `OpenSSLSelectAlpnVector` from the
provider session unit. The helper checks the full client vector before it
selects a protocol. A zero-length entry, a truncated entry, a nil input, or an
empty input vector returns the fatal result. It returns no acknowledgement
when the client vector is valid and the server has no preferred protocols.
The selected name pointer refers to the name bytes in the original client
vector. The selected length is the exact name length. The server preference
order selects the protocol when the client offers more than one name.

Each session stores its encoded server ALPN vector when it is created. The C
callback uses this stored vector. It does not encode strings or allocate a new
vector during callback execution. The callback returns a fatal result for
malformed vectors and does not select a protocol after a later malformed
entry.

The ALPN test unit restores the 16 legacy selection assertions. It also checks
malformed trailing data, nil input and output pointers, and no configured
server protocols. Each passing assertion prints its stable `openssl.alpn.*`
ID. The test runner adds the returned assertion count.

The policy test unit checks role defaults, copy isolation, trust-anchor input
and output copies, missing server identity, reversed version ranges,
verification-depth boundaries, system trust, and missing trust and identity
files. It checks combined PEM loading by writing the existing certificate and
key to one fixture and passing that path as both arguments to
`FromPemFiles`. The fixture is removed after the check. The separate empty
key-path shorthand is not part of this behavior; both file arguments identify
the combined file.

The OpenSSL runner and both new test units compile with FPC 3.2.4 on macOS
/aarch64. The compile links the runner. The runner was not executed by this
worker. Root owns the bounded runtime run. No Linux or load validation is
included.

The current OpenSSL runner compiled and linked with FPC 3.2.4 on macOS/aarch64.
The compile used the repository TLS build driver with the pinned mORMot2 source
path. The executable is
`bin/aarch64-darwin/default/openssl-test/programs/Http2.Tls.OpenSSL.Tests`.
Its SHA-256 is
`8b2a892b47f96160939405aea4135ab1828c5f846aceb9f4a4ba7ec2a3491661`. The
executable was not run by this worker. The central bounded run remains the
runtime evidence source.

## Coordinator acceptance

The coordinator reviewed commit `b8f7125` and merged it as `51cb1db` on
2026-11-11. The review required fatal rejection of an empty client vector,
constructor-time ALPN encoding, visible case IDs, nontrivial policy-copy
checks, and server client-auth trust checks. These changes are in the final
commit. The native callback performs no Pascal string encoding or vector
allocation. Native handles remain absent from the public facades.

The final worker binary passed 139 cases in 0.504 seconds, exit 0, under a
30-second limit. The merged `python3 tools/build.py test:tls:openssl` target
passed the same 139 cases in 0.399 seconds, exit 0. The count is 93 existing
cases, 21 ALPN cases, and 25 policy/identity cases. Ten lifecycle repetitions
returned the native counters to X509=6, SSL=0, and SSL_CTX=2.

The logs are `bin/tls-coordinator/tls-alpn-policy-final-worker.log` and
`bin/tls-coordinator/tls-alpn-policy-main.log`. An earlier reviewed binary
passed 138 cases before the final mismatched-key assertion and cache cleanup;
its log remains `bin/tls-coordinator/tls-alpn-policy-worker.log`.
The worktree and branch were removed after merged acceptance.
