{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, parse, content-length, transfer-encoding
notes:
  - pure field value parsers for the HTTP/1.1 response framing (RFC 9112 section 6.3)
  - this unit uses SysUtils only, so the codec units can use it without a cycle
---
}
unit Http2.Client.Http1.Parse;

{$mode delphi}{$H+}

interface

/// parse a Content-Length field value (RFC 9110 section 8.6).  The value is
/// one or more decimal digits, or a comma list whose elements are all equal
/// (a repeated field is joined with a comma).  The result is False for any
/// other text, for an empty element, and for a value above High(Int64).
function TryParseContentLength(const AValue: string; out ALength: Int64): Boolean;

/// check a Transfer-Encoding field value (RFC 9112 section 6.1).  The value is
/// a comma list of codings.  Result is True when the last coding is chunked
/// (in any letter case).  AKnown is True when every coding is chunked; the
/// client knows no other transfer coding, so the caller refuses a response
/// with AKnown False.  Empty list elements are skipped.
function TransferEncodingIsChunked(const AValue: string;
  out AKnown: Boolean): Boolean;

implementation

uses
  SysUtils;

/// split AValue at each comma.  An empty element stays in the result.
function SplitComma(const AValue: string): TArray<string>;
var
  I, N, Start: Integer;
begin
  Result := nil;
  N := 0;
  Start := 1;
  for I := 1 to Length(AValue) + 1 do
    if (I > Length(AValue)) or (AValue[I] = ',') then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(AValue, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

function TryParseContentLength(const AValue: string; out ALength: Int64): Boolean;
var
  Items: TArray<string>;
  I, J: Integer;
  Item: string;
  Value: Int64;
  Digit: Int64;
  Have: Boolean;
begin
  ALength := 0;
  Result := False;
  Items := SplitComma(AValue);
  Have := False;
  for I := 0 to High(Items) do
  begin
    Item := Trim(Items[I]);
    if Item = '' then
      Exit;
    Value := 0;
    for J := 1 to Length(Item) do
    begin
      // RFC 9110 section 8.6: 1*DIGIT only, so no sign and no prefix
      if (Item[J] < '0') or (Item[J] > '9') then
        Exit;
      Digit := Ord(Item[J]) - Ord('0');
      // check the overflow before the multiplication (Int64 wraps silently)
      if Value > (High(Int64) - Digit) div 10 then
        Exit;
      Value := Value * 10 + Digit;
    end;
    // a list of Content-Length values is valid only when all values are equal
    if Have and (Value <> ALength) then
      Exit;
    ALength := Value;
    Have := True;
  end;
  Result := Have;
end;

function TransferEncodingIsChunked(const AValue: string;
  out AKnown: Boolean): Boolean;
var
  Items: TArray<string>;
  I: Integer;
  Item, Last: string;
  Count: Integer;
begin
  AKnown := True;
  Last := '';
  Count := 0;
  Items := SplitComma(AValue);
  for I := 0 to High(Items) do
  begin
    Item := Trim(Items[I]);
    if Item = '' then
      Continue;
    Last := LowerCase(Item);
    Inc(Count);
    // the client accepts a single chunked and no other coding (as Go does)
    if (Last <> 'chunked') or (Count > 1) then
      AKnown := False;
  end;
  Result := Last = 'chunked';
end;

end.
