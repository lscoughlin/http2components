{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this contains frame comparison helpers for client tests
---
}
unit Http2.Client.MockSocket.Frames;

{$mode delphi}{$H+}
interface

uses SysUtils, Classes, fpcunit, Http2.Common.Frames;

{ ---- frame serialization + exact-sequence assertion helpers (11.3) ---- }

/// serialize one frame to its wire bytes
function FrameToBytes(const AFrame: TFrame): TBytes;
/// append a serialized frame to a byte accumulator
function AppendFrame(const AAcc: TBytes; const AFrame: TFrame): TBytes;
/// parse one frame starting at AOffset; returns False when not enough bytes
function ParseFrameAt(const ABytes: TBytes; const AOffset: Integer;
  out AFrame: TFrame; out ANextOffset: Integer): Boolean;
/// parse every complete frame, optionally skipping the 24-byte preface
function ParseFrameSequence(const ABytes: TBytes;
  const ASkipPreface: Boolean): TArray<TFrame>;

/// one-line human-readable frame description (also the oracle dump format)
function FrameSummary(const AFrame: TFrame): string;
/// one line per frame, in order
function FrameSequenceSummary(const AFrames: TArray<TFrame>): string;

/// assert AActual matches AExpected frame for frame (type, flags, stream id,
/// payload length and bytes)
procedure AssertFrameSequence(const AExpected, AActual: TArray<TFrame>;
  const ALabel: string);

implementation
{ ---- frame helpers ---- }

function FrameToBytes(const AFrame: TFrame): TBytes;
var
  MS: TMemoryStream;
begin
  Result := nil;
  MS := TMemoryStream.Create;
  try
    WriteFrame(MS, AFrame);
    SetLength(Result, MS.Size);
    if MS.Size > 0 then
      Move(MS.Memory^, Result[0], MS.Size);
  finally
    MS.Free;
  end;
end;

function AppendFrame(const AAcc: TBytes; const AFrame: TFrame): TBytes;
var
  B: TBytes;
  N: Integer;
begin
  Result := nil;
  B := FrameToBytes(AFrame);
  N := Length(AAcc);
  SetLength(Result, N + Length(B));
  if N > 0 then
    Move(AAcc[0], Result[0], N);
  if Length(B) > 0 then
    Move(B[0], Result[N], Length(B));
end;

function ParseFrameAt(const ABytes: TBytes; const AOffset: Integer;
  out AFrame: TFrame; out ANextOffset: Integer): Boolean;
var
  Hdr: TBytes;
  Total: Integer;
begin
  AFrame.Header.Clear;
  AFrame.Payload := nil;
  ANextOffset := AOffset;
  if AOffset + FrameHeaderSize > Length(ABytes) then
    Exit(False);
  Hdr := Copy(ABytes, AOffset, FrameHeaderSize);
  AFrame.Header := TFrameHeader.ReadFrom(Hdr);
  Total := FrameHeaderSize + Integer(AFrame.Header.Length);
  if AOffset + Total > Length(ABytes) then
    Exit(False);
  AFrame.Payload := Copy(ABytes, AOffset + FrameHeaderSize,
    AFrame.Header.Length);
  ANextOffset := AOffset + Total;
  Result := True;
end;

function ParseFrameSequence(const ABytes: TBytes;
  const ASkipPreface: Boolean): TArray<TFrame>;
var
  Ofs: Integer;
  F: TFrame;
begin
  Result := nil;
  if ASkipPreface then
    Ofs := 24
  else
    Ofs := 0;
  while ParseFrameAt(ABytes, Ofs, F, Ofs) do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := F;
  end;
end;

function FrameSummary(const AFrame: TFrame): string;
var
  B: TBytes;
  I: Integer;
  Hex: string;
begin
  B := AFrame.Payload;
  Hex := '';
  for I := 0 to High(B) do
    Hex := Hex + IntToHex(B[I], 2);
  Result := Format('%s flags=0x%.2x stream=%d len=%d payload=%s',
    [FrameTypeName(AFrame.Header.FrameType),
     FrameFlagsToByte(AFrame.Header.Flags), AFrame.Header.StreamId,
     Length(B), Hex]);
end;

function FrameSequenceSummary(const AFrames: TArray<TFrame>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFrames) do
  begin
    if I > 0 then
      Result := Result + LineEnding;
    Result := Result + '#' + IntToStr(I) + ' ' + FrameSummary(AFrames[I]);
  end;
end;

procedure AssertFrameSequence(const AExpected, AActual: TArray<TFrame>;
  const ALabel: string);
var
  I: Integer;
begin
  TAssert.AssertEquals(ALabel + ': frame count', Length(AExpected), Length(AActual));
  for I := 0 to High(AExpected) do
  begin
    TAssert.AssertEquals(ALabel + ': frame ' + IntToStr(I) + ' type',
      Ord(AExpected[I].Header.FrameType), Ord(AActual[I].Header.FrameType));
    TAssert.AssertEquals(ALabel + ': frame ' + IntToStr(I) + ' flags',
      FrameFlagsToByte(AExpected[I].Header.Flags),
      FrameFlagsToByte(AActual[I].Header.Flags));
    TAssert.AssertEquals(ALabel + ': frame ' + IntToStr(I) + ' stream id',
      AExpected[I].Header.StreamId, AActual[I].Header.StreamId);
    TAssert.AssertEquals(ALabel + ': frame ' + IntToStr(I) + ' payload length',
      Length(AExpected[I].Payload), Length(AActual[I].Payload));
    if Length(AExpected[I].Payload) > 0 then
      TAssert.AssertTrue(ALabel + ': frame ' + IntToStr(I) + ' payload bytes',
        CompareMem(@AExpected[I].Payload[0], @AActual[I].Payload[0],
          Length(AExpected[I].Payload)));
  end;
end;

{ TMockSocket }


end.
