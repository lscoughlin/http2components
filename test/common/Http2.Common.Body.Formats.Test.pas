{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, text, json, xml, test
notes:
  - This test checks the text, JSON and XML helpers over a reader that gives one octet per call.
  - The round trips go through the writer factories, so the parsers read across the chunks.
  - The tests check the format errors, the us-ascii declaration and the errors of the reader.
---
}
unit Http2.Common.Body.Formats.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, fpjson, jsonparser, DOM, XMLRead,
  Http2.Common.Body, Http2.Common.Body.Text, Http2.Common.Body.Json,
  Http2.Common.Body.Xml, Http2.Common.Body.Fixtures;

type
  TBodyFormatsTest = class(TTestCase)
  published
    procedure TestTextRoundTripOneOctet;
    procedure TestTextCapRaises;
    procedure TestJsonRoundTripOneOctet;
    procedure TestJsonNotJsonRaises;
    procedure TestJsonEmptyBodyRaises;
    procedure TestJsonNotObjectRaises;
    procedure TestJsonReaderErrorPasses;
    procedure TestJsonWriterRefusesNil;
    procedure TestXmlRoundTripOneOctet;
    procedure TestXmlUsAsciiDeclaration;
    procedure TestXmlNotWellFormedRaises;
    procedure TestXmlEmptyBodyRaises;
    procedure TestXmlReaderErrorPasses;
    procedure TestXmlWriterRefusesNil;
    procedure TestParseXmlNotWellFormedRaises;
  end;

implementation

const
  cSampleXml = '<?xml version="1.0" encoding="UTF-8"?>' +
    '<a x="1"><b>text &amp; more</b><c/></a>';

procedure TBodyFormatsTest.TestTextRoundTripOneOctet;
var
  LText, LBack: string;
  LOctets: TBytes;
begin
  // the octets above 127 pass unchanged
  LText := 'caf' + #$C3#$A9 + ' and bytes ' + #$FF#$00 + ' end';
  LOctets := DrainWriter(TextBodyWriter(LText));
  AssertEquals('the writer gives the octets of the text', Length(LText), Length(LOctets));
  LBack := ReadText(TStepReader.Create(LOctets, 1));
  AssertEquals('the reader gives the same octets', LText, LBack);
end;

procedure TBodyFormatsTest.TestTextCapRaises;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ReadText(TStepReader.Create(PatternOctets(100), 16), 10);
  except
    on E: EBodyTooLarge do
      LRaised := True;
  end;
  AssertTrue('a body over the cap raises EBodyTooLarge', LRaised);
end;

procedure TBodyFormatsTest.TestJsonRoundTripOneOctet;
var
  LSource: TJSONData;
  LObject: TJSONObject;
  LOctets: TBytes;
begin
  LSource := GetJSON('{"name":"widget","count":3,"tags":["a","b",true,null]}');
  try
    LOctets := DrainWriter(JsonBodyWriter(LSource));
    LObject := ReadJsonObject(TStepReader.Create(LOctets, 1));
    try
      AssertEquals('the object is the same', string(LSource.AsJSON), string(LObject.AsJSON));
      AssertEquals('a member after the round trip', 3, LObject.Get('count', -1));
    finally
      LObject.Free;
    end;
  finally
    LSource.Free;
  end;
end;

procedure TBodyFormatsTest.TestJsonNotJsonRaises;
var
  LRaised: Boolean;
  LData: TJSONData;
begin
  LRaised := False;
  LData := nil;
  try
    LData := ReadJson(TStepReader.Create(OctetsOf('this is not json'), 1));
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a body that is not JSON raises EBodyFormatError', LRaised);
  AssertTrue('no value leaks out', LData = nil);
end;

procedure TBodyFormatsTest.TestJsonEmptyBodyRaises;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ReadJson(TStepReader.Create(nil, 1)).Free;
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('an empty body raises EBodyFormatError', LRaised);
end;

procedure TBodyFormatsTest.TestJsonNotObjectRaises;
var
  LRaised: Boolean;
  LObject: TJSONObject;
begin
  LRaised := False;
  LObject := nil;
  try
    LObject := ReadJsonObject(TStepReader.Create(OctetsOf('[1,2,3]'), 1));
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a JSON array is not an object', LRaised);
  AssertTrue('no object leaks out', LObject = nil);
end;

procedure TBodyFormatsTest.TestJsonReaderErrorPasses;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ReadJson(TFailingReader.Create(OctetsOf('{"a":1,"b":2}'), 4)).Free;
  except
    on E: TProbeError do
      LRaised := True;
  end;
  AssertTrue('the reader error reaches the caller', LRaised);
end;

procedure TBodyFormatsTest.TestJsonWriterRefusesNil;
var
  LRaised: Boolean;
  LWriter: IBodyWriter;
begin
  LRaised := False;
  try
    LWriter := JsonBodyWriter(nil);
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a nil value is refused', LRaised);
end;

procedure TBodyFormatsTest.TestXmlRoundTripOneOctet;
var
  LSource, LBack: TXMLDocument;
  LRoot, LChild: TDOMNode;
  LOctets: TBytes;
begin
  LSource := ParseXml(cSampleXml);
  try
    LOctets := DrainWriter(XmlBodyWriter(LSource));
    LBack := ReadXml(TStepReader.Create(LOctets, 1));
    try
      LRoot := LBack.DocumentElement;
      AssertEquals('the root element', 'a', LRoot.NodeName);
      AssertEquals('the attribute', '1', TDOMElement(LRoot).GetAttribute('x'));
      LChild := LRoot.FirstChild;
      AssertEquals('the first child', 'b', LChild.NodeName);
      AssertEquals('the text with an entity', 'text & more', LChild.TextContent);
      AssertEquals('the second child is an empty element', 'c', LChild.NextSibling.NodeName);
    finally
      LBack.Free;
    end;
  finally
    LSource.Free;
  end;
end;

procedure TBodyFormatsTest.TestXmlUsAsciiDeclaration;
var
  LDoc: TXMLDocument;
begin
  // fcl-xml rejects us-ascii; the reader reads the declaration as utf-8
  LDoc := ReadXml(TStepReader.Create(
    OctetsOf('<?xml version="1.0" encoding="us-ascii"?><r>x</r>'), 1));
  try
    AssertEquals('the root element after a us-ascii declaration', 'r',
      LDoc.DocumentElement.NodeName);
  finally
    LDoc.Free;
  end;
end;

procedure TBodyFormatsTest.TestXmlNotWellFormedRaises;
var
  LRaised: Boolean;
  LDoc: TXMLDocument;
begin
  LRaised := False;
  LDoc := nil;
  try
    LDoc := ReadXml(TStepReader.Create(OctetsOf('<a><b></a>'), 1));
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a body that is not well-formed raises EBodyFormatError', LRaised);
  AssertTrue('no document leaks out', LDoc = nil);
end;

procedure TBodyFormatsTest.TestXmlEmptyBodyRaises;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ReadXml(TStepReader.Create(nil, 1)).Free;
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('an empty body raises EBodyFormatError', LRaised);
end;

procedure TBodyFormatsTest.TestXmlReaderErrorPasses;
var
  LRaised, LFormat: Boolean;
  LText: string;
begin
  // the reader fails after the prolog, inside the parser: the caller gets the reader error
  LText := '<root>' + StringOfChar('x', 3000) + '</root>';
  LRaised := False;
  LFormat := False;
  try
    ReadXml(TFailingReader.Create(OctetsOf(LText), 2000)).Free;
  except
    on E: TProbeError do
      LRaised := True;
    on E: EBodyFormatError do
      LFormat := True;
  end;
  AssertTrue('the reader error reaches the caller', LRaised);
  AssertFalse('the reader error is not a format error', LFormat);
end;

procedure TBodyFormatsTest.TestXmlWriterRefusesNil;
var
  LRaised: Boolean;
  LWriter: IBodyWriter;
begin
  LRaised := False;
  try
    LWriter := XmlBodyWriter(nil);
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a nil document is refused', LRaised);
end;

procedure TBodyFormatsTest.TestParseXmlNotWellFormedRaises;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    ParseXml('<a>').Free;
  except
    on E: EBodyFormatError do
      LRaised := True;
  end;
  AssertTrue('a text that is not well-formed raises EBodyFormatError', LRaised);
end;

initialization
  RegisterTest(TBodyFormatsTest);

end.
