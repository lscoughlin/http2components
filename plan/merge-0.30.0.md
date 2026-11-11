# Dependency matrix

This is the merge plan for **http2components 0.30.0**. A dependency in the
third column must pass its acceptance checks before the next story starts.
The owner is a work role. One agent can fill more than one role in sequence.

| ID | Work | Depends on | Owner | Completion evidence |
| --- | --- | --- | --- | --- |
| M00 | Record source baselines and license provenance | None | Integration | Source hashes, file inventory, baseline results, license record |
| M01 | Set layout, build rules, checks, and version | M00 | Build | Build tasks, `VERSION`, source and document checks |
| M02 | Merge common errors and headers | M01 | Common | One type identity; both source test sets pass |
| M03 | Merge HPACK | M02 | Common | Both codec test sets and directional settings tests pass |
| M04 | Merge frames and flow control | M03 | Common | Both test sets and settings/credit tests pass |
| M05 | Freeze the common API for the imports | M04 | Integration | Common facade, API manifest, independent build |
| M06 | Import and rename the client | M05 | Client | Client compiles; test inventory has no losses |
| M07 | Import and rename the server | M05 | Server | Server compiles; full server unit suite passes |
| C01 | Divide client transport and proxy units | M06 | Client transport | TLS, proxy, SOCKS, identity tests pass |
| C02 | Divide client connection, stream, and HTTP/1 units | C01 | Client protocol | Lifecycle, flow, timeout, and HTTP/1 tests pass |
| C03 | Divide client WebSocket units; retain SSE | C02 | Client streaming | WebSocket and SSE unit tests pass |
| C04 | Divide client API and pool; retain helpers | C03 | Client API | Full client suite passes; all source sizes pass |
| M08 | Align test files, fixtures, and runners | C04, M07 | Test | All imported tests accounted for; all test sizes pass |
| M09 | Move tools and examples | M08 | Tooling | Examples compile; validation tasks find local inputs |
| M10 | Complete public facades and Lazarus packages | M08 | Packaging | Common, client, server, and combined compile probes pass |
| M11 | Test client and server together | M09, M10 | Integration test | Local HTTP/2, HTTP/1, TLS, SSE, and WebSocket results |
| M12 | Merge documentation and reference copies | M09, M10 | Documentation | Complete index; valid headers and links; migration table |
| M13 | Run independent peer and platform checks | M11 | Validation | Client and server external results; platform record |
| M14 | Review the merge and close defects | M12, M13 | Review | No open required checks or unexplained test losses |
| M15 | Prepare release 0.30.0 | M14 | Release | Version agreement; clean source archive builds |

M06 and M07 can run at the same time. M09 and M10 can run at the same time.
M12 can run while M11 and M13 run. C01 through C04 are in sequence because
these units share types and implementation dependencies. Separate agents
must not edit those units at the same time.

## Runtime dependency matrix

`Yes` permits a dependency. `No` prohibits a dependency. The rule covers
interface and implementation `uses` clauses and package dependencies.

| Consumer | RTL / basic FCL | `Http2.Common.*` | `Http2.Client.*` | `Http2.Server.*` | mORMot2 / OpenSSL binding | JSON / XML FCL |
| --- | --- | --- | --- | --- | --- | --- |
| `Http2.Common` and its units | Yes | Yes, with no cycle | No | No | No | No |
| `Http2.Client` and its core units | Yes | Yes | Yes, with legal Pascal dependencies | No | Yes | No |
| `Http2.Client.Readers` | Yes | Yes | Yes | No | Through client | Yes |
| `Http2.Server` and its units | Yes | Yes | No | Yes, with legal Pascal dependencies | Yes | No |
| Common unit tests | Yes, plus fpcunit | Yes | No | No | No | No |
| Client unit tests | Yes, plus fpcunit | Yes | Yes | No | As required | Reader tests only |
| Server unit tests | Yes, plus fpcunit | Yes | No | Yes | As required | No |
| Integration tests | Yes, plus fpcunit | Yes | Yes | Yes | Yes | Only when tested |

A leaf unit names the leaf units that it needs. It does not name a facade
that imports it. Interface dependency cycles are prohibited. An existing
legal implementation dependency needs a recorded reason if it remains.

## Scope and evidence

The target repository is `http2components`. The source repositories are
`../http2client` and `../http2server`. This plan defines a source merge into
one build and one release. It does not execute that merge.

The source inspection date is 2026-11-11. The inspected commits are:

| Source | Commit | Package version | Production units |
| --- | --- | --- | --- |
| `http2client` | `709336f542cbedf9ce1ab67d83bddcfd560eb1c0` | 0.23.0 | 25 |
| `http2server` | `16e2003a9f31648005c5565d118bbd42acf935a8` | 0.29.0 | 77 |

Both source working trees were clean at inspection. These are source facts,
not test results. No build or protocol test was run to prepare this plan.
The source README test totals are historical. M00 records current totals.

The complete initial source-unit map is
[merge-0.30.0-units.tsv](merge-0.30.0-units.tsv). It accounts for all 102
production units. Rows with `split` give the main destination; the stories
below define the additional units. M00 extends the inventory to tests,
examples, tools, documents, fixtures, and package files.

[Source review notes](notes/merge-0.30.0-source-review.md) record the known
differences. Each story adds its reading and test notes under
`plan/notes/merge-0.30.0-<ID>.md`.

The release retains the existing client and server features. It does not
replace either thread model, add HTTP/3, add client WebSocket over HTTP/2,
or combine the HTTP/1, TLS, WebSocket session, and SSE implementations.
Those areas have different roles and contracts. Only the five established
protocol areas become shared implementations in this release.

## Naming and layout decisions

The three public entry units are real Pascal units:

- `src/common/Http2.Common.pas`: shared protocol types and operations.
- `src/client/Http2.Client.pas`: client factory, request, response, and client API.
- `src/server/Http2.Server.pas`: server factory, handler, request, and response API.

All production Pascal units are under `src/common`, `src/client`, or
`src/server`. Dotted unit names express the same three groups. A core
consumer has the common directory and its role directory on the compiler
unit search path, together with the configured dependencies. No production
unit is directly under `src/`.

| Source name or pattern | Target name or pattern | Rule |
| --- | --- | --- |
| `Http2.{Errors,Headers,Hpack,Frames,FlowControl}` and server equivalents | `Http2.Common.<Area>` | One implementation per shared area; role errors are separated |
| `Http2.Client` | `Http2.Client` plus `Http2.Client.Core` and smaller units | Existing public entry name stays; implementation moves below it |
| Client `Http2.<Area>` outside the shared set | `Http2.Client.<Area>` | Existing suffix stays, except the next row |
| `Http2.WebSocketClient` | `Http2.Client.WebSocket.Connection` | Separates the connection from the WebSocket API and codec |
| `Http2Server` | `Http2.Server` | Public server entry unit |
| `Http2Server.Server` | `Http2.Server.Runtime` | Avoids a repeated `Server.Server` name |
| `Http2Server.Ws.<Area>` | `Http2.Server.WebSocket.<Area>` | Aligns the spelling with the client |
| Other `Http2Server.<Area>` | `Http2.Server.<Area>` | Existing suffix stays |
| `Http2` umbrella | Retired; its use becomes `Http2.Client` plus explicit feature units | No fourth public umbrella |

The unit map applies to filenames, unit declarations, `uses` clauses,
qualified symbols, tests, tools, package lists, and examples. A global
substring replacement is not sufficient. Pascal unit names are case
insensitive. M01 checks duplicates without regard to case.

Existing public type, member, parameter, enum, and constant names stay when
their contracts stay. Examples include `THttpClientFactory`, `IHttpClient`,
`THttp2ServerFactory`, and `IHttp2Server`. The merge does not rename every
`TWs` type to `TWebSocket`. This would add a separate API change.

This release changes many unit names. It provides a full migration table;
it does not promise that every old `uses` clause compiles unchanged. No
legacy wrapper tree is required. The unchanged `Http2.Client` entry must
retain its public names. New facades use explicit type aliases, constant
aliases, and small forwarding functions where needed. An interface `uses`
list alone does not prove that names are available to a consumer.

Shared aliases use `TName = OtherUnit.TName`, not a new type declaration or
a subclass. Shared interfaces retain their GUIDs. The server and client
`IBodyWriter` contracts remain distinct. A combined consumer uses
`Http2.Client.IBodyWriter` or `Http2.Server.IBodyWriter` explicitly.
Factories, helpers, enums, overloads, and exceptions need compile probes.

The planned tree is:

```text
VERSION                         # 0.30.0 followed by a newline
LICENSE, NOTICE, LICENSES/       # provenance established in M00
Makefile, Taskfile.yaml
http2common.lpk
http2client.lpk
http2server.lpk
http2clientreaders.lpk           # optional JSON/XML helpers
src/common/Http2.Common*.pas
src/client/Http2.Client*.pas
src/server/Http2.Server*.pas
test/common/
test/client/
test/server/
test/integration/
test/fixtures/                  # shared non-secret test data
examples/client/
examples/server/
examples/integration/
tools/check/
tools/client/
tools/server/
tools/integration/
doc/README.md
doc/design/common/
doc/design/client/
doc/design/server/
doc/verification/
doc/references/
plan/notes/
third_party/                    # ignored, revision-pinned dependencies
bin/<target>/<profile>/         # ignored programs, results, and object files
```

`<target>` identifies CPU and OS. `<profile>` distinguishes unit tests,
integration tests, normal builds, and debug builds. Make and Task must not
write incompatible `.ppu` files to the same output directory. Each runner
has a separate program name. `-FU` directs unit output; `-FE` directs
program output. Source directories contain no generated objects.

## Shared-code decisions

### Errors and headers

`Http2.Common.Errors` owns `THttp2ErrorCode`, `Http2ErrorCodeName`, and the
common base hierarchy: `EHttpError`, `EHttpConnectionError`,
`EHttpProtocolError`, `EHttpStreamError`, `EHttpTimeout`, and
`EHttpConnectionClosed`. Their codes, constructors, and fields stay.

`Http2.Client.Errors` owns redirect, replay, SSE retry, proxy, client TLS,
and client WebSocket exceptions. `Http2.Server.Errors` owns
`EServerConfigError`, `EStreamCancelled`, `EStreamReset`, and
`EServerStopped`. Each role unit can alias common names for its consumers.
It must not declare another common exception class.

The header implementations differ only by `HeaderLastEventId` after removal
of comments and unit prefixes. The common implementation retains this
constant, the full API, and the existing `IHttpHeaders` GUID. HPACK header
records stay in `Http2.Common.Hpack` to avoid an unnecessary type move.

### HPACK

The server implementation is the starting point. It contains
`SetDecoderLimit`, `SetEncoderCap`, `SetPeerTableSize`, table-size update
emission, and `MaxHeaderListSize`. All client codec tests remain inputs.
The common codec preserves `ApplySettings` with its recorded legacy
contract. New connection code uses the directional operations.

A received peer table-size setting changes the encoder limit. The local
advertised limit controls the decoder. M03 tests shrinking, growing,
shrink-then-grow before a block, zero size, malformed integers, Huffman
padding, sensitive fields, and header-list limits. M06 adapts client call
sites; M07 retains the server call sequence.

### Frames and flow control

The common frame API combines the two source APIs. It retains client
`TFrame.ArrivedUs`, `HeadersDecoded`, and `DecodedHeaders`. These fields
contain metadata, not bytes added to the wire. This keeps client wire-order
HPACK decoding intact. The common Frames unit can therefore depend on
common Hpack. The server preface helpers, settings delta overload,
`EnableConnectProtocol`, and priority helper also remain.

If the union reaches 1000 lines, implementation helpers move to
`Http2.Common.Frames.Codec` and `Http2.Common.Settings`. A small
`Http2.Common.Frames.Types` unit can own records to prevent a cycle.
`Http2.Common.Frames` retains aliases and the existing callable surface.
Public methods on records remain with their record declarations; helper
units hold independent operations. Large include files are not a size fix.

Common flow control retains `TryConsume` and the server's separate
connection/stream operations. Each caller uses exactly one accounting path
for each byte. Queueing DATA and actually sending DATA must not charge the
same window twice. SETTINGS changes apply to stream windows, and omitted
settings retain their prior values. Role-specific SETTINGS validation stays
in the connection code; a common decoder does not make both roles equal.

### Features that stay separate

`Encoding`, `Tls`, `ClientCert`, `Connection`, `Stream`, `Observer`, `Http1`,
`Sse`, and WebSocket have separate client and server meanings. Matching
suffixes do not establish matching interfaces. Server TLS client-certificate
inspection is not client identity selection. Server WebSocket frames are
unmasked on send; client frames require masking. Server SSE encoding is not
client SSE parsing or reconnection. The merge retains these distinctions.

## Build and convention contract

The compiler baseline is Free Pascal 3.2.4, as recorded by both projects.
The merge keeps `{$mode delphi}{$H+}`, applicable mode switches, COM
interfaces, and the established `T`, `I`, `E`, `F`, and `A` prefixes.
Unix programs load `cthreads` before threaded units. Existing `RTLEvent`
and `TCriticalSection` use stays until its tests justify a change.

Both projects pin mORMot2 to
`b2b195da1e0580058672a88620ef71bb47283eb1`. The merged build uses that one
checkout. The client harness pin remains
`0bc075cc21e5a247dfd222e005d1e7e5679d2bff`. Parser tooling, if retained, uses
the server's recorded pin. The merge does not update dependencies.

`FPC`, `FPCFLAGS`, `FPC_UNITS`, `MORMOT`, and `OPENSSL_LIBPATH` remain
configurable in both build entry points. The build derives CPU, OS, and
compiler version as the server build does. OpenSSL 3 remains a runtime
dependency. `fpcunit` belongs to test commands. JSON/XML units belong only
to the optional Readers build. Common compiles without mORMot2.

All maintained Pascal files, including programs under tools and tests, have
the specified pasdoc YAML header and fewer than 1000 lines. A method above
499 lines needs division or an explicit responsibility review in the story
notes. The line limit includes headers. The server has units at 998 and
989 lines, so added comments can also require division.

Documents in `doc/` have the required YAML, declarative text, and no plan
references. Reference `.txt` copies remain verbatim. A copied document's
front matter changes only with accurate license and provenance information.
Historical results are marked as source-project results, not merged results.

The license record needs particular care. The client `LICENSE` and `NOTICE`
state Apache-2.0. The server uses
`LGPL-2.1-only WITH Independent-modules-exception`. The common file ancestry
also crosses these projects. M00 records each source license and preserves
notices. A header-format change must not silently change a source license.
A verified license decision is a release prerequisite. The plan does not
assume permission to relabel Apache source as LGPL source. Where provenance
remains unresolved, the release remains incomplete; independent technical
work can continue. A checker validates the applicable SPDX expression from
the inventory instead of enforcing the server's hard-coded expression on
all imported files.

## Story instructions

Every story follows this procedure:

1. Read this plan, its dependency notes, and the named source sections.
2. Record the inspected source commit and reading notes in its notes file.
3. Change only owned paths. Send cross-owner changes to the integration owner.
4. Run the named checks. Record the command, environment, exit status, test
   totals, skips, and evidence path. An unavailable check is not a pass.
5. Supply a short handoff with changed files, public API changes, remaining
   issues, and the commit or patch to integrate.

The following `C:` and `S:` prefixes mean `../http2client/` and
`../http2server/`. They identify source reading. After M12, the equivalent
merged documents use the target paths from the document inventory.
The commands below are the target command contract. They do not exist in
this target repository yet. M01 establishes them as their inputs arrive.

### M00 — Baseline and provenance

**Owned paths:** source inventory and notes under `plan/`; initial license
records and missing reference copies under `doc/references/`. The source
repositories remain unchanged.

**Reading:** both `README.md` sections about requirements, build, test, and
validation; both `LICENSE` and `NOTICE` files; both `doc/verification/toolchain.md`
sections `Compiler and platform`; both validation documents in full;
`S:doc/design/protocol.md`, `The two table directions` and `Flow control`.

**Work:**

- Confirm the two commits and working-tree states. Record changes from the
  inspected commits before importing. Import a fixed tracked snapshot, not
  an uncontrolled directory copy. Record origins without rewriting source
  history or merging the two unrelated Git histories.
- Inventory every tracked source, test, example, tool, document, reference,
  license, and build input. Record old path, new path, source hash, license,
  and action. Assign an explicit disposition to every tracked file.
- Exclude `.git`, build outputs, `.task`, `.DS_Store`, editor state,
  `packagefiles.xml` with absolute user paths, local agent settings, and
  untracked third-party trees. Preserve maintained test fixtures.
- Run each original unit suite with its original build in a disposable
  checkout. Record the test names and skips, not only a total. Record any
  existing failure before the merge changes code.
- Record license provenance and any missing authorization evidence. Keep
  source `NOTICE` texts and the distinct license texts in the import record.
- Obtain missing RFC 1928 and RFC 1929 plain-text copies for C01. Record
  rfc-editor URLs, hashes, and retrieval dates in the reference index. The
  index has the required YAML header; the reference text stays verbatim.

**Acceptance:** all 102 production units are covered once as inputs; test
counts and known failures are recorded; file/license decisions are explicit.
Missing tools or license evidence have named owners and release impact.

### M01 — Build and repository checks

**Owned paths:** root build files, `VERSION`, `tools/check/`, output rules,
and package skeletons. Preserve unrelated user changes in `.gitignore`.

**Reading:** both Makefiles and Taskfiles; `S:doc/verification/toolchain.md`,
`Build flags` and `Dependency bootstrap`; target `AGENTS.md`;
`S:tools/check/doc_rules.sh` and `yaml_headers.rb`.

**Work:**

- Set `VERSION` to exactly `0.30.0`. Establish the task names in the command
  table below. An incomplete required target fails with a clear message.
- Use shared build settings. Make and Task produce the same flags and pins.
  Setup is explicit; ordinary unit tests do not install system packages,
  fetch dependencies, or start Docker.
- Add recursive checks for Pascal headers, line counts, unit-name/path
  agreement, case-insensitive duplicates, and package/source inventory.
- Extend the YAML checker to all maintained Pascal files, including nested
  tests, examples, and tools. A missing YAML parser fails the required check.
  A blank line before the pasdoc closing brace fails the check.
- Add a dependency check that reads real Pascal `uses` clauses and ignores
  comments and strings. Check the runtime matrix, facade back-references,
  and interface cycles. Regular-expression hits in comments are not edges.
- Keep clean targets within generated directories. Keep generated test
  keys and compiler output out of the source archive.

**Acceptance:** version check passes; rule checks reject deliberate invalid
fixtures; an empty required test suite cannot report success. Build tasks
accept environment overrides and isolated output paths.

### M02 — Common errors and headers

**Owned paths:** common Errors/Headers, role Errors, and their common tests.

**Reading:** both Errors and Headers unit interfaces and tests;
`C:doc/design/messages.md`, `Headers and header names`;
`S:doc/design/protocol.md`, `Errors`;
`S:doc/references/rfc9113.txt`, sections 7 and 8.2.

**Work:** implement the error/header decisions above. Preserve all
constructors, fields, enum ordinals, header constants, and interface GUIDs.
Place both source test sets in separate common test units initially. Use
`.ClientOrigin.Test` and `.ServerOrigin.Test` suffixes where names collide.

**Acceptance:** both test sets pass. A test catches errors from both role
units as the same common base class. Header interface assignments compile
across role boundaries. `HeaderLastEventId` is present.

### M03 — Common HPACK

**Owned paths:** common Hpack and common HPACK tests.

**Reading:** both Hpack units, Hpack tests, and HpackProps tests;
`S:src/Http2Server.HpackConnection.pas`;
`S:doc/design/protocol.md`, `HPACK`, `The header-list limit`, and
`The two table directions`; `S:doc/references/rfc7541.txt`, sections 2–7
and appendices A–C; RFC 9113 sections 4.3, 6.5.2, and 10.5.1.

**Work:** start with the server codec and reconcile every diff with the
client. Implement the shared HPACK decisions. Keep a single definition of
`THttpHeaderField`, `THeaderBlock`, and `THpackCodec`. Add direction and
pending-size-update tests before changing client settings calls. Record
whether an expected byte change follows a protocol correction.

**Acceptance:** both source codec/property suites pass. RFC vectors pass;
encoder and decoder limits remain independent; header-list bounds remain
active. The common codec has no transport or role dependency.

### M04 — Common frames and flow control

**Owned paths:** common Frames/FlowControl, necessary small helper units,
and common frame/window tests.

**Reading:** both Frames and FlowControl units and tests;
`S:test/Http2Server.H2Flow.Test.pas` and `H2Credit.Test.pas`;
`C:test/Http2.HpackOrder.Test.pas`;
`S:doc/design/protocol.md`, `Frames`, `Server settings`, and `Flow control`;
RFC 9113 sections 3.4, 4–7; RFC 8441 sections 3–5 in the server references.

**Work:** implement the union described above. Preserve client frame
metadata initialization in all constructors and builders. Preserve server
settings-delta decoding. Keep connection-specific validation in its role.
Divide the frame unit if required. Test negative stream windows after a
settings decrease, overflow, zero updates, padding credit, and independent
connection/stream consumption.

**Acceptance:** both original suites pass; metadata never changes frame
serialization; repeated SETTINGS retain omitted values; a transmitted DATA
byte receives exactly the intended credit and charge at each level.

### M05 — Common API handoff

**Owned paths:** `Http2.Common`, common public API manifest, common build
probe, and the common boundary record.

**Reading:** M02–M04 notes; both original public protocol interfaces;
`S:test/Http2Server.Facade.Test.pas` as a facade-test pattern.

**Work:** expose common public types, enum constants, and required helpers
through explicit aliases and forwarding operations. Record all shared
symbols and their defining units. Define the client migration from
`ApplySettings` to directional HPACK calls. Freeze these interfaces for M06
and M07; a later change updates both consumers in one integration change.

**Acceptance:** `task test:common` passes. A consumer of only `Http2.Common`
compiles and uses errors, headers, HPACK, frames, and windows with no client,
server, mORMot2, JSON, or XML dependency.

### M06 — Client import

**Owned paths:** client source, imported client tests, and client inventory.

**Reading:** `C:doc/design/architecture.md`, all sections;
`C:doc/design/transport.md`, `Threading and queues` and
`Connection lifecycle`; `C:doc/design/protocol.md`, all sections;
M05 API handoff; complete source-unit map.

**Work:** copy tracked inputs and apply the map. Replace the five protocol
copies with common imports. Add correct license headers without changing
provenance. Retain original client public names. Adapt received SETTINGS to
common delta decoding and HPACK direction without moving decoding away
from the connection reader. Preserve CONTINUATION ordering and metadata.
Register every imported client test. Record temporary size failures by file;
C01–C04 and M08 must close them before release.

**Acceptance:** client build and imported unit suite run. Every failure is
resolved or traced to M00 evidence with a repair owner. No new failure is
accepted as an unexplained rename effect. Client has no server dependency.

### M07 — Server import

**Owned paths:** server source, imported server tests, and server inventory.

**Reading:** `S:doc/design/architecture.md`, `The layers` and
`The thread model`; `threading.md`, all sections; `connection.md`, all
sections; `public-api.md`, `The facade`; M05 API handoff and unit map.

**Work:** copy and rename server units. Replace protocol copies with common
imports and move the runtime to `Http2.Server.Runtime`. Rename `Ws` unit
segments to `WebSocket`. Preserve server API types, handler/seam ownership,
nonblocking IO, bounded queues, cancellation, and shutdown. Keep live tests
that use the sibling client for M11. Keep independent server unit tests
under `test/server/`. Check size again after header and name changes.

**Acceptance:** `task test:server` passes. No server production unit imports
a client unit. Server tests for HPACK direction, stream lifetime, limits,
ALPN, and HTTP/1 remain registered. No production file reaches 1000 lines.

### C01 — Client transport and proxy division

**Owned paths:** client Tls, Proxy, Socks, ClientCert, IdentityHandle,
SigPipe, and new units in those groups. Related tests stay with the owner
until M08.

**Reading:** `C:doc/design/transport.md`, `TLS and ALPN`;
`proxy.md`, all sections; `mtls.md`, `Loading and use`, `Pooling`,
`Selector and proxy identity`, `Per-request identity`, and `Rejection`;
`fpc-runtime.md`, all sections. RFC reading: server copies of RFC 7301
section 3, RFC 8446 sections 4.3–4.4, and RFC 5280 section 6. SOCKS details
use the source project's cited RFC 1928 sections 3–7 and RFC 1929 section 2;
M00 obtains missing reference copies and records their retrieval dates.

**Work:** divide `Tls` into public contracts/enums, plain sockets, TLS
sockets, and tunnel/BIO operations. Suggested suffixes are `Tls.Types`,
`Tls.Plain`, `Tls.Socket`, and `Tls.Tunnel`. Divide `Proxy` into public
values/selectors and `Proxy.Environment`/`Proxy.Match` helpers. Keep public
aliases in `Tls` and `Proxy`. Do not turn private state into public mutable
state solely to move methods. Move complete classes with their methods.

**Acceptance:** proxy selection, no-proxy matching, SOCKS, nested TLS,
identity isolation, cancellation, and cleanup tests pass. Secret values do
not enter new diagnostics. A transport file has fewer than 1000 lines.

### C02 — Client connection, stream, and HTTP/1 division

**Owned paths:** client Connection, Stream, Http1, Messages, their helper
units, and related tests.

**Reading:** `C:doc/design/transport.md`, `Threading and queues` and
`Connection lifecycle`; `messages.md`, `Request and response streaming`;
`fallback.md`, all sections; RFC 9113 sections 4.3, 5, 6.5, and 6.9;
RFC 9112 sections 6–9 from the server reference copies.

**Work:** move reusable queue code to `Connection.Queue`; separate
connection contracts from reader-thread work where a cycle would result.
Divide Stream into body contracts/implementations, cancellation, ID
allocation, and lease implementation. Suggested units are `Stream.Types`,
`Stream.Body`, `Stream.Cancel`, `Stream.Ids`, and `Stream.Lease`. Divide
Http1 into buffered reading, response/body parsing, and connection logic.
Keep `Stream`, `Connection`, and `Http1` as stable role entry units. Record
lock order and reference ownership before and after each move.

**Acceptance:** stream IDs, queue cancellation, reader shutdown, HPACK
ordering, partial reads, redirects with bodies, timeout handling, and
cleartext exactly-once behavior retain their tests. All files satisfy the
size limit; no new interface cycle or lock held across a wait appears.

### C03 — Client WebSocket division and SSE retention

**Owned paths:** client WebSocket units, Sse, and their tests.

**Reading:** `C:doc/design/websocket.md`, `Interfaces`, `Frames`,
`Delivery and demand`, `Sending`, `Closing`, and `Known limits`;
`server-sent-events.md`, `Wire format and parser`, `Cancellation`,
`Content coding`, and `Reconnection and resume`; RFC 6455 sections 4–8;
server WHATWG SSE reference, sections `Parsing an event stream` and
`Interpreting an event stream`.

**Work:** separate WebSocket public types, frames/parser, message assembly,
handshake, and connection/reader work. Suggested suffixes are
`WebSocket.Types`, `WebSocket.Frames`, `WebSocket.Parser`,
`WebSocket.Handshake`, `WebSocket.Connection`, and `WebSocket.Reader`.
Keep RNG-backed client masking, demand, ordering, close behavior, and
request observation. Move the SSE client without combining it with the
server encoder. Preserve content-coding rejection and reconnect state.

**Acceptance:** WebSocket frame, connection, observation, cancellation,
and close tests pass. SSE parsing, read timeout, cancellation, and resume
tests pass. No file reaches 1000 lines. No new RFC 8441 client feature is
claimed.

### C04 — Client API, pool, and facade division

**Owned paths:** `Http2.Client`, client Core, Request, Factory, Pool,
Response, observer/helper units, and their tests.

**Reading:** `C:doc/design/client-api.md`, all sections;
`architecture.md`, `Resolved multiplexing model`; `messages.md`,
`HttpRequest`, `HttpResponse`, and `Text, JSON, and XML helpers`;
`request-observability.md`, all sections; source `Http2.Client` interface.

**Work:** divide the 4642-line source by responsibility. Put request values
in `Client.Request`, response implementation in `Client.Response`, pool
contracts and state in `Client.Pool.Types`/`Client.Pool`, HTTP/1 and HTTP/2
pool adapters in separate units, factory code in `Client.Factory`, and
request execution in `Client.Core`. Here `Client.*` means the full
`Http2.Client.*` prefix. Extract small shared contracts downward when
Factory/Core/Pool would form a cycle. Keep advanced-record methods with
their declaration; use helper services for independent operations.

Retain `Encoding`, `Observer`, `RequestObserver`, `Clock`, and `Readers`
under the client prefix. Keep request/connection observation distinct.
The public `Http2.Client` unit aliases all former public names and preserves
fluent calls, helper resolution, overloads, default arguments, and generic
reader use. Generic aliases require a Free Pascal 3.2.4 compile check; use
a small public wrapper if that compiler cannot express the alias.

**Acceptance:** full client unit suite passes. Pool caps, lease ownership,
redirect rules, identity-based pool separation, and observer isolation are
unchanged. Examples using only `Http2.Client` still compile for the former
public API. Readers remain optional. All client source files pass size rules.

### M08 — Test structure and accounting

**Owned paths:** test directories, runners, fixtures, test size fixes, and
test-registration manifest. Build-owner changes go through M01's owner.

**Reading:** both TestRunner and RunTests programs; M00 test inventory;
`C:doc/design/testing-observability.md`, all sections;
`S:doc/verification/toolchain.md`, `The test suite`.

**Work:** create separate common/client/server/integration runners. Divide
all oversized tests and MockSocket by scenario or support responsibility.
Retain every test name or record its one-to-one replacement. A duplicate
common test is removed only after its inputs and assertions are accounted
for. Fix test fixture paths and use separate temporary directories. Do not
make a unit runner require live peers. Both source test sets exercise the
same common implementation. Test discovery fails on missing registration.

**Acceptance:** the test-accounting table has no unexplained loss; all unit
suites pass; no test Pascal file reaches 1000 lines; repeated runs leave no
live server, thread, open fixture handle, or stale output dependency.

### M09 — Tools and examples

**Owned paths:** examples, client/server tools, integration tool helpers,
and validation task definitions through the build owner.

**Reading:** source Makefile and Taskfile validation targets; tracked tools
inventory; both validation documents, all sections; client example README.

**Work:** preserve both tool trees under role directories. Recalculate each
script's root from its new location. Replace sibling `-Fu` paths with local
paths. Keep client observer example units as support units, not programs.
Preserve Docker contexts, harness inputs, expected-results files, and
external peer configurations. Generate PKI per run with separate paths.
Make each script wait for peer readiness and clean up only its own peers.

**Acceptance:** `task examples` compiles all intended programs. Every tool
resolves source, fixture, Docker, and output paths from a clean checkout.
No runtime/build dependency names `../http2client` or `../http2server`.
Historical provenance references are allowed in records.

### M10 — Public facades and packages

**Owned paths:** three facade units, package files and generated package
sources, API compile probes, and package manifests. Coordinate edits to
`Http2.Client` with the C04 owner after C04 is complete.

**Reading:** source package XML; source facade interfaces and facade tests;
M05/C04 public API records; `S:doc/design/public-api.md`, `The facade`.

**Work:** build `http2common`, `http2client`, and `http2server` packages.
Client and server depend on the common package, never on each other.
Common has no mORMot2 dependency. Keep JSON/XML readers in their optional
package. Every package version is 0.30.0 (XML 0/30/0/0). One unit belongs to
one defining package. Generated package Pascal sources meet header rules;
regeneration and the required header step are documented and checked.

Add compile probes for each facade alone, both roles together, shared
header assignment, common exception catches, factory helpers, enum
constants, generic readers, and qualified `IBodyWriter` use. Check
`IHttpClient`, `IHttp2Server`, and shared interface GUID identity. Match
package file counts to the actual unit inventory.

**Acceptance:** clean CLI builds and Lazarus package builds pass. A missing
Lazarus installation is a gap to resolve before this story passes. The
core client package does not load JSON/XML. Facades expose real usable APIs.

### M11 — Local integration

**Owned paths:** integration tests and results under generated output.

**Reading:** server tests under `test/mtls/` and `test/tls/`;
`S:doc/design/http1.md`, `Protocol selection` and `Known limits`;
both TLS/mTLS, SSE, and WebSocket documents; M09 tool map.

**Work:** move the existing server/client live TLS and mTLS tests into this
repository. Use local loopback peers and ephemeral ports where supported.
Add the cases in the validation matrix below. Exercise client and server
in one process as well as separate processes to expose type, initialization,
and OpenSSL global-state conflicts. Test shutdown, cancellation, and reuse.

**Acceptance:** local integration passes with deterministic deadlines and
cleanup. Required cases do not silently skip. Shared-code peer agreement is
not treated as independent protocol proof; M13 supplies that proof.

### M12 — Documents and references

**Owned paths:** root README and changelog, `doc/`, and documentation checks
through the build owner. License records stay under the provenance owner.

**Reading:** source documentation indexes and architecture documents;
`S:doc/references/README.md`; target documentation rules; all story handoffs.

**Work:** preserve client/server topic documents under role directories.
Write common architecture/protocol documents from the final code. Merge
build and validation instructions around the real command contract. Add
`doc/migration-0.30.0.md` with every unit rename, removed umbrella, API
qualification case, package change, and version decision. Retain historical
changelogs with clear source labels; do not describe 0.23.0 or 0.29.0 as
released merely because they appear in package metadata.

Copy server reference text verbatim; add required missing client references
with source URLs and actual retrieval dates. Verify copy hashes. Preserve
client compiler probes as evidence in a clearly named verification area;
exclude obsolete copied library implementations from active builds. Index
all maintained documents. Fix relative links, YAML links, old line-number
citations, and references after file moves. RFC citations give number,
rfc-editor URL, and actual check date. Do not invent a new retrieval date
for an unchanged reference copy.

**Acceptance:** `task docs:check` passes; each API and architecture statement
matches final source. Documents have declarative text, correct front matter,
and no plan links. Fresh validation evidence is separate from source history.

### M13 — External and platform verification

**Owned paths:** external validation records and defect reports.

**Reading:** both `doc/verification/validation.md` documents in full;
source harness scripts and expected-results files; server toolchain section
`Linux amd64 (deliberate gap)`; M11 results.

**Work:** run the preserved client and server external gates against
independent peers. Run the client harness alone because its source setup
uses host port 8080. Preserve its outcome classifications; zero WORSE rows
is required. Record UNKNOWN and CLASS-DIFF separately. Run server external
HTTP/2 checks, WebSocket checks, SSE checks, and the existing abuse/load
checks with their stated resource prerequisites.

Run clean unit, facade, package, and local integration builds on macOS
arm64 and Linux amd64 with the recorded compiler/dependencies. Record the
actual OpenSSL and external tool versions. A platform not run remains an
explicit gap and is not advertised as verified. Required release platforms
are these two targets; a gap keeps M13 open.

**Acceptance:** no new failure against M00; all mandatory cases pass.
Historical expected skips retain explicit reasons. Infrastructure failures
are separated from protocol failures. Results identify the exact merged
commit. Repeat only affected checks after a fix, then run the final required
set on the release candidate.

### M14 — Integration review

**Owned paths:** review record; fixes remain with their area owners.

**Reading:** all story evidence; source/target inventories; public API map;
license record; dependency and validation matrices.

**Work:** compare inventories with the final tree. Check shared type
identity, both thread models, settings directions, flow accounting,
optional Readers, all renamed paths, license notices, and version fields.
Review every deferred failure and skip. Confirm that source copied from
both projects has not lost a later fix. Confirm all baseline tests still
have coverage. Check a clean build without access to either sibling tree.

**Acceptance:** no unresolved required defect, dependency, license decision,
size violation, or validation gap. The review identifies a release candidate
commit and its exact evidence. This gate cannot pass on historical logs.

### M15 — Release preparation

**Owned paths:** release metadata, source-archive manifest, release notes,
and final evidence record.

**Reading:** M14 record, root `VERSION`, all package versions, changelog,
README version text, and final build instructions.

**Work:** set every current version to 0.30.0. Keep historical source release
numbers unchanged. Prepare the `0.30.0` changelog entry and release notes.
Build a source archive from tracked required inputs, with licenses,
references, tests, and setup pins. Unpack into a new directory without
sibling repositories. Run dependency setup and the documented build/test
commands there. Confirm that optional dependency setup is explicit.

**Acceptance:** all current version fields agree; the archive has no
absolute user paths, private keys, third-party checkout copies, or build
outputs; the fresh build passes. The intended release tag is `v0.30.0`.
Creating or publishing that tag is a later release action, not part of
writing this plan.

## Target command contract

The Task names below are planned. Make exposes equivalent targets with
hyphens in place of colons. A top-level command stops on a required failure.

| Command | Required behavior |
| --- | --- |
| `task setup:deps` | Fetch only revision-pinned build dependencies |
| `task build` | Build common, then client and server with isolated output |
| `task build:common`, `build:client`, `build:server` | Build one component and its declared dependencies |
| `task build:readers` | Build optional JSON/XML readers |
| `task test:common`, `test:client`, `test:server` | Run the respective unit suite and fail on missing registration |
| `task test` | Run all three unit suites in sequence |
| `task test:integration` | Run local integration after required peer setup |
| `task test:api` | Compile the facade, type-identity, and generic-reader probes |
| `task packages:check` | Build packages and check inventories and versions |
| `task source:check` | Check headers, sizes, unit names, and dependencies |
| `task docs:check` | Check documentation rules, links, index, and YAML |
| `task version:check` | Check current version agreement against `VERSION` |
| `task examples` | Compile client, server, and combined examples |
| `task validate:client:<gate>` | Preserve each original client validation gate |
| `task validate:server:<gate>` | Preserve each original server validation gate |
| `task validate:fast` | Run unit, API, local integration, and short external checks |
| `task validate` | Run all required gates in a documented safe sequence |

Client gate names retain `sanity`, `interop`, `harness`, `sse`, `proxy`,
`proxy:real`, `websocket`, `websocket:autobahn`, `cleartext`, `mtls`, and
`mtls-real` suffixes. Server gate names cover `conformance`, `fast`,
`tls-live`, `mtls-live`, `websocket`, `websocket:h2`, `sse`, and `abuse`.
M09 records the exact source script and arguments for every target. Server
load tools remain distinct from unit tests. The 10,000-connection check
records file-descriptor limits and resource requirements.

## Validation matrix

| Area | Required cases | Evidence owner |
| --- | --- | --- |
| Common headers/errors | Both source suites; shared interface and exception identity | M02, M10 |
| HPACK | RFC vectors; both property suites; separate directions; pending size changes; list limits; wire-order decode | M03, M06, M07 |
| Frames/settings | Partial input; malformed lengths; padding; CONTINUATION; omitted settings; role restrictions; extended CONNECT setting | M04, M06, M07 |
| Flow control | Connection/stream windows; negative stream window; overflow; zero update; DATA padding; no double charge | M04, M11 |
| HTTP/2 local | TLS ALPN h2; cleartext prior knowledge; concurrent streams; trailers; binary bodies; reset; GOAWAY and drain | M11 |
| HTTP/1 local | Enabled fallback; strict client rejection; keep-alive; chunked bodies; HEAD; early close | M11 |
| h2c upgrade | Original client exactly-once tests against its independent HTTP/1 fixture; no unsupported server h2c-upgrade promise | M09, M13 |
| TLS/mTLS | Valid, absent, expired, and untrusted identity; TLS ranges; separate origin/proxy identity; ALPN policy | C01, M11, M13 |
| Proxy | HTTP CONNECT, HTTPS proxy, SOCKS5; credentials; no-proxy; cancellation; direct path | C01, M13 |
| SSE | HTTP/2 and HTTP/1; UTF-8 splits; Last-Event-ID; reconnect; cancellation; back-pressure; coding rejection | C03, M11 |
| WebSocket | Client/server HTTP/1 ws/wss; mask direction; fragmentation; UTF-8; ping/pong; close; server RFC 8441 with independent peer | C03, M11, M13 |
| Runtime | Both roles in one process; repeated start/stop; reader cleanup; bounded queues; timeout and cancellation | M11 |
| Packaging | Each component alone; both roles; optional readers; clean archive; no sibling paths | M10, M15 |
| Conventions | Headers; valid YAML; fewer than 1000 Pascal lines; method review; declarative docs; reference hashes | M01, M12, M14 |

## Team handoff and recovery rules

The integration owner controls root build files, shared API changes, and
story order. An agent receives one story, its input commit, owned paths,
reading list, and acceptance commands. An agent does not expand its task to
change another layer without an integration decision.

Each story has a separate commit or reviewable patch. Import, rename,
structural division, and behavior correction are separate changes when
possible. A behavior correction includes a regression test and a reason.
The tests are not weakened merely to accept the merged implementation.

When a shared change breaks both roles, the common owner and integration
owner resolve the contract before either role adds a private protocol copy.
A failed story remains incomplete. Recovery uses its isolated change; it
does not reset another agent's work. Fixed-port external tests and package
output directories have one owner at a time.

The source repositories remain available as evidence until M15 passes.
Release completion requires every row in the dependency matrix. A partial
merge, a successful compile alone, or a passing client/server pair does not
satisfy the release checks.

## Source directory decision

The library units are under `src/common`, `src/client`, and `src/server`.
No library unit is directly under `src/`. Unit names retain the `Http2.Common`,
`Http2.Client`, and `Http2.Server` prefixes. Build paths, package inventories,
and source checks use these directories. This owner instruction supersedes
the earlier flat source layout. Tests and examples retain their role directories.
