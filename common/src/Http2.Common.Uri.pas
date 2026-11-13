{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: uri, rfc3986, parser, redirect
notes:
  - This unit holds the one URI parser of the library (RFC 3986).
  - The parser rejects bytes that other parsers read in a different way.
  - The host is normalized once, so every caller sees the same host.
---
}
unit Http2.Common.Uri;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// a parsed URI; all fields are read-only
  TURI = record
  private
    FScheme: string;
    FUserInfo: string;
    FHost: string;
    FPort: Integer;
    FHasPort: Boolean;
    FPath: string;
    FQuery: string;
    FFragment: string;
    FHasAuthority: Boolean;
    FHasUserInfo: Boolean;
    FHasQuery: Boolean;
    FHasFragment: Boolean;
    FIsIPLiteral: Boolean;
    function GetPort: Integer;
    function GetAuthority: string;
    function GetIsAbsolute: Boolean;
  public
    /// the scheme in lower case; empty for a relative reference
    property Scheme: string read FScheme;
    property UserInfo: string read FUserInfo;
    /// the normalized host; an IPv6 literal has no brackets
    property Host: string read FHost;
    /// the port, or -1 when the URI has none
    property Port: Integer read GetPort;
    property HasPort: Boolean read FHasPort;
    property Path: string read FPath;
    property Query: string read FQuery;
    property Fragment: string read FFragment;
    property HasAuthority: Boolean read FHasAuthority;
    property HasUserInfo: Boolean read FHasUserInfo;
    property HasQuery: Boolean read FHasQuery;
    property HasFragment: Boolean read FHasFragment;
    property IsIPLiteral: Boolean read FIsIPLiteral;
    /// the host (in brackets for IPv6) and the port when present
    property Authority: string read GetAuthority;
    /// True when the URI has a scheme
    property IsAbsolute: Boolean read GetIsAbsolute;
  end;

/// parse a URI or a relative reference
// - raises EHttpProtocolError (ecProtocolError) when the text is not valid
// - the message never holds the text, so a log never holds a hostile string
function ParseURI(const AUri: string): TURI;

/// the same as ParseURI, but returns False and does not raise
function TryParseURI(const AUri: string; out AResult: TURI): Boolean;

/// RFC 3986 section 5.2 (strict), with remove_dot_segments of section 5.2.4
// - raises EHttpProtocolError when ABase has no scheme
function ResolveReference(const ABase, ARef: TURI): TURI;

/// the text of a URI (RFC 3986 section 5.3), with the normalized host
function UriToString(const AUri: TURI): string;

/// True when both have a host and the normalized hosts are equal
function SameHost(const A, B: TURI): Boolean;

/// True when scheme, host and effective port are equal
// - the default port of http is 80 and the default port of https is 443
function SameOrigin(const A, B: TURI): Boolean;

/// True when the hosts are the same, ABase is http and ATarget is https
function IsHttpToHttpsUpgrade(const ABase, ATarget: TURI): Boolean;

implementation

uses
  SysUtils, Http2.Common.Errors;

function TURI.GetPort: Integer;
begin
  if FHasPort then
    Result := FPort
  else
    Result := -1;
end;

function TURI.GetAuthority: string;
begin
  if FIsIPLiteral then
    Result := '[' + FHost + ']'
  else
    Result := FHost;
  if FHasPort then
    Result := Result + ':' + IntToStr(FPort);
end;

function TURI.GetIsAbsolute: Boolean;
begin
  Result := FScheme <> '';
end;

procedure ClearURI(var R: TURI);
begin
  R.FScheme := '';
  R.FUserInfo := '';
  R.FHost := '';
  R.FPort := 0;
  R.FHasPort := False;
  R.FPath := '';
  R.FQuery := '';
  R.FFragment := '';
  R.FHasAuthority := False;
  R.FHasUserInfo := False;
  R.FHasQuery := False;
  R.FHasFragment := False;
  R.FIsIPLiteral := False;
end;

function IsHexDigit(const C: Char): Boolean;
begin
  Result := C in ['0'..'9', 'a'..'f', 'A'..'F'];
end;

function HexValue(const C: Char): Integer;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := Ord(C) - Ord('A') + 10;
  end;
end;

function IsUnreserved(const C: Char): Boolean;
begin
  Result := C in ['a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~'];
end;

function IsSubDelim(const C: Char): Boolean;
begin
  Result := C in ['!', '$', '&', '''', '(', ')', '*', '+', ',', ';', '='];
end;

/// bytes that RFC 3986 does not allow and that parsers read in different ways
function CheckBytes(const AUri: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  I := 1;
  while I <= Length(AUri) do
  begin
    C := AUri[I];
    if (Ord(C) <= $20) or (Ord(C) >= $7F) then
      Exit('the URI holds a control, space or non-ASCII byte');
    if C = '\' then
      Exit('the URI holds a backslash');
    if C = '%' then
    begin
      if (I + 2 > Length(AUri)) or not IsHexDigit(AUri[I + 1]) or
        not IsHexDigit(AUri[I + 2]) then
        Exit('the URI holds a broken percent-encoding');
      Inc(I, 2);
    end;
    Inc(I);
  end;
end;

function ValidScheme(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (AText <> '') and (AText[1] in ['a'..'z', 'A'..'Z']);
  if not Result then
    Exit;
  for I := 2 to Length(AText) do
    if not (AText[I] in ['a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.']) then
      Exit(False);
end;

function ValidIPv4(const AText: string): Boolean;
var
  LPart: string;
  LPos, LStart, LCount, I, LValue: Integer;
begin
  Result := False;
  LCount := 0;
  LStart := 1;
  repeat
    LPos := LStart;
    while (LPos <= Length(AText)) and (AText[LPos] <> '.') do
      Inc(LPos);
    LPart := Copy(AText, LStart, LPos - LStart);
    if (LPart = '') or (Length(LPart) > 3) then
      Exit;
    if (Length(LPart) > 1) and (LPart[1] = '0') then
      Exit;
    LValue := 0;
    for I := 1 to Length(LPart) do
    begin
      if not (LPart[I] in ['0'..'9']) then
        Exit;
      LValue := LValue * 10 + Ord(LPart[I]) - Ord('0');
    end;
    if LValue > 255 then
      Exit;
    Inc(LCount);
    LStart := LPos + 1;
  until LPos > Length(AText);
  Result := LCount = 4;
end;

/// count the 16-bit groups of one side of an IPv6 literal
function CountGroups(const AText: string; const AAllowV4: Boolean;
  out ACount: Integer): Boolean;
var
  LPos, LStart, I: Integer;
  LPart: string;
  LLast: Boolean;
begin
  Result := False;
  ACount := 0;
  if AText = '' then
    Exit(True);
  LStart := 1;
  repeat
    LPos := LStart;
    while (LPos <= Length(AText)) and (AText[LPos] <> ':') do
      Inc(LPos);
    LLast := LPos > Length(AText);
    LPart := Copy(AText, LStart, LPos - LStart);
    if LPart = '' then
      Exit;
    if LLast and AAllowV4 and (Pos('.', LPart) > 0) then
    begin
      if not ValidIPv4(LPart) then
        Exit;
      Inc(ACount, 2);
    end
    else
    begin
      if Length(LPart) > 4 then
        Exit;
      for I := 1 to Length(LPart) do
        if not IsHexDigit(LPart[I]) then
          Exit;
      Inc(ACount);
    end;
    LStart := LPos + 1;
  until LLast;
  Result := True;
end;

function ValidIPv6(const AText: string): Boolean;
var
  LGap, LHead, LTail: Integer;
begin
  Result := False;
  if Pos(':', AText) = 0 then
    Exit;
  LGap := Pos('::', AText);
  if LGap = 0 then
    Result := CountGroups(AText, True, LHead) and (LHead = 8)
  else
  begin
    if Pos('::', Copy(AText, LGap + 1, MaxInt)) > 0 then
      Exit;
    Result := CountGroups(Copy(AText, 1, LGap - 1), False, LHead) and
      CountGroups(Copy(AText, LGap + 2, MaxInt), True, LTail) and
      (LHead + LTail <= 7);
  end;
end;

/// the normalized registered name; empty text and ok = False on an error
function NormalizeRegName(const AText: string; out AHost: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := False;
  AHost := '';
  I := 1;
  while I <= Length(AText) do
  begin
    C := AText[I];
    if C = '%' then
    begin
      C := Chr(HexValue(AText[I + 1]) * 16 + HexValue(AText[I + 2]));
      if not IsUnreserved(C) then
        Exit;
      Inc(I, 2);
    end
    else if not (IsUnreserved(C) or IsSubDelim(C)) then
      Exit;
    AHost := AHost + LowerCase(C);
    Inc(I);
  end;
  if (AHost <> '') and (AHost[Length(AHost)] = '.') then
    SetLength(AHost, Length(AHost) - 1);
  Result := True;
end;

function ParsePort(const AText: string; var R: TURI): Boolean;
var
  I, LValue: Integer;
begin
  Result := False;
  if AText = '' then
    Exit(True);
  LValue := 0;
  for I := 1 to Length(AText) do
  begin
    if not (AText[I] in ['0'..'9']) then
      Exit;
    LValue := LValue * 10 + Ord(AText[I]) - Ord('0');
    if LValue > 65535 then
      Exit;
  end;
  R.FPort := LValue;
  R.FHasPort := True;
  Result := True;
end;

function ParseAuthority(const AAuth: string; var R: TURI): string;
var
  LAt, I, LClose, LColon: Integer;
  LHostPort, LRest, LIp: string;
begin
  Result := '';
  LAt := 0;
  for I := Length(AAuth) downto 1 do
    if AAuth[I] = '@' then
    begin
      LAt := I;
      Break;
    end;
  LHostPort := AAuth;
  if LAt > 0 then
  begin
    R.FUserInfo := Copy(AAuth, 1, LAt - 1);
    R.FHasUserInfo := True;
    for I := 1 to Length(R.FUserInfo) do
      if not (IsUnreserved(R.FUserInfo[I]) or IsSubDelim(R.FUserInfo[I]) or
        (R.FUserInfo[I] in [':', '%', '@'])) then
        Exit('the user information holds a character that is not allowed');
    LHostPort := Copy(AAuth, LAt + 1, MaxInt);
  end;
  if (LHostPort <> '') and (LHostPort[1] = '[') then
  begin
    LClose := Pos(']', LHostPort);
    if LClose = 0 then
      Exit('the IP literal has no closing bracket');
    LIp := Copy(LHostPort, 2, LClose - 2);
    if Pos('%', LIp) > 0 then
      Exit('the IP literal holds a zone identifier');
    if not ValidIPv6(LIp) then
      Exit('the IP literal is not a valid IPv6 address');
    R.FHost := LowerCase(LIp);
    R.FIsIPLiteral := True;
    LRest := Copy(LHostPort, LClose + 1, MaxInt);
    if LRest <> '' then
    begin
      if LRest[1] <> ':' then
        Exit('the IP literal is followed by an unexpected character');
      if not ParsePort(Copy(LRest, 2, MaxInt), R) then
        Exit('the port is not valid');
    end;
    Exit;
  end;
  LColon := Pos(':', LHostPort);
  if LColon > 0 then
  begin
    if not ParsePort(Copy(LHostPort, LColon + 1, MaxInt), R) then
      Exit('the port is not valid');
    LHostPort := Copy(LHostPort, 1, LColon - 1);
  end;
  if not NormalizeRegName(LHostPort, R.FHost) then
    Result := 'the host holds a character that is not allowed';
end;

/// the empty text when AUri is valid, else the text of the problem
function ParseCore(const AUri: string; out R: TURI): string;
var
  LI, LEnd: Integer;
  LRest, LAuth: string;
begin
  ClearURI(R);
  Result := CheckBytes(AUri);
  if Result <> '' then
    Exit;
  LI := 1;
  while (LI <= Length(AUri)) and not (AUri[LI] in [':', '/', '?', '#']) do
    Inc(LI);
  LRest := AUri;
  if (LI <= Length(AUri)) and (AUri[LI] = ':') then
  begin
    if not ValidScheme(Copy(AUri, 1, LI - 1)) then
      Exit('the scheme is not valid');
    R.FScheme := LowerCase(Copy(AUri, 1, LI - 1));
    LRest := Copy(AUri, LI + 1, MaxInt);
  end;
  if Copy(LRest, 1, 2) = '//' then
  begin
    LEnd := 3;
    while (LEnd <= Length(LRest)) and not (LRest[LEnd] in ['/', '?', '#']) do
      Inc(LEnd);
    LAuth := Copy(LRest, 3, LEnd - 3);
    LRest := Copy(LRest, LEnd, MaxInt);
    R.FHasAuthority := True;
    Result := ParseAuthority(LAuth, R);
    if Result <> '' then
      Exit;
    if (R.FHost = '') and ((R.FScheme = 'http') or (R.FScheme = 'https')) then
      Exit('the host is empty');
  end;
  LEnd := 1;
  while (LEnd <= Length(LRest)) and not (LRest[LEnd] in ['?', '#']) do
    Inc(LEnd);
  R.FPath := Copy(LRest, 1, LEnd - 1);
  LRest := Copy(LRest, LEnd, MaxInt);
  if (LRest <> '') and (LRest[1] = '?') then
  begin
    LEnd := 2;
    while (LEnd <= Length(LRest)) and (LRest[LEnd] <> '#') do
      Inc(LEnd);
    R.FQuery := Copy(LRest, 2, LEnd - 2);
    R.FHasQuery := True;
    LRest := Copy(LRest, LEnd, MaxInt);
  end;
  if LRest <> '' then
  begin
    R.FFragment := Copy(LRest, 2, MaxInt);
    R.FHasFragment := True;
    if Pos('#', R.FFragment) > 0 then
      Exit('the fragment holds a number sign');
  end;
end;

function TryParseURI(const AUri: string; out AResult: TURI): Boolean;
begin
  Result := ParseCore(AUri, AResult) = '';
  if not Result then
    ClearURI(AResult);
end;

function ParseURI(const AUri: string): TURI;
var
  LProblem: string;
begin
  LProblem := ParseCore(AUri, Result);
  if LProblem <> '' then
    raise EHttpProtocolError.Create(LProblem, ecProtocolError);
end;

function RemoveDotSegments(const APath: string): string;
var
  LIn, LOut: string;
  LPos: Integer;

  procedure DropLastSegment;
  var
    K: Integer;
  begin
    K := Length(LOut);
    while (K > 0) and (LOut[K] <> '/') do
      Dec(K);
    if K = 0 then
      LOut := ''
    else
      SetLength(LOut, K - 1);
  end;

begin
  LIn := APath;
  LOut := '';
  while LIn <> '' do
  begin
    if Copy(LIn, 1, 3) = '../' then
      Delete(LIn, 1, 3)
    else if Copy(LIn, 1, 2) = './' then
      Delete(LIn, 1, 2)
    else if Copy(LIn, 1, 3) = '/./' then
      Delete(LIn, 1, 2)
    else if LIn = '/.' then
      LIn := '/'
    else if Copy(LIn, 1, 4) = '/../' then
    begin
      Delete(LIn, 1, 3);
      DropLastSegment;
    end
    else if LIn = '/..' then
    begin
      LIn := '/';
      DropLastSegment;
    end
    else if (LIn = '.') or (LIn = '..') then
      LIn := ''
    else
    begin
      LPos := 2;
      while (LPos <= Length(LIn)) and (LIn[LPos] <> '/') do
        Inc(LPos);
      LOut := LOut + Copy(LIn, 1, LPos - 1);
      Delete(LIn, 1, LPos - 1);
    end;
  end;
  Result := LOut;
end;

function MergePaths(const ABase, ARef: TURI): string;
var
  K: Integer;
begin
  if ABase.FHasAuthority and (ABase.FPath = '') then
    Exit('/' + ARef.FPath);
  K := Length(ABase.FPath);
  while (K > 0) and (ABase.FPath[K] <> '/') do
    Dec(K);
  Result := Copy(ABase.FPath, 1, K) + ARef.FPath;
end;

procedure TakeAuthority(const ASource: TURI; var ATarget: TURI);
begin
  ATarget.FUserInfo := ASource.FUserInfo;
  ATarget.FHost := ASource.FHost;
  ATarget.FPort := ASource.FPort;
  ATarget.FHasPort := ASource.FHasPort;
  ATarget.FHasAuthority := ASource.FHasAuthority;
  ATarget.FHasUserInfo := ASource.FHasUserInfo;
  ATarget.FIsIPLiteral := ASource.FIsIPLiteral;
end;

function ResolveReference(const ABase, ARef: TURI): TURI;
begin
  if not ABase.IsAbsolute then
    raise EHttpProtocolError.Create('the base URI has no scheme',
      ecProtocolError);
  Result := ARef;
  ClearURI(Result);
  if ARef.IsAbsolute then
  begin
    Result := ARef;
    Result.FPath := RemoveDotSegments(ARef.FPath);
  end
  else
  begin
    Result.FScheme := ABase.FScheme;
    if ARef.FHasAuthority then
    begin
      TakeAuthority(ARef, Result);
      Result.FPath := RemoveDotSegments(ARef.FPath);
      Result.FQuery := ARef.FQuery;
      Result.FHasQuery := ARef.FHasQuery;
    end
    else
    begin
      TakeAuthority(ABase, Result);
      if ARef.FPath = '' then
      begin
        Result.FPath := ABase.FPath;
        if ARef.FHasQuery then
        begin
          Result.FQuery := ARef.FQuery;
          Result.FHasQuery := True;
        end
        else
        begin
          Result.FQuery := ABase.FQuery;
          Result.FHasQuery := ABase.FHasQuery;
        end;
      end
      else
      begin
        if ARef.FPath[1] = '/' then
          Result.FPath := RemoveDotSegments(ARef.FPath)
        else
          Result.FPath := RemoveDotSegments(MergePaths(ABase, ARef));
        Result.FQuery := ARef.FQuery;
        Result.FHasQuery := ARef.FHasQuery;
      end;
    end;
  end;
  Result.FFragment := ARef.FFragment;
  Result.FHasFragment := ARef.FHasFragment;
end;

function UriToString(const AUri: TURI): string;
begin
  Result := '';
  if AUri.FScheme <> '' then
    Result := AUri.FScheme + ':';
  if AUri.FHasAuthority then
  begin
    Result := Result + '//';
    if AUri.FHasUserInfo then
      Result := Result + AUri.FUserInfo + '@';
    Result := Result + AUri.Authority;
  end;
  Result := Result + AUri.FPath;
  if AUri.FHasQuery then
    Result := Result + '?' + AUri.FQuery;
  if AUri.FHasFragment then
    Result := Result + '#' + AUri.FFragment;
end;

function EffectivePort(const A: TURI): Integer;
begin
  if A.FHasPort then
    Exit(A.FPort);
  if A.FScheme = 'http' then
    Result := 80
  else if A.FScheme = 'https' then
    Result := 443
  else
    Result := -1;
end;

function SameHost(const A, B: TURI): Boolean;
begin
  Result := A.FHasAuthority and B.FHasAuthority and (A.FHost <> '') and
    (A.FHost = B.FHost);
end;

function SameOrigin(const A, B: TURI): Boolean;
begin
  Result := (A.FScheme = B.FScheme) and SameHost(A, B) and
    (EffectivePort(A) = EffectivePort(B));
end;

function IsHttpToHttpsUpgrade(const ABase, ATarget: TURI): Boolean;
begin
  Result := SameHost(ABase, ATarget) and (ABase.FScheme = 'http') and
    (ATarget.FScheme = 'https');
end;

end.
