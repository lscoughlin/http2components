# TLS-04 coordinator review

Review date: 2026-11-11. Host: macOS arm64. Main revision after fixes:
`917f081`. The provider implementation tasks are still in progress.

## Compiler search paths

The TlsLib worker found two search path omissions. The provider package
command did not include `tls/tlslib/src`. The dependency package commands
did not search their compiled `bootstrap` directory. Commits `89ab196` and
`917f081` correct these paths.

`PROFILE=tls04-path-review make -C tls/tlslib build` passed from an empty
profile output directory. It passed again with existing output after the
second correction. The first run used the first correction. The second run
used both corrections. No executable TLS test was part of these commands.
The main provider still contains its TLS-04 skeleton. This check is evidence
for the build paths, not for the TLS-06 implementation.

Logs are `bin/tls-coordinator/tls04-path-review.log` and
`bin/tls-coordinator/tls04-path-review-repeat.log`.

## Real engine compile path

The TLS-06 provider then exposed a third path error. The package bootstrap
completed, but the final provider compile selected CryptoLib source before
its compiled units. That source traversal reached the
`ClpMultipliers` / `ClpWNafUtilities` cycle. The error named a missing unit
even though its compiled unit existed.

A small program that imports `TlpDefaultCryptoProvider` and
`TlpDefaultPkixProvider` reproduced the error with the original path order.
The same program compiled when the bootstrap directory came before the
dependency source directories. Commit `f8fd26d` applies that order to
provider, test, integration, and package bootstrap commands. The earlier
skeleton build did not reach these engine imports and did not detect this
error. Compiler traces are under `bin/tls-coordinator/tlslib-resolution`.
The probe was compiled only; no executable TLS exchange was claimed.

## Installed Lazarus group reader

A temporary probe under `bin/tls-coordinator/lazarus-group` compiled the
installed Lazarus 4.0 `ProjectGroup` reader with the NoGUI interface. It
called `TIDEProjectGroup.LoadFromFile` with `pgloSkipDialog` and
`pgloErrorInvalid`. The reader returned six targets. Each target had type
`ttPackage` and resolved to the expected package file in this repository.
The probe exited with status zero within its 30-second limit.

The probe did not call the recursive package editor interface. It did not
open a GUI or change the user IDE profile. Separate package compilation
remains part of TLS-10 after the providers and role changes are merged.
No system Lazarus source or output was changed. All probe compiler output
is below the repository `bin` directory. The first compilation attempts
failed because installed unit files used a different compiler checksum and
source search paths and the `-Scghi` options were incomplete. The final
probe compiled from the installed source with these paths and options.
The compile script, probe source, compile log, and run log remain in the
same output directory for the final build review.
