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

The probe compile does not prove runtime random reads or loaded-image closure.
The central TLS-10 exchange and dyld image inspection provide that evidence.
No Linux validation is included.
