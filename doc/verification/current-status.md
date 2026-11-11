---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: verification, status, integration
notes:
  - Results describe the merged tree and identify the limits of each run.
---

# Current verification status

This record describes results on macOS arm64 with Free Pascal 3.2.4 and
OpenSSL 3. It separates completed checks from runs without a final result.

## Completed checks

| Check | Result |
| --- | --- |
| Common unit suite | 229 passed. |
| API unit suite | 16 passed. |
| API compile probes | Six passed. The probes cover the common facade, client facade, server facade, combined facades, optional Readers, and connection-lifetime API. |
| In-process integration | Nine cases passed. The cases cover HTTP/2, HTTP/1.1, TLS, repeated start and stop, concurrency, SSE, and WebSocket. |
| Separate-process integration | HTTP and TLS checks passed. |
| Server TLS live gate | 21 checks passed. |
| Server mTLS live gate | 40 checks passed. The checks include client identity modes, HTTP/1.1, HTTP/2 WebSocket, and the leak counter. |
| Focused server factory suite | 27 passed. |
| Focused server TLS-context suite | 10 passed. |
| Source and package checks | 353 Pascal header and size checks, 337 active Pascal file checks, 135 production unit checks, 54 documentation checks, and 1,780 source test mappings passed. All four Lazarus packages passed. |

The integration cases use the merged client and server. They verify local
peer agreement. They do not establish independent protocol conformance.

## Unit suite coverage

The full server unit run reached its 60-second deadline. A progress sample
showed about 149 completed test cases after 45 seconds, including normal
time in a connection-age wait. This evidence does not prove a hang and does
not make the whole suite pass.

The default client runner passed 805 registered cases with no errors or
failures. Thirty-three environment-gated cases did not run: 10 proxy live
cases, 18 WebSocket live cases, two SSE live cases, one TLS integration case,
and two lifecycle integration cases. These cases require environment settings
or an external peer. The source accounting record contains 913 client and 867 server source test
records. Those source counts include cases that moved to common and API
suites; they are not the merged client runner total.

## Deferred checks

Linux builds, load checks, abuse checks, and independent external conformance
checks remain deferred. Their results are open. No Linux, load, abuse, or
external conformance pass is stated here.

The root `task validate:fast` target includes the bounded unit, API, local
integration, source, documentation, version, and package checks. The root
`task validate` target adds the explicit client and server gates. Some of
those gates use Docker, external peers, or load tools. The command contract
is in the [repository README](../../README.md).

## Linux container build

The server build context is `tools/server/container/Dockerfile`. From the
repository root, the build command is:

```sh
docker build --progress=plain -f tools/server/container/Dockerfile \
  -t http2components-amd64 .
```

The build was not run. Linux validation remains deferred.
