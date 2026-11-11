# Implementation completion

The implementation is version 0.30.0. The three public facades are
Http2.Common, Http2.Client, and Http2.Server. All 135 library units are under
src/common, src/client, or src/server. The original sibling repositories
remain unchanged. Owned code and documentation have the authorized dual
license. Original third-party and specification terms remain intact.

## Review and verification

All planned imports and source divisions are merged. Public class, method,
constant, interface, and generic names are retained through their original
role units where required. The parent reviewed each agent branch and fixed
public-name losses, source fixture paths, encoder-lock lifetime, upload wait
locking, notification ordering, script paths, and build prerequisites.

- Common suite: 229 cases pass.
- Default client runner: 805 registered results, zero errors or failures,
  28.805 seconds. Thirty-three environment-gated live cases were inactive.
  The 10 proxy, 18 WebSocket, two SSE, one TLS, and two lifecycle cases stay
  in the explicit external/live validation scope.
- API: 16 cases and six probes pass.
- Local integration: nine in-process cases and two separate-process
  HTTP/2 exchanges pass.
- Local TLS and mTLS: 21 and 40 checks pass.
- Focused server factory and TLS context: 27 and ten cases pass.
- All four Lazarus packages compile.
- Source checks pass for 353 Pascal files and 135 library units. All active
  Pascal files have the required headers and are below 1000 lines.
- Documentation checks pass for 54 documents. Version metadata agrees.
- All 1780 original test registrations have checked dispositions. All 440
  source identity/hash/license records are unchanged. Retained targets
  resolve; 25 omitted artifacts or workflow files have explicit reasons.

The complete timed server suite is not a pass. Its 60-second run stopped
before completion, and a diagnostic sample showed a normal timed sleep.
The stale factory fixture discovered in that run is corrected. Full timed
completion, original cancellation-result comparison, Linux, load/abuse,
and independent conformance remain in validation-after-merge-0.30.0.md.
M13 is deliberately deferred. M14 closes the implementation review with
those explicit scope limits. M15 prepares source version 0.30.0 without
publishing or tagging a release.

## Clean archive

Candidate 6ac7077 was exported with git archive. The archive contains no
bin, third_party, or Git metadata. It was extracted to an empty directory.
The common, client, server, and optional Readers builds pass there, using
the target-owned mORMot clone at pinned revision
b2b195da1e0580058672a88620ef71bb47283eb1. It uses no original sibling source
or compiled unit. Source, documentation, and accounting checks also pass.

Archive SHA-256: 23a547842cc1ff1a60bcceea066ed803be5e575bd760eca047de07e1433a17ef

The retained archive is bin/archive-review/http2components-0.30.0.tar.
Build and check logs are in the same directory. The later completion
records change documentation only. They do not change the tested code.

## Cleanup

All completed agent worktrees and branches are removed after review. The
parent integration worktree is removed after its accepted commits and
review evidence reach main. The independent dependency clone remains under
main's ignored third_party/mORMot2. Raw review logs and the tested archive
remain under main's ignored bin directory. No generated operational PKI or
compiled worktree output is needed as release evidence.
