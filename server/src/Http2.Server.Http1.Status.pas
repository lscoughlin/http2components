{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, status line, reason phrase
notes:
  - This unit holds the reason phrases of the HTTP/1.1 status line (RFC 9112
    section 4). A code that is not in the table gets an empty phrase, and the
    status line keeps the space after the code.
---
}
/// Reason phrases of the HTTP/1.1 status line
unit Http2.Server.Http1.Status;

{$mode delphi}{$H+}

interface

/// the reason phrase of AStatus, or an empty text for an unknown code
function Http1ReasonPhrase(const AStatus: Integer): string;

/// the status line with its CRLF, for example 'HTTP/1.1 200 OK'#13#10
// - an unknown code gives 'HTTP/1.1 299 '#13#10, with the space kept
function Http1StatusLine(const AStatus: Integer;
  const AMinor: Integer = 1): string;

implementation

uses
  SysUtils, Http2.Common.Status;

function Http1ReasonPhrase(const AStatus: Integer): string;
begin
  case AStatus of
    HttpStatusContinue: Result := 'Continue';
    HttpStatusSwitchingProtocols: Result := 'Switching Protocols';
    HttpStatusOk: Result := 'OK';
    HttpStatusCreated: Result := 'Created';
    HttpStatusAccepted: Result := 'Accepted';
    HttpStatusNonAuthoritativeInformation: Result := 'Non-Authoritative Information';
    HttpStatusNoContent: Result := 'No Content';
    HttpStatusResetContent: Result := 'Reset Content';
    HttpStatusPartialContent: Result := 'Partial Content';
    HttpStatusMultipleChoices: Result := 'Multiple Choices';
    HttpStatusMovedPermanently: Result := 'Moved Permanently';
    HttpStatusFound: Result := 'Found';
    HttpStatusSeeOther: Result := 'See Other';
    HttpStatusNotModified: Result := 'Not Modified';
    HttpStatusTemporaryRedirect: Result := 'Temporary Redirect';
    HttpStatusPermanentRedirect: Result := 'Permanent Redirect';
    HttpStatusBadRequest: Result := 'Bad Request';
    HttpStatusUnauthorized: Result := 'Unauthorized';
    HttpStatusForbidden: Result := 'Forbidden';
    HttpStatusNotFound: Result := 'Not Found';
    HttpStatusMethodNotAllowed: Result := 'Method Not Allowed';
    HttpStatusNotAcceptable: Result := 'Not Acceptable';
    HttpStatusRequestTimeout: Result := 'Request Timeout';
    HttpStatusConflict: Result := 'Conflict';
    HttpStatusGone: Result := 'Gone';
    HttpStatusLengthRequired: Result := 'Length Required';
    HttpStatusPreconditionFailed: Result := 'Precondition Failed';
    HttpStatusContentTooLarge: Result := 'Content Too Large';
    HttpStatusUriTooLong: Result := 'URI Too Long';
    HttpStatusUnsupportedMediaType: Result := 'Unsupported Media Type';
    HttpStatusRangeNotSatisfiable: Result := 'Range Not Satisfiable';
    HttpStatusExpectationFailed: Result := 'Expectation Failed';
    HttpStatusUpgradeRequired: Result := 'Upgrade Required';
    HttpStatusTooManyRequests: Result := 'Too Many Requests';
    HttpStatusRequestHeaderFieldsTooLarge: Result := 'Request Header Fields Too Large';
    HttpStatusInternalServerError: Result := 'Internal Server Error';
    HttpStatusNotImplemented: Result := 'Not Implemented';
    HttpStatusBadGateway: Result := 'Bad Gateway';
    HttpStatusServiceUnavailable: Result := 'Service Unavailable';
    HttpStatusGatewayTimeout: Result := 'Gateway Timeout';
    HttpStatusHttpVersionNotSupported: Result := 'HTTP Version Not Supported';
  else
    Result := '';
  end;
end;

function Http1StatusLine(const AStatus, AMinor: Integer): string;
begin
  Result := 'HTTP/1.' + IntToStr(AMinor) + ' ' + IntToStr(AStatus) + ' ' +
    Http1ReasonPhrase(AStatus) + #13#10;
end;

end.
