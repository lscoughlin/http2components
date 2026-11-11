# M12 final documentation and source provenance

## Inputs

The M12 scope, documentation rules, reference index, client and server design
records, and current merged build files were reviewed. The two source
repositories were read at the pinned commits:

- Client: `709336f542cbedf9ce1ab67d83bddcfd560eb1c0`.
- Server: `16e2003a9f31648005c5565d118bbd42acf935a8`.

Both original repositories remain unchanged. Their pinned source hashes match
all 440 rows in `LICENSES/source-provenance.tsv`: 196 client rows and 244
server rows. Twenty-five rows have `not-retained` targets with explicit
dispositions. These rows record compiled probe outputs, agent workflow files,
a duplicate obsolete source unit, a source plan pointer, and an unused static
analysis config. The remaining paths resolve to files in the merged tree or
the retained server container context.

The inventory keeps both original source license names and source notices.
The project license choice is `Apache-2.0 OR (LGPL-2.1-only WITH
Independent-modules-exception)`. The user authorized dual licensing for all
project code and confirmed copyright ownership. RFC and other specification
copies keep their source terms.

## Documentation state

The root README and changelog describe the merged 0.30.0 tree. The README
lists the three public entry units, optional Readers package, build commands,
verification results, and deferred checks. The migration table maps all 102
source production units. It includes client API, pool, connection, stream,
transport, and WebSocket helper splits. The documentation index links the
design, history, references, and verification records.

The design pages use the merged `src/common`, `src/client`, and `src/server`
paths and the target unit namespaces. The common protocol page cites RFC 7541
and RFC 9113 with rfc-editor URLs and check dates. The reference index lists
RFC 1928 and RFC 1929 with their rfc-editor URLs, retrieval dates, and hashes.
The server Dockerfile and both ignore files are under
`tools/server/container/`. Its documented root-context command is:

```sh
docker build --progress=plain -f tools/server/container/Dockerfile \
  -t http2components-amd64 .
```

The container build was not run. Linux validation remains deferred.

## Current evidence

The parent reports these final checks:

- Common suite: 229 passed.
- API suite: 16 passed; six compile probes passed.
- In-process integration: nine cases passed; separate-process HTTP and TLS
  checks passed.
- Default client runner: 805 registered cases passed with no errors or
  failures. Thirty-three environment-gated proxy, WebSocket, SSE, TLS, and
  lifecycle cases did not run.
- Server TLS live gate: 21 passed; server mTLS live gate: 40 passed.
- Source check: 353 Pascal header and size checks, 337 active Pascal files,
  135 production units, 53 docs, and 1,780 exact source test records passed.
- Four Lazarus package checks passed.

The full server suite reached its 60-second command deadline and has no
completed result. A progress sample showed normal test progress; it does not
prove a hang or a pass. Linux, load, abuse, and external conformance runs are
deferred. Parent validation logs are in `bin/review-*` in the final
integration checkout.
