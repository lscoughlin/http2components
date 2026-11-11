{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Upgrade;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  Http2.Client.Errors,
  Http2.Common.Frames,
  Http2.Common.Headers,
  Http2.Client.Tls,
  Http2.Client.Stream;


function Base64UrlEncode(const AData: TBytes): string;

function Http2SettingsBase64Url: string;

function BuildH2cUpgradeRequest(const ARequest: TStreamRequest): TBytes;

function ReadHeadLineBytewise(const ASock: IHttp2Socket;
  out ALine: string): Boolean;

implementation

uses
  Http2.Client.Http1;

function Base64UrlEncode(const AData: TBytes): string;
const
  cStd = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  I, N: Integer;
  B0, B1, B2: Byte;
begin
  Result := '';
  I := 0;
  N := Length(AData);
  while I < N do
  begin
    B0 := AData[I];
    if I + 1 < N then B1 := AData[I + 1] else B1 := 0;
    if I + 2 < N then B2 := AData[I + 2] else B2 := 0;
    Result := Result + cStd[(B0 shr 2) + 1];
    Result := Result + cStd[(((B0 and $03) shl 4) or (B1 shr 4)) + 1];
    if I + 1 < N then
      Result := Result + cStd[(((B1 and $0F) shl 2) or (B2 shr 6)) + 1];
    if I + 2 < N then
      Result := Result + cStd[(B2 and $3F) + 1];
    Inc(I, 3);
  end;
  // base64url alphabet, no '=' padding (RFC 4648 section 5)
  for N := 1 to Length(Result) do
    if Result[N] = '+' then
      Result[N] := '-'
    else if Result[N] = '/' then
      Result[N] := '_';
end;

function Http2SettingsBase64Url: string;
begin
  // exactly the SETTINGS payload DoPreface writes, so the HTTP2-Settings value
  // and the first SETTINGS frame carry the same settings (RFC 7540 s 3.2.1)
  Result := Base64UrlEncode(TConnectionSettings.Defaults.Encode);
end;

function BuildH2cUpgradeRequest(const ARequest: TStreamRequest): TBytes;
var
  Head, Host, Value: string;
  Names, Vals: TArray<string>;
  I, J: Integer;
  B: TBytes;
begin
  Head := ARequest.Method;
  if Head = '' then
    Head := 'GET';
  if ARequest.Path = '' then
    Head := Head + ' / HTTP/1.1' + #13#10
  else
    Head := Head + ' ' + ARequest.Path + ' HTTP/1.1' + #13#10;

  Host := '';
  if ARequest.Headers <> nil then
    Host := ARequest.Headers.GetFirst(HeaderHost);
  if Host = '' then
    Host := ARequest.Authority;
  if Host = '' then
    raise EHttpProtocolError.Create('h2c upgrade request has no Host',
      ecProtocolError);
  Head := Head + 'Host: ' + Host + #13#10;

  if ARequest.Headers <> nil then
  begin
    Names := ARequest.Headers.Names;
    for I := 0 to High(Names) do
    begin
      if SameText(Names[I], HeaderHost) then
        Continue;
      Vals := ARequest.Headers.GetValues(Names[I]);
      for J := 0 to High(Vals) do
      begin
        Value := Vals[J];
        Head := Head + Names[I] + ': ' + Value + #13#10;
      end;
    end;
  end;

  Head := Head + 'Upgrade: h2c' + #13#10;
  Head := Head + 'Connection: Upgrade, HTTP2-Settings' + #13#10;
  Head := Head + 'HTTP2-Settings: ' + Http2SettingsBase64Url + #13#10;
  Head := Head + #13#10;

  SetLength(B, Length(Head));
  if Length(B) > 0 then
    Move(Head[1], B[0], Length(B));
  Result := B;
end;

function ReadHeadLineBytewise(const ASock: IHttp2Socket;
  out ALine: string): Boolean;
var
  One: array[0..0] of Byte;
  Buf: TBytes;
  N: Integer;
begin
  ALine := '';
  Buf := nil;
  while True do
  begin
    N := ASock.Read(One[0], 1);
    if N <= 0 then
      Break;
    SetLength(Buf, Length(Buf) + 1);
    Buf[High(Buf)] := One[0];
    if One[0] = 10 then
      Break;
    if Length(Buf) > cHttp1MaxHeaderBytes then
      raise EHttpProtocolError.Create(
        'h2c upgrade status line exceeds the header-size limit',
        ecProtocolError);
  end;
  if Length(Buf) = 0 then
    Exit(False);
  if Buf[High(Buf)] = 10 then
    SetLength(Buf, Length(Buf) - 1);
  if (Length(Buf) > 0) and (Buf[High(Buf)] = 13) then
    SetLength(Buf, Length(Buf) - 1);
  SetLength(ALine, Length(Buf));
  if Length(Buf) > 0 then
    Move(Buf[0], ALine[1], Length(Buf));
  Result := True;
end;

end.
