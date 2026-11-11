# Implementation state

Updated at the 30-minute report on 2026-11-11.

## User instructions

- GPT-6-Luna agents work in separate worktrees of http2components.
- The parent reviews and merges their work, then removes finished worktrees
  and branches.
- Brief reports are due every five minutes; detailed reports every 15.
  Work started at 06:38 UTC; the 30-minute report is complete.
- No resource-intensive tests or Linux validation run during implementation.
  The separate final validation plan records them.
- All new work belongs to http2components. Existing http2client and
  http2server repositories are read-only inputs.
- The user owns the project copyrights and authorized dual licensing:
  Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception).
- Current AGENTS instructions require CodeGraph before code searches in an
  indexed repository. Target worktrees have no index; the original server
  repository has one. Indexing is not part of this work.

## Worktrees and agents

The worktree base is
`/Users/liamcoughlin/Source/lscoughlin/.http2components-worktrees/`.

| Worktree | Branch | Agent | Active work |
| --- | --- | --- | --- |
| integration | merge/integration | parent | Reviewed merges and focused verification |
| build | merge/build | baseline_client | M01 build/check infrastructure; final commit pending |
| common | merge/common | baseline_server | M02–M05; M04 next |
| docs | merge/docs | inventory | M12 preparation; review corrections pending |

The agent names reflect their first assignment. All child agents use
GPT-6-Luna. Each tool command has an explicit workdir and `login:false`.
The login shell produced blank command output early in this session.

## Accepted work

M00 inventory records 440 source entries with independently verified hashes.
There are 196 client entries and 244 server entries; the server has one
tracked symlink. License texts and historical notices are preserved.
The current root LICENSE and NOTICE state the approved dual-license choice.
RFC 1928 and RFC 1929 copies and retrieval records are present.

The client baseline passes 913 tests on OpenSSL 3.5.9; focused mTLS passes
78 tests. OpenSSL 4.1.0 failures did not recur with OpenSSL 3. The server
builds. Its combined suite was stopped after 753 of 867 cases, with two
cancellation failures. Both failures pass alone. That combined-run issue
remains recorded, not resolved. Raw baseline files are in
`integration/bin/baseline-evidence/`.

M02 commit a5903d6 is merged. Independent parent runs passed 38 common
and 16 API tests. Cross-role error tests are under test/api. The common
suite is pure. The shared header interface never had an explicit GUID;
the merge retains one type identity without inventing a GUID.

M03 commit 3bccbb7 is merged. The parent verified the HPACK executable code
against the pinned server implementation after namespace normalization.
The common suite passes 113 tests. Direct parent output is under
`integration/bin/review-m02/` and `integration/bin/review-m03/`.

Completed baseline-client, baseline-server, and inventory worktrees and
branches have been removed after merging. Their agent sessions remain for
new assignments. The current docs worktree is the inventory agent's next
assignment.

## Pending review

M01 has received detailed review feedback. It uses one Python build driver
for Make and Task. It must correctly check real Pascal dependencies,
facade direction, root/package/probe headers, source sizes, XML package
versions, docs, empty suites, and bounded timeouts. Common agent owns
`test/api/Http2.Api.RunTests.pas`; test:api compiles that runner directly,
without requiring absent future client/server facades. The build agent
reports fixture tests and checks against an exported M02/M03 tree pass.

Docs preparation commit ff3f79b is not merged. It contains source docs,
reference copies, historical evidence, migration table, and root docs.
Corrections requested: probe Pascal headers, remove Story column from
migration docs, remove remaining imperative prose, full license names in
README, correct no-GUID claim, and obsolete client unit count/umbrella text.
Final API/architecture and real build-command review remains after imports.
Reference whitespace is verbatim and is exempt from diff whitespace cleanup.

## Next work

After M01 review, merge it into integration and the common worktree, then
run its real checks. After M05, import client and server in parallel.
Suggested roles: build agent moves to client M06/C01–C04; docs agent moves
to server M07. Common agent can then prepare M08 test division/accounting
in a separate worktree while the client source divisions proceed, with
explicit test-file ownership to avoid overlapping edits.

M09–M15 still remain, subject to the user's deferred validation scope.
`plan/validation-after-merge-0.30.0.md` contains the deferred matrix.

The main user worktree remains on main with its original staged .gitignore.
It has not been included in any agent commit. The accepted code is on
merge/integration. Final integration into main must preserve that staged
change. Ignored plan inputs were copied into each worktree; owned evidence
is explicitly added with git add -f. Ignored logs needed after cleanup must
be copied to the final target bin directory before worktree removal.

The integration worktree has its own independent pinned mORMot2 clone in
third_party/mORMot2. It was cloned from the original dependency as a read
operation with --no-hardlinks. All compiler output stays in target bin.
Source repositories and original dependency checkout are clean. No recent
compiler output was found in their source directories.
