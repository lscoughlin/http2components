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
  N, Total: Integer;
begin
  Result := nil;
  Total := 0;
  while True do
  begin
    N := ABody.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    SetLength(Result, Total + N);
    Move(Buf[0], Result[Total], N);
    Inc(Total, N);
  end;
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
