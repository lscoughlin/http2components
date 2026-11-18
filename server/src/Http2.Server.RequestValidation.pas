{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, request, validation
notes:
  - The unit holds the RFC 9113 section 8.1 request-header rules.  The
    connection core calls one function for each completed request header
    block, and the function reports the first fault it finds.
---
}
/// request header block validation (RFC 9113 section 8.1)
unit Http2.Server.RequestValidation;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Hpack, Http2.Common.Headers, Http2.Common.Uri;

type
  /// the outcome of one request header block check
  TRequestVerdict = record
    /// true when the block obeys every request rule
    Valid: Boolean;
    /// the content-length that the block declares, or -1 when absent
    DeclaredLength: Int64;
    /// true when the block is an extended CONNECT of RFC 8441 (it carries :protocol)
    IsExtendedConnect: Boolean;
  end;

/// check one request header block
/// - AIsTrailer is true for a trailing header block, where the
///   pseudo-headers are forbidden and the request pseudo-headers are not
///   required
/// - AConnectProtocol is true when the server advertised
///   SETTINGS_ENABLE_CONNECT_PROTOCOL; only then is :protocol legal
///   (RFC 8441 section 4 and RFC 9113 section 8.1.1)
function ValidateRequestHeaders(const ABlock: THeaderBlock;
  const AIsTrailer: Boolean; const AConnectProtocol: Boolean = False): TRequestVerdict;

/// true when AValue is a whole non-negative decimal number, and ALength
/// then holds its value
function ParseContentLength(const AValue: string; out ALength: Int64): Boolean;

implementation

const
  /// the request pseudo-headers of RFC 9113 section 8.3.1
  PseudoMethod    = HeaderMethod;
  PseudoScheme    = HeaderScheme;
  PseudoPath      = HeaderPath;
  PseudoAuthority = HeaderAuthority;
  PseudoProtocol  = ':protocol';

  /// HTTP/1.1 connection-specific header fields, forbidden on the HTTP/2
  /// wire (RFC 9113 section 8.1.2.2)
  ForbiddenHeaders: array[0..4] of string = (
    HeaderConnection, 'keep-alive', 'proxy-connection', HeaderTransferEncoding,
    HeaderUpgrade);

/// true when C is a token character of RFC 9110 section 5.6.2
function IsTokenChar(const C: Char): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
    ((C >= '0') and (C <= '9')) or
    (C in ['!', '#', '$', '%', '&', '''', '*', '+', '-', '.',
           '^', '_', '`', '|', '~']);
end;

/// true when C is an uppercase letter, which a header name forbids
function IsUpperCase(const C: Char): Boolean;
begin
  Result := (C >= 'A') and (C <= 'Z');
end;

/// RFC 9113 section 8.1.2.6: a header name is a lowercase token
function ValidHeaderName(const AName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Length(AName) = 0 then
    Exit;
  for I := 1 to Length(AName) do
    if IsUpperCase(AName[I]) or (not IsTokenChar(AName[I])) then
      Exit;
  Result := True;
end;

/// RFC 9113 section 8.1.2.6: a field value holds no null, CR or LF
function ValidHeaderValue(const AValue: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to Length(AValue) do
    if (AValue[I] = #0) or (AValue[I] = #10) or (AValue[I] = #13) then
      Exit;
  Result := True;
end;

function ParseContentLength(const AValue: string; out ALength: Int64): Boolean;
var
  I, Digit: Integer;
begin
  ALength := 0;
  Result := Length(AValue) > 0;
  if not Result then
    Exit;
  for I := 1 to Length(AValue) do
  begin
    if (AValue[I] < '0') or (AValue[I] > '9') then
      Exit(False);
    Digit := Ord(AValue[I]) - Ord('0');
    if ALength > (High(Int64) - Digit) div 10 then
      Exit(False);
    ALength := ALength * 10 + Digit;
  end;
end;

/// RFC 9110 section 9.1: a method is a non-empty token
function ValidMethod(const AMethod: string): Boolean;
var
  I: Integer;
begin
  Result := AMethod <> '';
  for I := 1 to Length(AMethod) do
    if not IsTokenChar(AMethod[I]) then
      Exit(False);
end;

/// true when C is a hexadecimal digit (RFC 3986 section 2.1)
function IsHexChar(const C: Char): Boolean;
begin
  Result := C in ['0'..'9', 'a'..'f', 'A'..'F'];
end;

/// RFC 9113 section 8.3.1: :path starts with "/", or it is "*" for OPTIONS.
/// The byte rule follows Go (golang.org/x/net/http2, url.ParseRequestURI):
/// no byte of 0x00 to 0x1F and no 0x7F; the space and the bytes above 0x7F are
/// accepted. A "%" in the path part (before the first "?") holds two hex digits.
function ValidPath(const APath, AMethod: string): Boolean;
var
  I, PathEnd: Integer;
begin
  if APath = '*' then
    Exit(AMethod = 'OPTIONS');
  Result := (APath <> '') and (APath[1] = '/');
  if not Result then
    Exit;
  for I := 1 to Length(APath) do
    if (Ord(APath[I]) < $20) or (Ord(APath[I]) = $7F) then
      Exit(False);
  PathEnd := Pos('?', APath);
  if PathEnd = 0 then
    PathEnd := Length(APath) + 1;
  for I := 1 to PathEnd - 1 do
    if APath[I] = '%' then
    begin
      if I + 2 > PathEnd - 1 then
        Exit(False);
      if not (IsHexChar(APath[I + 1]) and IsHexChar(APath[I + 2])) then
        Exit(False);
    end;
end;

/// RFC 3986 section 3.2: an authority is parsed with the scheme of the request
/// and holds no userinfo ("@") and no path, query or fragment delimiter
function ValidAuthority(const AScheme, AAuthority: string; out AUri: TURI): Boolean;
begin
  Result := IsValidTargetPart(AAuthority) and (Pos('@', AAuthority) = 0) and
    (Pos('/', AAuthority) = 0) and (Pos('?', AAuthority) = 0) and
    (Pos('#', AAuthority) = 0) and TryParseURI(AScheme + '://' + AAuthority + '/', AUri);
end;

/// true when ALowerName is a connection-specific header field
function IsForbidden(const ALowerName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(ForbiddenHeaders) to High(ForbiddenHeaders) do
    if ALowerName = ForbiddenHeaders[I] then
      Exit(True);
end;

function ValidateRequestHeaders(const ABlock: THeaderBlock;
  const AIsTrailer: Boolean; const AConnectProtocol: Boolean): TRequestVerdict;
var
  I: Integer;
  Name, Value, Lower: string;
  SeenRegular: Boolean;
  HasMethod, HasScheme, HasPath, HasAuthority, HasLength, HasProtocol: Boolean;
  Declared: Int64;
  Method, PathValue, AuthorityValue, SchemeValue: string;
  Hosts: array of string;
  AuthorityUri, HostUri: TURI;
begin
  PathValue := '';
  AuthorityValue := '';
  SchemeValue := '';
  Hosts := nil;
  Result.Valid := False;
  Result.IsExtendedConnect := False;
  HasProtocol := False;
  Method := '';
  Result.DeclaredLength := -1;
  SeenRegular := False;
  HasMethod := False;
  HasScheme := False;
  HasPath := False;
  HasAuthority := False;
  HasLength := False;
  for I := 0 to High(ABlock) do
  begin
    Name := ABlock[I].Name;
    Value := ABlock[I].Value;
    if Length(Name) = 0 then
      Exit;
    if not ValidHeaderValue(Value) then
      Exit;
    if Name[1] = ':' then
    begin
      // RFC 9113 section 8.1.2.1: a pseudo-header follows no regular header
      // field and never appears in a trailer
      if AIsTrailer or SeenRegular then
        Exit;
      if (Name = PseudoMethod) and (not HasMethod) and (Value <> '') then
      begin
        HasMethod := True;
        Method := Value;
      end
      else if (Name = PseudoProtocol) and AConnectProtocol and (not HasProtocol) and
        (Value <> '') then
        HasProtocol := True
      else if (Name = PseudoScheme) and (not HasScheme) and (Value <> '') then
      begin
        HasScheme := True;
        SchemeValue := Value;
      end
      else if (Name = PseudoPath) and (not HasPath) and (Value <> '') then
      begin
        HasPath := True;
        PathValue := Value;
      end
      else if (Name = PseudoAuthority) and (not HasAuthority) then
      begin
        HasAuthority := True;
        AuthorityValue := Value;
      end
      else
        // an unknown pseudo-header, a response pseudo-header, a duplicate or
        // an empty value is a fault
        Exit;
    end
    else
    begin
      SeenRegular := True;
      if not ValidHeaderName(Name) then
        Exit;
      Lower := LowerCase(Name);
      if IsForbidden(Lower) then
        Exit;
      if Lower = HeaderHost then
      begin
        // RFC 9113 section 8.3.1: a host field is compared with :authority
        SetLength(Hosts, Length(Hosts) + 1);
        Hosts[High(Hosts)] := Value;
      end;
      if Lower = HeaderTe then
      begin
        // RFC 9113 section 8.1.2.2: "te" is the sole exception, and its
        // only legal value is "trailers"
        if not SameText(Value, 'trailers') then
          Exit;
      end
      else if Lower = HeaderContentLength then
      begin
        if HasLength or (not ParseContentLength(Value, Declared)) then
          Exit;
        HasLength := True;
        Result.DeclaredLength := Declared;
      end;
    end;
  end;
  // RFC 9113 section 8.3.1: a request head carries :method, :scheme and
  // :path exactly once; a trailer carries none of them
  if (not AIsTrailer) and ((not HasMethod) or (not HasScheme) or
     (not HasPath)) then
    Exit;
  if not AIsTrailer then
  begin
    // RFC 9113 section 8.3.1: the method, the path and the authority obey their
    // grammar; a host field that names another entity is malformed
    if not ValidMethod(Method) then
      Exit;
    if not ValidPath(PathValue, Method) then
      Exit;
    if HasAuthority and (AuthorityValue <> '') then
    begin
      if not ValidAuthority(SchemeValue, AuthorityValue, AuthorityUri) then
        Exit;
      for I := 0 to High(Hosts) do
        if (not ValidAuthority(SchemeValue, Hosts[I], HostUri)) or
          (not SameHost(AuthorityUri, HostUri)) then
          Exit;
    end;
  end;
  if HasProtocol then
  begin
    // RFC 8441 section 4: :protocol belongs to CONNECT, and the request then names
    // :scheme, :path and :authority
    if (Method <> 'CONNECT') or (not HasAuthority) then
      Exit;
    Result.IsExtendedConnect := True;
  end;
  Result.Valid := True;
end;

end.