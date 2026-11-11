{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, errors, client
notes:
  - This unit owns client-only errors and aliases the common error types.
---
}
unit Http2.Client.Errors;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Http2.Common.Errors;

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

  EHttpTooManyRedirects = class(EHttpError);
  EHttpTooManySseRetries = class(EHttpError);
  EHttpNotReplayable = class(EHttpError);
  EHttpProxyConfigError = class(EHttpError);
  EHttpTlsConfigError = class(EHttpError);
  EHttpTlsClientAuthError = class(EHttpConnectionError)
  private
    FAlert: string;
  public
    constructor Create(const AMessage, AAlert: string); overload;
    property Alert: string read FAlert;
  end;
  EHttpWebSocketError = class(EHttpError);
  EHttpWebSocketClosedError = class(EHttpWebSocketError);
  EHttpWebSocketProtocolError = class(EHttpWebSocketError)
  private
    FCloseCode: Integer;
  public
    constructor Create(const AMessage: string;
      const ACloseCode: Integer); overload;
    constructor CreateFmt(const AFormat: string; const AArgs: array of const;
      const ACloseCode: Integer); overload;
    property CloseCode: Integer read FCloseCode;
  end;
  EHttpWebSocketHandshakeError = class(EHttpWebSocketError)
  private
    FStatusCode: Integer;
    FHeaderLines: string;
    FBody: string;
  public
    constructor Create(const AMessage: string; const AStatusCode: Integer;
      const AHeaderLines, ABody: string);
    property StatusCode: Integer read FStatusCode;
    property HeaderLines: string read FHeaderLines;
    property Body: string read FBody;
    function Header(const AName: string): string;
  end;

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;

implementation

constructor EHttpTlsClientAuthError.Create(const AMessage, AAlert: string);
begin
  inherited Create(AMessage);
  FAlert := AAlert;
end;

constructor EHttpWebSocketProtocolError.Create(const AMessage: string;
  const ACloseCode: Integer);
begin
  inherited Create(AMessage);
  FCloseCode := ACloseCode;
end;

constructor EHttpWebSocketProtocolError.CreateFmt(const AFormat: string;
  const AArgs: array of const; const ACloseCode: Integer);
begin
  inherited Create(Format(AFormat, AArgs));
  FCloseCode := ACloseCode;
end;

constructor EHttpWebSocketHandshakeError.Create(const AMessage: string;
  const AStatusCode: Integer; const AHeaderLines, ABody: string);
begin
  inherited Create(AMessage);
  FStatusCode := AStatusCode;
  FHeaderLines := AHeaderLines;
  FBody := ABody;
end;

function EHttpWebSocketHandshakeError.Header(const AName: string): string;
var
  Lines: TStringList;
  I, P: Integer;
  Prefix: string;
begin
  Result := '';
  Prefix := LowerCase(AName);
  Lines := TStringList.Create;
  try
    Lines.Text := FHeaderLines;
    for I := 0 to Lines.Count - 1 do
    begin
      P := Pos(':', Lines[I]);
      if (P > 0) and (LowerCase(Trim(Copy(Lines[I], 1, P - 1))) = Prefix) then
        Exit(Trim(Copy(Lines[I], P + 1, MaxInt)));
    end;
  finally
    Lines.Free;
  end;
end;

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;
begin
  Result := Http2.Common.Errors.Http2ErrorCodeName(ACode);
end;

end.
