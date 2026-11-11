# TLS-11 example notes

The client examples select OpenSSL explicitly for HTTPS and WSS requests.
Origin and HTTPS proxy connections use separate TLS contexts where the proxy
has its own TLS connection. The mTLS example loads identity files through the
OpenSSL identity loader. Its optional CA file remains trusted by both the
origin and HTTPS proxy contexts.

Four integration programs use public client and server facades. They show
OpenSSL with system trust, TlsLib with an explicit CA file, one OpenSSL
context shared by client and server roles, and separate TLS contexts for an
HTTPS origin and proxy. The dual-role program uses the server's actual port
after start and trusts the supplied server certificate for `localhost`.

The client README now describes explicit provider selection and the relocated
identity loader behavior. The integration README describes each program and
its trust configuration.

The compile command was `python3 tools/build.py examples`. It used dependency
roots in the main checkout and wrote generated files under this worktree's
ignored `bin/` directory. It started at about 15:13:47 UTC and completed
before 15:19:55 UTC on 2026-11-11. All 25 example programs had output files,
but the command exit status and full compiler output were not retained.
This was provisional evidence, not complete build acceptance. The visible
output included warnings from source and dependency units; no compile error
was reported.

The output hash manifest is `bin/aarch64-darwin/default/examples-programs.sha256`.
The build compiled programs only; no example was run and no external request
was sent.

## Coordinator acceptance

The coordinator reviewed `fe9c02b` and merged it as `15feb54`. The review
required public-facade-only imports in the four new programs, explicit
partial-chain trust in the shared-context example, the actual bound server
port, and preservation of the mTLS example's CA trust on the separate proxy
context. The client facade now aliases the three proxy-kind values.

The merged `python3 tools/build.py examples` command ran from
2026-11-11 15:21:48 UTC to 15:26:09 UTC. It returned exit 0 after 261.178
seconds. All 25 binaries have modification times after this run started:
11 client programs, 10 server programs, and 4 integration programs. The
programs were compiled and linked; none was executed.

The complete log is `bin/tls-coordinator/tls11-examples-main.log`. Its command,
UTC times, duration, and exit status are also in
`bin/tls-coordinator/tls11-examples-main.json`. The output hashes are in
`bin/tls-coordinator/tls11-main-examples.sha256`; the worker's provisional
manifest is retained as `bin/tls-coordinator/tls11-worker-examples.sha256`.
The task worktree and branch were removed after this acceptance.
