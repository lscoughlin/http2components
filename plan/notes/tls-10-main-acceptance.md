# TLS-10 coordinator acceptance

Checked on 2026-11-11. Main merge `65b512e` contains the package isolation
work through `fe923bc`. Commit `935cf6e` adds the random-source probe runtime
record. The separate test-inventory correction remains in progress.

## Source and build review

The coordinator reviewed the six restricted compiler probes, separate package
outputs and Lazarus configurations, recursive Pascal include expansion,
dependency checks, generated package paths, and macOS random-source overlay.
The include parser keeps the parent unit and interface or implementation
section. The source check covers five production roots and six packages.

All six packages built separately in the worker. The merged source checker
passed with 399 Pascal files, one include, 152 production units, and 54
documents. Package inventories are 11 common, 55 client, 71 server,
6 OpenSSL, 8 TlsLib, and 1 optional Readers unit.

The supported Lazarus 4.0 project-group reader loaded all six package targets.
Its source, compile script, binary, and compile log remain under
`bin/tls-coordinator/lazarus-group/`. The group-read log is
`bin/tls-coordinator/tls10-lazarus-group.log`. This is an actual Lazarus reader
check, separate from the package XML check.

## macOS random-source correction

The original pure Pascal TLS runner passed 87 cases but loaded system
`libssl.48.dylib` and `libcrypto.46.dylib` through framework dependencies.
Those libraries identify LibreSSL 3.3.6. That result did not pass A16.
A small Security.framework probe also loaded those libraries.

The reviewed patch changes only the FPC/macOS branch of the pinned CryptoLib
random provider. It reads `/dev/urandom`, checks invalid and zero inputs,
retries interrupted opens and reads, retains the offset after short reads,
fails on zero or other negative reads, and closes the descriptor in `finally`.
There is no weak random fallback. The upstream checkout stays unchanged.
The build helper checks the exact revision and source, patch, and output
hashes. Its fingerprint invalidates old bootstrap units.

The small random-source probe passed 3 cases in 0.217 seconds, exit 0, with
a 30-second outer limit. Its loaded-image log contains no SSL library.
The log is `bin/tls-coordinator/tls10-rng-images.log`.

## Exact exchange and loaded images

The worker's corrected exchange runner passed 87 cases in 0.880 seconds,
exit 0, with a 30-second outer limit. It loaded 82 images and no `libssl` or
`libcrypto` image. The log is
`bin/tls-coordinator/tls10-tlslib-images-patched.log`.

The merged tree then compiled the exact runner with:

```text
python3 tools/build.py isolation:tlslib:runtime
```

The coordinator ran it through `tools.build.run_suite` with
`DYLD_PRINT_LIBRARIES=1`, no `OPENSSL_LIBPATH`, its program directory as the
working directory, and a 30-second limit. It passed 87 cases in 0.906 seconds,
exit 0. Its 82 loaded images contain no SSL library. The full compiler trace
contains no OpenSSL provider, mORMot, CocoaAll, or Security random-reader unit.
System CommonCrypto and CoreCrypto images are OS cryptographic services;
they are not OpenSSL or LibreSSL images.

The merged binary has the same SHA-256 as the worker binary:
`b8d61db6fd945af66fd226de3d27e38335b0a04ab72f691f4afc524ebc14ee1c`.
The merged compiler trace SHA-256 is
`1f987ce769fbb35babaf021383f867dc0b363d68d20018303c346d9a79e45910`.
The logs are `bin/tls-coordinator/tls10-main-compile.log` and
`bin/tls-coordinator/tls10-main-images.log`. All worker compiler traces and
package logs were copied to `bin/tls-coordinator/tls10-artifacts/`.

A coordinator diagnostic used the wrong trace filename after the successful
worker run and image assertions. That diagnostic raised FileNotFoundError.
The correct trace was then hashed separately; the test itself had exit 0.
No repeat test was used to conceal a failed runtime case.

## Cleanup and limits

Both completed TLS-10 worktrees and their branches were removed after review
and merge. The random-source branch used cherry-picked commits; its owned
files were checked byte-for-byte against main before branch removal.

The five dependency checkouts remain pinned and clean. The compatibility
source and compiler wrapper are generated under ignored `bin/`. No dependency
checkout, normal IDE profile, or original source sibling was changed.
Linux, load, external peers, and full conformance remain deferred.
