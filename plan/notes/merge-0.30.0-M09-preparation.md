# Tool and example preparation

The role tool trees and example programs are copied from the pinned source
snapshots. Client observer support units belong to the test import.
Pascal names and license headers are updated. Shell root calculations and
source paths are updated for the role directories. The h2probe program is
at tools/client/h2probe.pas; its outcome helper remains in test/client.

This import is preparation, not acceptance. The next work covers:

- Driver dispatch for every original validation target and its arguments.
- Isolated output paths, per-run generated certificates, unique container
  names, readiness failure checks, and cleanup restricted to owned peers.
- Removal of old process-wide pkill cleanup in server validation.
- Original script command compatibility with the new test runner and paths.
- Compile-only checks of every example and validation Pascal program.
- Static shell/Python checks and an exact gate mapping.

No external, load, container, or Linux validation was run.
