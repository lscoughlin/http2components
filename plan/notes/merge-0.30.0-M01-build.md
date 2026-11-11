# M01 build and repository checks

## Build entry points

`Makefile` and `Taskfile.yaml` call one driver at `tools/build.py`. The
same driver builds code and runs checks for both entry points. It reads
`FPC`, `FPCFLAGS`, `FPC_UNITS`, `MORMOT`, `OPENSSL_LIBPATH`, `TARGET`, and
`PROFILE` from the environment.

Each compile command sets `-FU` and `-FE`. Output goes under
`bin/<target>/<profile>/<component>/units` and `programs`. Test builds use a
separate component directory from normal builds. The common build has no
mORMot2 search path. The client, server, readers, API probes, and examples
use the pinned mORMot2 unit paths. The build checks the mORMot2 revision
before it uses the dependency.

The default FPC unit path uses the compiler version, target CPU, and target
OS. Darwin uses `/usr/local/lib/fpc/<version>/units/<cpu>-<os>`. Other
systems use `/usr/lib/fpc/<version>/units/<cpu>-<os>`. The default OpenSSL
path is Homebrew OpenSSL 3 on Darwin. Linux uses its architecture-specific
library directory. The environment can override each path.

`task setup:deps` fetches mORMot2 at
`b2b195da1e0580058672a88620ef71bb47283eb1` into this target worktree. It
never checks out or changes an external source tree. The separate
`task setup:harness` target fetches the client harness at
`0bc075cc21e5a247dfd222e005d1e7e5679d2bff`. Ordinary build and test targets
do not fetch dependencies, install packages, or start Docker.

The unit runner must report at least one test. The default run limit is 180
seconds. `TEST_TIMEOUT` changes the limit. `TEST_SUITE` selects one fpcunit
suite. A timeout stops the test process group and returns a failure. It does
not report a pass. These settings support focused checks when one original
suite blocks.

`clean` removes only `bin/`. It does not remove compiler output from source
or dependency directories. Example programs use separate output directories
for the client, server, and integration groups. Example support units are
not linked as programs.

## Checks

`tools/check/repository.py` provides four checks:

- `version` checks the exact `VERSION` text and package XML version fields.
- `source` checks Pascal headers, file sizes, unit paths and names, duplicate
  unit names, project imports, facade direction, and interface cycles.
- `docs` checks YAML front matter, local links, the document index, plan
  references, and likely imperative sentences.
- `packages` checks package XML, package versions, source paths, and one
  package owner for each production unit.

The package task checks each `.lpk` file list and unit output directory. It
then builds each package with `lazbuild`, a separate Lazarus profile under
`bin/`, and per-package `-FU` and `-FE` paths.

The Pascal reader removes line comments, block comments, and string literals
before it reads `uses` clauses. It reads unit and program files. It includes
`uses Unit in 'file.pas'` imports. It reports unknown `Http2` imports. The
runtime checks keep common, client, server, and integration roles apart.
The interface graph check detects cycles. Text in comments and strings is
not an import edge.

The header and size checks include maintained Pascal files under `src/`,
`test/`, `examples/`, and `tools/`, root package Pascal files, and historical
probes under `doc/verification/client-probes/`. Historical probes do not
join the active dependency graph. The YAML checker uses Ruby's YAML parser.
It fails if Ruby or the YAML parser is not available. It checks the exact
dual-license SPDX value and copyright line. It rejects a blank line before
the closing pasdoc brace.

The imperative check is a text heuristic. It checks sentence starts,
numbered lists, and bullet lists. It removes inline and fenced code first.
A match needs a reader's review because a verb can also begin a descriptive
sentence.

## Check record

The following commands passed on 2026-11-11:

- `python3 -m py_compile tools/build.py tools/check/repository.py`
- `ruby -c tools/check/yaml_headers.rb`
- `task --list`
- `task version:check`
- `make version-check`
- `git diff --check`

Temporary checker trees also passed these checks:

- A legal common/client/server facade graph and a client API test that uses
the public client facade.
- The optional Readers group accepted JSON use. Client core rejected both a
  JSON import and an import of the optional Readers group.
- Imports in comments and string literals were ignored. An in-file unit
  reference was retained.
- Bad facade direction, an interface cycle, an unknown project import,
a mismatched file name, and a case-insensitive duplicate unit failed.
- Valid document YAML, local links, and the document index passed. A plan
  reference, sentence and numbered-list imperatives, a broken link, and an
  invalid package version failed.
- A correct package version and one-to-one source inventory passed. A
  zero-test runner and a timed-out runner failed.
- Root package Pascal files and historical client probes received header
  and size checks. A missing probe header failed.

The checker also passed on a temporary copy of the current integration
`src/` and `test/` trees. It checked 20 Pascal files: 5 production units,
13 test units, and 2 runner programs. The copy was removed after the check.

Several repository targets are incomplete in this build worktree. The
version check passes. Build and test commands fail with a clear missing
source or runner message. Source checks fail while no source tree is present.
The document check fails because `doc/README.md` is not present. Package
checks fail because package files and production units are not present. These
files arrive in later merge stories. No Pascal build or unit suite ran in
this worktree.

The source `http2client`, `http2server`, and client mORMot2 working trees
were clean after this work. This task did not run Linux, load, abuse,
conformance, Docker, or external validation. The user deferred those checks.
