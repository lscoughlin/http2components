---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, fpc, compiler-mode, thread-manager, runtime
notes:
  - This document records the Free Pascal facts the library rests on.
  - Imported from http2server/doc/design/server/fpc-runtime.md at the source commit recorded in the source inventory.
scope: The compiler modes, the thread manager, the verified runtime facts, the build line and the file header rule.
primary_types: []
db_tables: []
related_docs:
  - doc/design/server/architecture.md
  - doc/verification/source/server/toolchain.md
invariants:
  - The library compiles in the Delphi mode.
  - The thread manager comes from mORMot2 and not from a program unit.
---

# FPC runtime and language facts

The server library is Object Pascal for Free Pascal 3.2.4. This document
records the compiler modes and the verified language facts that the build
line and the test harness rely on. The facts were verified on `fpc 3.2.4`
(`ppca64`), macOS aarch64.

## Compiler modes

Every unit and program opens with the same directives
(`server/src/Http2.Server.pas`, `test/server/Http2.Server.TestRunner.pas`,
`test/server/Http2.Server.RunTests.pas`):

```pascal
{$mode delphi}
{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}
```

`{$mode delphi}` selects the Delphi dialect. `{$H+}` selects long strings.
`{$modeswitch advancedrecords}` permits methods and visibility inside
records. `{$modeswitch typehelpers}` permits type helpers. `{$interfaces com}`
selects reference-counted CORBA-style interfaces, so the object lifetime ends
when the last interface reference leaves scope.

The Delphi mode is required for generic methods. Under `{$mode objfpc}`, a
generic method does not parse even with `{$modeswitch genericmethods}`: the
compiler reports `Syntax error, ";" expected but "<" found`. The server
design uses generic code, so the mode is fixed.

## Thread manager

A program pulls in the Unix thread manager before any unit that uses threads
(`test/server/Http2.Server.RunTests.pas`,
`test/server/Http2.Server.TestRunner.pas`):

```pascal
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, consoletestrunner, Http2.Server.TestRunner;
```

Without `cthreads`, a threaded binary aborts at run time with
`This binary has no thread support compiled in ... Runtime error 232`. The
directive places `cthreads` first in the `uses` clause, because a unit that
is compiled earlier captures the thread manager state at that point.

## Verified Free Pascal facts

These Free Pascal facts come from the archived client compiler probes and the
merged server source. The probes remain historical evidence. The merged
compiler version in the merged tree is Free Pascal 3.2.4.

| Assumption | FPC 3.2.4 result |
|---|---|
| `TThreadedQueue<T>` | absent; the server builds a blocking queue from `TQueue<T>` |
| `TMonitor` | absent; a `TCriticalSection` guards shared state |
| `TEvent` / `TSimpleEvent` | raise `ESyncObjectException` on macOS; `RTLEvent` is used instead |
| `TStringList.Remove` | absent; `IndexOf` plus `Delete` is used |
| interface reference counting | verified; `TInterfacedObject.Destroy` runs when the last interface reference is cleared |
| generic class and generic method | work under `{$mode delphi}` |

## The build line

The Taskfile tasks compile library
units from `common/src` and `server/src`; it stores compiler outputs and
programs in `bin/<cpu>-<os>/<profile>/`. The server unit test command is
`task test:server`. It compiles and runs the server test runner with the
common and server source paths. The full command contract is in the root
README.

## The facade unit

`server/src/Http2.Server.pas` is the public facade of the library
(`server/src/Http2.Server.pas`). The unit declares type aliases for the public types of the library and the
helper that turns a factory into a server. The build line and the test runner
link this unit. The units of the library are recorded in `doc/design/server/`.

## File headers

Each Pascal file starts with a pasdoc comment that wraps YAML front matter.
The `license` value is `Apache-2.0 OR (LGPL-2.1-only WITH
Independent-modules-exception)`. `LICENSE` and `NOTICE` contain the full
license names and preserved source notices.
