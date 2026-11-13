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


function ReadAllBodyBytes(const ABody: IHttpBodyStream): TBytes;

function ReadText(const AResponse: IHttpResponse): string;

implementation

uses
  Http2.Client.Errors;

function ReadAllBodyBytes(const ABody: IHttpBodyStream): TBytes;
var
  Buf: array[0..4095] of Byte;
  N: Integer;
  Total, Cap, NewCap: Int64;
begin
  // the total is an Int64 and the buffer grows by doubling; a body that
  // would not fit in one TBytes raises EHttpResponseTooLarge
  Result := nil;
  Total := 0;
  Cap := 0;
  while True do
  begin
    N := ABody.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    if Total + N > High(Integer) then
      raise EHttpResponseTooLarge.CreateFmt(
        'response body passes %d bytes', [High(Integer)]);
    if Total + N > Cap then
    begin
      NewCap := Cap * 2;
      if NewCap < 4096 then
        NewCap := 4096;
      if NewCap < Total + N then
        NewCap := Total + N;
      if NewCap > High(Integer) then
        NewCap := High(Integer);
      SetLength(Result, NewCap);
      Cap := NewCap;
    end;
    Move(Buf[0], Result[Integer(Total)], N);
    Inc(Total, N);
  end;
  SetLength(Result, Integer(Total));
end;

function ReadText(const AResponse: IHttpResponse): string;
var
  Raw: TBytes;
begin
  if AResponse = nil then
    raise EHttpProtocolError.Create('response is nil', ecInternalError);
  Raw := ReadAllBodyBytes(AResponse.Body);
  SetLength(Result, Length(Raw));
  if Length(Raw) > 0 then
    Move(Raw[0], Result[1], Length(Raw));
end;

end.
