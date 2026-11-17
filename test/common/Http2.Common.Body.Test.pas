{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_writer, chunk_buffer, test
notes:
  - This test checks the chunk buffer that a body writer fills.
  - The tests check that Reset keeps the allocated memory.
  - The tests check the helpers that append a chunk.
---
}
unit Http2.Common.Body.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Common.Body;

type
  /// a chunk buffer that shows the allocated size; TMemoryStream keeps Capacity protected
  TChunkBufferProbe = class(TChunkBuffer)
  public
    /// the allocated size of the memory
    function Allocated: PtrInt;
  end;

  TChunkBufferTest = class(TTestCase)
  private
    function Filled(const ACount: Integer; const AStart: Integer): TBytes;
    function SameBytes(const A, B: TBytes): Boolean;
  published
    procedure TestResetKeepsTheMemory;
    procedure TestResetEmpties;
    procedure TestResetKeepsAHugeBuffer;
    procedure TestAppendHelpers;
    procedure TestCapacityStopsGrowing;
    procedure TestChunkBytes;
  end;

implementation

function TChunkBufferProbe.Allocated: PtrInt;
begin
  Result := Capacity;
end;

function TChunkBufferTest.Filled(const ACount: Integer; const AStart: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte((AStart + I) and $FF);
end;

function TChunkBufferTest.SameBytes(const A, B: TBytes): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if not Result then
    Exit;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
    begin
      Result := False;
      Exit;
    end;
end;

procedure TChunkBufferTest.TestResetKeepsTheMemory;
var
  LBuffer: TChunkBuffer;
  LFirst: Pointer;
begin
  LBuffer := TChunkBuffer.Create;
  try
    ChunkAppend(LBuffer, Filled(1000, 0));
    LFirst := LBuffer.Memory;
    LBuffer.Reset;
    ChunkAppend(LBuffer, Filled(1000, 1));
    AssertTrue('Reset keeps the memory', LFirst = LBuffer.Memory);
    AssertEquals(1000, LBuffer.Size);
  finally
    LBuffer.Free;
  end;
end;

procedure TChunkBufferTest.TestResetEmpties;
var
  LBuffer: TChunkBuffer;
begin
  LBuffer := TChunkBuffer.Create;
  try
    ChunkAppend(LBuffer, Filled(10, 0));
    LBuffer.Reset;
    AssertEquals(0, LBuffer.Size);
    AssertEquals(0, LBuffer.Position);
  finally
    LBuffer.Free;
  end;
end;

procedure TChunkBufferTest.TestResetKeepsAHugeBuffer;
var
  LBuffer: TChunkBuffer;
  LData: TBytes;
  LFirst: Pointer;
begin
  LBuffer := TChunkBuffer.Create;
  try
    LData := Filled(8 * 1024 * 1024, 0);
    ChunkAppend(LBuffer, LData);
    LFirst := LBuffer.Memory;
    LBuffer.Reset;
    ChunkAppend(LBuffer, LData);
    AssertTrue('Reset keeps a huge buffer', LFirst = LBuffer.Memory);
    AssertEquals(8 * 1024 * 1024, LBuffer.Size);
  finally
    LBuffer.Free;
  end;
end;

procedure TChunkBufferTest.TestAppendHelpers;
var
  LBuffer: TChunkBuffer;
  LExpected: TBytes;
begin
  LBuffer := TChunkBuffer.Create;
  try
    ChunkAppend(LBuffer, Filled(3, 1));
    ChunkAppendText(LBuffer, 'ab');
    ChunkAppend(LBuffer, nil);
    ChunkAppendText(LBuffer, '');
    SetLength(LExpected, 5);
    LExpected[0] := 1;
    LExpected[1] := 2;
    LExpected[2] := 3;
    LExpected[3] := 97;
    LExpected[4] := 98;
    AssertTrue('the helpers append in order', SameBytes(LExpected, ChunkBytes(LBuffer)));
  finally
    LBuffer.Free;
  end;
end;

procedure TChunkBufferTest.TestCapacityStopsGrowing;
const
  cCycles = 1000;
  cLargest = 60000;
var
  LBuffer: TChunkBufferProbe;
  LSource: TBytes;
  LSize: Integer;
  LCycle: Integer;
  LAtHundred: PtrInt;
begin
  // The largest chunk comes first, so the capacity has its final value from cycle 1.
  LSource := Filled(cLargest, 0);
  LBuffer := TChunkBufferProbe.Create;
  try
    LAtHundred := 0;
    for LCycle := 1 to cCycles do
    begin
      LBuffer.Reset;
      if LCycle = 1 then
        LSize := cLargest
      else
        LSize := 100 + ((LCycle * 7919) mod 59901);
      LBuffer.WriteBuffer(LSource[0], LSize);
      if LCycle = 100 then
        LAtHundred := LBuffer.Allocated;
    end;
    AssertEquals('the capacity stops growing after cycle 100', LAtHundred, LBuffer.Allocated);
  finally
    LBuffer.Free;
  end;
end;

procedure TChunkBufferTest.TestChunkBytes;
var
  LBuffer: TChunkBuffer;
  LData: TBytes;
begin
  LBuffer := TChunkBuffer.Create;
  try
    AssertEquals(0, Length(ChunkBytes(LBuffer)));
    LData := Filled(5, 10);
    ChunkAppend(LBuffer, LData);
    AssertTrue('ChunkBytes copies the chunk', SameBytes(LData, ChunkBytes(LBuffer)));
  finally
    LBuffer.Free;
  end;
end;

initialization
  RegisterTest(TChunkBufferTest);
end.
