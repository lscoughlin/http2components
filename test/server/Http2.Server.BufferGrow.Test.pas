{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: buffer, growth, overflow, body limit, test, fpcunit
notes:
  - This test checks the growth rule of the HTTP/1.1 buffers for sizes above 1 GiB.
  - The tests pass sizes to the growth function and never allocate a buffer.
---
}
/// Tests of the growth rule of the HTTP/1.1 buffers
unit Http2.Server.BufferGrow.Test;

{$mode delphi}{$H+}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  Http2.Common.Errors, Http2.Server.Http1.Grow, Http2.Server.Http1.Limits;

type
  TBufferGrowTest = class(TTestCase)
  private
    function OneGiB: Int64;
  published
    procedure TestSmallNeedGrowsWithSlack;
    procedure TestCurrentLengthThatFitsIsKept;
    procedure TestNeedNearOneAndAHalfGiBDoesNotOverflow;
    procedure TestNeedAtHighIntegerIsKept;
    procedure TestNeedAboveHighIntegerIsRefused;
    procedure TestSumOfIntegersAboveHighIntegerIsRefused;
    procedure TestBodyLimitAboveHighIntegerIsReported;
    procedure TestBodyLimitAtHighIntegerIsAccepted;
    procedure TestZeroBodyLimitIsAccepted;
  end;

implementation

function TBufferGrowTest.OneGiB: Int64;
begin
  Result := Int64(1) shl 30;
end;

procedure TBufferGrowTest.TestSmallNeedGrowsWithSlack;
begin
  // 100 + 100 div 2 + 256
  AssertTrue('the grown length of 100 octets', GrownLength(100, 0) = 406);
end;

procedure TBufferGrowTest.TestCurrentLengthThatFitsIsKept;
begin
  AssertTrue('a need within the current length does not grow',
    GrownLength(50, 100) = 50);
end;

procedure TBufferGrowTest.TestNeedNearOneAndAHalfGiBDoesNotOverflow;
var
  Need, Grown: Int64;
begin
  // 1.5 GiB; the sum with its half and 256 is above High(Integer)
  Need := OneGiB + OneGiB div 2;
  Grown := GrownLength(Need, 0);
  AssertTrue('the grown length is not below the need', Grown >= Need);
  AssertTrue('the grown length is not above High(Integer)', Grown <= High(Integer));
end;

procedure TBufferGrowTest.TestNeedAtHighIntegerIsKept;
begin
  // 2 GiB - 1; the grown length would pass High(Integer), so the need is kept
  AssertTrue('a need of High(Integer) is kept',
    GrownLength(High(Integer), 0) = High(Integer));
end;

procedure TBufferGrowTest.TestNeedAboveHighIntegerIsRefused;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    GrownLength(Int64(High(Integer)) + 1, 0);
  except
    on E: EHttpProtocolError do
      Raised := E.ErrorCode = ecInternalError;
  end;
  AssertTrue('a need above High(Integer) raises EHttpProtocolError', Raised);
end;

procedure TBufferGrowTest.TestSumOfIntegersAboveHighIntegerIsRefused;
var
  Raised: Boolean;
begin
  // the call sites add two Integer values; the Int64 sum is above High(Integer)
  Raised := False;
  try
    GrownLength(Int64(High(Integer)) + 5, 0);
  except
    on E: EHttpProtocolError do
      Raised := E.ErrorCode = ecInternalError;
  end;
  AssertTrue('an Int64 sum above High(Integer) raises EHttpProtocolError', Raised);
end;

procedure TBufferGrowTest.TestBodyLimitAboveHighIntegerIsReported;
var
  L: THttp11Limits;
  P: TArray<string>;
begin
  L := THttp11Limits.Create.WithMaxBodySize(Int64(High(Integer)) + 1);
  L.Problems(P);
  AssertTrue('a body limit above High(Integer) is reported', Length(P) = 1);
end;

procedure TBufferGrowTest.TestBodyLimitAtHighIntegerIsAccepted;
var
  L: THttp11Limits;
  P: TArray<string>;
begin
  L := THttp11Limits.Create.WithMaxBodySize(High(Integer));
  L.Problems(P);
  AssertTrue('a body limit of High(Integer) is accepted', Length(P) = 0);
end;

procedure TBufferGrowTest.TestZeroBodyLimitIsAccepted;
var
  L: THttp11Limits;
  P: TArray<string>;
begin
  L := THttp11Limits.Create.WithMaxBodySize(0);
  L.Problems(P);
  AssertTrue('a body limit of 0 is accepted', Length(P) = 0);
end;

initialization
  RegisterTest(TBufferGrowTest);
end.
