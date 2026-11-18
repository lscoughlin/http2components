{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: parameters, map, cookie, case-sensitive, record copy
notes:
  - This unit holds TParameters, a case-sensitive map of a name to its list of values.
  - The record holds one reference to a counted map. A copy of the record shares the map.
  - Copy makes an independent map.
  - The unit does not parse or format text. A later unit gives the text forms.
---
}
unit Http2.Common.Parameters;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Generics.Collections;

type
  /// the counted map that a TParameters record refers to
  // - names keep their insertion order, and so do the values of one name
  // - names are case-sensitive
  IParameterMap = interface
    ['{7E1F0C11-00F4-4A11-9C72-000000003701}']
    /// append AValue to the values of AName; a new name is added at the end
    procedure Add(const AName, AValue: string);
    /// replace every value of AName with AValue
    procedure SetValue(const AName, AValue: string);
    /// remove AName and its values; an absent name does nothing
    procedure Remove(const AName: string);
    /// remove every name
    procedure Clear;
    function Contains(const AName: string): Boolean;
    /// the first value of AName, or '' when absent
    function GetFirst(const AName: string): string;
    /// every value of AName in insertion order (empty when absent)
    function GetValues(const AName: string): TArray<string>;
    /// every name in insertion order
    function Names: TArray<string>;
    /// the number of names
    function Count: Integer;
  end;

  /// a case-sensitive map of names to lists of values, in insertion order
  // - the record refers to one counted map. The map is created at the first
  //   write method call, so a record that has never been written holds no map.
  // - a copy of the record shares the map: a write to one copy shows in the other.
  // - Copy gives a new record with its own map.
  // - a read method on a record without a map gives empty results.
  // - the write methods return the record, so calls chain.
  TParameters = record
  private
    FMap: IParameterMap;
    function Writable: IParameterMap;
    function GetCount: Integer;
    function GetItems(const AName: string): TArray<string>;
  public
    /// a new empty record with no map yet
    class function Create: TParameters; static;
    /// append AValue to the values of AName
    function Add(const AName, AValue: string): TParameters;
    /// replace the values of AName with the single AValue
    function SetValue(const AName, AValue: string): TParameters;
    /// remove AName and its values
    function Remove(const AName: string): TParameters;
    /// remove every name
    function Clear: TParameters;
    /// True when AName is present, even with a value of ''
    function Contains(const AName: string): Boolean;
    /// the first value of AName, or '' when absent
    function GetFirst(const AName: string): string;
    /// every name in insertion order
    function Names: TArray<string>;
    /// every value of AName in insertion order (empty when absent)
    function GetValues(const AName: string): TArray<string>;
    /// a new record with its own map that holds the same names and values
    function Copy: TParameters;
    /// the number of names
    property Count: Integer read GetCount;
    /// the values of AName in insertion order (default property)
    property Items[const AName: string]: TArray<string> read GetItems; default;
  end;

/// a new counted map that holds no name
function NewParameterMap: IParameterMap;

implementation

type
  /// the map object; the names are in FNames, and each name holds a TStringList of values
  TParameterMap = class(TInterfacedObject, IParameterMap)
  private
    FNames: TStringList;
    function Find(const AName: string): Integer;
    function ValuesAt(const AIndex: Integer): TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AName, AValue: string);
    procedure SetValue(const AName, AValue: string);
    procedure Remove(const AName: string);
    procedure Clear;
    function Contains(const AName: string): Boolean;
    function GetFirst(const AName: string): string;
    function GetValues(const AName: string): TArray<string>;
    function Names: TArray<string>;
    function Count: Integer;
  end;

function NewParameterMap: IParameterMap;
begin
  Result := TParameterMap.Create;
end;

constructor TParameterMap.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
end;

destructor TParameterMap.Destroy;
var
  I: Integer;
begin
  for I := 0 to FNames.Count - 1 do
    FNames.Objects[I].Free;
  FNames.Free;
  inherited Destroy;
end;

function TParameterMap.Find(const AName: string): Integer;
var
  I: Integer;
begin
  // a plain loop, because the comparison must be case-sensitive
  for I := 0 to FNames.Count - 1 do
    if FNames[I] = AName then
      Exit(I);
  Result := -1;
end;

function TParameterMap.ValuesAt(const AIndex: Integer): TStringList;
begin
  Result := TStringList(FNames.Objects[AIndex]);
end;

procedure TParameterMap.Add(const AName, AValue: string);
var
  LIndex: Integer;
begin
  LIndex := Find(AName);
  if LIndex < 0 then
    LIndex := FNames.AddObject(AName, TStringList.Create);
  ValuesAt(LIndex).Add(AValue);
end;

procedure TParameterMap.SetValue(const AName, AValue: string);
var
  LIndex: Integer;
begin
  LIndex := Find(AName);
  if LIndex < 0 then
    LIndex := FNames.AddObject(AName, TStringList.Create);
  ValuesAt(LIndex).Clear;
  ValuesAt(LIndex).Add(AValue);
end;

procedure TParameterMap.Remove(const AName: string);
var
  LIndex: Integer;
begin
  LIndex := Find(AName);
  if LIndex >= 0 then
  begin
    ValuesAt(LIndex).Free;
    FNames.Delete(LIndex);
  end;
end;

procedure TParameterMap.Clear;
var
  I: Integer;
begin
  for I := 0 to FNames.Count - 1 do
    FNames.Objects[I].Free;
  FNames.Clear;
end;

function TParameterMap.Contains(const AName: string): Boolean;
begin
  Result := Find(AName) >= 0;
end;

function TParameterMap.GetFirst(const AName: string): string;
var
  LIndex: Integer;
begin
  Result := '';
  LIndex := Find(AName);
  if (LIndex >= 0) and (ValuesAt(LIndex).Count > 0) then
    Result := ValuesAt(LIndex)[0];
end;

function TParameterMap.GetValues(const AName: string): TArray<string>;
var
  LIndex, I: Integer;
  LList: TStringList;
begin
  Result := nil;
  LIndex := Find(AName);
  if LIndex < 0 then
    Exit;
  LList := ValuesAt(LIndex);
  SetLength(Result, LList.Count);
  for I := 0 to LList.Count - 1 do
    Result[I] := LList[I];
end;

function TParameterMap.Names: TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, FNames.Count);
  for I := 0 to FNames.Count - 1 do
    Result[I] := FNames[I];
end;

function TParameterMap.Count: Integer;
begin
  Result := FNames.Count;
end;

{ TParameters }

class function TParameters.Create: TParameters;
begin
  Result.FMap := nil;
end;

function TParameters.Writable: IParameterMap;
begin
  if FMap = nil then
    FMap := NewParameterMap;
  Result := FMap;
end;

function TParameters.GetCount: Integer;
begin
  if FMap = nil then
    Result := 0
  else
    Result := FMap.Count;
end;

function TParameters.GetItems(const AName: string): TArray<string>;
begin
  Result := GetValues(AName);
end;

function TParameters.GetValues(const AName: string): TArray<string>;
begin
  if FMap = nil then
    Result := nil
  else
    Result := FMap.GetValues(AName);
end;

function TParameters.Add(const AName, AValue: string): TParameters;
begin
  Writable.Add(AName, AValue);
  Result := Self;
end;

function TParameters.SetValue(const AName, AValue: string): TParameters;
begin
  Writable.SetValue(AName, AValue);
  Result := Self;
end;

function TParameters.Remove(const AName: string): TParameters;
begin
  Writable.Remove(AName);
  Result := Self;
end;

function TParameters.Clear: TParameters;
begin
  Writable.Clear;
  Result := Self;
end;

function TParameters.Contains(const AName: string): Boolean;
begin
  Result := (FMap <> nil) and FMap.Contains(AName);
end;

function TParameters.GetFirst(const AName: string): string;
begin
  if FMap = nil then
    Result := ''
  else
    Result := FMap.GetFirst(AName);
end;

function TParameters.Names: TArray<string>;
begin
  if FMap = nil then
    Result := nil
  else
    Result := FMap.Names;
end;

function TParameters.Copy: TParameters;
var
  LName: string;
  LValue: string;
begin
  Result := TParameters.Create;
  for LName in Names do
    for LValue in GetValues(LName) do
      Result.Add(LName, LValue);
end;

end.
