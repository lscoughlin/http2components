{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: parameters, test
notes:
  - This test checks TParameters: case, order, the shared map of a record copy, Copy and the empty map.
---
}
unit Http2.Common.Parameters.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Parameters;

type
  TParametersTest = class(TTestCase)
  private
    function SameNames(const AExpected: array of string; const AActual: TArray<string>): Boolean;
    function SameValues(const AExpected: array of string; const AActual: TArray<string>): Boolean;
  published
    procedure TestEmptyRecordReads;
    procedure TestEmptyMapWrites;
    procedure TestCaseIsSignificant;
    procedure TestNamesAndValuesKeepOrder;
    procedure TestSetValueReplacesTheList;
    procedure TestRemoveKeepsTheOtherNames;
    procedure TestClearEmptiesTheMap;
    procedure TestWritesChain;
    procedure TestContainsSeesAnEmptyValue;
    procedure TestDefaultPropertyGivesTheValues;
    procedure TestCopyOfARecordSharesTheMap;
    procedure TestCopyMakesAnIndependentMap;
    procedure TestCopyOfAnEmptyRecord;
  end;

implementation

function TParametersTest.SameNames(const AExpected: array of string; const AActual: TArray<string>): Boolean;
var
  I: Integer;
begin
  Result := Length(AExpected) = Length(AActual);
  if not Result then
    Exit;
  for I := 0 to High(AExpected) do
    if AExpected[I] <> AActual[I] then
      Exit(False);
end;

function TParametersTest.SameValues(const AExpected: array of string; const AActual: TArray<string>): Boolean;
begin
  Result := SameNames(AExpected, AActual);
end;

procedure TParametersTest.TestEmptyRecordReads;
var
  P: TParameters;
begin
  P := TParameters.Create;
  AssertEquals('an empty record has no names', 0, P.Count);
  AssertFalse('an empty record contains no name', P.Contains('a'));
  AssertEquals('an empty record gives an empty first value', '', P.GetFirst('a'));
  AssertEquals('an empty record gives no values', 0, Length(P.GetValues('a')));
  AssertEquals('an empty record gives no values by the default property', 0, Length(P['a']));
  AssertEquals('an empty record gives no names', 0, Length(P.Names));
  AssertEquals('a copy of an empty record has no names', 0, P.Copy.Count);
end;

procedure TParametersTest.TestEmptyMapWrites;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Remove('a');
  AssertEquals('Remove on an empty map leaves it empty', 0, P.Count);
  P.Clear;
  AssertEquals('Clear on an empty map leaves it empty', 0, P.Count);
  P.SetValue('a', '1');
  AssertEquals('SetValue on an empty map adds the name', 1, P.Count);
  AssertEquals('the value is the one that was set', '1', P.GetFirst('a'));

  P := TParameters.Create;
  P.Clear.Remove('a').SetValue('b', '2');
  AssertEquals('the chained empty-map calls leave one name', 1, P.Count);
  AssertEquals('the one name is the one that was set', '2', P.GetFirst('b'));
end;

procedure TParametersTest.TestCaseIsSignificant;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1').Add('A', '2');
  AssertEquals('two names differ by case', 2, P.Count);
  AssertEquals('the lower-case name has its own value', '1', P.GetFirst('a'));
  AssertEquals('the upper-case name has its own value', '2', P.GetFirst('A'));
  AssertFalse('a name in another case is absent', P.Contains('b'));
  AssertTrue('the exact name is present', P.Contains('A'));
  P.Remove('A');
  AssertFalse('Remove deletes only the exact name', P.Contains('A'));
  AssertTrue('the other case stays', P.Contains('a'));
end;

procedure TParametersTest.TestNamesAndValuesKeepOrder;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('b', '1').Add('a', '2').Add('b', '3').Add('c', '4');
  AssertTrue('names keep their insertion order', SameNames(['b', 'a', 'c'], P.Names));
  AssertTrue('values of one name keep their insertion order', SameValues(['1', '3'], P.GetValues('b')));
  AssertEquals('the count is the number of names', 3, P.Count);
end;

procedure TParametersTest.TestSetValueReplacesTheList;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1').Add('a', '2').Add('b', '3');
  P.SetValue('a', 'x');
  AssertTrue('SetValue leaves one value', SameValues(['x'], P.GetValues('a')));
  AssertTrue('SetValue keeps the place of the name', SameNames(['a', 'b'], P.Names));
end;

procedure TParametersTest.TestRemoveKeepsTheOtherNames;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1').Add('b', '2').Add('c', '3');
  P.Remove('b');
  AssertTrue('the other names keep their order', SameNames(['a', 'c'], P.Names));
  AssertEquals('the count is down by one', 2, P.Count);
  P.Remove('missing');
  AssertEquals('an absent name changes nothing', 2, P.Count);
end;

procedure TParametersTest.TestClearEmptiesTheMap;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1').Add('b', '2');
  P.Clear;
  AssertEquals('Clear removes every name', 0, P.Count);
  AssertFalse('a cleared name is absent', P.Contains('a'));
  P.Add('c', '3');
  AssertTrue('the map works after Clear', SameNames(['c'], P.Names));
end;

procedure TParametersTest.TestWritesChain;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1').Add('b', '2').SetValue('c', '3').Remove('a');
  AssertTrue('the chained calls leave two names', SameNames(['b', 'c'], P.Names));
end;

procedure TParametersTest.TestContainsSeesAnEmptyValue;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('flag', '');
  AssertTrue('a name with an empty value is present', P.Contains('flag'));
  AssertEquals('its first value is empty', '', P.GetFirst('flag'));
  AssertEquals('it has one value', 1, Length(P.GetValues('flag')));
end;

procedure TParametersTest.TestDefaultPropertyGivesTheValues;
var
  P: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', 'x').Add('a', 'y');
  AssertTrue('the default property gives the values', SameValues(['x', 'y'], P['a']));
  AssertEquals('the default property of an absent name is empty', 0, Length(P['missing']));
end;

procedure TParametersTest.TestCopyOfARecordSharesTheMap;
var
  P: TParameters;
  Q: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1');
  Q := P;
  Q.Add('b', '2');
  AssertTrue('a write to the copy of the record shows in the first record', P.Contains('b'));
  P.Remove('a');
  AssertFalse('a removal in the first record shows in the copy', Q.Contains('a'));
  AssertEquals('both records count the same names', P.Count, Q.Count);
end;

procedure TParametersTest.TestCopyMakesAnIndependentMap;
var
  P: TParameters;
  Q: TParameters;
begin
  P := TParameters.Create;
  P.Add('a', '1').Add('a', '2').Add('b', '3');
  Q := P.Copy;
  AssertTrue('the copy holds the names in the same order', SameNames(['a', 'b'], Q.Names));
  AssertTrue('the copy holds the values in the same order', SameValues(['1', '2'], Q.GetValues('a')));
  Q.Add('c', '4');
  Q.Remove('a');
  AssertFalse('a write to the copy does not show in the original', P.Contains('c'));
  AssertTrue('a removal from the copy does not show in the original', P.Contains('a'));
  P.Add('d', '5');
  AssertFalse('a write to the original does not show in the copy', Q.Contains('d'));
end;

procedure TParametersTest.TestCopyOfAnEmptyRecord;
var
  P: TParameters;
  Q: TParameters;
begin
  P := TParameters.Create;
  Q := P.Copy;
  Q.Add('a', '1');
  AssertEquals('a copy of an empty record starts empty', 0, P.Count);
  AssertEquals('the copy holds its own name', 1, Q.Count);
end;

initialization
  RegisterTest(TParametersTest);
end.
