# M07 server import

## Source and reading

The input is the clean server source at commit `16e2003a9f31648005c5565d118bbd42acf935a8`. The source checkout stayed unchanged. The M07 file inventory records the source path, Git blob, SHA-256, target path, and disposition for each server Pascal file. It also records the M09 test helper path.

The reading covered the server architecture layers and thread model, the lock and wait rules, connection behavior, and the public facade. The import keeps the established separation: IO threads own protocol and HPACK work; handler threads run synchronous application code; cancel workers run cancel hooks. The seam carries bytes and does not transfer protocol parsing to handler code. The existing lock order, queue bounds, cancellation, and shutdown paths remain unchanged.

The M05 API handoff supplies one shared implementation for frames, headers, HPACK, flow control, and base errors. The server uses the directional HPACK operations. The server facade aliases those shared types and retains distinct server error types and the server `IBodyWriter` contract. The shared interface `IHttpHeaders` keeps one identity and has no explicit GUID.

## Import and disposition

M07 imported 71 server-owned units and the `Http2.Server` facade. The server runtime is `Http2.Server.Runtime`. Server WebSocket units use the `WebSocket` namespace. Shared protocol units remain in `Http2.Common.*`; M07 did not copy those implementations. The source error unit remains in the M02 role-error implementation.

The pinned production units are unchanged apart from unit names and the target license header. The facade import retains the source aliases and forwarding methods. Its final public API review remains in M10.

The test runner registers 75 suites and 754 server cases. The case inventory maps all 867 source registrations:

- 105 shared primitive cases move to the existing common suites: 32 frame, 24 HPACK, 10 HPACK property, 23 flow-control, and 16 header cases.
- Six base error cases move to the existing API server-error suite. That suite also checks cross-role type identity and does not create a server-to-client unit dependency.
- The pure TLS protocol-range case stays in the server suite as `TTlsProtocolMappingTest`.
- Two live TLS handshake cases stay under `test/integration/server` for M11.
- The remaining 754 cases retain their source test names and run from the server runner.

The `.pas.pending` integration files hold client-dependent live source until the client units are available in the integration tree. The M07 server runner has no client-unit imports. The mTLS config and context cases use the M09 certificate generator at `tools/server/certs/make_mtls_pki.sh`; the generator writes test keys and certificates to a temporary directory. M07 does not own that tool.

## Verification

`source:check` passed. It checked 181 Pascal headers and sizes, 169 active Pascal files, 80 production units, and 165 unit declarations. No server production or server test unit has a client dependency.

`build:server` passed with Free Pascal 3.2.4 on macOS arm64 and the pinned mORMot2 checkout under the integration worktree. The build used `OPENSSL_LIBPATH=/opt/homebrew/opt/openssl@3/lib`. The compiler emitted existing mORMot, server, and test warnings; it produced the server facade and runner.

The bounded server checks passed 183 cases across these suites: `TFactoryTest`, `TAlpnSelectTest`, `TTlsPolicyTest`, `TTlsProtocolMappingTest`, `TMoreConfigTest`, `TConnectionCoreTest`, `TConnectionFlowTest`, `TConnectionLifetimeTest`, `TStreamTimeoutsTest`, `TH2HpackTest`, `THttp1ConfigTest`, `TLicenceTest`, `TServerProtocolTest`, `TFacadeTest`, `THttp1HeadTest`, `TMtlsConfigTest`, and `TMtlsContextTest`. Each suite reported zero errors and zero failures.

The first mTLS configuration run found the M09 certificate generator at its pre-merge source path. The test now names its target path, and all 11 config cases pass. The 10 context cases also pass. The test-support script is not included in the M07 commit.

The full 754-case server run was not started. The M00 baseline full run did not complete and recorded two cancellation failures in its partial output. Parent instructions require bounded checks and no repeated full baseline run. Live TLS integration, load tests, Linux checks, and external sweeps remain deferred. No deferred check is reported as passing.
