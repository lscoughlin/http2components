# M00 server baseline

## Source snapshot

The server source was clean at commit `16e2003a9f31648005c5565d118bbd42acf935a8` on 2026-11-11. The source repository stayed unchanged. The disposable snapshot came from `git archive` at that commit. It has no `.git` directory and contains 244 tracked files. `merge-0.30.0-M00-server-files.tsv` records each source path, Git blob ID, SHA-256, and archive disposition. `bin/baseline-server/` holds the extracted snapshot.

The source license is `LGPL-2.1-only WITH Independent-modules-exception`. The source `LICENSE` and `NOTICE` were read. The notice identifies mORMot2 as an external dependency and records five protocol units and `Http2Server.Encoding` as copies from the Apache-2.0 client project. It records the original source revisions and the prior permission for distribution under the server license. The notice remains source provenance evidence; it does not replace the target license record.

## Build environment

The build used macOS 27.2 on `aarch64-darwin`, Free Pascal 3.2.4, and mORMot2 revision `b2b195da1e0580058672a88620ef71bb47283eb1`. The compiler used the `/opt/homebrew/opt/openssl@3/lib` runtime library path. That OpenSSL installation reports 3.5.9. The default `openssl` command reports 4.1.0, so the command-line OpenSSL and runtime library versions differ. The build used the fixed source archive and passed the mORMot unit path through `MORMOT`; it did not add a mORMot checkout to the snapshot.

The build command was:

```sh
make test MORMOT=/Users/liamcoughlin/Source/lscoughlin/http2client/third_party/mORMot2/src OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib
```

The library and test runner compiled successfully. The compiler emitted warnings in mORMot, server source, and tests, including range-check warnings in `Http2Server.Connection.Test.pas` and `Http2Server.Ws.Frames.Test.pas`. The raw build and first runner output is `bin/baseline-server-test.raw.log`.

## Unit test inventory and result

The runner registered 82 test suites and 867 test cases. `merge-0.30.0-M00-server-tests.tsv` records each test name and registration order. The full suite did not complete. The first run used the original `--all --format=plain --sparse` command and was stopped after more than two minutes without output. A second full run used `--all --format=plain --progress` to expose progress. It was stopped after more than three minutes, as directed, after 753 cases had run: 751 pass markers and two failure markers, with no error markers. The progress log is `bin/baseline-server-test-progress.raw.log`. The runner did not produce a final summary, so total skips and final counts are unknown.

The two failure markers were at registration positions 711 and 712: `TCancellationTest.TestResetRaisesInsideHandler` and `TCancellationTest.TestResetBeforeDispatchNeverRuns`. Both cases passed when the suite ran alone with `--suite=TCancellationTest --format=plain`; its raw output is `bin/baseline-server-cancellation.raw.log`. This isolated result does not resolve the failures seen in the full run. The suite remained incomplete at baseline.

The runner's `--list` output is `bin/baseline-server-test-inventory.xml`. The mTLS context suite passed all ten tests in isolation with the OpenSSL 3.5.9 command path and runtime path; its raw output is `bin/baseline-server-mtls-context.raw.log`. This focused result is not a full-suite result.

## Reading notes

The source README and toolchain document describe the FPC 3.2.4 build and the fpcunit runner. The validation document distinguishes unit tests from external protocol checks and load tools. The protocol design document states that the peer's `SETTINGS_HEADER_TABLE_SIZE` sizes the response encoder, while the server's advertised setting limits the request decoder. Its flow-control section sets the maximum window to 2^31-1 octets and describes separate connection and stream windows. These records agree with the M00 test and build setup.

## Review and cleanup

The parent reviewed and merged this evidence. The temporary worktree and
branch were removed after review. The disposable checkout no longer exists.
The raw log and registration files named above are retained by basename under
`bin/baseline-evidence/` in the target repository. No source repository file
was changed.
