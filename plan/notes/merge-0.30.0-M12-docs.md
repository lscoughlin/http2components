# M12 documentation preparation

## Reading and inputs

The M12 scope in `plan/merge-0.30.0.md` and
`plan/notes/merge-0.30.0-scope.md` was read. The client documentation index,
client design notes, server documentation index, server design notes,
verification records, and server reference index were reviewed. The target
front-matter rules and the dual-license authorization were also reviewed.

The source revisions are client
`709336f542cbedf9ce1ab67d83bddcfd560eb1c0` and server
`16e2003a9f31648005c5565d118bbd42acf935a8`. Both source trees were clean at
those revisions and remain unchanged.

## Prepared documentation

The client and server topic documents are in `doc/design/client/` and
`doc/design/server/`. Their unit references use the target unit map. The
`doc/design/common/` pages record the approved target architecture and
protocol responsibilities. They mark final source review as pending.

`doc/migration-0.30.0.md` has one row for each of the 102 production source
units. It records splits, merges, moves, and the renamed WebSocket units. It
also describes the removed client umbrella, type qualification cases,
planned package layout, and the planned 0.30.0 version. Package details and
API compatibility remain pending final source and build review.

The root README describes the three entry units and optional Readers package.
It lists the expected build command contract as unverified. It makes no
claim that a command exists or passes. The changelog starts with an
integration-preparation entry. Historical source changelogs are stored
separately and label 0.23.0 and 0.29.0 as source package versions, not
asserted releases.

All 20 server reference files were copied byte for byte. The target
`doc/references/README.md` records their source URLs, actual source retrieval
dates, and SHA-256 hashes. RFC 1928 and RFC 1929 were already present in the
target tree; their RFC Editor URLs, 2026-11-11 retrieval dates, and hashes
are in the index. Hash comparison found no mismatch. The server references
were retrieved on 2026-10-22, except RFC 4514, 5280, 7301, and 8446, which
were retrieved on 2026-10-25. The IANA registry and WHATWG copy retain the
2026-10-22 dates in the source index.

Twelve client compiler probe source files are in
`doc/verification/client-probes/`. The duplicate source library unit and
compiled probe binaries are excluded. The original probe description is
retained as a historical source note. Client and server verification
documents and client verification data files are grouped under
`doc/verification/source/`; they are marked as source history, not merged
validation.

## Review status

Reference byte comparisons, the 22-entry reference hash table, YAML header
shape, local Markdown links, and the 102-row unit table were checked. No test,
build, documentation task, Linux check, or resource-intensive validation was
run. The root command contract is not yet verified against the final build
files.

M12 acceptance remains pending final review of every API and architecture
statement against the merged source, build commands against the actual root
build files, and the documentation check command. Linux and resource-heavy
validation remain deferred by user direction.
