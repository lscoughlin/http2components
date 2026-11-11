{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, errors, common
notes:
  - This unit holds the shared HTTP/2 error codes and base exception classes.
---
}
unit Http2.Common.Errors;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils;

type
  THttp2ErrorCode = (
    ecNoError            = $0,
    ecProtocolError      = $1,
    ecInternalError      = $2,
    ecFlowControlError   = $3,
    ecSettingsTimeout    = $4,
    ecStreamClosed       = $5,
    ecFrameSizeError     = $6,
    ecRefusedStream      = $7,
    ecCancel             = $8,
    ecCompressionError   = $9,
    ecConnectError       = $a,
    ecEnhanceYourCalm    = $b,
    ecInadequateSecurity = $c,
    ecHttp11Required     = $d);

  EHttpError = class(Exception)
  private
    FErrorCode: THttp2ErrorCode;
  public
    constructor Create(const AMessage: string); overload;
    constructor Create(const AMessage: string;
      const AErrorCode: THttp2ErrorCode); overload;
    property ErrorCode: THttp2ErrorCode read FErrorCode;
  end;

  EHttpConnectionError = class(EHttpError);
  EHttpProtocolError = class(EHttpError);
  EHttpStreamError = class(EHttpError)
  private
    FStreamId: LongWord;
  public
    constructor Create(const AMessage: string; const AStreamId: LongWord;
      const AErrorCode: THttp2ErrorCode); overload;
    property StreamId: LongWord read FStreamId;
  end;
  EHttpTimeout = class(EHttpError);
  EHttpConnectionClosed = class(EHttpError);

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;

implementation

constructor EHttpError.Create(const AMessage: string);
begin
  inherited Create(AMessage);
  FErrorCode := ecInternalError;
end;

constructor EHttpError.Create(const AMessage: string;
  const AErrorCode: THttp2ErrorCode);
begin
  inherited Create(AMessage);
  FErrorCode := AErrorCode;
end;

constructor EHttpStreamError.Create(const AMessage: string;
  const AStreamId: LongWord; const AErrorCode: THttp2ErrorCode);
begin
  inherited Create(AMessage, AErrorCode);
  FStreamId := AStreamId;
end;

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;
begin
  case ACode of
    ecNoError:            Result := 'NO_ERROR';
    ecProtocolError:      Result := 'PROTOCOL_ERROR';
    ecInternalError:      Result := 'INTERNAL_ERROR';
    ecFlowControlError:   Result := 'FLOW_CONTROL_ERROR';
    ecSettingsTimeout:    Result := 'SETTINGS_TIMEOUT';
    ecStreamClosed:       Result := 'STREAM_CLOSED';
    ecFrameSizeError:     Result := 'FRAME_SIZE_ERROR';
    ecRefusedStream:      Result := 'REFUSED_STREAM';
    ecCancel:             Result := 'CANCEL';
    ecCompressionError:   Result := 'COMPRESSION_ERROR';
    ecConnectError:       Result := 'CONNECT_ERROR';
    ecEnhanceYourCalm:    Result := 'ENHANCE_YOUR_CALM';
    ecInadequateSecurity: Result := 'INADEQUATE_SECURITY';
    ecHttp11Required:     Result := 'HTTP_1_1_REQUIRED';
  else
    Result := 'UNKNOWN_' + IntToStr(Ord(ACode));
  end;
end;

end.
