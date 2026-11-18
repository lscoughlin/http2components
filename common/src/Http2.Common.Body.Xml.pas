{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, xml, fcl-xml, us-ascii
notes:
  - This unit reads an XML body and writes an XML body. It uses fcl-xml.
  - ReadXml parses the body as its octets arrive; the document is in memory when the call returns.
  - A declaration with encoding us-ascii or ascii is read as utf-8, which is a subset of the same octets.
  - A body that is not well-formed XML raises EBodyFormatError. An fcl-xml exception does not leave the unit.
  - The unit is separate, so a program that does not use XML does not link fcl-xml.
---
}
unit Http2.Common.Body.Xml;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, DOM, XMLRead, XMLWrite,
  Http2.Common.Body, Http2.Common.Body.Streams;

type
  /// the writer of an XML body; the body is the serialization of the document
  // - the caller owns the document and keeps it until the body ends
  TXmlBodyWriter = class(TSerializedBodyWriter)
  private
    FDoc: TXMLDocument;
  protected
    procedure Serialize(const ATarget: TStream); override;
  public
    constructor Create(const ADoc: TXMLDocument);
  end;

/// parse AText as XML and give the document; the caller owns the result
// - a text that is not well-formed raises EBodyFormatError
function ParseXml(const AText: string): TXMLDocument;

/// read the body to its end, parse it as XML and give the document; the caller owns the result
// - a body that is not well-formed raises EBodyFormatError
// - an exception of the reader passes to the caller; it is not a format error
function ReadXml(AReader: IBodyReader): TXMLDocument;

/// a body writer for ADoc; the body is the serialized XML of ADoc
// - the caller owns ADoc and keeps it until the body ends
function XmlBodyWriter(const ADoc: TXMLDocument): IBodyWriter;

implementation

const
  /// the octets that ReadXml reads to find the end of the XML declaration
  cXmlPrologBytes = 1024;

/// case-insensitive index of ASub in S, searching from AStart (1-based);
/// 0 when not found
function IndexOfCI(const S: string; const AStart: Integer;
  const ASub: string): Integer;
var
  I, J: Integer;
begin
  Result := 0;
  if ASub = '' then
    Exit;
  for I := AStart to Length(S) - Length(ASub) + 1 do
  begin
    J := 1;
    while (J <= Length(ASub)) and
          (UpCase(S[I + J - 1]) = UpCase(ASub[J])) do
      Inc(J);
    if J > Length(ASub) then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

/// fcl-xml's XMLRead accepts utf-8 and iso-8859-1 but rejects `us-ascii` (and
/// windows-1252/utf-16) as an unsupported encoding. US-ASCII is a strict
/// subset of UTF-8, so rewriting an `us-ascii`/`ascii` declaration to `utf-8`
/// is byte-safe and lets us parse the many documents that declare us-ascii.
/// The rewrite is deliberately bounded to that one case: a blind rewrite of
/// windows-1252 or utf-16 (which carry high bytes or a BOM) would corrupt the
/// input, so those still raise.
function NormalizeXmlDeclarationEncoding(const AText: string): string;
var
  P, DeclEnd, EncPos, ValStart, ValEnd: Integer;
  Quote: Char;
  Value: string;
begin
  Result := AText;
  P := 1;
  // a UTF-8 BOM may precede the declaration
  if (Length(AText) >= 3) and (AText[1] = #$EF) and (AText[2] = #$BB) and
     (AText[3] = #$BF) then
    P := 4;
  if Copy(AText, P, 5) <> '<?xml' then
    Exit;
  DeclEnd := Pos('?>', AText);
  if DeclEnd = 0 then
    Exit;
  EncPos := IndexOfCI(AText, P, 'encoding');
  if (EncPos = 0) or (EncPos > DeclEnd) then
    Exit;
  Inc(EncPos, Length('encoding'));
  while (EncPos <= DeclEnd) and (AText[EncPos] <= ' ') do
    Inc(EncPos);
  if (EncPos > DeclEnd) or (AText[EncPos] <> '=') then
    Exit;
  Inc(EncPos);
  while (EncPos <= DeclEnd) and (AText[EncPos] <= ' ') do
    Inc(EncPos);
  if (EncPos > DeclEnd) or not (AText[EncPos] in ['''', '"']) then
    Exit;
  Quote := AText[EncPos];
  ValStart := EncPos + 1;
  ValEnd := ValStart;
  while (ValEnd <= DeclEnd) and (AText[ValEnd] <> Quote) do
    Inc(ValEnd);
  if ValEnd > DeclEnd then
    Exit;
  Value := LowerCase(Copy(AText, ValStart, ValEnd - ValStart));
  if (Value = 'us-ascii') or (Value = 'ascii') then
    Result := Copy(AText, 1, ValStart - 1) + 'utf-8' +
      Copy(AText, ValEnd, Length(AText) - ValEnd + 1);
end;

/// the octets of ABuffer as a string
function BufferText(const ABuffer: TChunkBuffer): string;
begin
  Result := '';
  if ABuffer.Size > 0 then
    SetString(Result, PAnsiChar(ABuffer.Memory), ABuffer.Size);
end;

/// the octets of AText as an array
function TextOctets(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

{ TXmlBodyWriter }

constructor TXmlBodyWriter.Create(const ADoc: TXMLDocument);
begin
  inherited Create;
  FDoc := ADoc;
end;

procedure TXmlBodyWriter.Serialize(const ATarget: TStream);
begin
  WriteXML(FDoc, ATarget);
end;

{ module routines }

function ParseXml(const AText: string): TXMLDocument;
var
  LStream: TStringStream;
  LDoc: TXMLDocument;
begin
  LDoc := nil;
  LStream := TStringStream.Create(NormalizeXmlDeclarationEncoding(AText));
  try
    try
      ReadXMLFile(LDoc, LStream);
    except
      on E: Exception do
      begin
        LDoc.Free;
        raise EBodyFormatError.Create('body is not well-formed XML: ' + E.Message);
      end;
    end;
  finally
    LStream.Free;
  end;
  Result := LDoc;
end;

function ReadXml(AReader: IBodyReader): TXMLDocument;
var
  LHead: TChunkBuffer;
  LStream: TReaderStream;
  LDoc: TXMLDocument;
  LMore: Boolean;
begin
  LDoc := nil;
  LHead := TChunkBuffer.Create;
  try
    // the declaration is in the first octets; the unit reads them before the parser starts
    repeat
      LMore := AReader.ReadChunk(LHead);
    until (not LMore) or (LHead.Size >= cXmlPrologBytes) or
          (Pos('?>', BufferText(LHead)) > 0);
    LStream := TReaderStream.Create(AReader, True);
    try
      LStream.PushBack(TextOctets(NormalizeXmlDeclarationEncoding(BufferText(LHead))));
      try
        ReadXMLFile(LDoc, LStream);
      except
        on E: Exception do
        begin
          LDoc.Free;
          // an error of the reader is not a format error: it passes unchanged
          if LStream.ReaderFailed then
            raise;
          raise EBodyFormatError.Create('body is not well-formed XML: ' + E.Message);
        end;
      end;
    finally
      LStream.Free;
    end;
  finally
    LHead.Free;
  end;
  Result := LDoc;
end;

function XmlBodyWriter(const ADoc: TXMLDocument): IBodyWriter;
begin
  if ADoc = nil then
    raise EBodyFormatError.Create('the XML document is nil');
  Result := TXmlBodyWriter.Create(ADoc);
end;

end.
