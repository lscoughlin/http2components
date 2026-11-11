# M14 documentation, provenance, and C04 review

## Provenance and documentation review

The source provenance inventory has 440 entries: 196 client entries and 244
server entries. Hashes were recomputed from `git show` bytes at the two pinned
source commits, including the server symlink blob. All 440 hashes match. Each
retained target path resolves in the final merged tree or in the retained
server container context. Twenty-five non-retained rows state why the source
input is absent. The source-to-target map preserves all 913 client and 867
server source test records through the 1,780-record exact accounting check.

The root README and changelog state 0.30.0 as the merged source tree and do
not claim a published release. The docs use the merged namespace and source
layout. The README gives the full names and SPDX expression for the authorized
dual license. The source history and reference copies retain their source
terms. The reference index records the RFC Editor URLs and retrieval dates.

The server Dockerfile and Docker ignore files are retained under
`tools/server/container/`. The root-context command is in the verification
record. The Docker build was not run, and Linux validation remains deferred.

## C04 public API review

The public client API keeps the existing interface identities. `IHttpHeaders`
has no explicit GUID in either pinned source, so the merged API does not add
one. Parent source review found 207 C04 routine bodies byte-identical to the
source bodies. No new behavior defect was found in those moved bodies.

Two inherited lifetime/type limits remain documented:

1. `THttpResponse` owns the lease and connection references. `TGuardedBody`
   holds weak references. A caller retains `IHttpResponse` while reading its
   `Body`; the body interface alone does not own the lease or connection.
2. `TResponseReader<T>` supports byte-string values, `TBytes`, and unmanaged
   fixed-size values. Other managed values and dynamic arrays are not
   supported by its current raw-copy implementation.

These limits are not new split defects. Follow-up work should add response
and body lifetime tests for HTTP/2 and HTTP/1.1, including response release
while a body reference remains. Reader tests should cover every supported
value category and make unsupported managed values explicit. This merge
makes no behavior change for these limits.

## Validation record

The parent reports passing common, API, facade, default client runner,
integration, source, documentation, and package checks. The default client
runner passed 805 registered cases. Thirty-three environment-gated client
cases did not run. Server TLS and mTLS live gates
passed 21 and 40 checks. The full server unit suite has no completed result;
its bounded command ended at 60 seconds while tests continued to make normal
progress. Linux, load, abuse, and independent external conformance remain
deferred. These gates are not represented as passing.
