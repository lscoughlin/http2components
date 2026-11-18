{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.BodyReader;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  Http2.Client.Messages,
  Http2.Client.Stream;


/// read a body to EOF with no cap (the body is read whole, up to the size of
/// one TBytes)
function ReadAllBodyBytes(const ABody: IHttpBodyStream): TBytes; overload;

/// read a body to EOF; raises EHttpResponseTooLarge as soon as the total
/// would pass AMaxBytes, before the buffer grows past it. AMaxBytes <= 0 means
/// no cap
function ReadAllBodyBytes(const ABody: IHttpBodyStream;
  const AMaxBytes: Int64): TBytes; overload;

function ReadText(const AResponse: IHttpResponse): string; overload;

/// read a response body as text with a cap (see ReadAllBodyBytes); AMaxBytes
/// <= 0 means no cap
function ReadText(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): string; overload;

implementation

uses
  Http2.Client.Errors, Http2.Common.Body, Http2.Common.Body.Text;

function ReadAllBodyBytes(const ABody: IHttpBodyStream): TBytes;
begin
  Result := ReadAllBodyBytes(ABody, 0);
end;

function ReadAllBodyBytes(const ABody: IHttpBodyStream;
  const AMaxBytes: Int64): TBytes;
var
  Buf: array[0..4095] of Byte;
  N: Integer;
  Total, Cap, NewCap, Limit: Int64;
begin
  // the total is an Int64 and the buffer grows by doubling. The limit is the
  // cap when one is set, and High(Integer) otherwise: a body that would not
  // fit in one TBytes raises EHttpResponseTooLarge
  Limit := High(Integer);
  if (AMaxBytes > 0) and (AMaxBytes < Limit) then
    Limit := AMaxBytes;
  Result := nil;
  Total := 0;
  Cap := 0;
  while True do
  begin
    N := ABody.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    // the check comes before the buffer grows, so the buffer never holds
    // more than Limit bytes
    if Total + N > Limit then
      raise EHttpResponseTooLarge.CreateFmt(
        'response body passes %d bytes', [Limit]);
    if Total + N > Cap then
    begin
      NewCap := Cap * 2;
      if NewCap < 4096 then
        NewCap := 4096;
      if NewCap < Total + N then
        NewCap := Total + N;
      if NewCap > Limit then
        NewCap := Limit;
      SetLength(Result, NewCap);
      Cap := NewCap;
    end;
    Move(Buf[0], Result[Integer(Total)], N);
    Inc(Total, N);
  end;
  SetLength(Result, Integer(Total));
end;

function ReadText(const AResponse: IHttpResponse): string;
begin
  Result := ReadText(AResponse, 0);
end;

function ReadText(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): string;
var
  Limit: Int64;
begin
  if AResponse = nil then
    raise EHttpProtocolError.Create('response is nil', ecInternalError);
  // the common reader takes the limit as a count; High(Integer) stands for no cap
  Limit := AMaxBytes;
  if Limit <= 0 then
    Limit := High(Integer);
  try
    Result := Http2.Common.Body.Text.ReadText(AResponse.Body, Limit);
  except
    on E: EBodyTooLarge do
      raise EHttpResponseTooLarge.CreateFmt(
        'response body passes %d bytes', [Limit]);
  end;
end;

end.
