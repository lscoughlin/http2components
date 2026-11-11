# TLS-10 macOS random source note

## Reason

The TlsLib program must not load an SSL image. The pinned CryptoLib macOS
provider used Cocoa on Free Pascal. Cocoa reached the system GUI and curl
libraries. Those libraries loaded `libcrypto.46.dylib` and
`libssl.48.dylib`. A small `SecRandomCopyBytes` program also loaded these
images through Security.framework. The images identify LibreSSL 3.3.6. Their
identity does not meet the no-SSL-image acceptance rule.

## Change

The versioned patch changes only the Free Pascal branch in
`ClpMacOSRandomProvider.pas`. It reads from `/dev/urandom` with BaseUnix calls.
It validates the length and pointer, returns success for zero bytes, retries
open and read operations after `EINTR`, continues after short reads, fails on
zero or other negative reads, and closes an opened descriptor in `finally`.
It has no weaker random source fallback. The Delphi branch and the public
provider contract remain unchanged.

The patch applies only to CryptoLib revision
`f559d27462ddd149ef9d1880f97854a8a4cc8368`. The original unit SHA-256 is
`a6c5059e3602557eb26731689c88fca8a804ec3a21a2d369cb211dccec527d6a`. The
patched unit SHA-256 is
`4b7f08330ee2ff61522c964d711f1346f1119aa1c52896a2bcca551196dec712`. The
patch SHA-256 is
`20f339b010d36638a903bc57451d9496e75a15106ab24e2def3617ec0f3235a8`.

The overlay helper validates the revision and both source and patch hashes. It
copies the one upstream unit and the include directory to the build output,
then applies the patch. Its fingerprint combines the revision, original unit
hash, and patch hash. The upstream checkout is unchanged.

## Compile evidence

The probe source calls the provider with zero, 16-byte, and 4096-byte arrays.
A provider exception fails the program. The compile-only command used FPC
3.2.4 on macOS aarch64 with `-Cn -Mdelphi -O2 -vw`, the overlay provider path
first, and source directories from the pinned CryptoLib, HashLib,
SimpleBaseLib, and TlsLib checkouts. It compiled both the provider and probe
without errors. FPC wrote `ClpMacOSRandomProvider.o` and
`Tls10.MacOSRandomProvider.Probe.o`; no program was linked or run.

The probe object SHA-256 is
`6a4ded7ce457105089f1417e6a0a628cfd5072f2803c8569ba6a736ea4ace60e`. The
provider object SHA-256 is
`3149df43161ed8d7178aa0d73b43bfe9f3a66ce3fb1a97e3e952291af9982111`.

## Limits

The reproducible compile and link helper is
`tools/studies/tls/rng/compile_probe.py`. It reads the dependency roots from
`CRYPTOLIB4PASCAL_ROOT`, `HASHLIB4PASCAL_ROOT`, `SIMPLEBASELIB4PASCAL_ROOT`,
and `TLSLIB4PASCAL_ROOT`. `HTTP2_ROOT` names this checkout. `TLS10_RNG_OUTPUT`
selects the output directory. The helper prints the exact FPC command and
fingerprint, links the probe, and does not execute it.

The linked probe SHA-256 is
`d2f9db78d0546516ab939fff737b89c1f748764ac4c0c9a92694d80492a5ca9e`.
`otool -L` lists only `/usr/lib/libSystem.B.dylib`. This is static linked-image evidence. The central probe run used
`run_suite30s` with `DYLD_PRINT_LIBRARIES=1`. It passed all 3 cases in 0.217
seconds and exited 0. The log is
`bin/tls-coordinator/tls10-rng-images.log`. The dyld output contained no
`libssl` or `libcrypto` images. It did contain the system CommonCrypto and
CoreCrypto libraries. The run verified zero-byte, 16-byte, and 4096-byte
requests through the patched OS entropy path. No Linux validation is included.
