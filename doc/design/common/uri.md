---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: uri, rfc3986, parser, host, redirect
notes:
  - This document describes the one URI parser of the shared library.
scope: The URI record, the parser rules, the host rules, reference resolution and the origin helpers.
primary_types:
  - TURI
related_docs:
  - doc/design/common/protocol.md
  - doc/references/README.md
invariants:
  - One parser gives one host for the dial, the pool key, the Host header, the proxy match and the redirect check.
  - A backslash, a space, a control byte and a byte above 0x7E are always errors.
---

# URI parser

## Specification basis

URI syntax is specified by
[RFC 3986](https://www.rfc-editor.org/rfc/rfc3986.html), checked for this
document on 2026-11-13. The plain-text copy is `doc/references/rfc3986.txt`.

## Reason

Two parsers that read one string in different ways cause security faults. A
check can see one host while the connection goes to another host. The unit
`Http2.Common.Uri` holds the only parser. Its result is the single source of
the host for every later step.

## The record

`TURI` is an advanced record with read-only properties: `Scheme`, `UserInfo`,
`Host`, `Port`, `HasPort`, `Path`, `Query`, `Fragment`, `HasAuthority`,
`HasUserInfo`, `HasQuery`, `HasFragment`, `IsIPLiteral`, `Authority` and
`IsAbsolute`. `Port` is -1 when the URI has no port. `Authority` is the host,
in brackets for an IPv6 literal, and the port when present. It does not hold
the user information.

`ParseURI` parses an absolute URI or a relative reference. The empty string is
a valid relative reference. `ParseURI` raises `EHttpProtocolError` with the
code `ecProtocolError` when the text is not valid. The message never holds the
text. `TryParseURI` returns a Boolean.

## Parser rules

- The authority ends at the first `/`, `?` or `#`.
- The user information ends at the last `@` of the authority.
- A fragment can hold `@` and `/`. A fragment cannot hold a second `#`.
- The scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` and is returned in
  lower case. A first path segment of a relative reference cannot hold `:`.
- The port has digits only, from 0 to 65535. An empty port means no port.
- An IPv6 literal is in brackets and is checked as an IPv6 address. A zone
  identifier is an error. A future-version literal is an error.
- A percent sign must be followed by two hexadecimal digits.

## Rejected bytes

A backslash, a space, a control byte (0x00 to 0x20 and 0x7F) and a byte above
0x7E are errors. RFC 3986 does not allow them. Browsers read a backslash as a
slash. The library rejects it, so no parser disagrees without notice.

## Host normalization

The host is normalized once:

- The host is in lower case. An IPv6 literal has no brackets in `Host`.
- A percent-encoded unreserved character is decoded (RFC 3986 section 6.2.2.2).
  So `good%2Ecom` gives `good.com`. Any other percent-encoded byte in the host
  is an error.
- One trailing dot is removed.
- An empty host with an authority is an error for `http` and `https`.

## Reference resolution

`ResolveReference` follows RFC 3986 section 5.2 in the strict form, with the
dot-segment removal of section 5.2.4. The base must have a scheme.
`UriToString` follows section 5.3 and writes the normalized host.

## Origin helpers

- `SameHost` is True when both URIs have a host and the normalized hosts are
  equal.
- `SameOrigin` compares the scheme, the host and the effective port. The
  default port of `http` is 80 and the default port of `https` is 443.
- `IsHttpToHttpsUpgrade` is True when the hosts are the same, the base scheme
  is `http` and the target scheme is `https`.
