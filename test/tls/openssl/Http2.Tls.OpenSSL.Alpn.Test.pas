{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, openssl, alpn, regression
notes:
  - this checks provider-local ALPN vector selection
---
}
unit Http2.Tls.OpenSSL.Alpn.Test;
{$mode delphi}{$H+}
interface
function RunOpenSSLAlpnRegressionTests: Integer;
implementation
uses SysUtils, Http2.OpenSSL.Session;

const
  AlpnSelected = 0;
  AlpnFatal = 2;
  AlpnNoAck = 3;

procedure AssertCase(const AId: string; const ACondition: Boolean;
  var ACount: Integer);
begin
  if not ACondition then
    raise Exception.Create('FAIL ' + AId);
  Inc(ACount);
  WriteLn('PASS ', AId);
end;

function EncodeOffer(const ANames: array of string): TBytes;
var I, J, Offset: Integer; Name: UTF8String;
begin
  Result := nil;
  for I := 0 to High(ANames) do
  begin
    Name := UTF8String(ANames[I]);
    Offset := Length(Result);
    SetLength(Result, Offset + 1 + Length(Name));
    Result[Offset] := Byte(Length(Name));
    for J := 1 to Length(Name) do
      Result[Offset + J] := Byte(Name[J]);
  end;
end;

function Select(const APreferred: array of string; const AInput: TBytes;
  out ASelected: PByte; out ASelectedLength: Byte): Integer;
var Preferred: TBytes;
begin
  Preferred := EncodeOffer(APreferred);
  ASelected := nil;
  ASelectedLength := 0;
  if Length(AInput) = 0 then
  begin
    if Length(Preferred) = 0 then
      Result := OpenSSLSelectAlpnVector(nil, 0, nil, 0, @ASelected,
        @ASelectedLength)
    else
      Result := OpenSSLSelectAlpnVector(@Preferred[0], Length(Preferred),
        nil, 0, @ASelected, @ASelectedLength);
  end
  else if Length(Preferred) = 0 then
    Result := OpenSSLSelectAlpnVector(nil, 0, @AInput[0], Length(AInput),
      @ASelected, @ASelectedLength)
  else
    Result := OpenSSLSelectAlpnVector(@Preferred[0], Length(Preferred),
      @AInput[0], Length(AInput), @ASelected, @ASelectedLength);
end;

function SelectedText(const ASelected: PByte; const ALength: Byte): string;
begin
  if (ASelected = nil) or (ALength = 0) then
    Exit('');
  SetString(Result, PAnsiChar(ASelected), ALength);
end;

function RunOpenSSLAlpnRegressionTests: Integer;
var
  Offer, MultiOffer, BadTail, ZeroEntry, Truncated: TBytes;
  Selected: PByte;
  SelectedLength: Byte;
  Status: Integer;
  PreferredH2, PreferredHttp11: TBytes;
begin
  Result := 0;
  Offer := EncodeOffer(['h2']);
  MultiOffer := EncodeOffer(['http/1.1', 'h2']);
  PreferredH2 := EncodeOffer(['h2']);
  PreferredHttp11 := EncodeOffer(['http/1.1']);

  Status := Select(['h2'], Offer, Selected, SelectedLength);
  AssertCase('openssl.alpn.selects_h2_alone',
    (Status = AlpnSelected) and (SelectedText(Selected, SelectedLength) = 'h2'), Result);
  Status := Select(['h2'], MultiOffer, Selected, SelectedLength);
  AssertCase('openssl.alpn.selects_h2_from_multi_entry_list',
    (Status = AlpnSelected) and (SelectedText(Selected, SelectedLength) = 'h2'), Result);
  Status := Select(['h2', 'http/1.1'], MultiOffer, Selected, SelectedLength);
  AssertCase('openssl.alpn.prefers_h2_over_http11',
    (Status = AlpnSelected) and (SelectedText(Selected, SelectedLength) = 'h2'), Result);
  Status := Select(['h2'], EncodeOffer(['http/1.1']), Selected, SelectedLength);
  AssertCase('openssl.alpn.refuses_http11_without_fallback', Status = AlpnFatal, Result);
  Status := Select(['h2', 'http/1.1'], EncodeOffer(['http/1.1']), Selected, SelectedLength);
  AssertCase('openssl.alpn.accepts_http11_with_fallback',
    (Status = AlpnSelected) and (SelectedText(Selected, SelectedLength) = 'http/1.1'), Result);
  Status := Select(['h2'], EncodeOffer(['spdy/3']), Selected, SelectedLength);
  AssertCase('openssl.alpn.refuses_no_acceptable_protocol', Status = AlpnFatal, Result);

  SetLength(ZeroEntry, 1);
  ZeroEntry[0] := 0;
  Status := Select(['h2'], ZeroEntry, Selected, SelectedLength);
  AssertCase('openssl.alpn.refuses_zero_length_entry', Status = AlpnFatal, Result);
  SetLength(Truncated, 2);
  Truncated[0] := 4; Truncated[1] := Ord('h');
  Status := Select(['h2'], Truncated, Selected, SelectedLength);
  AssertCase('openssl.alpn.refuses_truncated_entry', Status = AlpnFatal, Result);
  Status := Select(['h2'], nil, Selected, SelectedLength);
  AssertCase('openssl.alpn.refuses_empty_list', Status = AlpnFatal, Result);
  AssertCase('openssl.alpn.chosen_name_matches_entry',
    (Select(['h2'], Offer, Selected, SelectedLength) = AlpnSelected) and
    (SelectedText(Selected, SelectedLength) = 'h2'), Result);
  AssertCase('openssl.alpn.callback_points_at_name_octets',
    (Selected <> nil) and (Selected = @Offer[1]), Result);
  AssertCase('openssl.alpn.callback_reports_name_length', SelectedLength = 2, Result);
  Status := Select(['h2'], EncodeOffer(['http/1.1']), Selected, SelectedLength);
  AssertCase('openssl.alpn.callback_refuses_unacceptable_list', Status = AlpnFatal, Result);
  Status := OpenSSLSelectAlpnVector(@PreferredH2[0], Length(PreferredH2), nil, 0,
    @Selected, @SelectedLength);
  AssertCase('openssl.alpn.callback_refuses_nil_list', Status = AlpnFatal, Result);
  Status := Select([], Offer, Selected, SelectedLength);
  AssertCase('openssl.alpn.no_server_protocols_returns_noack', Status = AlpnNoAck, Result);
  Status := Select(['h2', 'http/1.1'], MultiOffer, Selected, SelectedLength);
  AssertCase('openssl.alpn.prefers_h2_when_http11_first',
    (Status = AlpnSelected) and (SelectedText(Selected, SelectedLength) = 'h2'), Result);
  Status := OpenSSLSelectAlpnVector(@PreferredH2[0], Length(PreferredH2),
    @Offer[0], Length(Offer), @Selected, @SelectedLength);
  AssertCase('openssl.alpn.policy_arguments_are_separate',
    (Status = AlpnSelected) and (SelectedText(Selected, SelectedLength) = 'h2') and
    (OpenSSLSelectAlpnVector(@PreferredHttp11[0], Length(PreferredHttp11),
      @Offer[0], Length(Offer), @Selected, @SelectedLength) = AlpnFatal), Result);

  BadTail := EncodeOffer(['h2']);
  SetLength(BadTail, Length(BadTail) + 1);
  BadTail[High(BadTail)] := 3;
  Status := Select(['h2'], BadTail, Selected, SelectedLength);
  AssertCase('openssl.alpn.refuses_malformed_trailing_entry', Status = AlpnFatal, Result);
  Status := OpenSSLSelectAlpnVector(@PreferredH2[0], Length(PreferredH2),
    @Offer[0], Length(Offer), nil, @SelectedLength);
  AssertCase('openssl.alpn.refuses_nil_output_pointer', Status = AlpnFatal, Result);
  Status := OpenSSLSelectAlpnVector(@PreferredH2[0], Length(PreferredH2),
    @Offer[0], Length(Offer), @Selected, nil);
  AssertCase('openssl.alpn.refuses_nil_output_length', Status = AlpnFatal, Result);
  Status := OpenSSLSelectAlpnVector(@PreferredH2[0], Length(PreferredH2), nil, 1,
    @Selected, @SelectedLength);
  AssertCase('openssl.alpn.refuses_nil_input_with_positive_length', Status = AlpnFatal, Result);
end;

end.
