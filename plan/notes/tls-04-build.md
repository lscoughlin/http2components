# TLS-04 build and dependency notes

The review date is 2026-11-11. The task base is `27bae2c`. The worktree uses
the TLS-01 layout and the accepted TLS-02 dependency and adapter decisions.
The common TLS API is not part of this change. The two provider units are
temporary package facades. Their operations raise explicit unavailable
errors until TLS-05 and TLS-06 replace them.

## Pinned dependencies

The revision and license records are in `tools/dependencies.json`. The TlsLib
dependency revisions are exact. Their origin URLs are the public Git remotes.
`mORMot2` remains at `b2b195da1e0580058672a88620ef71bb47283eb1`. The MIT
license files stay in each local third-party clone. The mORMot upstream
`LICENCE.md` and project notice record its license choices.

TlsLib calls use the source and include directories from all four pinned
dependencies. Compiler package units are written in the TLS-02 order:
HashLib, SimpleBaseLib, CryptoLib. The compiled TlsLib facade follows those
package units. This order avoids the source cycle through
`ClpMultipliers`, `ClpWnafUtilities`, and `ClpECAlgorithms`. Every unit file
and program output is under `bin/<target>/<profile>/tlslib/`; bootstrap units
are under its `units/bootstrap/` subdirectory. Each compile has a 300-second
limit. A timed command stops only its own process group.

The TLS-02 capability record remains the implementation boundary. TlsLib
client and server support for TLS 1.2, TLS 1.3, ALPN, explicit trust anchors,
client authentication, and partial-chain trust was proved by its engine
study. Its optional system-trust package is required for system roots.
TlsLib does not expose configurable verification depth; its path builder
limit is four. OpenSSL supports both roles and both TLS versions through the
pinned mORMot bindings and the system OpenSSL library. The OpenSSL provider
uses `-dUSE_OPENSSL`; its dynamic library path is set only in OpenSSL build or
runtime commands. No TLS policy is enabled by these package skeletons.

## Build and package setup

`make setup-deps` is the only dependency-fetch operation. It checks out all
five dependencies at the recorded revisions. A local cache can be selected
with `TLS_DEPENDENCY_CACHE_ROOT`; setup clones with independent object stores
and sets each clone's origin to its recorded public URL. Normal builds do not
fetch. They check revision, origin, local source status, and license evidence.
Build tools accept absolute or repository-relative source overrides through
`MORMOT_ROOT`, `TLSLIB4PASCAL_ROOT`, `CRYPTOLIB4PASCAL_ROOT`,
`HASHLIB4PASCAL_ROOT`, and `SIMPLEBASELIB4PASCAL_ROOT`.

The six packages use version 0.30.0. The Lazarus group order is common,
OpenSSL, TlsLib, client, server, and optional Readers. The provider packages
depend only on common. The TLS package search paths are provider-specific.
Compiler outputs use a package-specific directory. The Lazarus configuration
is under `bin/` and does not use the user's normal IDE configuration.

The root targets `test-tls-contract`, `test-tls-openssl`,
`test-tls-tlslib`, and `test-tls-integration` select one named bounded
program each and apply a 30-second process-group limit. A missing runner is
an explicit error. These runner sources are supplied by TLS-03, TLS-05,
TLS-06, and TLS-09. The targets do not call the full client or server test
runners.

## Checks

The following checks passed on macOS arm64 with Free Pascal 3.2.4-rc2 and
Lazarus 4.0:

- `TLS_DEPENDENCY_CACHE_ROOT=<local cache> python3 tools/build.py setup:deps`
- `make -C tls/openssl build`
- `make -C tls/tlslib build`
- `python3 tools/check/repository.py packages`
- `python3 tools/check/repository.py source`
- `python3 tools/build.py packages:check`

Both provider builds compiled from pinned source. The package check built all
six Lazarus packages with an isolated Lazarus configuration. No TLS contract
or network test ran because its owning runner is not part of TLS-04. Opening
the group in the graphical IDE, real provider sessions, Linux builds, and
provider integration remain future checks. Provider closure is not proved by
the current empty facades.
