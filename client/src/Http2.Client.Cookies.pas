{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, cookie, request, cookie header
notes:
  - This unit adds the cookies of a TParameters map to a client request.
  - The unit is separate, so the common cookie unit does not depend on the client.
---
}
/// Cookie helpers for client requests (RFC 6265 section 4.2)
// - WithCookies adds one cookie field to a request; the map gives the pairs
// - this unit is part of the http2client project and depends on Http2.Common.Cookie
unit Http2.Client.Cookies;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  Http2.Client.Request, Http2.Common.Parameters;

/// the request with one cookie field that holds every pair of ACookies
// - the pairs are written as 'name=value; name=value' (see CookieHeaderValue)
// - an empty map adds no field; the request is returned as it is
// - raises EBodyFormatError when a name or a value is not valid
// - a second call adds a second cookie field, which HTTP/2 allows (RFC 9113 section 8.2.3)
function WithCookies(const ARequest: THttpRequest; const ACookies: TParameters): THttpRequest;

implementation

uses
  SysUtils, Http2.Common.Headers, Http2.Common.Cookie;

function WithCookies(const ARequest: THttpRequest; const ACookies: TParameters): THttpRequest;
var
  LValue: string;
  LRequest: THttpRequest;
begin
  LValue := CookieHeaderValue(ACookies);
  LRequest := ARequest;
  if LValue = '' then
    Result := LRequest
  else
    Result := LRequest.WithHeader(HeaderCookie, LValue);
end;

end.
