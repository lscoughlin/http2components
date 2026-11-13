{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, chunk size line, chunk extension, quoted string, control byte, test, fpcunit
notes:
  - This unit tests the check of the chunk size line in H1CheckChunkLine.
  - A CR, a LF or a NUL anywhere in the line is refused. A quoted string holds only
    the bytes of RFC 9110 section 5.6.4.
---
}
/// Tests of the chunk size line check of the HTTP/1.1 guard
unit Http2.Server.ChunkLine.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server.Http1.Limits, Http2.Server.Http1.Guard, Http2.Server.Http1.TestKit;

type
  TChunkLineTest = class(TTestCase)
  private
    FLimits: THttp11Limits;
    procedure AssertRefused(const AName: string; const ALine: RawByteString);
    procedure AssertAccepted(const AName: string; const ALine: RawByteString);
  protected
    procedure SetUp; override;
  published
    procedure TestBareLineFeedInQuotedStringIsRefused;
    procedure TestCrLfAndNulAnywhereInTheLineAreRefused;
    procedure TestControlByteAfterBackslashIsRefused;
    procedure TestDelAndControlBytesInQuotedStringAreRefused;
    procedure TestQuotedPairWithDelimiterIsAccepted;
    procedure TestValidChunkLinesAreAccepted;
    procedure TestBareLineFeedReachesTheGuardThroughTheParser;
  end;

implementation

procedure TChunkLineTest.SetUp;
begin
  FLimits := THttp11Limits.Create;
end;

procedure TChunkLineTest.AssertRefused(const AName: string; const ALine: RawByteString);
var
  Size: Int64;
  V: TH1Verdict;
begin
  V := H1CheckChunkLine(ALine, FLimits, Size);
  AssertTrue(AName + ': the line is refused', V.Status <> 0);
end;

procedure TChunkLineTest.AssertAccepted(const AName: string; const ALine: RawByteString);
var
  Size: Int64;
  V: TH1Verdict;
begin
  V := H1CheckChunkLine(ALine, FLimits, Size);
  AssertEquals(AName + ': the line is accepted; reason: ' + V.Reason, 0, V.Status);
end;

procedure TChunkLineTest.TestBareLineFeedInQuotedStringIsRefused;
begin
  AssertRefused('bare LF in a quoted string', '3;a="x' + #10 + 'y"');
end;

procedure TChunkLineTest.TestCrLfAndNulAnywhereInTheLineAreRefused;
begin
  AssertRefused('CR in a quoted string', '3;a="x' + #13 + 'y"');
  AssertRefused('CR after the size', '3' + #13);
  AssertRefused('LF after the size', '3' + #10);
  AssertRefused('LF in an extension name', '3;a' + #10 + 'b');
  AssertRefused('NUL in a quoted string', '3;a="x' + #0 + 'y"');
  AssertRefused('NUL after the size', '3' + #0);
end;

procedure TChunkLineTest.TestControlByteAfterBackslashIsRefused;
begin
  AssertRefused('control byte after a backslash', '3;a="x\' + #1 + 'y"');
  AssertRefused('DEL after a backslash', '3;a="x\' + #$7F + 'y"');
end;

procedure TChunkLineTest.TestDelAndControlBytesInQuotedStringAreRefused;
begin
  AssertRefused('DEL in a quoted string', '3;a="' + #$7F + '"');
  AssertRefused('control byte in a quoted string', '3;a="' + #1 + '"');
end;

procedure TChunkLineTest.TestQuotedPairWithDelimiterIsAccepted;
begin
  // RFC 9110 section 5.6.4: a quoted-pair may hold a DQUOTE and a backslash
  AssertAccepted('escaped DQUOTE', '3;a="x\"y"');
  AssertAccepted('escaped backslash', '3;a="x\\y"');
end;

procedure TChunkLineTest.TestValidChunkLinesAreAccepted;
begin
  AssertAccepted('size only', '3');
  AssertAccepted('size and blank', '3 ;a');
  AssertAccepted('two extensions, one quoted', '3;a=b;c="d e"');
  AssertAccepted('HTAB in a quoted string', '3;a="x' + #9 + 'y"');
  AssertAccepted('obs-text in a quoted string', '3;a="' + #$80 + '"');
end;

procedure TChunkLineTest.TestBareLineFeedReachesTheGuardThroughTheParser;
var
  T: string;
begin
  // the parser passes a bare LF inside a chunk extension to the guard;
  // the request is refused and the pipelined second request is not processed
  T := H1RunAll('POST / HTTP/1.1' + #13#10 + 'Host: a' + #13#10 +
    'Transfer-Encoding: chunked' + #13#10 + #13#10 + '3;a="x' + #10 + 'y"' + #13#10 +
    'abc' + #13#10 + '0' + #13#10 + #13#10 + 'GET /second HTTP/1.1' + #13#10 +
    'Host: a' + #13#10 + #13#10, FLimits);
  AssertTrue('the bare LF is refused with 400; got: ' + T, H1Rejected(T, 400));
  AssertEquals('the second request is not processed', 0, Pos('/second', T));
end;

initialization
  RegisterTest(TChunkLineTest);

end.
