{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, path, test
notes:
  - This test checks the shared rule for a Unix socket path.
---
}
unit Http2.Common.UnixPath.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.UnixPath;

type
  TUnixPathRuleTest = class(TTestCase)
  private
    function Accented(const ACount: Integer): string;
  published
    procedure TestAbsolutePathPasses;
    procedure TestEmptyPathIsRefused;
    procedure TestRelativePathIsRefused;
    procedure TestNulIsRefused;
    procedure TestPathOf103BytesPasses;
    procedure TestPathOf104BytesIsRefused;
    procedure TestMultiByteCountsBytes;
    procedure TestTextNeverHoldsThePath;
  end;

implementation

function TUnixPathRuleTest.Accented(const ACount: Integer): string;
var
  LChar: RawByteString;
  I: Integer;
begin
  // U+00E9 as UTF-8 bytes; the source codepage does not matter
  LChar := AnsiChar($C3) + AnsiChar($A9);
  Result := '/';
  for I := 1 to ACount do
    Result := Result + UTF8Decode(LChar);
end;

procedure TUnixPathRuleTest.TestAbsolutePathPasses;
begin
  AssertEquals('', UnixPathProblem('/tmp/a.sock'));
end;

procedure TUnixPathRuleTest.TestEmptyPathIsRefused;
begin
  AssertEquals('the Unix socket path is empty', UnixPathProblem(''));
end;

procedure TUnixPathRuleTest.TestRelativePathIsRefused;
begin
  AssertEquals('the Unix socket path is not absolute', UnixPathProblem('a.sock'));
end;

procedure TUnixPathRuleTest.TestNulIsRefused;
begin
  AssertEquals('the Unix socket path holds a NUL byte',
    UnixPathProblem('/tmp/a' + #0 + 'b'));
end;

procedure TUnixPathRuleTest.TestPathOf103BytesPasses;
begin
  AssertEquals('', UnixPathProblem('/' + StringOfChar('a', 102)));
end;

procedure TUnixPathRuleTest.TestPathOf104BytesIsRefused;
begin
  AssertEquals('the Unix socket path is 104 bytes long; the limit is 103',
    UnixPathProblem('/' + StringOfChar('a', 103)));
end;

procedure TUnixPathRuleTest.TestMultiByteCountsBytes;
begin
  AssertEquals('51 characters', '', UnixPathProblem(Accented(51)));
  AssertEquals('52 characters',
    'the Unix socket path is 105 bytes long; the limit is 103',
    UnixPathProblem(Accented(52)));
end;

procedure TUnixPathRuleTest.TestTextNeverHoldsThePath;
begin
  AssertEquals(0, Pos('secret-name', UnixPathProblem('secret-name')));
  AssertEquals(0, Pos('secret-name', UnixPathProblem('/secret-name' +
    StringOfChar('a', 120))));
end;

initialization
  RegisterTest(TUnixPathRuleTest);
end.
