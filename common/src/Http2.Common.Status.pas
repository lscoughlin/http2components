{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http, status code, constants
notes:
  - This unit names the HTTP status codes. It holds constants and no code.
  - The codes and their names come from RFC 9110 section 15 and the registry of HTTP status codes. 418 is not listed, because RFC 9110 reserves it.
  - 428, 429 and 431 come from RFC 6585. 451 comes from RFC 7725. 511 comes from RFC 6585.
---
}
/// the HTTP status codes as named constants (RFC 9110 section 15)
unit Http2.Common.Status;

{$mode delphi}{$H+}

interface

const
  // 1xx informational (RFC 9110 section 15.2)
  HttpStatusContinue = 100;
  HttpStatusSwitchingProtocols = 101;
  HttpStatusEarlyHints = 103;

  // 2xx successful (RFC 9110 section 15.3)
  HttpStatusOk = 200;
  HttpStatusCreated = 201;
  HttpStatusAccepted = 202;
  HttpStatusNonAuthoritativeInformation = 203;
  HttpStatusNoContent = 204;
  HttpStatusResetContent = 205;
  HttpStatusPartialContent = 206;

  // 3xx redirection (RFC 9110 section 15.4)
  HttpStatusMultipleChoices = 300;
  HttpStatusMovedPermanently = 301;
  HttpStatusFound = 302;
  HttpStatusSeeOther = 303;
  HttpStatusNotModified = 304;
  HttpStatusTemporaryRedirect = 307;
  HttpStatusPermanentRedirect = 308;

  // 4xx client error (RFC 9110 section 15.5)
  HttpStatusBadRequest = 400;
  HttpStatusUnauthorized = 401;
  HttpStatusPaymentRequired = 402;
  HttpStatusForbidden = 403;
  HttpStatusNotFound = 404;
  HttpStatusMethodNotAllowed = 405;
  HttpStatusNotAcceptable = 406;
  HttpStatusProxyAuthenticationRequired = 407;
  HttpStatusRequestTimeout = 408;
  HttpStatusConflict = 409;
  HttpStatusGone = 410;
  HttpStatusLengthRequired = 411;
  HttpStatusPreconditionFailed = 412;
  HttpStatusContentTooLarge = 413;
  HttpStatusUriTooLong = 414;
  HttpStatusUnsupportedMediaType = 415;
  HttpStatusRangeNotSatisfiable = 416;
  HttpStatusExpectationFailed = 417;
  HttpStatusMisdirectedRequest = 421;
  HttpStatusUnprocessableContent = 422;
  HttpStatusUpgradeRequired = 426;
  HttpStatusPreconditionRequired = 428;
  HttpStatusTooManyRequests = 429;
  HttpStatusRequestHeaderFieldsTooLarge = 431;
  HttpStatusUnavailableForLegalReasons = 451;

  // 5xx server error (RFC 9110 section 15.6)
  HttpStatusInternalServerError = 500;
  HttpStatusNotImplemented = 501;
  HttpStatusBadGateway = 502;
  HttpStatusServiceUnavailable = 503;
  HttpStatusGatewayTimeout = 504;
  HttpStatusHttpVersionNotSupported = 505;
  HttpStatusNetworkAuthenticationRequired = 511;

implementation

end.
