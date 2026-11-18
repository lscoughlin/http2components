{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, xml, json, text, large, test
notes:
  - This test reads a body of about 20 MB through each format helper, in chunks of cReadChunkBytes.
  - The XML document holds 40 parts of 512 KiB each. The JSON document holds one string of 20 MiB.
---
}
unit Http2.Common.Body.Large.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, fpjson, jsonparser, DOM,
  Http2.Common.Body, Http2.Common.Body.Text, Http2.Common.Body.Json,
  Http2.Common.Body.Xml, Http2.Common.Body.Fixtures;

const
  /// the number of parts of the large XML document
  cLargeParts = 40;
  /// the octets of the text of one part of the large XML document
  cLargePartOctets = 512 * 1024;

type
  TBodyLargeTest = class(TTestCase)
  published
    procedure TestTwentyMegabyteXml;
    procedure TestTwentyMegabyteJson;
    procedure TestTwentyMegabyteText;
  end;

implementation

procedure TBodyLargeTest.TestTwentyMegabyteXml;
var
  LBytes: TBytes;
  LPart, LText: string;
  LDoc: TXMLDocument;
  LChild: TDOMNode;
  LIndex, LCount: Integer;
begin
  // build the document: an XML declaration, the parts, and the end of the root
  LPart := StringOfChar('x', cLargePartOctets);
  LText := '<?xml version="1.0" encoding="UTF-8"?><doc>';
  for LIndex := 1 to cLargeParts do
    LText := LText + '<part n="' + IntToStr(LIndex) + '">' + LPart + '</part>';
  LText := LText + '</doc>';
  LBytes := OctetsOf(LText);
  LText := '';
  AssertTrue('the document is about 20 MB', Length(LBytes) > 20 * 1024 * 1024 - 1024);

  LDoc := ReadXml(TStepReader.Create(LBytes, cReadChunkBytes));
  try
    LCount := 0;
    LChild := LDoc.DocumentElement.FirstChild;
    while LChild <> nil do
    begin
      Inc(LCount);
      LChild := LChild.NextSibling;
    end;
    AssertEquals('every part is in the document', cLargeParts, LCount);
    LChild := LDoc.DocumentElement.FirstChild;
    AssertEquals('the text of a part is whole', cLargePartOctets,
      Length(LChild.TextContent));
  finally
    LDoc.Free;
  end;
end;

procedure TBodyLargeTest.TestTwentyMegabyteJson;
var
  LText: string;
  LBytes: TBytes;
  LData: TJSONObject;
  LValue: string;
begin
  LText := '{"text":"' + StringOfChar('y', 20 * 1024 * 1024) + '","n":7}';
  LBytes := OctetsOf(LText);
  LText := '';
  LData := ReadJsonObject(TStepReader.Create(LBytes, cReadChunkBytes));
  try
    LValue := LData.Get('text', '');
    AssertEquals('the string is whole', 20 * 1024 * 1024, Length(LValue));
    AssertEquals('the member after it is read', 7, LData.Get('n', -1));
  finally
    LData.Free;
  end;
end;

procedure TBodyLargeTest.TestTwentyMegabyteText;
var
  LText, LBack: string;
  LOctets: TBytes;
begin
  LText := StringOfChar('t', 20 * 1024 * 1024);
  LOctets := DrainWriter(TextBodyWriter(LText));
  LBack := ReadText(TStepReader.Create(LOctets, cReadChunkBytes));
  AssertEquals('the text is whole', Length(LText), Length(LBack));
  AssertTrue('the text is the same', LText = LBack);
end;

initialization
  RegisterTest(TBodyLargeTest);

end.
