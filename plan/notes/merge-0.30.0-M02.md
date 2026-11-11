# M02 common errors and headers

The error codes and shared exception classes now live in
`Http2.Common.Errors`. `Http2.Client.Errors` and `Http2.Server.Errors` alias
the common classes, enum type, constants, and name function. Each role unit
defines only its own exception classes. The shared header map and constants
now live in `Http2.Common.Headers`; this copy retains `HeaderLastEventId`.

The common test runner uses only common production units. It runs the two
source header test sets and a common error test set under `test/common/`. The
role error tests and identity checks are under `test/api/`, outside the common
runner. The API runner retains both source error test sets. The server source
test checked two client-only exceptions because its old error unit duplicated
them; the target test qualifies these two classes through the client role unit.
The API identity test confirms that each common class and the enum type are
aliases of the same definitions.

The source plan asks to preserve the `IHttpHeaders` GUID. Neither fixed source
interface declares an explicit GUID. The target therefore preserves one
canonical interface declaration and does not add a new GUID. A facade
assignment probe remains part of M05.

The common and API test builds used Free Pascal 3.2.4 on macOS arm64 and
isolated compiler output under `bin/common/` and `bin/api/`. The common runner
passed 38 tests with 0 errors and 0 failures. The API runner passed 16 tests
with 0 errors and 0 failures. Raw build and test output is under the ignored
`bin/common/` and `bin/api/` directories. Neither build had a mORMot2 path.

The source reading covered client `doc/design/messages.md`, section
`Headers and header names`; server `doc/design/protocol.md`, section `Errors`;
and RFC 9113 sections 7 and 8.2. RFC 9113 was checked on 2026-11-11 at
<https://www.rfc-editor.org/rfc/rfc9113>. Section 7 defines the shared
32-bit error code space. Section 8.2 requires lowercase field names and
prohibits connection-specific fields, with `TE: trailers` as the exception.
The existing header map keeps its established rule: it rejects the five
connection-specific names and leaves `TE` handling to message validation.
