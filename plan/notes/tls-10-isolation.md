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
The package build completed with this wrapper and fresh bootstrap PPUs.
The generated wrapper is under ignored `bin/` output and is not a source
artifact. On macOS/FPC, the build driver applies the hash-checked CryptoLib
RNG overlay under the profile's `tlslib/compat/cryptolib` directory. The
overlay fingerprint invalidates cached bootstrap units when its inputs change.
The generated TlsLib package includes the overlay provider and include paths;
the bootstrap path remains first in the unit search order. The separate
CryptoLib source checkout stays pinned and clean.

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
`bin/tls-coordinator/tls10-packages.log` (SHA-256 `5a19767ab5445409f9fdb1585bba43c1f4a6617544390153df52f1f269bc4622`).

`make -n build` showed only component build targets. Dependency setup is a
separate explicit target. `make -n clean` showed that clean removes only
this repository's `bin/` directory. No clean target was run. Root and
component build commands use component Makefiles. The root Lazarus group
has six relative package targets. The Lazarus 4.0 group reader probe passed
one case with all six worktree package targets. The exact invocation and
resolved targets are recorded in
`bin/tls-coordinator/tls10-lazarus-group.log`; it used the Lazarus group reader
binary at `../http2components/bin/tls-coordinator/lazarus-group/GroupReadProbe`.

## Runtime evidence

The 87-case TlsLib exchange runner was compiled separately with an FPC unit
trace after the macOS RNG overlay integration. Its binary is
`bin/aarch64-darwin/default/isolation-tlslib-runtime/programs/Http2.Tls.TlsLib.Tests`.
Its SHA-256 is
`b8d61db6fd945af66fd226de3d27e38335b0a04ab72f691f4afc524ebc14ee1c`.
Its trace SHA-256 is
`1b97c913fbe8decc6bf02a0933e5b5b25727befce2a5faca7741bb1be2406c20`.

The coordinator ran this exact binary. All 87 cases passed in 0.880 seconds.
The loaded-image check recorded 82 images and no `libssl` or `libcrypto` image.
The FPC trace shows `ClpMacOSRandomProvider.ppu` from the generated, pinned
CryptoLib overlay. The patched source SHA-256 is
`4b7f08330ee2ff61522c964d711f1346f1119aa1c52896a2bcca551196dec712`.
The source checker also verified the pinned CryptoLib revision and original
unit hash before applying the patch. The overlay changes only the FPC/macOS
provider source and its required include tree. The original dependency checkout
remains unchanged. The coordinator image log is
`bin/tls-coordinator/tls10-tlslib-images-patched.log`.

The independent RNG provider probe reported `PASS 3 cases`. Its macOS loaded
image check listed only `libSystem` and no SSL or crypto image. Its exact
source and compile helper are `tools/studies/tls/rng/`.

The original pre-overlay binary and image results are retained as diagnostic
history in `bin/tls-coordinator/tls10-tlslib-images.log`; they showed system
LibreSSL. The accepted image check is the patched run above.

`python3 tools/check/repository.py source`, the YAML header checker, docs,
version, package inventory, and package-generation checks passed. The
repository aggregate check had 87 stale test-accounting rows in two files; a
separate accounting task owns those records. The earlier client test runner
compile completed without execution after adding test-only provider paths and
`USE_OPENSSL`. Its output is
`bin/aarch64-darwin/default/client-test/programs/Http2.Client.RunTests`.
`git diff --check` passed.

The existing client test runner compiled without execution after the
test-only provider search paths and `USE_OPENSSL` define were added. Its
compile output is
`bin/aarch64-darwin/default/client-test/programs/Http2.Client.RunTests`.

The six isolated compiler probes were rebuilt after the RNG overlay change.
Their trace files are under
`bin/aarch64-darwin/default/isolation-{common,client,server,openssl,tlslib,both}/programs/`.
The exact TlsLib runner compile command is:

```text
python3 tools/build.py isolation:tlslib:runtime
```
