{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, body limit
notes:
  - A body wrapper that raises EHttpResponseTooLarge past a byte limit.
  - The limit is in bytes that the wrapped stream returns.
---
}
unit Http2.Client.Body.Limits;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Messages,
  Http2.Client.Stream, Http2.Client.RequestObserver, Http2.Common.Body;

type
  /// a body stream that raises EHttpResponseTooLarge when more than AMaxBytes
  // arrive; a limit of 0 means no limit
  TLimitedBodyStream = class(TBodyReaderBase, IHttpBodyStream)
  private
    FInner: IHttpBodyStream;
    FMaxBytes: Int64;
    FCount: Int64;
  public
    /// wrap AInner, counting the bytes it returns
    constructor Create(const AInner: IHttpBodyStream; const AMaxBytes: Int64);
    function Read(var ABuffer; const ACount: LongInt): LongInt; override;
    function Eof: Boolean;
  end;

  /// a response whose body is a TLimitedBodyStream; the other members come
  // from the wrapped response
  TLimitedResponse = class(TInterfacedObject, IHttpResponse,
    IAttemptProgress)
  private
    FAccessories: IHttpResponse;
    FProgress: IAttemptProgress;
    FBody: IHttpBodyStream;
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
  public
    /// wrap AResponse, limiting its body to AMaxBytes
    constructor Create(const AResponse: IHttpResponse; const AMaxBytes: Int64);
    property Progress: IAttemptProgress read FProgress
      implements IAttemptProgress;
  end;

/// the body limit for one request
// - a request that set its own limit wins, even when that limit is 0; the
//   client option applies otherwise
function EffectiveResponseLimit(const ARequest: TStreamRequest;
  const AOption: Int64): Int64;

/// wrap AResponse so that its body raises EHttpResponseTooLarge past AMaxBytes
// - returns AResponse unchanged when AMaxBytes is 0 or less
function WrapLimitedResponse(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): IHttpResponse;

implementation

{ TLimitedBodyStream }

constructor TLimitedBodyStream.Create(const AInner: IHttpBodyStream;
  const AMaxBytes: Int64);
begin
  inherited Create;
  FInner := AInner;
  FMaxBytes := AMaxBytes;
  FCount := 0;
end;

function TLimitedBodyStream.Read(var ABuffer; const ACount: LongInt): LongInt;
begin
  Result := FInner.Read(ABuffer, ACount);
  if Result <= 0 then
    Exit;
  Inc(FCount, Result);
  if (FMaxBytes > 0) and (FCount > FMaxBytes) then
    raise EHttpResponseTooLarge.CreateFmt(
      'response body passes its limit of %d bytes', [FMaxBytes]);
end;

function TLimitedBodyStream.Eof: Boolean;
begin
  Result := FInner.Eof;
end;

{ TLimitedResponse }

constructor TLimitedResponse.Create(const AResponse: IHttpResponse;
  const AMaxBytes: Int64);
begin
  inherited Create;
  FAccessories := AResponse;
  if not Supports(AResponse, IAttemptProgress, FProgress) then
    FProgress := NullAttemptProgress;
  FBody := TLimitedBodyStream.Create(AResponse.Body, AMaxBytes);
end;

function TLimitedResponse.GetStatusCode: LongInt;
begin
  Result := FAccessories.StatusCode;
end;

function TLimitedResponse.GetHeaders: IHttpHeaders;
begin
  Result := FAccessories.Headers;
end;

function TLimitedResponse.GetBody: IHttpBodyStream;
begin
  Result := FBody;
end;

{ functions }

function EffectiveResponseLimit(const ARequest: TStreamRequest;
  const AOption: Int64): Int64;
begin
  Result := AOption;
  if ARequest.MaxResponseBytesSet then
    Result := ARequest.MaxResponseBytes;
end;

function WrapLimitedResponse(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): IHttpResponse;
begin
  Result := AResponse;
  if (AResponse = nil) or (AMaxBytes <= 0) then
    Exit;
  Result := TLimitedResponse.Create(AResponse, AMaxBytes);
end;

end.
