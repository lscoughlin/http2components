{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, test, fixture
notes:
  - This unit holds the readers and writers that the format tests share.
  - The unit is a test support unit. It registers no test.
---
}
unit Http2.Common.Body.Fixtures;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Http2.Common.Body, Http2.Common.Body.Streams;

type
  /// the exception that the failing reader raises
  TProbeError = class(Exception);

  /// a reader over a byte array; each Read gives at most AStep octets
  TStepReader = class(TBodyReaderBase)
  private
    FData: TBytes;
    FPosition: Integer;
    FStep: Integer;
  public
    constructor Create(const AData: TBytes; const AStep: Integer);
    function Read(var ABuffer; const ACount: Integer): Integer; override;
  end;

  /// a reader over a byte array that raises TProbeError when it reaches AFailAt
  // - the reader gives one octet per Read, so the failure comes at a known octet
  TFailingReader = class(TBodyReaderBase)
  private
    FData: TBytes;
    FPosition: Integer;
    FFailAt: Integer;
  public
    constructor Create(const AData: TBytes; const AFailAt: Integer);
    function Read(var ABuffer; const ACount: Integer): Integer; override;
  end;

  /// a writer that serializes AOctets octets of a pattern
  TPatternWriter = class(TSerializedBodyWriter)
  private
    FOctets: Integer;
  protected
    procedure Serialize(const ATarget: TStream); override;
  public
    constructor Create(const AOctets: Integer);
  end;

/// the octets of AText
function OctetsOf(const AText: string): TBytes;

/// the octets of the first ACount octets of the pattern that TPatternWriter writes
function PatternOctets(const ACount: Integer): TBytes;

/// pull a writer to its end and give all its octets
function DrainWriter(const AWriter: IBodyWriter): TBytes;

/// the text of AOctets, one octet for each byte
function TextOf(const AOctets: TBytes): string;

implementation

{ TStepReader }

constructor TStepReader.Create(const AData: TBytes; const AStep: Integer);
begin
  inherited Create;
  FData := AData;
  FStep := AStep;
  FPosition := 0;
end;

function TStepReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := Length(FData) - FPosition;
  if Result > FStep then
    Result := FStep;
  if Result > ACount then
    Result := ACount;
  if Result > 0 then
  begin
    Move(FData[FPosition], ABuffer, Result);
    Inc(FPosition, Result);
  end;
end;

{ TFailingReader }

constructor TFailingReader.Create(const AData: TBytes; const AFailAt: Integer);
begin
  inherited Create;
  FData := AData;
  FFailAt := AFailAt;
  FPosition := 0;
end;

function TFailingReader.Read(var ABuffer; const ACount: Integer): Integer;
begin
  if FPosition >= FFailAt then
    raise TProbeError.Create('the probe reader fails');
  Result := 1;
  if Result > ACount then
    Result := ACount;
  if Result > Length(FData) - FPosition then
    Result := Length(FData) - FPosition;
  if Result > 0 then
  begin
    Move(FData[FPosition], ABuffer, Result);
    Inc(FPosition, Result);
  end;
end;

{ TPatternWriter }

constructor TPatternWriter.Create(const AOctets: Integer);
begin
  inherited Create;
  FOctets := AOctets;
end;

procedure TPatternWriter.Serialize(const ATarget: TStream);
var
  LData: TBytes;
begin
  LData := PatternOctets(FOctets);
  if Length(LData) > 0 then
    ATarget.WriteBuffer(LData[0], Length(LData));
end;

{ module routines }

function OctetsOf(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function PatternOctets(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte(I mod 251);
end;

function DrainWriter(const AWriter: IBodyWriter): TBytes;
var
  LBuffer: TChunkBuffer;
  LOut: TMemoryStream;
  LMore: Boolean;
begin
  LBuffer := TChunkBuffer.Create;
  LOut := TMemoryStream.Create;
  try
    repeat
      LBuffer.Reset;
      LMore := AWriter.NextChunk(LBuffer);
      if LBuffer.Size > 0 then
        LOut.WriteBuffer(LBuffer.Memory^, LBuffer.Size);
    until not LMore;
    Result := nil;
    SetLength(Result, LOut.Size);
    if LOut.Size > 0 then
      Move(LOut.Memory^, Result[0], LOut.Size);
  finally
    LOut.Free;
    LBuffer.Free;
  end;
end;

function TextOf(const AOctets: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(AOctets));
  if Length(AOctets) > 0 then
    Move(AOctets[0], Result[1], Length(AOctets));
end;

end.
