{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: hpack, integer, decoder, test
notes:
  - This test checks the continuation limit of the HPACK integer decoder.
---
}
unit Http2.Common.HpackInteger.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Errors, Http2.Common.Hpack;

type
  THpackIntegerTest = class(TTestCase)
  private
    function DecodeError(const ABlock: TBytes): string;
    function NameBlock(const AIntBytes: array of Byte;
      ANameLength: Integer): TBytes;
    function Block(const AValues: array of Byte): TBytes;
  published
    procedure TestAnalysisCaseIsCompressionError;
    procedure TestLongestValidEncodingDecodes;
    procedure TestFiveContinuationOctetsDecode;
    procedure TestSixContinuationOctetsAreRefused;
    procedure TestTruncatedIntegerIsRefused;
  end;

implementation

function THpackIntegerTest.Block(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

{ Builds a literal header field without indexing and a new name. The name
  length is the integer under test (7-bit prefix). The name holds ANameLength
  bytes, and the value is empty. }
function THpackIntegerTest.NameBlock(const AIntBytes: array of Byte;
  ANameLength: Integer): TBytes;
var
  I, N: Integer;
begin
  SetLength(Result, 1 + Length(AIntBytes) + ANameLength + 1);
  N := 0;
  Result[N] := $00;
  Inc(N);
  for I := 0 to High(AIntBytes) do
  begin
    Result[N] := AIntBytes[I];
    Inc(N);
  end;
  for I := 1 to ANameLength do
  begin
    Result[N] := Ord('a');
    Inc(N);
  end;
  Result[N] := $00;
end;

{ Decodes the block and returns the message of the protocol error, or an
  empty string when the block decodes. }
function THpackIntegerTest.DecodeError(const ABlock: TBytes): string;
var
  Codec: THpackCodec;
begin
  Result := '';
  Codec := THpackCodec.Create;
  try
    try
      Codec.Decode(ABlock);
    except
      on E: EHttpProtocolError do
      begin
        AssertEquals('error code', Ord(ecCompressionError), Ord(E.ErrorCode));
        Result := E.Message;
      end;
    end;
  finally
    Codec.Free;
  end;
end;

procedure THpackIntegerTest.TestAnalysisCaseIsCompressionError;
begin
  // 7F, ten continuation octets of 80, then 01: the shift passes 28
  AssertEquals('integer overflow', 'HPACK: integer overflow',
    DecodeError(NameBlock([$7F, $80, $80, $80, $80, $80, $80, $80, $80,
      $80, $80, $01], 0)));
end;

procedure THpackIntegerTest.TestLongestValidEncodingDecodes;
begin
  // 2147483647 with a 7-bit prefix: 7F, then 80 FF FF FF 07. The decoded
  // length overruns the block, so the decoder reports the overrun and not
  // an integer error.
  AssertEquals('overrun, not an integer error',
    'HPACK: string literal length overruns block',
    DecodeError(NameBlock([$7F, $80, $FF, $FF, $FF, $07], 0)));
end;

procedure THpackIntegerTest.TestFiveContinuationOctetsDecode;
begin
  // 7F, then 80 80 80 80 00: five continuation octets, value 127
  AssertEquals('decodes', '', DecodeError(NameBlock([$7F, $80, $80, $80,
    $80, $00], 127)));
end;

procedure THpackIntegerTest.TestSixContinuationOctetsAreRefused;
begin
  // 7F, then 80 80 80 80 80 00: six continuation octets
  AssertEquals('integer overflow', 'HPACK: integer overflow',
    DecodeError(NameBlock([$7F, $80, $80, $80, $80, $80, $00], 0)));
end;

procedure THpackIntegerTest.TestTruncatedIntegerIsRefused;
begin
  // the continuation octet 80 has no successor
  AssertTrue('truncated integer is a compression error',
    DecodeError(Block([$00, $7F, $80])) <> '');
end;

initialization
  RegisterTest(THpackIntegerTest);
end.
