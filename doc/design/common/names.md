---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: header names, status codes, constants, HTTP fields, WebSocket handshake
notes:
  - The header names are constants in Http2.Common.Headers. Http2.Common repeats each one.
  - The status codes are constants in Http2.Common.Status. The unit holds no code.
  - RFC 9110 sections 5 and 15 were read in the plain-text copy doc/references/rfc9110.txt and checked on 2026-11-18 at https://www.rfc-editor.org/rfc/rfc9110.html.
  - RFC 9113 sections 8.2 and 8.2.2 (lower-case names and connection-specific fields) were read in the plain-text copy doc/references/rfc9113.txt and checked on 2026-11-18 at https://www.rfc-editor.org/rfc/rfc9113.html.
  - RFC 6585 (428, 429, 431 and 511) has the plain-text copy doc/references/rfc6585.txt. RFC 7725 (451) is cited by its number only.
  - RFC 6455 section 11.3 (the WebSocket handshake fields) was read in the plain-text copy doc/references/rfc6455.txt and checked on 2026-11-18 at https://www.rfc-editor.org/rfc/rfc6455.html.
scope: The header-name constants, the status-code constants, their spelling rules, and where each set is declared.
primary_types:
  - Http2.Common.Headers
  - Http2.Common.Status
related_docs:
  - protocol.md
  - cookies.md
  - ../client/messages.md
  - ../server/public-api.md
invariants:
  - A header-name constant is lower case, the HTTP/2 wire form, and it is a token.
  - A status-code constant has the name of its code in RFC 9110 section 15 and the number of that code.
  - A constant never changes its value.
---

# Header names and status codes

## Header names

`Http2.Common.Headers` declares the name of each common header field as a constant.
Every name is lower case, which is the HTTP/2 wire form (RFC 9113 section 8.2). The
header map is case-insensitive, so a program can use a constant for a lookup in the map
and for a field that it adds.

| Group | Constants |
| --- | --- |
| Pseudo-header fields | `HeaderMethod`, `HeaderPath`, `HeaderScheme`, `HeaderAuthority`, `HeaderStatus` |
| Content | `HeaderContentType`, `HeaderContentLength`, `HeaderContentEncoding`, `HeaderContentLanguage`, `HeaderContentDisposition`, `HeaderContentRange` |
| Negotiation | `HeaderAccept`, `HeaderAcceptEncoding`, `HeaderAcceptLanguage`, `HeaderAcceptRanges`, `HeaderVary` |
| Request | `HeaderHost`, `HeaderUserAgent`, `HeaderReferer`, `HeaderOrigin`, `HeaderAuthorization`, `HeaderCookie`, `HeaderRange`, `HeaderExpect`, `HeaderTe`, `HeaderLastEventId` |
| Conditions | `HeaderEtag`, `HeaderLastModified`, `HeaderIfMatch`, `HeaderIfNoneMatch`, `HeaderIfModifiedSince`, `HeaderIfUnmodifiedSince`, `HeaderIfRange` |
| Response | `HeaderLocation`, `HeaderSetCookie`, `HeaderCacheControl`, `HeaderServer`, `HeaderDate`, `HeaderAllow`, `HeaderRetryAfter` |
| Connection | `HeaderConnection`, `HeaderUpgrade`, `HeaderTransferEncoding` |
| WebSocket handshake | `HeaderSecWebSocketKey`, `HeaderSecWebSocketAccept`, `HeaderSecWebSocketVersion`, `HeaderSecWebSocketProtocol`, `HeaderSecWebSocketExtensions` |

The connection group names fields that HTTP/2 forbids on the wire (RFC 9113 section
8.2.2). The header map refuses to add them. The constants serve HTTP/1.1 code and the
WebSocket handshake, which runs over HTTP/1.1.

The unit `Http2.Common` repeats each name, so a program that uses `Http2.Common` needs no
second unit for a name.

## Status codes

`Http2.Common.Status` declares the status codes as integer constants. Each name is
`HttpStatus` followed by the name of the code in RFC 9110 section 15, for example
`HttpStatusOk` (200), `HttpStatusNotFound` (404) and `HttpStatusServiceUnavailable`
(503). The unit lists the codes of RFC 9110 section 15 and these others:

- 428, 429, 431 and 511 (RFC 6585);
- 451 (RFC 7725).

The unit does not list 418, because RFC 9110 reserves it.

The unit holds constants only. The reason phrase of an HTTP/1.1 status line is in the
server unit `Http2.Server.Http1.Status`.

```pascal
uses Http2.Common.Status;

AResponse.SendHeaders(HttpStatusNotFound, Headers, False);
```
