# C01 client transport division

## Changes

The client TLS implementation is divided into contract and OpenSSL helpers,
plain sockets, TLS sockets, and tunnel operations. The original
`Http2.Client.Tls` unit is a facade with aliases and forwarding functions.
Proxy values and selectors, matching logic, and environment lookup now use
separate units. The original `Http2.Client.Proxy` unit retains its public
names through aliases and forwarding functions.

The division preserves the client interfaces, GUIDs, TLS policy, proxy
selection, and socket behavior. A helper creates the TLS layer for an HTTPS
proxy without exposing mutable TLS state. Existing SOCKS, identity, and
SIGPIPE units remain separate.

## Validation

`build:client` passed on FPC 3.2.4 for macOS arm64, with the pinned mORMot2
checkout and OpenSSL 3 library path. The compiler reported two existing
warnings in `Http2.Client.pas`: a hidden inherited `Dispatch` method and a
function result that may not be set.

The TLS, proxy, SOCKS, and identity unit tests remain owned by M08. They are
not recorded as passed here. All new TLS and proxy units have fewer than
1000 lines. The largest is `Http2.Client.Tls.Socket` at 994 lines.
