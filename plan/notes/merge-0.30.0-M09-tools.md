# M09 tool and example preparation

## Tool paths and process handling

The client tools use `tools/client` source and fixture paths. The server tools
use `tools/server` paths. The remote client Docker context is
`tools/client/container`. No tool has a runtime or build dependency on a sibling
`http2client` or `http2server` checkout.

The client mTLS live gates create certificates under a unique run directory.
The server TLS gate creates its certificate under a temporary run directory.
The server mTLS generator accepts an output directory, and the integration
runner uses a separate directory for each run. Docker container names include
the process ID. Server validation cleanup stops only the server processes that
its helper starts. The server runner has separate `conformance`, `fast`,
`tls-live`, `websocket`, `websocket:h2`, `sse`, and `abuse` modes.

The WebSocket TLS protocol unit test keeps only the two live handshake cases.
Its pure protocol mapping case stays in the bounded server suite. The M07 TLS
and mTLS integration programs are active Pascal files with the target client
namespaces.

## Gate dispatch

- Client sanity: `tools/client/validate/h2probe-sanity.sh`.
- Client interop: `tools/client/validate/interop.sh`.
- Client harness: `tools/client/validate/harness.sh`.
- Client SSE: `tools/client/validate/sse-live.sh`.
- Client proxy: `tools/client/validate/proxy-live.sh`.
- Client proxy real: `tools/client/validate/proxy-real.sh`.
- Client WebSocket: `tools/client/validate/websocket-live.sh live`.
- Client WebSocket Autobahn: `tools/client/validate/websocket-live.sh autobahn`.
- Client cleartext: `tools/client/validate/cleartext-live.sh`.
- Client mTLS: `tools/client/validate/mtls-live.sh`.
- Client mTLS real: `tools/client/validate/mtls-real.sh`.
- Server conformance: `tools/server/validate/run.sh conformance`.
- Server fast: `tools/server/validate/run.sh fast`.
- Server TLS live: `tools/server/validate/run.sh tls-live`.
- Server mTLS live: the integration program and the M09 PKI generator.
- Server WebSocket: `tools/server/validate/run.sh websocket`.
- Server WebSocket over HTTP/2: `tools/server/validate/run.sh websocket:h2`.
- Server SSE: `tools/server/validate/run.sh sse`.
- Server abuse: `tools/server/validate/run.sh abuse`.

The client real-proxy script owns its build container. The root driver calls
that script once. It does not call the script's internal `--build` mode on the
host.

The client live runners default to the role-specific client test output path
and accept `BIN` as an override. The server validation runner defaults to the
role-specific server examples output path and accepts `SERVER_BIN` as an
override. The client probe scripts include `test/client` when they compile
`h2probe.pas`, because that unit uses `Http2.Client.ProbeOutcome`.

The real-proxy runner writes each run's result table and diagnostic logs below
`bin/<target>/<profile>/validation/`. It captures logs from its three owned
containers before it removes them. It removes the temporary run directory,
which contains generated private keys and build outputs. Missing tools remain
optional skips in full conformance. A missing required tool or package in a
specific server gate produces a failure.

The shared build driver maps each client and server validation target to its
role script. Server script runs receive `SERVER_BIN` for the server example
output directory. The TLS and mTLS server targets compile and run their
dedicated integration programs with a private PKI directory. `validate:fast`
runs the bounded unit, API, and local integration suites, then the source,
documentation, version, and package checks. `validate` adds every explicit
client and server validation gate after the fast checks.

## Checks

All shell scripts pass syntax checks with their declared shells. All Python
tool files parse. `git diff --check` passes.

`MORMOT=/Users/liamcoughlin/Source/lscoughlin/.http2components-worktrees/integration/third_party/mORMot2/src OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib python3 tools/build.py examples` compiled all client and server example programs after the role source layout merge. The command did not run the programs. Its captured output is at `/tmp/m09-examples-final2.log` on the build host.

The four client validation Pascal programs `h2probe.pas`, `autobahn_client.pas`, `cleartext_probe.pas`, and `proxy_real_client.pas` compiled with `src/common`, `src/client`, and `src/server` paths. The active server TLS and mTLS integration programs also compiled with those role paths and the test integration directories on the compiler path. No live, Docker, load, external, or Linux gate ran.

The source checker reports 13 existing client files above the line limit and the client SSE implementation importing the facade. The active integration files have no unresolved project-unit names. These are client source issues, not M09 paths.
