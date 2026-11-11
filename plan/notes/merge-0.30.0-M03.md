# M03 common HPACK

`Http2.Common.Hpack` starts from the server implementation at commit
`16e2003a9f31648005c5565d118bbd42acf935a8`. It keeps the common definitions
of `THttpHeaderField`, `THeaderBlock`, and `THpackCodec`. Its only production
dependency is `Http2.Common.Errors`. The server implementation contains the
directional encoder/decoder settings, pending size-update emission, and
header-list limit that the client copy does not contain.

The legacy `ApplySettings` call remains. It sets both encoder and decoder
table limits as the source method did. New role code uses `SetDecoderLimit`
for the local advertised limit and `SetEncoderCap` with `SetPeerTableSize`
for the response encoder limit.

Both source HPACK test sets remain in `test/common/` under distinct class and
unit names. Both fixed-seed property suites also remain. The new directional
tests check that peer settings do not change the decoder limit, that the
encoder uses the smaller cap, that a shrink followed by a growth emits both
updates in order, that zero-size updates are emitted, that the decoder rejects
an update above its local limit, that `ApplySettings` retains its old behavior,
and that the decoded header-list cap is active. The existing suites check
RFC 7541 vectors, integer errors, Huffman padding, sensitive fields, and
round-trip properties.

The direct common runner build used FPC 3.2.4 on macOS arm64. It used isolated
compiler output in `bin/common/` and no mORMot2 path. The suite passed 113
tests with 0 errors and 0 failures. Raw output is in
`bin/common/m03-test.raw.log`.

The source reading covered both HPACK units, both codec test units, both
property test units, the server HPACK connection calls, and the server
protocol design. RFC 7541 sections 2 through 7 and appendices A through C,
and RFC 9113 sections 4.3, 6.5.2, and 10.5.1, were checked on 2026-11-11.
The source links are [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541) and
[RFC 9113](https://www.rfc-editor.org/rfc/rfc9113). The checked rules keep the
encoder and decoder contexts independent, require at most two pending size
updates after multiple changes, define the field size as 32 plus name and
value octets, and make the peer's advertised table size a limit for its
decoder. The expected shrink-then-grow bytes follow those rules.
