{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, json, fcl-json
notes:
  - This unit reads a JSON body and writes a JSON body. It uses fcl-json.
  - fcl-json parses a whole text, so ReadJson holds the whole body in memory before it parses.
  - A body that is not JSON raises EBodyFormatError. An fcl-json exception does not leave the unit.
  - The unit is separate, so a program that does not use JSON does not link fcl-json.
---
}
unit Http2.Common.Body.Json;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpjson, jsonparser,
  Http2.Common.Body, Http2.Common.Body.Streams;

type
  /// the writer of a JSON body; the body is the AsJSON text of the data
  // - the caller owns the data and keeps it until the body ends
  TJsonBodyWriter = class(TSerializedBodyWriter)
  private
    FData: TJSONData;
  protected
    procedure Serialize(const ATarget: TStream); override;
  public
    constructor Create(const AData: TJSONData);
  end;

/// parse AText as JSON and give the value; the caller owns the result
// - a text that is not JSON raises EBodyFormatError
function ParseJson(const AText: string): TJSONData;

/// read the body to its end and parse it as JSON; the caller owns the result
// - a body that is not JSON raises EBodyFormatError
// - an exception of the reader passes to the caller
function ReadJson(AReader: IBodyReader): TJSONData;

/// read the body to its end and parse it as a JSON object; the caller owns the result
// - a body that is not a JSON object raises EBodyFormatError
function ReadJsonObject(AReader: IBodyReader): TJSONObject;

/// a body writer for AData; the body is the JSON text of AData
// - the caller owns AData and keeps it until the body ends
function JsonBodyWriter(const AData: TJSONData): IBodyWriter;

implementation

{ TJsonBodyWriter }

constructor TJsonBodyWriter.Create(const AData: TJSONData);
begin
  inherited Create;
  FData := AData;
end;

procedure TJsonBodyWriter.Serialize(const ATarget: TStream);
var
  LText: string;
begin
  LText := FData.AsJSON;
  if Length(LText) > 0 then
    ATarget.WriteBuffer(LText[1], Length(LText));
end;

{ module routines }

function ParseJson(const AText: string): TJSONData;
begin
  Result := nil;
  try
    Result := GetJSON(AText);
  except
    // fcl-json raises its own classes; the caller sees only the library error
    on Exception do
      raise EBodyFormatError.Create('body is not valid JSON');
  end;
  if Result = nil then
    raise EBodyFormatError.Create('body is not valid JSON');
end;

function ReadJson(AReader: IBodyReader): TJSONData;
var
  LBytes: TBytes;
  LText: string;
begin
  // fcl-json needs the whole text, so the whole body is read first
  LBytes := ReadAllBody(AReader);
  SetLength(LText, Length(LBytes));
  if Length(LBytes) > 0 then
    Move(LBytes[0], LText[1], Length(LBytes));
  Result := ParseJson(LText);
end;

function ReadJsonObject(AReader: IBodyReader): TJSONObject;
var
  LData: TJSONData;
begin
  LData := ReadJson(AReader);
  if not (LData is TJSONObject) then
  begin
    LData.Free;
    raise EBodyFormatError.Create('body is not a JSON object');
  end;
  Result := TJSONObject(LData);
end;

function JsonBodyWriter(const AData: TJSONData): IBodyWriter;
begin
  if AData = nil then
    raise EBodyFormatError.Create('the JSON data is nil');
  Result := TJsonBodyWriter.Create(AData);
end;

end.
