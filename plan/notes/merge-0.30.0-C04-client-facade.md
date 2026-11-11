# C04 client facade division

The client facade now delegates to request, factory, socket factory, pool,
response, URL, upgrade, body reader, and attempt observer units. All library
files are in `src/client/`. The original facade names remain aliases or
forwarding functions. The generic response reader remains in the facade
because FPC does not support the required generic alias syntax.

The pool state base owns membership, limits, counters, and lifetime. The
concrete pool owns transport selection and acquisition. Constructor and
public state methods are inherited. SSE depends on the client contracts and
body reader directly, so it does not depend on the facade.

Review compared all 207 original implementation routines with their new
owners. Every routine body, including its comments, is byte-identical after
the pool class owner changes from TConnectionPool to TPoolState. The facade
adds forwarding functions and useful aliases for request and body types.

On macOS aarch64 with FPC 3.2.4 and OpenSSL 3, the client build passes,
16 API tests and five facade probes pass, and all five local HTTP integration
cases pass. Logs are in `bin/review-c04-{build,api,integration}.log` in the
integration worktree. Source checks report no C04 size or dependency defect.
Other client source splits and stale test imports remain separate work.
No Linux, load, or external conformance validation was run.
