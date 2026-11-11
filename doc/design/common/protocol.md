---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, protocol, rfc
notes:
  - Protocol statements describe the approved target design.
  - Final source and test review is pending.
---

# Shared protocol design

## Specification basis

HTTP/2 is specified by [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html),
checked for this document on 2026-11-11. Header compression is specified by
[RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html), also checked on
2026-11-11. The reference index lists the plain-text copies and their
retrieval dates.

## Shared areas

The shared protocol implementation has five areas. Errors define the common
error codes and base exceptions. Headers define the shared header collection
and constants. HPACK encodes and decodes header blocks. Frames encode and
decode HTTP/2 frames and shared SETTINGS values. Flow control tracks
connection and stream credit.

Client and server connection code owns role-specific policy. A shared decoder
does not make client and server behavior identical. In particular, a peer's
header table setting changes the local encoder limit. The local advertised
limit controls the decoder. SETTINGS changes apply to stream windows, and
omitted values keep their prior state. Each DATA byte follows one accounting
path.

HTTP/2 error handling, directional HPACK settings, frame sequencing, and flow
control require independent tests in both roles. Final test evidence is not
part of this document. Resource-intensive and Linux checks remain deferred.

## Review status

The protocol ownership and directional rules follow the approved design.
The final merged call sequence and public signatures remain subject to source
review.

## RFC references

- [RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html), checked 2026-11-11.
- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html), checked 2026-11-11.
