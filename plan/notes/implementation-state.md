# Implementation state

Updated at 07:40 UTC on 2026-11-11. Work started at 06:38 UTC.
The one-hour detailed report is complete. The next detailed report is due
at 07:53 UTC. Brief reports occur every five minutes.

## Persistent instructions

All work is in http2components and its worktrees. The original client and
server repositories are read-only. Agents use GPT-6-Luna in separate
worktrees. Reviewed changes are merged; finished worktrees and branches
are removed. No resource-intensive tests, containers, external conformance,
or Linux validation run now. The separate final validation plan covers
these checks. The owner authorized the dual license:
Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception).

CodeGraph is used first for code questions in the indexed original server
repository. Target worktrees have no index. All shell tool calls use
login:false and an explicit working directory.

## Accepted work

M00: inventory has 440 source entries with independently checked hashes.
License texts, notices, and RFC reference copies are retained. The original
client baseline passes 913 tests with OpenSSL 3.5.9. The server baseline has
867 tests; its combined run stopped after 753 cases with two cancellation
failures. Those two cases pass alone. This combined-run issue remains open.

M01: Make and Task share tools/build.py. Output is isolated under bin by
platform, profile, component and purpose. Source, version, documentation,
package and test-run checks are real checks. Tests have bounded deadlines.

M02–M05: common primitives, facade, and role error aliases are merged.
The parent passed 229 common tests, 16 API tests, and the common facade
probe. Shared headers have one type identity and no invented GUID.

M12 preparation: 53 Markdown documents and 12 compiler probe sources are
merged. Documentation and header checks passed before role imports.
Final API, architecture, commands and migration review remains.

M07 import 3b8da78 is merged. All 72 imported production units are
executable-identical after namespace mapping. Parent build:server and
TFactoryTest (27 cases) pass. Server test accounting and selected tests
remain with the server agent. Live client-dependent integration inputs
have .pas.pending suffixes until the client is ready.

M06 import ddc43a3 and lock fix 198600e are merged. Parent review found
and corrected lock creation order and exception-path lock release in peer
settings handling. Parent build:client passes. Real source divisions and
regression tests remain. Existing client public API must be preserved.

M09 import preparation dff8e071 is merged. Role tools and example programs
are present, with namespace and basic path changes. The preparation note
lists the required script, output, readiness, and cleanup work.

M10 preparation is in progress in the integration worktree. Four generated
packages compile with Lazarus on macOS. The generator, final inventory,
header restoration after Lazarus regeneration, and API probes need review.

## Current team

Worktree base: /Users/liamcoughlin/Source/lscoughlin/.http2components-worktrees

| Agent | Worktree / branch | Task |
| --- | --- | --- |
| parent | integration / merge/integration | Review, merges, packages and API probes |
| baseline_server | client / merge/client | C01–C04 client production division |
| baseline_client | tests / merge/tests | M08 client tests, support, fixtures, accounting |
| inventory | server / merge/server | M07 server test accounting and focused checks |

Client test import 4efe6b5 is committed but not accepted. Review found wrong
Http2.Client.Client imports and a trivial sentinel test. The agent fixed
these and reports 801 imported tests pass against ddc43a3. There are 111
source registrations mapped to common/API and one removed source sentinel.
File divisions and accounting verification are still required.

The server agent next takes M09 tools/examples in a new worktree after
M07 review. Parent already copied tools/server/certs/make_mtls_pki.sh;
server test references must use that path, not a duplicate tools/certs path.

Six finished worktrees/branches were removed after review: baseline-client,
baseline-server, inventory, build, common, docs. Evidence logs were copied
into integration/bin/baseline-evidence and integration/bin/agent-evidence.

## Repository and remaining work

Main is clean at e6cc749 and contains accepted foundation through M05 and
documentation preparation. User commit 263036d retained .gitignore.
Integration is ahead with role imports. Active agent worktrees have an
untracked copy of the same .gitignore; it must be removed only after byte
comparison if a merge would overwrite it.

Pinned mORMot2 is a target-owned independent clone in
integration/third_party/mORMot2. Agents use it read-only through MORMOT.
Compiler output stays in target bin. OpenSSL 3 is selected explicitly or
through the driver default; OpenSSL 4 produced baseline mTLS errors.

The original plan inputs are ignored. Evidence notes are added with git
add -f. Raw logs are ignored and must be retained before worktree cleanup.
M09 completion, M10 final probes, M11 bounded local integration, M12 final
docs, M14 review, and M15 archive verification remain. M13 and heavy/Linux
checks are deferred by explicit user instruction. No release tag is made.
