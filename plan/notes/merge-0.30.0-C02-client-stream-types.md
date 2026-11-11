# C02 client stream contract division

## Changes

Request and response body contracts, cancellation, request records, arrival
statistics, and stream-id allocation now live in `Http2.Client.Stream.Types`.
`Http2.Client.Stream` retains aliases for the existing public type names and
HTTP method enum values. The stream lease remains in `Http2.Client.Stream`.

The type moves preserve the existing GUIDs and enum values. `Http2.Client`
continues to compile its existing enum case statements through the aliases.

## Validation

The direct FPC client build passed on FPC 3.2.4 for macOS arm64, with both
`src` and `src/client` on the unit path and the pinned mORMot2 source paths.
The repository build driver does not yet include `src/client`; its owner has
the required layout update. No stream tests were run. C02 remains open.
