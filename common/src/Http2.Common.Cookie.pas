{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: cookie, set-cookie, cookie header, RFC 6265, RFC 9110, HTTP-date, SameSite, Partitioned
notes:
  - This unit holds the cookie record THttpCookie and the helpers that read and write cookie fields.
  - RFC 6265 section 4.1.1 gives the Set-Cookie grammar. RFC 9110 section 5.6.7 gives the HTTP-date formats.
  - The SameSite and Partitioned attributes come from the RFC 6265bis draft and the CHIPS draft.
  - A name or a value with a forbidden octet raises EBodyFormatError. A Parse call ignores an unknown or malformed attribute.
---
}
unit Http2.Common.Cookie;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Body, Http2.Common.Headers, Http2.Common.Parameters;

type
  /// the value of the SameSite attribute; ssUnset means that the attribute is absent
  TSameSite = (ssUnset, ssNone, ssLax, ssStrict);

  /// a cookie of a Set-Cookie field, with its attributes
  // - all fields are read-only; the With methods give a changed copy
  // - the Expires value is in UTC
  // - Domain and Path are kept as they are written; they are not normalized
  THttpCookie = record
  private
    FName: string;
    FValue: string;
    FHasExpires: Boolean;
    FExpires: TDateTime;
    FHasMaxAge: Boolean;
    FMaxAge: Int64;
    FDomain: string;
    FPath: string;
    FSecure: Boolean;
    FHttpOnly: Boolean;
    FSameSite: TSameSite;
    FPartitioned: Boolean;
  public
    /// a cookie with a name and a value and no attribute
    class function Create(const AName, AValue: string): THttpCookie; static;
    /// parse a Set-Cookie field value
    // - raises EBodyFormatError when the name or the value is not valid
    // - an attribute whose value is malformed is ignored, as RFC 6265 section 5.2 says
    class function Parse(const AValue: string): THttpCookie; static;
    /// the same as Parse, but returns False and does not raise
    class function TryParse(const AValue: string; out ACookie: THttpCookie): Boolean; static;
    /// the Set-Cookie field value of the cookie
    // - raises EBodyFormatError when the name, the value, the domain or the path is not valid
    function ToString: string;
    function WithName(const AName: string): THttpCookie;
    function WithValue(const AValue: string): THttpCookie;
    function WithExpires(const AExpires: TDateTime): THttpCookie;
    function WithoutExpires: THttpCookie;
    function WithMaxAge(const AMaxAge: Int64): THttpCookie;
    function WithoutMaxAge: THttpCookie;
    function WithDomain(const ADomain: string): THttpCookie;
    function WithPath(const APath: string): THttpCookie;
    function WithSecure(const AValue: Boolean = True): THttpCookie;
    function WithHttpOnly(const AValue: Boolean = True): THttpCookie;
    function WithSameSite(const AValue: TSameSite): THttpCookie;
    function WithPartitioned(const AValue: Boolean = True): THttpCookie;
    property Name: string read FName;
    property Value: string read FValue;
    /// True when the cookie has an Expires attribute
    property HasExpires: Boolean read FHasExpires;
    /// the Expires attribute in UTC; meaningful only when HasExpires is True
    property Expires: TDateTime read FExpires;
    /// True when the cookie has a Max-Age attribute
    property HasMaxAge: Boolean read FHasMaxAge;
    /// the Max-Age attribute in seconds; meaningful only when HasMaxAge is True
    property MaxAge: Int64 read FMaxAge;
    property Domain: string read FDomain;
    property Path: string read FPath;
    property Secure: Boolean read FSecure;
    property HttpOnly: Boolean read FHttpOnly;
    property SameSite: TSameSite read FSameSite;
    property Partitioned: Boolean read FPartitioned;
  end;

/// True when AName is a cookie name: a non-empty RFC 9110 token
function IsCookieName(const AName: string): Boolean;

/// True when AValue is a cookie value: every octet is a cookie-octet of RFC 6265 section 4.1.1
// - the octets excluded are control octets, space, '"', ',', ';' and '\'
function IsCookieValue(const AValue: string): Boolean;

/// the IMF-fixdate text of a UTC time (RFC 9110 section 5.6.7)
// - the text is always 29 octets, for example 'Sun, 06 Nov 1994 08:49:37 GMT'
function FormatHttpDate(const ADate: TDateTime): string;

/// parse an HTTP-date in any of the three formats of RFC 9110 section 5.6.7
// - accepts IMF-fixdate, the RFC 850 format and the asctime format
// - a two-digit year follows RFC 6265 section 5.1.1: 70 to 99 is 19xx, 0 to 69 is 20xx
// - the day name is not checked; a leap second (60) is refused
function TryParseHttpDate(const AText: string; out ADate: TDateTime): Boolean;

/// parse a Cookie field value (RFC 6265 section 4.2.1) into names and values
// - a pair without '=' is skipped; a pair with an empty name is skipped
// - names and values are trimmed; a quoted value loses its quotes
// - the names keep their case and the values keep their order
function ParseCookies(const AValue: string): TParameters;

/// the cookies of every cookie field of AHeaders, in one map
// - HTTP/2 can send more than one cookie field (RFC 9113 section 8.2.3); all are read
function GetCookies(const AHeaders: IHttpHeaders): TParameters;

/// the cookies of every set-cookie field of AHeaders, in field order
// - a set-cookie field is never joined with another one
// - raises EBodyFormatError when a field is not valid
function GetSetCookies(const AHeaders: IHttpHeaders): TArray<THttpCookie>;

/// the value of one cookie field that holds every pair of ACookies (for example 'a=1; b=2')
// - the pairs keep the order of the map; a name with more values gives more pairs
// - an empty map gives an empty text
// - raises EBodyFormatError when a name or a value is not valid
function CookieHeaderValue(const ACookies: TParameters): string;

/// add one set-cookie field with the Set-Cookie value of ACookie
procedure AddSetCookie(const AHeaders: IHttpHeaders; const ACookie: THttpCookie);

implementation

const
  cDayNames: array[1..7] of string = ('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat');
  cMonthNames: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');

function IsTokenChar(const C: Char): Boolean;
begin
  // RFC 9110 section 5.6.2: tchar
  Result := C in ['0'..'9', 'a'..'z', 'A'..'Z', '!', '#', '$', '%', '&', '''', '*',
    '+', '-', '.', '^', '_', '`', '|', '~'];
end;

function IsAttributeChar(const C: Char): Boolean;
begin
  // a visible octet other than ';'
  Result := (C > ' ') and (C < #$7F) and (C <> ';');
end;

function IsCookieName(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := AName <> '';
  for I := 1 to Length(AName) do
    if not IsTokenChar(AName[I]) then
      Exit(False);
end;

function IsCookieValue(const AValue: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := True;
  for I := 1 to Length(AValue) do
  begin
    C := AValue[I];
    // cookie-octet = %x21 / %x23-2B / %x2D-3A / %x3C-5B / %x5D-7E
    if not ((C = #$21) or ((C >= #$23) and (C <= #$2B)) or ((C >= #$2D) and (C <= #$3A))
      or ((C >= #$3C) and (C <= #$5B)) or ((C >= #$5D) and (C <= #$7E))) then
      Exit(False);
  end;
end;

function IsAttributeText(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 1 to Length(AText) do
    if not IsAttributeChar(AText[I]) then
      Exit(False);
end;

procedure CheckCookieNameAndValue(const AName, AValue: string);
begin
  if not IsCookieName(AName) then
    raise EBodyFormatError.Create('a cookie name is empty or holds a forbidden octet');
  if not IsCookieValue(AValue) then
    raise EBodyFormatError.Create('a cookie value holds a forbidden octet');
end;

function FormatHttpDate(const ADate: TDateTime): string;
var
  LYear, LMonth, LDay, LHour, LMinute, LSecond, LMilli: Word;
begin
  DecodeDate(ADate, LYear, LMonth, LDay);
  DecodeTime(ADate, LHour, LMinute, LSecond, LMilli);
  Result := Format('%s, %.2d %s %.4d %.2d:%.2d:%.2d GMT',
    [cDayNames[DayOfWeek(ADate)], LDay, cMonthNames[LMonth], LYear, LHour, LMinute, LSecond]);
end;

/// the month number of a three-letter English name, or 0
function MonthOf(const AName: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to 12 do
    if SameText(AName, cMonthNames[I]) then
      Exit(I);
end;

/// the number of a token of digits, or -1 when the token is not digits
function DigitsValue(const AText: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (AText = '') or (Length(AText) > 4) then
    Exit;
  Result := 0;
  for I := 1 to Length(AText) do
  begin
    if not (AText[I] in ['0'..'9']) then
      Exit(-1);
    Result := Result * 10 + (Ord(AText[I]) - Ord('0'));
  end;
end;

/// True when AText is one to AMaxLength digits (no sign, no space)
function IsDigits(const AText: string; const AMaxLength: Integer): Boolean;
var
  I: Integer;
begin
  Result := (AText <> '') and (Length(AText) <= AMaxLength);
  if Result then
    for I := 1 to Length(AText) do
      if not (AText[I] in ['0'..'9']) then
        Exit(False);
end;

/// split AText at ASep; an empty part stays in the result
function SplitText(const AText: string; const ASep: Char): TArray<string>;
var
  I, LStart, LCount: Integer;
begin
  Result := nil;
  LCount := 0;
  LStart := 1;
  for I := 1 to Length(AText) + 1 do
    if (I > Length(AText)) or (AText[I] = ASep) then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(AText, LStart, I - LStart);
      Inc(LCount);
      LStart := I + 1;
    end;
end;

/// split AText at the spaces, the commas and the dashes, and drop the empty parts
function DateTokens(const AText: string): TArray<string>;
var
  LText: string;
  I: Integer;
  LCount: Integer;
  LCurrent: string;
begin
  LText := AText;
  for I := 1 to Length(LText) do
    if (LText[I] = ',') or (LText[I] = '-') then
      LText[I] := ' ';
  Result := nil;
  LCount := 0;
  LCurrent := '';
  for I := 1 to Length(LText) + 1 do
    if (I > Length(LText)) or (LText[I] = ' ') or (LText[I] = #9) then
    begin
      if LCurrent <> '' then
      begin
        SetLength(Result, LCount + 1);
        Result[LCount] := LCurrent;
        Inc(LCount);
        LCurrent := '';
      end;
    end
    else
      LCurrent := LCurrent + LText[I];
end;

function TryParseHttpDate(const AText: string; out ADate: TDateTime): Boolean;
var
  LTokens: TArray<string>;
  LDay, LMonth, LYear, LHour, LMinute, LSecond: Integer;
  LTime: TArray<string>;
  LDayText, LMonthText, LYearText, LTimeText: string;
  LDayDate: TDateTime;
  LTimePart: TDateTime;
begin
  Result := False;
  ADate := 0;
  LTokens := DateTokens(AText);
  // IMF-fixdate and RFC 850: day-name day month year time GMT
  // asctime: day-name month day time year (UTC by definition)
  if (Length(LTokens) = 6) and SameText(LTokens[5], 'GMT') then
  begin
    LDayText := LTokens[1];
    LMonthText := LTokens[2];
    LYearText := LTokens[3];
    LTimeText := LTokens[4];
  end
  else if Length(LTokens) = 5 then
  begin
    LMonthText := LTokens[1];
    LDayText := LTokens[2];
    LTimeText := LTokens[3];
    LYearText := LTokens[4];
  end
  else
    Exit;
  LDay := DigitsValue(LDayText);
  LYear := DigitsValue(LYearText);
  LMonth := MonthOf(LMonthText);
  if (LDay < 1) or (LDay > 31) or (LMonth = 0) or (LYear < 0) then
    Exit;
  if Length(LYearText) = 2 then
  begin
    if LYear >= 70 then
      Inc(LYear, 1900)
    else
      Inc(LYear, 2000);
  end
  else if Length(LYearText) <> 4 then
    Exit;
  LTime := SplitText(LTimeText, ':');
  if Length(LTime) <> 3 then
    Exit;
  LHour := DigitsValue(LTime[0]);
  LMinute := DigitsValue(LTime[1]);
  LSecond := DigitsValue(LTime[2]);
  if (LHour < 0) or (LHour > 23) or (LMinute < 0) or (LMinute > 59) or (LSecond < 0) or (LSecond > 59) then
    Exit;
  if not TryEncodeDate(LYear, LMonth, LDay, LDayDate) then
    Exit;
  if not TryEncodeTime(LHour, LMinute, LSecond, 0, LTimePart) then
    Exit;
  ADate := LDayDate + LTimePart;
  Result := True;
end;

class function THttpCookie.Create(const AName, AValue: string): THttpCookie;
begin
  CheckCookieNameAndValue(AName, AValue);
  Result := Default(THttpCookie);
  Result.FName := AName;
  Result.FValue := AValue;
end;

class function THttpCookie.TryParse(const AValue: string; out ACookie: THttpCookie): Boolean;
begin
  Result := False;
  ACookie := Default(THttpCookie);
  try
    ACookie := Parse(AValue);
    Result := True;
  except
    on EBodyFormatError do
      Result := False;
  end;
end;

class function THttpCookie.Parse(const AValue: string): THttpCookie;
var
  LParts: TArray<string>;
  LPair: string;
  LEquals: Integer;
  LName: string;
  LValue: string;
  I: Integer;
  LAttribute: string;
  LAttrValue: string;
  LAttrName: string;
  LDigits: string;
  LNegative: Boolean;
  LDate: TDateTime;
  LStart: Integer;
begin
  Result := Default(THttpCookie);
  LParts := SplitText(AValue, ';');
  LPair := LParts[0];
  LEquals := Pos('=', LPair);
  if LEquals = 0 then
    raise EBodyFormatError.Create('a Set-Cookie value has no name=value pair');
  LName := Trim(Copy(LPair, 1, LEquals - 1));
  LValue := Trim(Copy(LPair, LEquals + 1, MaxInt));
  if (Length(LValue) >= 2) and (LValue[1] = '"') and (LValue[Length(LValue)] = '"') then
    LValue := Copy(LValue, 2, Length(LValue) - 2);
  CheckCookieNameAndValue(LName, LValue);
  Result.FName := LName;
  Result.FValue := LValue;
  for I := 1 to High(LParts) do
  begin
    LAttribute := Trim(LParts[I]);
    LStart := Pos('=', LAttribute);
    if LStart = 0 then
    begin
      LAttrName := LAttribute;
      LAttrValue := '';
    end
    else
    begin
      LAttrName := Trim(Copy(LAttribute, 1, LStart - 1));
      LAttrValue := Trim(Copy(LAttribute, LStart + 1, MaxInt));
    end;
    if SameText(LAttrName, 'expires') then
    begin
      if TryParseHttpDate(LAttrValue, LDate) then
      begin
        Result.FHasExpires := True;
        Result.FExpires := LDate;
      end;
    end
    else if SameText(LAttrName, 'max-age') then
    begin
      // an optional '-' and up to 18 digits; any other text is ignored
      LDigits := LAttrValue;
      LNegative := (LDigits <> '') and (LDigits[1] = '-');
      if LNegative then
        Delete(LDigits, 1, 1);
      if IsDigits(LDigits, 18) then
      begin
        Result.FHasMaxAge := True;
        Result.FMaxAge := StrToInt64(LDigits);
        if LNegative then
          Result.FMaxAge := -Result.FMaxAge;
      end;
    end
    else if SameText(LAttrName, 'domain') then
    begin
      if LAttrValue <> '' then
        Result.FDomain := LAttrValue;
    end
    else if SameText(LAttrName, 'path') then
    begin
      if LAttrValue <> '' then
        Result.FPath := LAttrValue;
    end
    else if SameText(LAttrName, 'secure') then
      Result.FSecure := True
    else if SameText(LAttrName, 'httponly') then
      Result.FHttpOnly := True
    else if SameText(LAttrName, 'partitioned') then
      Result.FPartitioned := True
    else if SameText(LAttrName, 'samesite') then
    begin
      if SameText(LAttrValue, 'strict') then
        Result.FSameSite := ssStrict
      else if SameText(LAttrValue, 'lax') then
        Result.FSameSite := ssLax
      else if SameText(LAttrValue, 'none') then
        Result.FSameSite := ssNone;
    end;
  end;
end;

function THttpCookie.ToString: string;
begin
  CheckCookieNameAndValue(FName, FValue);
  Result := FName + '=' + FValue;
  if FHasExpires then
    Result := Result + '; Expires=' + FormatHttpDate(FExpires);
  if FHasMaxAge then
    Result := Result + '; Max-Age=' + IntToStr(FMaxAge);
  if FDomain <> '' then
    Result := Result + '; Domain=' + FDomain;
  if FPath <> '' then
    Result := Result + '; Path=' + FPath;
  if FSecure then
    Result := Result + '; Secure';
  if FHttpOnly then
    Result := Result + '; HttpOnly';
  case FSameSite of
    ssNone: Result := Result + '; SameSite=None';
    ssLax: Result := Result + '; SameSite=Lax';
    ssStrict: Result := Result + '; SameSite=Strict';
  end;
  if FPartitioned then
    Result := Result + '; Partitioned';
end;

function THttpCookie.WithName(const AName: string): THttpCookie;
begin
  if not IsCookieName(AName) then
    raise EBodyFormatError.Create('a cookie name is empty or holds a forbidden octet');
  Result := Self;
  Result.FName := AName;
end;

function THttpCookie.WithValue(const AValue: string): THttpCookie;
begin
  if not IsCookieValue(AValue) then
    raise EBodyFormatError.Create('a cookie value holds a forbidden octet');
  Result := Self;
  Result.FValue := AValue;
end;

function THttpCookie.WithExpires(const AExpires: TDateTime): THttpCookie;
begin
  Result := Self;
  Result.FHasExpires := True;
  Result.FExpires := AExpires;
end;

function THttpCookie.WithoutExpires: THttpCookie;
begin
  Result := Self;
  Result.FHasExpires := False;
  Result.FExpires := 0;
end;

function THttpCookie.WithMaxAge(const AMaxAge: Int64): THttpCookie;
begin
  Result := Self;
  Result.FHasMaxAge := True;
  Result.FMaxAge := AMaxAge;
end;

function THttpCookie.WithoutMaxAge: THttpCookie;
begin
  Result := Self;
  Result.FHasMaxAge := False;
  Result.FMaxAge := 0;
end;

function THttpCookie.WithDomain(const ADomain: string): THttpCookie;
begin
  if not IsAttributeText(ADomain) then
    raise EBodyFormatError.Create('a cookie domain holds a forbidden octet');
  Result := Self;
  Result.FDomain := ADomain;
end;

function THttpCookie.WithPath(const APath: string): THttpCookie;
begin
  if not IsAttributeText(APath) then
    raise EBodyFormatError.Create('a cookie path holds a forbidden octet');
  Result := Self;
  Result.FPath := APath;
end;

function THttpCookie.WithSecure(const AValue: Boolean): THttpCookie;
begin
  Result := Self;
  Result.FSecure := AValue;
end;

function THttpCookie.WithHttpOnly(const AValue: Boolean): THttpCookie;
begin
  Result := Self;
  Result.FHttpOnly := AValue;
end;

function THttpCookie.WithSameSite(const AValue: TSameSite): THttpCookie;
begin
  Result := Self;
  Result.FSameSite := AValue;
end;

function THttpCookie.WithPartitioned(const AValue: Boolean): THttpCookie;
begin
  Result := Self;
  Result.FPartitioned := AValue;
end;

function ParseCookies(const AValue: string): TParameters;
var
  LPairs: TArray<string>;
  LPair: string;
  LEquals: Integer;
  LName: string;
  LValue: string;
begin
  Result := TParameters.Create;
  LPairs := SplitText(AValue, ';');
  for LPair in LPairs do
  begin
    LEquals := Pos('=', LPair);
    if LEquals = 0 then
      Continue;
    LName := Trim(Copy(LPair, 1, LEquals - 1));
    LValue := Trim(Copy(LPair, LEquals + 1, MaxInt));
    if LName = '' then
      Continue;
    if (Length(LValue) >= 2) and (LValue[1] = '"') and (LValue[Length(LValue)] = '"') then
      LValue := Copy(LValue, 2, Length(LValue) - 2);
    Result.Add(LName, LValue);
  end;
end;

function GetCookies(const AHeaders: IHttpHeaders): TParameters;
var
  LFields: TArray<string>;
  LField: string;
  LPairs: TParameters;
  LName: string;
  LValue: string;
begin
  Result := TParameters.Create;
  LFields := AHeaders.GetValues(HeaderCookie);
  for LField in LFields do
  begin
    LPairs := ParseCookies(LField);
    for LName in LPairs.Names do
      for LValue in LPairs.GetValues(LName) do
        Result.Add(LName, LValue);
  end;
end;

function GetSetCookies(const AHeaders: IHttpHeaders): TArray<THttpCookie>;
var
  LFields: TArray<string>;
  I: Integer;
begin
  Result := nil;
  LFields := AHeaders.GetValues(HeaderSetCookie);
  SetLength(Result, Length(LFields));
  for I := 0 to High(LFields) do
    Result[I] := THttpCookie.Parse(LFields[I]);
end;

function CookieHeaderValue(const ACookies: TParameters): string;
var
  LName: string;
  LValue: string;
begin
  Result := '';
  for LName in ACookies.Names do
    for LValue in ACookies.GetValues(LName) do
    begin
      CheckCookieNameAndValue(LName, LValue);
      if Result <> '' then
        Result := Result + '; ';
      Result := Result + LName + '=' + LValue;
    end;
end;

procedure AddSetCookie(const AHeaders: IHttpHeaders; const ACookie: THttpCookie);
begin
  AHeaders.Add(HeaderSetCookie, ACookie.ToString);
end;

end.
