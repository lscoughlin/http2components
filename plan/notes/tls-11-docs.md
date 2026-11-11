---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, documentation, migration
notes:
  - This record covers the TLS-11 documentation work.
---

# TLS-11 documentation and migration

Review date: 2026-11-11. The worktree is
`/Users/liamcoughlin/Source/lscoughlin/http2components-worktrees/tls-11-docs`
on branch `tls/TLS-11-docs`, based on `935cf6e`.

## Documentation scope

The README describes the five production roots and six packages at version
0.30.0. It records offline normal builds, explicit dependency setup, supported
tool versions, dependency root overrides, scoped package output and Lazarus
configuration, the macOS TlsLib RNG overlay and compiler wrapper, and the
bounded TLS targets. It states that `make examples` compiles programs only.
The integration example names are `tls_openssl.pas`, `tls_tlslib.pas`,
`tls_dual_role.pas`, and `tls_https_proxy.pas`.

New designs are `doc/design/common/tls-context.md`,
`doc/design/tls/openssl.md`, and `doc/design/tls/tlslib.md`. Updated client
and server material covers explicit role contexts, origin and HTTPS proxy
separation, common identity selection and peer metadata, retired native
server TLS units, and the current server configuration. The migration guide
has old and new API forms and labels the old source map as historical.

RFC 8446, RFC 5280, RFC 7301, RFC 9113, and RFC 9525 references state that
they were checked on 2026-11-11. The common and provider documents describe
trust anchors as PEM file paths. Secure defaults add no trust anchors and do
not enable system trust. OpenSSL system trust requires explicit
`WithSystemTrust(True)`.

## API and behavior decisions

Common owns the `ITLSContext`, `ITLSSession`, and `ITLSIdentity` contracts.
Client and server accept the common context; they do not re-export provider
interfaces. A context can hold client and server policies and serve both
roles across threads. Each transport owns a distinct serialized session.
Principal mapping uses server role `WithClientCertPrincipal`, not
`TTlsServerPolicy`.

The client identity order is request, selector, factory identity, then
context default. The selector runs once per new dial outside the pool lock. A
nil selector result suppresses the context default. Expired identities fail
before socket creation. Pool keys distinguish origin and proxy contexts and
selected origin identities. Proxy identity and context apply only to the
HTTPS proxy leg. Copied peer metadata contains no native handles or private
keys, and logs and observer records omit key secrets.

TlsLib documentation identifies fixed verification depth four, unsupported
system trust, explicit depth, DER identities, distinct SNI and verification
names, and peer verification without hostname verification. OpenSSL TLS 1.2
error metadata limits and unforced native `SSL_write` WANT behavior are
recorded as test limits, not behavior guarantees.

## Build and verification limits

The README records FPC 3.2.4 and Lazarus 4.0. The TlsLib build documentation
records the scoped Lazarus compiler wrapper, ordered pinned bootstrap, and
hash-checked macOS/FPC RNG overlay. The dependency checkout remains pinned and
unchanged. Runtime evidence and package-isolation details remain in the
accepted TLS-10 isolation record. TLS-09 HTTP and security results are
bounded macOS runs. Linux, load, independent-peer, and full conformance work
remains deferred in `plan/validation-after-merge-0.30.0.md`; rows V00 through
V14 are explicitly deferred. The old client and server source verification
counts are not presented as TLS acceptance.

The documentation-only check is `python3 tools/check/repository.py docs`.
It checks document and Pascal header syntax. No runtime, network, load, or
Linux suite is part of TLS-11 documentation work.
