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
before 15:19:55 UTC on 2026-11-11. All 25 example programs have output files,
so the compile completed successfully. The full compiler output was not
retained. It included warnings from the source and dependency units; no
compile error was reported.

The output hash manifest is `bin/aarch64-darwin/default/examples-programs.sha256`.
The build compiled programs only; no example was run and no external request
was sent.
