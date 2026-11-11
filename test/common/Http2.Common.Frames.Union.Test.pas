{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, frames, tests
notes:
  - This unit tests frame APIs that the source roles do not share.
---
}
unit Http2.Common.Frames.Union.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Common.Errors,
  Http2.Common.Headers, Http2.Common.Frames;

type
  TCommonFramesUnionTest = class(TTestCase)
  published
    procedure TestFrameMetadataDefaults;
    procedure TestSettingsDecodeUsesBase;
    procedure TestClientPrefaceHelpers;
    procedure TestHeaderBlockOffsetIncludesPaddingAndPriority;
    procedure TestHeaderBlockOffsetRejectsShortPriorityFields;
    procedure TestHeaderPriorityDependsOn;
    procedure TestFrameMetadataIsNotSerialized;
  end;

implementation

procedure TCommonFramesUnionTest.TestFrameMetadataDefaults;
var
  F: TFrame;
begin
  F := TFrame.Create(ftData, [], 1, nil);
  AssertEquals(0, F.ArrivedUs);
  AssertFalse(F.HeadersDecoded);
  AssertTrue(F.DecodedHeaders = nil);
end;

procedure TCommonFramesUnionTest.TestSettingsDecodeUsesBase;
var
  Base, Got: TConnectionSettings;
  Payload: TBytes;
begin
  Base := TConnectionSettings.Defaults;
  Base.MaxConcurrentStreams := 21;
  Base.EnableConnectProtocol := True;
  SetLength(Payload, 6);
  Payload[0] := 0; Payload[1] := SettingMaxFrameSize;
  Payload[2] := 0; Payload[3] := 1; Payload[4] := 0; Payload[5] := 0;
  Got := TConnectionSettings.Decode(Payload, Base);
  AssertEquals(65536, Got.MaxFrameSize);
  AssertEquals(21, Got.MaxConcurrentStreams);
  AssertTrue(Got.EnableConnectProtocol);
end;

procedure TCommonFramesUnionTest.TestClientPrefaceHelpers;
var
  B: TBytes;
begin
  SetLength(B, ClientPrefaceSize);
  Move(ClientPreface[0], B[0], ClientPrefaceSize);
  AssertTrue(CheckClientPreface(B));
  B[0] := B[0] xor $FF;
  AssertFalse(CheckClientPreface(B));
end;

procedure TCommonFramesUnionTest.TestHeaderBlockOffsetIncludesPaddingAndPriority;
var
  F: TFrame;
begin
  F.Header.FrameType := ftHeaders;
  F.Header.Flags := [ffPadded, ffPriority];
  F.Payload := TBytes.Create(2, 0, 0, 0, 0, 0, 9, 8);
  AssertEquals(6, HeaderBlockOffset(F));
end;

procedure TCommonFramesUnionTest.TestHeaderBlockOffsetRejectsShortPriorityFields;
var
  F: TFrame;
begin
  F.Header.FrameType := ftHeaders;
  F.Header.Flags := [ffPriority];
  F.Payload := TBytes.Create(0, 0, 0, 0);
  try
    HeaderBlockOffset(F);
    Fail('short priority block must raise');
  except
    on E: EHttpProtocolError do
      AssertEquals(Ord(ecProtocolError), Ord(E.ErrorCode));
  end;

  F.Header.Flags := [ffPadded, ffPriority];
  F.Payload := TBytes.Create(0, 0, 0, 0, 0);
  try
    HeaderBlockOffset(F);
    Fail('short padded priority block must raise');
  except
    on E: EHttpProtocolError do
      AssertEquals(Ord(ecProtocolError), Ord(E.ErrorCode));
  end;
end;

procedure TCommonFramesUnionTest.TestHeaderPriorityDependsOn;
var
  F: TFrame;
begin
  F.Header.FrameType := ftHeaders;
  F.Header.Flags := [ffPriority];
  F.Payload := TBytes.Create(0, 0, 0, 5, 0);
  AssertEquals(5, HeaderPriorityDependsOn(F));
end;

procedure TCommonFramesUnionTest.TestFrameMetadataIsNotSerialized;
var
  Plain, Marked: TFrame;
  PlainStream, MarkedStream: TMemoryStream;
  I: Integer;
begin
  Plain := TFrame.Create(ftData, [ffEndStream], 3, TBytes.Create(1, 2, 3));
  Marked := Plain;
  Marked.ArrivedUs := 123456;
  Marked.HeadersDecoded := True;
  SetLength(Marked.DecodedHeaders, 1);
  Marked.DecodedHeaders[0].Name := HeaderMethod;
  Marked.DecodedHeaders[0].Value := 'GET';
  PlainStream := TMemoryStream.Create;
  MarkedStream := TMemoryStream.Create;
  try
    WriteFrame(PlainStream, Plain);
    WriteFrame(MarkedStream, Marked);
    AssertEquals(PlainStream.Size, MarkedStream.Size);
    for I := 0 to PlainStream.Size - 1 do
      AssertEquals(PByte(PlainStream.Memory)[I], PByte(MarkedStream.Memory)[I]);
  finally
    PlainStream.Free;
    MarkedStream.Free;
  end;
end;

initialization
  RegisterTest(TCommonFramesUnionTest);

end.
