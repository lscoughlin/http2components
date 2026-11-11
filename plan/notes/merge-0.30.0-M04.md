# M04 common frames and flow control

## Implementation

`Http2.Common.Frames` uses the pinned server frame unit as its base. It retains the server client-preface helpers, SETTINGS delta decoder, SETTINGS_ENABLE_CONNECT_PROTOCOL field, and header-priority dependency helper. It restores the client `TFrame` receive metadata and initialization behavior, and the client `HeaderBlockOffset` helper. The frame reader and writer do not serialize the metadata fields.

`Http2.Common.FlowControl` uses the pinned server flow-control unit. It retains the server APIs for separate connection and stream consumption and for stream DATA sent accounting. Its dependency is `Http2.Common.Errors`.

Both original frame test sets and both original flow-control test sets are present under unique `ClientOrigin` and `ServerOrigin` unit and class names. The common runner also includes seven union regression tests for metadata defaults, SETTINGS delta behavior, preface comparison, header-block offset, and priority dependency.

## Verification

Direct FPC 3.2.4 macOS arm64 compile and bounded common suite:

- Command: `fpc -Fu./src -Fu./test/common -Fu/usr/local/lib/fpc/3.2.4/units/aarch64-darwin/fcl-fpcunit -FU./bin/common/units -FE./bin/common test/common/Http2.Common.RunTests.pas`
- Run: `bin/common/Http2.Common.RunTests --all --format=plain`
- Result: 229 tests, 0 errors, 0 failures, 0 ignored.
- The test run completed in 0.060 seconds.
- No mORMot, network tests, resource-intensive tests, or Linux tests were used.

Raw compiler and test output is available under `bin/common` and is ignored by Git.
