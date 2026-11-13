{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, frames, errors, flow control, test
notes:
  - This test checks the error code of a wire value, the raw code of RST_STREAM and
    GOAWAY, the clamp of a WINDOW_UPDATE increment and the role check of PUSH_PROMISE.
---
}
unit Http2.Common.FrameDetails.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Errors, Http2.Common.Frames,
  Http2.Common.FlowControl;

type
  TFrameDetailsTest = class(TTestCase)
  private
    function RawFrame(const AType: TFrameType; const AStreamId: LongWord;
      const AValue: LongWord): TFrame;
  published
    procedure TestWireCodeInRangeMaps;
    procedure TestWireCodeOutOfRangeIsInternal;
    procedure TestRstStreamKeepsRawCode;
    procedure TestRstStreamTruncatedCodeIsNotNoError;
    procedure TestGoAwayKeepsRawCode;
    procedure TestUpdateIncrementClampsToWindowMax;
    procedure TestUpdateIncrementKeepsRest;
    procedure TestPushPromiseRefusedForServer;
    procedure TestPushPromiseAcceptedForClient;
  end;

implementation

function TFrameDetailsTest.RawFrame(const AType: TFrameType;
  const AStreamId: LongWord; const AValue: LongWord): TFrame;
var
  Payload: TBytes;
  Len: Integer;
begin
  if AType = ftGoAway then
    Len := 8
  else
    Len := 4;
  SetLength(Payload, Len);
  FillChar(Payload[0], Len, 0);
  Payload[Len - 4] := (AValue shr 24) and $FF;
  Payload[Len - 3] := (AValue shr 16) and $FF;
  Payload[Len - 2] := (AValue shr 8) and $FF;
  Payload[Len - 1] := AValue and $FF;
  Result := TFrame.Create(AType, [], AStreamId, Payload);
end;

procedure TFrameDetailsTest.TestWireCodeInRangeMaps;
begin
  AssertEquals('code 0', Ord(ecNoError), Ord(ErrorCodeFromWire(0)));
  AssertEquals('code 13', Ord(ecHttp11Required), Ord(ErrorCodeFromWire(13)));
end;

procedure TFrameDetailsTest.TestWireCodeOutOfRangeIsInternal;
begin
  AssertEquals('code $100', Ord(ecInternalError), Ord(ErrorCodeFromWire($100)));
  AssertEquals('code $FFFFFFFF', Ord(ecInternalError),
    Ord(ErrorCodeFromWire($FFFFFFFF)));
  AssertEquals('code 14', Ord(ecInternalError), Ord(ErrorCodeFromWire(14)));
end;

procedure TFrameDetailsTest.TestRstStreamKeepsRawCode;
var
  Frame: TFrame;
  Code: THttp2ErrorCode;
  Raw: LongWord;
begin
  Frame := RawFrame(ftRstStream, 1, $100);
  ParseRstStreamRaw(Frame, Code, Raw);
  AssertEquals('mapped code', Ord(ecInternalError), Ord(Code));
  AssertEquals('raw code', $100, Integer(Raw));
end;

procedure TFrameDetailsTest.TestRstStreamTruncatedCodeIsNotNoError;
var
  Frame: TFrame;
  Code: THttp2ErrorCode;
begin
  Frame := RawFrame(ftRstStream, 1, $100);
  ParseRstStream(Frame, Code);
  AssertTrue('a $100 code must not read as NO_ERROR', Code <> ecNoError);
  AssertEquals(Ord(ecInternalError), Ord(Code));
end;

procedure TFrameDetailsTest.TestGoAwayKeepsRawCode;
var
  Frame: TFrame;
  LastId: LongWord;
  Code: THttp2ErrorCode;
  Debug: TBytes;
  Raw: LongWord;
begin
  Frame := RawFrame(ftGoAway, 0, $FFFFFFFF);
  ParseGoAwayRaw(Frame, LastId, Code, Debug, Raw);
  AssertEquals('mapped code', Ord(ecInternalError), Ord(Code));
  AssertEquals('raw code', LongWord($FFFFFFFF), Raw);
  AssertEquals('debug length', 0, Length(Debug));
end;

procedure TFrameDetailsTest.TestUpdateIncrementClampsToWindowMax;
var
  Win: TWindow;
  Inc1: LongWord;
begin
  Win := TWindow.Defaults(0);
  Win.ApplyDataReceived(3000000000);
  Inc1 := Win.UpdateIncrement;
  AssertEquals('first increment', LongWord(MaxWindowSize), Inc1);
end;

procedure TFrameDetailsTest.TestUpdateIncrementKeepsRest;
var
  Win: TWindow;
  Inc1, Inc2: LongWord;
begin
  Win := TWindow.Defaults(0);
  Win.ApplyDataReceived(3000000000);
  Inc1 := Win.UpdateIncrement;
  AssertEquals('rest kept in the window', Int64(3000000000) - MaxWindowSize,
    Win.Consumed);
  Inc2 := Win.UpdateIncrement;
  AssertEquals('second increment', LongWord(3000000000 - MaxWindowSize), Inc2);
  AssertEquals('nothing left', Int64(0), Win.Consumed);
  AssertEquals('total', Int64(3000000000), Int64(Inc1) + Int64(Inc2));
end;

procedure TFrameDetailsTest.TestPushPromiseRefusedForServer;
var
  Frame: TFrame;
begin
  Frame := RawFrame(ftPushPromise, 1, 2);
  try
    ValidateFrameForRole(Frame, DefaultMaxFrameSize, erServer);
    Fail('a server must refuse a PUSH_PROMISE');
  except
    on E: EHttpProtocolError do
      AssertEquals('code', Ord(ecProtocolError), Ord(E.ErrorCode));
  end;
end;

procedure TFrameDetailsTest.TestPushPromiseAcceptedForClient;
var
  Frame: TFrame;
begin
  Frame := RawFrame(ftPushPromise, 1, 2);
  ValidateFrameForRole(Frame, DefaultMaxFrameSize, erClient);
end;

initialization
  RegisterTest(TFrameDetailsTest);
end.
