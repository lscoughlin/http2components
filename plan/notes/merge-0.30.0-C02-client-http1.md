# C02 client HTTP/1 body division

## Changes

The buffered HTTP/1 reader, framing enum, and streaming response body now live
in `Http2.Client.Http1.Body`. `Http2.Client.Http1` retains aliases for these
public types. Request construction, response parsing, and connection
management remain in `Http2.Client.Http1`.

Trailer parsing and chunk-size parsing follow the imported HTTP/1 rules. The
body unit owns the helpers needed by its streaming path. The source behavior
and public type identities remain unchanged through aliases.

## Validation

`build:client` passed on FPC 3.2.4 for macOS arm64 with pinned mORMot2 and
OpenSSL 3 paths. No HTTP/1 tests were run for this division. C02 remains open:
the connection, stream, and other connection-unit divisions and their tests
are still required.
