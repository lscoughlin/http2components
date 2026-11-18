---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: cookie, Set-Cookie, Cookie header, THttpCookie, TParameters, SameSite, Partitioned, HTTP-date, IMF-fixdate
notes:
  - RFC 6265 was checked on 2026-11-18 at https://www.rfc-editor.org/rfc/rfc6265.html. The document has no plain-text copy in doc/references/.
  - RFC 9110 section 5.6.7 was checked on 2026-11-18 at https://www.rfc-editor.org/rfc/rfc9110.html. The plain-text copy is doc/references/rfc9110.txt.
  - RFC 9113 section 8.2.3 was checked on 2026-11-18 at https://www.rfc-editor.org/rfc/rfc9113.html. The plain-text copy is doc/references/rfc9113.txt.
  - The RFC 6265bis draft (draft-ietf-httpbis-rfc6265bis) was checked on 2026-11-18 at https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/. The datatracker shows the draft as expired.
  - The CHIPS draft (draft-cutler-httpbis-partitioned-cookies-01) defines Partitioned. It was checked on 2026-11-18 at https://datatracker.ietf.org/doc/draft-cutler-httpbis-partitioned-cookies/. The datatracker shows the draft as expired.
scope: The cookie record THttpCookie, the helpers that read and write cookie fields, the record TParameters that holds the cookie pairs, and the client helper WithCookies.
primary_types:
  - THttpCookie
  - TSameSite
  - TParameters
  - IParameterMap
related_docs:
  - body.md
  - architecture.md
  - ../client/messages.md
  - ../server/public-api.md
invariants:
  - A cookie name is an RFC 9110 token. A cookie value holds only cookie-octets of RFC 6265 section 4.1.1.
  - A name or a value with a forbidden octet raises EBodyFormatError when the cookie is made, changed or written.
  - TParameters compares names case-sensitively.
  - TParameters keeps the insertion order of the names and of the values of one name.
  - A copy of a TParameters record shares its map. Copy gives a record with its own map.
  - ToString writes the Expires attribute as an IMF-fixdate in UTC.
  - Parse ignores an attribute whose value it does not understand.
---

# Cookies

## Purpose

The library reads and writes cookies in two places. A `Set-Cookie` field sends a
cookie from a server to a client. A `Cookie` field sends the cookies of a client
to a server. The types of this document are in `common`, so the client and the
server use the same routines. The units are:

| Unit | Holds |
| --- | --- |
| `Http2.Common.Cookie` | `THttpCookie`, `TSameSite`, the date helpers, and the helpers of the cookie fields |
| `Http2.Common.Parameters` | `TParameters` and `IParameterMap` |
| `Http2.Client.Cookies` | `WithCookies`, which adds a `cookie` field to a client request |

The unit `Http2.Common.Cookie` depends on `Http2.Common.Body` for the exception
`EBodyFormatError`, and on `Http2.Common.Headers` for `IHttpHeaders`.

## The cookie record

`THttpCookie` is an advanced record. It holds one `Set-Cookie` value: a name, a
value and the attributes of RFC 6265 section 4.1.1.

`Parse` reads a `Set-Cookie` value. `TryParse` gives the same result without an
exception. `Create` makes a cookie that has a name and a value and no attribute.
`ToString` gives the `Set-Cookie` value of the cookie.

Each property is read-only. Each `With` method gives a new record, and the record
on which the method is called does not change. The methods are `WithName`,
`WithValue`, `WithExpires`, `WithoutExpires`, `WithMaxAge`, `WithoutMaxAge`,
`WithDomain`, `WithPath`, `WithSecure`, `WithHttpOnly`, `WithSameSite` and
`WithPartitioned`. A call of a `With` method can be chained with another call.

| Property | Attribute | Type | Rule |
| --- | --- | --- | --- |
| `Name` | name of the pair | `string` | RFC 9110 token, not empty |
| `Value` | value of the pair | `string` | cookie-octets only |
| `HasExpires`, `Expires` | `Expires` | `Boolean`, `TDateTime` | UTC; the text is an HTTP-date |
| `HasMaxAge`, `MaxAge` | `Max-Age` | `Boolean`, `Int64` | seconds; zero and negative values are kept |
| `Domain` | `Domain` | `string` | kept as written; the empty text means no attribute |
| `Path` | `Path` | `string` | kept as written; the empty text means no attribute |
| `Secure` | `Secure` | `Boolean` | flag |
| `HttpOnly` | `HttpOnly` | `Boolean` | flag |
| `SameSite` | `SameSite` | `TSameSite` | `ssUnset` means no attribute; `ssNone`, `ssLax` and `ssStrict` write `None`, `Lax` and `Strict` |
| `Partitioned` | `Partitioned` | `Boolean` | flag from the CHIPS draft |

`Domain` and `Path` have no normalization. The library does not remove a leading
dot from a domain, and it does not add a leading slash to a path. A user agent
does that when it stores the cookie (RFC 6265 section 5.2.3 and section 5.2.4).

### Parse

`Parse` splits the value at each `;`. The first part is the pair. The text before
the first `=` is the name, and the text after it is the value. The name and the
value lose their leading and trailing white space. A value with quotes loses the
two quotes. A value may hold `=`, for example `token=a=b=c` has the value `a=b=c`.

Each later part is an attribute. An attribute name is matched without regard to
case, so `max-age`, `Max-Age` and `MAX-AGE` are the same attribute. The parser
reads these attributes:

- `Expires` takes an HTTP-date of section 5.6.7 of RFC 9110. It is read in any of
  the three formats.
- `Max-Age` takes an optional `-` and up to 18 digits. Any other text is ignored.
- `Domain` and `Path` take the text after the `=`. An empty text is ignored.
- `Secure`, `HttpOnly` and `Partitioned` are flags. The presence of the name sets
  the flag, and the value is not read.
- `SameSite` takes `Strict`, `Lax` or `None`, without regard to case. Any other
  text is ignored, so the attribute stays `ssUnset`.

An attribute with a name that the parser does not know is ignored. This rule
follows the user agent processing of RFC 6265 section 5.2. An `Expires` that is
not an HTTP-date and a `Max-Age` that is not a number are ignored in the same way.

`Parse` raises `EBodyFormatError` when the value has no `=`, when the name is empty
or is not a token, or when the value holds a forbidden octet. `TryParse` returns
False in these cases.

## Names and values

A cookie name is an RFC 9110 token (section 5.6.2). A name with a space, a control
octet, `;`, `,`, `"`, `=` or another octet outside the token set is refused.

A cookie value holds the cookie-octets of RFC 6265 section 4.1.1. These octets are
`%x21`, `%x23-2B`, `%x2D-3A`, `%x3C-5B` and `%x5D-7E`. The octets that are refused
are the control octets, the space, `"`, `,`, `;` and `\`. The `=` is allowed in a
value.

The text of a `Domain` or a `Path` attribute holds no control octet, no space and
no `;`.

## Dates

`FormatHttpDate` writes the IMF-fixdate of RFC 9110 section 5.6.7, for example
`Sun, 06 Nov 1994 08:49:37 GMT`. The text has 29 octets. The unit writes every
`Expires` attribute in this format, as RFC 9110 requires for a sender.

`TryParseHttpDate` reads the three formats of RFC 9110 section 5.6.7:

- the IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`;
- the RFC 850 format, `Sunday, 06-Nov-94 08:49:37 GMT`;
- the asctime format, `Sun Nov  6 08:49:37 1994`.

A two-digit year follows RFC 6265 section 5.1.1. The years 70 to 99 are read as
1970 to 1999, and the years 0 to 69 are read as 2000 to 2069. The day name is not
checked. The function refuses a day that the month does not have, a zone other
than `GMT` in the two formats that have one, and a second of 60. A leap second
is refused because the date type has no representation for it.

## Errors

The unit raises `EBodyFormatError`, which is declared in `Http2.Common.Body`. The
exception is raised in these cases:

| Routine | Case |
| --- | --- |
| `THttpCookie.Create`, `WithName` | a name is empty or is not a token |
| `THttpCookie.Create`, `WithValue` | a value holds a forbidden octet |
| `THttpCookie.Parse` | no `=`, an empty or invalid name, a forbidden octet in the value |
| `THttpCookie.ToString` | the name, the value, the domain or the path is not valid |
| `WithDomain`, `WithPath` | the text holds a control octet, a space or `;` |
| `GetSetCookies` | a `set-cookie` field does not parse |
| `CookieHeaderValue` | a name or a value of the map is not valid |
| `WithCookies` (client) | the same cause as `CookieHeaderValue` |

The reading helpers of a `cookie` field do not raise. `ParseCookies` and
`GetCookies` skip a pair without `=` and a pair with an empty name. They keep any
other text as it is, because a received `Cookie` field is not checked by the
receiving side.

`TryParse` returns False where `Parse` raises.

## TParameters

`TParameters` is a case-sensitive map of a name to a list of values. It holds
the pairs of a `Cookie` field, and it is a general map that another format can
also use. The map does not parse or format text.

- A name is case-sensitive. `a` and `A` are two names.
- The names keep their insertion order. The values of one name keep their
  insertion order too.
- `Add` appends a value. A new name is added at the end of the names.
- `SetValue` replaces the values of a name with one value.
- `Remove` deletes a name and its values. `Clear` deletes every name.
- `Contains`, `GetFirst`, `GetValues`, `Names` and `Count` read the map.
- `Items[AName]` is the default property. It gives the values of `AName`.
- The write methods return the record, so calls can be chained:
  `P.Add('a', '1').Add('b', '2')`.

### The map and the sharing rule

The record refers to one counted map object. The map is created at the first call
of a write method, and it is freed when the last record that refers to it goes out
of scope. A record that has never been written has no map. Its read methods give
empty results, and its `Count` is 0.

A copy of the record shares the map. A write to one copy shows in every other copy
that refers to the same map. The record copy happens on assignment, when a record
is passed by value, and when a method returns it:

```pascal
P := TParameters.Create;
P.Add('a', '1');
Q := P;              // Q shares the map of P
Q.Add('b', '2');     // P.Contains('b') is now True
```

`Copy` makes a new record with its own map. The new map holds the same names and
the same values in the same order. A later write to the copy does not show in the
original, and a later write to the original does not show in the copy.

```pascal
Q := P.Copy;         // Q has its own map
Q.Add('c', '3');     // P.Contains('c') is still False
```

A copy that is taken before the first write shares no map. The first write to the
copy creates a map for the copy alone.

A record is not thread safe. One thread writes to one map at a time.

## Helpers for the cookie fields

| Routine | Meaning |
| --- | --- |
| `ParseCookies(AValue)` | parses one `Cookie` field value (`a=1; b=2; a=3`) into a `TParameters` in order |
| `GetCookies(AHeaders)` | reads every `cookie` field of an `IHttpHeaders` and merges the pairs into one map |
| `GetSetCookies(AHeaders)` | parses each `set-cookie` field into a `THttpCookie`, in field order |
| `CookieHeaderValue(ACookies)` | joins the pairs of a map into one `cookie` value, for example `a=1; a=3; b=2` |
| `AddSetCookie(AHeaders, ACookie)` | adds one `set-cookie` field with the value of `ACookie.ToString` |

HTTP/2 can send more than one `cookie` field. RFC 9113 section 8.2.3 allows the
split, and it says that the fields are joined with `; ` before a non-HTTP/2
context. `GetCookies` reads the pairs of every field, so a map has the pairs of
all fields in order. `CookieHeaderValue` gives the joined form.

A `set-cookie` field is never joined. RFC 9110 section 5.3 says that a Set-Cookie
field cannot be combined into one field value, so each field is one cookie.

`WithCookies` in `Http2.Client.Cookies` adds one `cookie` field to a client request.
It uses `CookieHeaderValue`. An empty map adds no field. A second call adds a second
field, which is allowed.

## Memory and identity

`THttpCookie` holds only strings, numbers and flags. Copies of the record are
independent. `TParameters` is the only cookie type that holds a shared object, as
described in the sharing rule.

## RFC references

- RFC 6265, Cookies: HTTP State Management Mechanism. Section 4.1.1 gives the
  Set-Cookie grammar. Section 5.1.1 gives the two-digit year rule. Section 5.2 gives
  the user agent rules for the attributes. The document was checked on 2026-11-18 at
  https://www.rfc-editor.org/rfc/rfc6265.html.
- RFC 9110, HTTP Semantics. Section 5.3 says that Set-Cookie cannot be combined.
  Section 5.6.2 gives the token. Section 5.6.7 gives the HTTP-date formats. The plain-text copy is `doc/references/rfc9110.txt`, which was
  read on 2026-11-18. The RFC Editor URL is https://www.rfc-editor.org/rfc/rfc9110.html.
- RFC 9113, HTTP/2. Section 8.2.3 allows a `cookie` field to be split. The
  plain-text copy is `doc/references/rfc9113.txt`, which was read on 2026-11-18. The
  RFC Editor URL is https://www.rfc-editor.org/rfc/rfc9113.html.
- draft-ietf-httpbis-rfc6265bis, Cookies: HTTP State Management Mechanism. The draft
  gives the SameSite values `Strict`, `Lax` and `None`. The datatracker page was read
  on 2026-11-18 at https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/.
  The datatracker shows the draft as expired.
- draft-cutler-httpbis-partitioned-cookies-01, Cookies Having Independent Partitioned
  State. The draft defines the Partitioned attribute. The datatracker page was read on
  2026-11-18 at https://datatracker.ietf.org/doc/draft-cutler-httpbis-partitioned-cookies/.
  The datatracker shows the draft as expired. The RFC 6265bis draft does not define
  the attribute.
