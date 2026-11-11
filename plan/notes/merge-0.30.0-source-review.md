# Source review for the 0.30.0 merge

Inspection date: 2026-11-11.

This record supports [the merge plan](../merge-0.30.0.md). It records source
inspection only. It does not report a successful build or test run.

## Source identity

| Project | Inspected commit | Working tree | Package XML version |
| --- | --- | --- | --- |
| `../http2client` | `709336f542cbedf9ce1ab67d83bddcfd560eb1c0` | Clean | 0.23.0 |
| `../http2server` | `16e2003a9f31648005c5565d118bbd42acf935a8` | Clean | 0.29.0 |

The target had no implementation at inspection. It contained `AGENTS.md`
and an existing staged `.gitignore`. That ignore file includes `plan/`.
The plan files therefore remain local unless the repository owner changes
the tracking rule or explicitly adds them. This work does not change the
existing staged ignore file.

The initial unit inventory contains 25 client units and 77 server units.
The [unit map](../merge-0.30.0-units.tsv) gives every source unit a target
and an implementation story. Additional split units are specified in the
main plan; the initial map is not the final package manifest.

## Read sources

The review covered both repository READMEs, Makefiles, Taskfiles, package
files, changelogs, license files, notices, architecture documents, and
compiler/environment documents. It also covered the public facades and
the interfaces and differences in Errors, Headers, Hpack, Frames, and
FlowControl. Source size and internal dependency searches covered `src/`.
The test, tool, document, and reference trees supplied the story reading
lists and validation scope.

The source searches are an inventory aid. A search that matches `uses` in
a Pascal comment can report a false dependency. M01 requires a checker
that excludes comments and strings before it enforces the dependency
matrix. The server Async comments, for example, can produce a false match
for the client `Http2` umbrella.

## Shared protocol differences

| Area | Observed difference | Planned treatment |
| --- | --- | --- |
| Errors | Both define the same wire codes and base classes. Client adds proxy, identity, SSE, and WebSocket errors. Server adds configuration, cancellation, reset, and stopped errors. | One common hierarchy; role errors derive from it. |
| Headers | After comment and namespace normalization, client adds `HeaderLastEventId`; the other code matches. | Retain the constant and one interface definition. |
| Hpack | Server adds directional table controls, pending size updates, and a decoded header-list cap. | Start with server code; retain both test sets and the client callable API. |
| Frames | Client carries arrival time and decoded header metadata. Server adds preface helpers, settings delta decode, extended CONNECT settings, and priority extraction. | Retain the union and test wire serialization separately from metadata. |
| FlowControl | Server adds `DefaultWindowSize`, separate connection/stream consumption, and `ApplyStreamDataSent`. | Retain both APIs; check each caller's accounting path. |

The server protocol headers state that these units came from an earlier
client revision. That origin does not make the current implementations
identical. A copy of only one current project would lose behavior from
the other project.

The client decodes HPACK in the connection reader and passes decoded fields
to streams. The server uses `HpackConnection` and runs HPACK on its IO side.
The common codec does not merge these scheduling models.

## Source size findings

Line counts include comments and headers. The target limit is fewer than
1000 lines per Pascal file. Adding required headers can increase these
counts. A final recursive check is required after all changes.

| Client production file | Inspected lines | Division story |
| --- | --- | --- |
| `src/Http2.Client.pas` | 4642 | C04 |
| `src/Http2.Connection.pas` | 1555 | C02 |
| `src/Http2.Http1.pas` | 1308 | C02 |
| `src/Http2.Proxy.pas` | 1066 | C01 |
| `src/Http2.Stream.pas` | 1595 | C02 |
| `src/Http2.Tls.pas` | 1944 | C01 |
| `src/Http2.WebSocket.pas` | 1244 | C03 |
| `src/Http2.WebSocketClient.pas` | 1212 | C03 |

Eight client production files exceed the limit. Fourteen client test or
support files also exceed it:

| Client test file | Inspected lines |
| --- | --- |
| `Http2.Client.Test.pas` | 1803 |
| `Http2.ClearText.Test.pas` | 1421 |
| `Http2.MockSocket.pas` | 1959 |
| `Http2.MutualTls.Test.pas` | 3006 |
| `Http2.ObserverAdapters.Test.pas` | 1301 |
| `Http2.ProxyClient.Test.pas` | 1004 |
| `Http2.ProxyTransport.Test.pas` | 1080 |
| `Http2.Redirects.Test.pas` | 1121 |
| `Http2.RequestObserver.Test.pas` | 3530 |
| `Http2.Sse.Test.pas` | 2023 |
| `Http2.Stream.Test.pas` | 1500 |
| `Http2.Tls.Test.pas` | 1075 |
| `Http2.WebSocketClient.Test.pas` | 1532 |
| `Http2.WebSocketObservability.Test.pas` | 1459 |

All inspected server production and test files are below 1000 lines.
`Http2Server.Async.pas` has 998 lines and
`Http2Server.Connection.Core.pas` has 989. The merge cannot assume that
these files have room for additional declarations or comments.

## Build and package findings

Both Taskfiles pin mORMot2 to
`b2b195da1e0580058672a88620ef71bb47283eb1`. Both projects record Free Pascal
3.2.4, Delphi mode, and OpenSSL 3. The server derives compiler target paths;
the client Makefile still has a macOS arm64 default path.

Client `Http2.Readers` is optional in the source architecture. It uses
JSON/XML FCL units. The client package registration source includes it, so
package separation needs an explicit check. The generated registration
source does not have the target pasdoc header format.

The server's `mtls-live` and `tls-live` build targets use
`../http2client/src`. Their tests already exercise both roles and are useful
starting points for local integration. The merged build must remove that
sibling path dependency.

The client `packagefiles.xml` records absolute user paths and IDE package
state. It is not a portable package manifest. It is excluded from the target.

Client and server validation tasks have different meanings. Their tools
must retain separate role prefixes. Client observer adapter examples are
units, so a loop that links every example `.pas` file is incorrect.

The client harness documents a fixed host port and a requirement to run
alone. A paired client/server test cannot replace that independent gate.

## Documentation and license findings

The client uses Apache-2.0 in `LICENSE` and `NOTICE`. The server uses
`LGPL-2.1-only WITH Independent-modules-exception`. These are observed
metadata values. This record makes no determination about relicensing.
The implementation plan requires a provenance decision and preservation of
notices before a release is complete.

The client documentation front matter starts with title and other metadata;
it does not satisfy the target license-on-line-two rule. Its Pascal sources
also need the required header form. The server uses the target form.

The server has verbatim reference copies in `doc/references/`. The client
has compiler probes under `doc/reference/fpc-verified/` and no `.txt`
reference copies found by this inspection. These probes include an old
copy of `Http2.Client`; that copy must not become an active library unit.

The server documentation checker hard-codes one license expression. Its
shell search covers nested files, but its Ruby Pascal header glob covers
only direct children of `src`, `test`, and `examples`. The Ruby script also
prints a blank-before-brace finding without increasing its failure count.
M01 addresses both points and includes Pascal programs under `tools/`.

The source changelogs distinguish tagged releases from newer package
versions. The target starts at 0.30.0; it preserves source release history
without presenting source package versions as new merged releases.

## Unverified work

The following remain implementation work: original baseline test runs,
full tracked-file provenance, reference retrieval for missing client RFCs,
API compile probes, license alignment, merged builds, external validation,
and the two target-platform checks. The plan contains acceptance criteria
for each item and does not claim that they have passed.
