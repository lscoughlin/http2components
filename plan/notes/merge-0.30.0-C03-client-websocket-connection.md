# C03 client WebSocket connection division

## Changes

The WebSocket opening handshake uses `Http2.Client.WebSocket.Connection.Open`.
The session end data and attempt interface use
`Http2.Client.WebSocket.Connection.Types`. Attempt end delivery uses
`Http2.Client.WebSocket.Connection.Observer`. The reader thread adapter uses
`Http2.Client.WebSocket.Connection.ReaderThread`. The connection facade retains
its public `OpenWebSocket`, `TWebSocketConnection`, and attempt type names.

The connection still owns its socket, listener demand, send serialization,
close state, reader loop, protocol dispatch, and resource lifetime. It uses the
HTTP/1.1 socket path for the WebSocket handshake. The reader thread retains the
connection until reader cleanup ends.

## Validation

`build:client` passed with FPC 3.2.4, the pinned mORMot2 checkout, and OpenSSL
3.5.9. `git diff --check` passed. The connection source is 995 lines. The
opening handshake, type contract, observer delivery, and reader thread units
have separate source files. WebSocket protocol codec ownership is recorded in
the standalone C03 source commit.
