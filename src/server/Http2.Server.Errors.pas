{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, errors, server
notes:
  - This unit owns server-only errors and aliases the common error types.
---
}
unit Http2.Server.Errors;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  Http2.Common.Errors;

const
  ecNoError = Http2.Common.Errors.ecNoError;
  ecProtocolError = Http2.Common.Errors.ecProtocolError;
  ecInternalError = Http2.Common.Errors.ecInternalError;
  ecFlowControlError = Http2.Common.Errors.ecFlowControlError;
  ecSettingsTimeout = Http2.Common.Errors.ecSettingsTimeout;
  ecStreamClosed = Http2.Common.Errors.ecStreamClosed;
  ecFrameSizeError = Http2.Common.Errors.ecFrameSizeError;
  ecRefusedStream = Http2.Common.Errors.ecRefusedStream;
  ecCancel = Http2.Common.Errors.ecCancel;
  ecCompressionError = Http2.Common.Errors.ecCompressionError;
  ecConnectError = Http2.Common.Errors.ecConnectError;
  ecEnhanceYourCalm = Http2.Common.Errors.ecEnhanceYourCalm;
  ecInadequateSecurity = Http2.Common.Errors.ecInadequateSecurity;
  ecHttp11Required = Http2.Common.Errors.ecHttp11Required;

type
  THttp2ErrorCode = Http2.Common.Errors.THttp2ErrorCode;
  EHttpError = Http2.Common.Errors.EHttpError;
  EHttpConnectionError = Http2.Common.Errors.EHttpConnectionError;
  EHttpProtocolError = Http2.Common.Errors.EHttpProtocolError;
  EHttpStreamError = Http2.Common.Errors.EHttpStreamError;
  EHttpTimeout = Http2.Common.Errors.EHttpTimeout;
  EHttpConnectionClosed = Http2.Common.Errors.EHttpConnectionClosed;

  EServerConfigError = class(EHttpError);
  EStreamCancelled = class(EHttpStreamError);
  EStreamReset = class(EHttpStreamError);
  EServerStopped = class(EHttpError);

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;

implementation

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;
begin
  Result := Http2.Common.Errors.Http2ErrorCodeName(ACode);
end;

end.
