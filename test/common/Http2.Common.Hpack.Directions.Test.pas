{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, hpack, direction, tests
notes:
  - This test checks independent HPACK directions and size-update emission.
---
}
unit Http2.Common.Hpack.Directions.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Errors, Http2.Common.Hpack;

type
  THpackDirectionsTest = class(TTestCase)
  private
    function Bytes(const AValues: array of Byte): TBytes;
    function Field(const AName, AValue: string): THttpHeaderField;
    procedure AssertBytes(const AExpected, AActual: TBytes);
  published
    procedure TestPeerSizeDoesNotChangeDecoderLimit;
    procedure TestEncoderUsesTheSmallerLimit;
    procedure TestShrinkThenGrowEmitsBothUpdates;
    procedure TestZeroSizeUpdateIsEmitted;
    procedure TestApplySettingsKeepsLegacyBehavior;
    procedure TestDecoderEnforcesItsLocalLimit;
    procedure TestHeaderListLimitStopsDecode;
  end;

implementation

function THpackDirectionsTest.Bytes(const AValues: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

function THpackDirectionsTest.Field(const AName,
  AValue: string): THttpHeaderField;
begin
  Result.Name := AName;
  Result.Value := AValue;
  Result.Sensitive := False;
end;

procedure THpackDirectionsTest.AssertBytes(const AExpected,
  AActual: TBytes);
var
  I: Integer;
begin
  AssertEquals('byte count', Length(AExpected), Length(AActual));
  for I := 0 to High(AExpected) do
    AssertEquals(Format('byte %d', [I]), AExpected[I], AActual[I]);
end;

procedure THpackDirectionsTest.TestPeerSizeDoesNotChangeDecoderLimit;
var
  Codec: THpackCodec;
begin
  Codec := THpackCodec.Create;
  try
    Codec.SetDecoderLimit(1024);
    Codec.SetPeerTableSize(128);
    AssertEquals('local decoder limit', 1024, Codec.DecoderMaxSize);
    AssertEquals('peer-sized encoder', 128, Codec.EncoderMaxSize);
  finally
    Codec.Free;
  end;
end;

procedure THpackDirectionsTest.TestEncoderUsesTheSmallerLimit;
var
  Codec: THpackCodec;
begin
  Codec := THpackCodec.Create;
  try
    Codec.SetEncoderCap(512);
    Codec.SetPeerTableSize(4096);
    AssertEquals('local cap applies', 512, Codec.EncoderMaxSize);
    AssertBytes(Bytes([$3F, $E1, $03]), Codec.Encode(nil));
    Codec.SetPeerTableSize(128);
    AssertEquals('peer limit applies', 128, Codec.EncoderMaxSize);
  finally
    Codec.Free;
  end;
end;

procedure THpackDirectionsTest.TestShrinkThenGrowEmitsBothUpdates;
var
  Codec: THpackCodec;
  Encoded: TBytes;
begin
  Codec := THpackCodec.Create;
  try
    Codec.SetPeerTableSize(128);
    Codec.SetPeerTableSize(256);
    Encoded := Codec.Encode(nil);
    AssertBytes(Bytes([$3F, $61, $3F, $E1, $01]), Encoded);
    AssertEquals('final encoder size', 256, Codec.EncoderMaxSize);
    AssertEquals('no duplicate update', 0, Length(Codec.Encode(nil)));
  finally
    Codec.Free;
  end;
end;

procedure THpackDirectionsTest.TestZeroSizeUpdateIsEmitted;
var
  Codec: THpackCodec;
begin
  Codec := THpackCodec.Create;
  try
    Codec.SetPeerTableSize(0);
    AssertBytes(Bytes([$20]), Codec.Encode(nil));
    AssertEquals('zero encoder size', 0, Codec.EncoderMaxSize);
  finally
    Codec.Free;
  end;
end;

procedure THpackDirectionsTest.TestApplySettingsKeepsLegacyBehavior;
var
  Codec: THpackCodec;
begin
  Codec := THpackCodec.Create;
  try
    Codec.ApplySettings(512);
    AssertEquals('legacy encoder limit', 512, Codec.EncoderMaxSize);
    AssertEquals('legacy decoder limit', 512, Codec.DecoderMaxSize);
  finally
    Codec.Free;
  end;
end;

procedure THpackDirectionsTest.TestDecoderEnforcesItsLocalLimit;
var
  Sender, Receiver: THpackCodec;
  Encoded: TBytes;
  Raised: Boolean;
begin
  Sender := THpackCodec.Create;
  Receiver := THpackCodec.Create;
  try
    Sender.SetPeerTableSize(257);
    Encoded := Sender.Encode(nil);
    Receiver.SetDecoderLimit(256);
    Receiver.SetPeerTableSize(128);
    Raised := False;
    try
      Receiver.Decode(Encoded);
    except
      on E: EHttpProtocolError do
        Raised := E.ErrorCode = ecCompressionError;
    end;
    AssertTrue('update above local limit is rejected', Raised);
  finally
    Receiver.Free;
    Sender.Free;
  end;
end;

procedure THpackDirectionsTest.TestHeaderListLimitStopsDecode;
var
  Sender, Receiver: THpackCodec;
  Encoded: TBytes;
  Raised: Boolean;
begin
  Sender := THpackCodec.Create;
  Receiver := THpackCodec.Create;
  try
    Sender.Huffman := False;
    Encoded := Sender.Encode([Field('x', 'x')]);
    Receiver.MaxHeaderListSize := 33;
    Raised := False;
    try
      Receiver.Decode(Encoded);
    except
      on E: EHttpProtocolError do
        Raised := E.ErrorCode = ecEnhanceYourCalm;
    end;
    AssertTrue('oversized header list is rejected', Raised);
  finally
    Receiver.Free;
    Sender.Free;
  end;
end;

initialization
  RegisterTest(THpackDirectionsTest);
end.
