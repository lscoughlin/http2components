# M00 client baseline

## Source snapshot

The source is `http2client` at commit
`709336f542cbedf9ce1ab67d83bddcfd560eb1c0`. Its branch was `main`. Its
working tree was clean on 2026-11-11. The mORMot2 checkout was at
`b2b195da1e0580058672a88620ef71bb47283eb1`; its working tree was clean.

A tracked-file archive at the source commit is in the disposable
`bin/baseline-client/` checkout. The checkout uses the existing mORMot2 path
through a symlink. No source repository file changed. The source inventory
has 196 tracked files. It gives each source path, candidate target path, SHA-256
hash, license record, and disposition in
`plan/merge-0.30.0-client-inventory.tsv`. The path mapping follows the M00
unit map where one applies. `retired-or-mapped/` marks umbrella units that do
not have a direct target file. The inventory includes project files and
build inputs as well as Pascal files and tests.

The source project license is Apache-2.0. Its `LICENSE` is the Apache 2.0
text. Its `NOTICE` identifies the project and third-party components. The
NOTICE records mORMot2 as a separate dependency, OpenSSL as a run-time
component, and the harness as a test tool with no stated upstream license.
The import must retain both source files and third-party notices. The owner
confirmed copyright ownership and authorized dual licensing of project code
under Apache-2.0 OR LGPL-2.1-only WITH Independent-modules-exception.
This authorization applies to the user's own code. It does not change the
license of third-party code. Root license files and imported headers are
owned by the inventory and import work.

## Compiler and TLS library

The host is macOS on aarch64. `fpc -iV` reported 3.2.4, `fpc -iTP` reported
`aarch64`, and `fpc -iTO` reported `darwin`. The default OpenSSL CLI and
runtime path used for the first test run selected OpenSSL 4.1.0. The project
Taskfile defaults to `/opt/homebrew/opt/openssl@3/lib`. That path selected
OpenSSL 3.5.9 on this host. The mORMot2 revision is the pinned project
revision above. The project test runner is `task` 3.54.0; `make` is also
available. `OPENSSL_LIBPATH` is required for the TLS tests.

## Unit suite

The tracked export was built and tested with the source project's `task test`
task. The suite command was
`bin/Http2.RunTests --all --format=plain --sparse`. Test names came from
`bin/Http2.RunTests --list`. The complete suite and method inventory is in
`plan/merge-0.30.0-client-tests.tsv` (913 registered test methods in 72
suites). The raw logs are under ignored `bin/`:

- `bin/baseline-client-task-test.log`: the first run used
  `OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@4/lib`. It ran 913 tests and
  reported 30 errors, 1 failure, and 0 ignored tests. All errors and the
  failure were in `TMutualTlsTest`. The TLS peer did not select ALPN `h2`, or
the handshake or TLS read failed. One selector concurrency assertion also
failed. This result is environment-specific evidence from OpenSSL 4.1.0.
- `bin/baseline-client-task-test-openssl3.log`: the repeat used
  `OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib`. It ran 913 tests with
  0 errors, 0 failures, and 0 ignored tests. The suite names and counts are
  in the raw log.
- `bin/baseline-client-mtls-openssl3.log`: focused command
  `PATH=/opt/homebrew/opt/openssl@3/bin:$PATH
  OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib
  bin/Http2.RunTests --suite=TMutualTlsTest --format=plain --sparse`.
  It ran 78 tests with 0 errors, 0 failures, and 0 ignored tests.
- `bin/baseline-client-registered-tests.txt`: raw fpcunit registration list.

The full OpenSSL 3 run passed. The initial OpenSSL 4 failures do not reproduce
with the project's OpenSSL 3 path. No skip was reported in either test run.
The live named suites in this unit runner were registered but their cases
were ignored by their runtime checks; the runner reports zero ignored cases.
No load test, conformance harness, Docker check, or Linux run was done. The
user deferred those checks to a later validation plan.

## Build command and outputs

The command was `OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib task test`
from the disposable checkout. Task compiled the library, compiled the test
runner, and ran the suite. The process exited 0. Compiler warnings were
reported in mORMot2, library, and test source. No warning stopped the build.
The raw task output is `bin/baseline-client-task-test-openssl3.log`.

The source Taskfile fixes its FPC flags and does not accept the attempted
`FPCFLAGS` environment override. Therefore the original task wrote compiler
outputs to its configured `bin/` directory and could use the shared mORMot2
unit paths. The source mORMot2 working tree remained clean after the run.
This is a tooling limitation for a repeated build, not a source change.
The baseline outputs are ignored and are not part of this commit.

## Review and cleanup

The parent reviewed and merged this evidence. The temporary worktree and
branch were removed after review. The disposable checkout no longer exists.
The raw log and registration files named above are retained by basename under
`bin/baseline-evidence/` in the target repository. No source repository file
was changed.
