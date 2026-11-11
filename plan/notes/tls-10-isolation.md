---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, build, package, isolation
notes:
  - This record covers TLS-10 build and package checks.
---

# TLS-10 build and package isolation

Review date: 2026-11-11. The implementation base is `f52bdf7`. The reviewed
TLS-09 protocol migration prerequisite is `cd6a46b`. The merged TLS-09 and
security acceptance revision is `5f16bce`. The worktree is
`/Users/liamcoughlin/Source/lscoughlin/http2components-worktrees/tls-10` on
branch `tls/TLS-10-isolation`.

## Source closure

The source checker reads these production roots: `common/src`, `client/src`,
`server/src`, `tls/openssl/src`, and `tls/tlslib/src`. It reads interface and
implementation `uses` clauses. It checks common-to-role and provider edges,
role-to-provider edges, provider-to-role edges, client/server edges, and
optional Readers edges.

The checker follows local `{$I}` and `{$INCLUDE}` files recursively. It checks
the include contents with the same dependency rules as the parent source. The
server async TLS include is `server/src/Http2.Server.Async.Tls.inc`. It is
checked for a valid Pascal header and a size below 1000 lines. The source
check reported 152 production units, 398 Pascal files, one include file, and
54 documentation files. The focused include check kept a synthetic common
interface include in its parent-unit context. It rejected a `mormot.core.base`
dependency with the same common dependency rule as the production scan and
allowed a common interface dependency.

TLS-09 commit `cd6a46b` replaced the stale project-unit imports in the
integration protocol test. The final source check passed after that commit.

## Package inventory and metadata

The package inventory is:

| Package | Units |
| --- | ---: |
| `http2common` | 11 |
| `http2client` | 55 |
| `http2server` | 71 |
| `http2openssl` | 6 |
| `http2tlslib` | 8 |
| `http2clientreaders` | 1 |

`tools/packages.py` is the source for package XML and registration units.
It reads dependency source directories from the normal checkout or from the
documented dependency path overrides. Generated manifest paths stay relative
to this repository. `tools/packages.py --check` reported the same counts.
The package checker confirmed one package owner for each of the 152 source
units, version `0.30.0`, relative output paths under `bin/`, and the six
targets in `http2components.lpg`.

Each package uses a separate Lazarus primary config directory under
`bin/<target>/<profile>/lazarus-config/<package>`. Each dependent package
registers its declared local package links in that private config. Package
unit outputs use separate paths under `bin/`.

Lazarus 4.0 adds a trailing `-B` when it compiles an unbuilt package. That
flag forces CryptoLib sources through the known multiplier cycle and defeats
the pinned bootstrap PPUs. The TlsLib package uses a generated compiler
wrapper in its private config directory. The wrapper forwards compiler
queries and arguments to `ppca64` and removes only the exact `-B` argument.
It does not change the compiler environment or the user's IDE profile.
The package build completed with this wrapper and the fresh bootstrap PPUs.
The generated wrapper is under ignored `bin/` output and is not a source
artifact.

## Isolated compiler probes

`python3 tools/build.py isolation:compile` builds six separate probes in
fresh `bin/<target>/<profile>/isolation-*` directories. The probe sources are
under `tools/studies/tls/tls10/`.

The compiler traces showed these closures:

| Probe | Project units allowed | Result |
| --- | --- | --- |
| Common only | Common | Pass |
| Client without provider | Common, Client | Pass |
| Server without provider | Common, Server | Pass |
| OpenSSL only | Common, OpenSSL | Pass |
| TlsLib only | Common, TlsLib | Pass |
| Both providers | Common, OpenSSL, TlsLib | Pass |

The build tool rejects forbidden project units in each trace. It does not
pass user `FPCFLAGS` to these probes. TlsLib bootstrap PPUs precede pinned
dependency source paths. The six compiler traces were checked and contained
no forbidden project unit names.

## Package build and root targets

The package command was:

```text
MORMOT2_ROOT=<main checkout>/third_party/mORMot2
TLSLIB4PASCAL_ROOT=<main checkout>/third_party/TlsLib4Pascal
CRYPTOLIB4PASCAL_ROOT=<main checkout>/third_party/CryptoLib4Pascal
HASHLIB4PASCAL_ROOT=<main checkout>/third_party/HashLib4Pascal
SIMPLEBASELIB4PASCAL_ROOT=<main checkout>/third_party/SimpleBaseLib4Pascal
python3 tools/build.py packages:check
```

All six Lazarus package builds completed on macOS arm64. The toolchain was
Free Pascal 3.2.4-rc2 and Lazarus 4.0. The full build log was
`/tmp/tls10-packages-final.log` during this work.

`make -n build` showed only component build targets. Dependency setup is a
separate explicit target. `make -n clean` showed that clean removes only
this repository's `bin/` directory. No clean target was run. Root and
component build commands use component Makefiles. The root Lazarus group
has six relative package targets. The Lazarus 4.0 group reader probe passed
one case with all six worktree package targets. Its coordinator log is
`bin/tls-coordinator/tls10-lazarus-group.log`.

## Runtime evidence

The 87-case TlsLib exchange runner was compiled separately with an FPC unit
trace. Its binary is
`bin/aarch64-darwin/default/isolation-tlslib-runtime/programs/Http2.Tls.TlsLib.Tests`.
Its SHA-256 is `0b06293fd2d05dc20bb41e6a1796ac2a0471676472483d4d0190e738b3f0e1ae`.
Its trace SHA-256 is
`7f4347784347b66887df01d35b529f1a14eb88ba0f849ed1dbdbaf20858ad0ad`.

The coordinator ran this exact binary. All 87 cases passed in 0.877 seconds.
The loaded-image check did not pass A16: it showed system
`/usr/lib/libcrypto.46.dylib` and `/usr/lib/libssl.48.dylib`. The binary has
no direct OpenSSL or mORMot link. Its unit trace loads CryptoLib's
`ClpMacOSRandomProvider` and `CocoaAll`. The system image log shows
`/usr/lib/libcurl.4.dylib` before the two SSL images. `dyld_info` confirms
that system libcurl has weak links to system libcrypto and libssl. No
Homebrew OpenSSL image appeared in the first image-log scan. The strict
no-OpenSSL-loaded acceptance remains unresolved until the provider owner
reviews this macOS framework path.

The coordinator's loaded-image log is
`bin/tls-coordinator/tls10-tlslib-images.log`. It used
`DYLD_PRINT_LIBRARIES=1`; it did not rely on an empty `OPENSSL_LIBPATH`.

`python3 tools/build.py source:check` passed its source, header, include, and
YAML checks. Its additional test-accounting check reported 87 stale records
in `test/client/client-test-accounting.tsv` and
`plan/notes/merge-0.30.0-M07-server-tests.tsv`. The missing method names refer
to migrated client and server tests. These records are outside TLS-10.
The separate documentation, package, version, and package-generation checks
passed. `git diff --check` passed.

The existing client test runner compiled without execution after the
test-only provider search paths and `USE_OPENSSL` define were added. Its
compile output is
`bin/aarch64-darwin/default/client-test/programs/Http2.Client.RunTests`.

The reproducible compile command is:

```text
python3 tools/build.py isolation:tlslib:runtime
```
