{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, xml, producer, body writer, streaming
notes:
  - This example builds an XML document and answers with WriteXML through BodyWriterFromStream.
  - The producer writes the document to the stream of the body while the response is sent, so the
    handler does not hold the serialized text in memory.
  - The document is freed after Finish, because the producer writes the document when Finish runs.
---
}
/// A server that answers with an XML document that a producer writes to the body
// - the program shows BodyWriterFromStream and WriteXML on a response
program xml_stream;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DOM, XMLWrite,
  Http2.Common.Body, Http2.Common.Body.Producers, Http2.Server;

const
  /// the number of items in the document of each response
  cItemCount = 2000;

type
  /// the handler of the example
  TXmlStreamHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// the document of one response; its method writes the document to the body
  TXmlDocumentProducer = class
  private
    FDoc: TXMLDocument;
  public
    /// build a document with ACount items
    constructor Create(const ACount: Integer);
    destructor Destroy; override;
    /// write the document to the stream of the body
    procedure Write(const AOut: TStream);
  end;

{ TXmlDocumentProducer }

constructor TXmlDocumentProducer.Create(const ACount: Integer);
var
  Root, Item: TDOMElement;
  I: Integer;
begin
  inherited Create;
  FDoc := TXMLDocument.Create;
  Root := FDoc.CreateElement('items');
  FDoc.AppendChild(Root);
  for I := 1 to ACount do
  begin
    Item := FDoc.CreateElement('item');
    Item.SetAttribute('id', IntToStr(I));
    Item.AppendChild(FDoc.CreateTextNode('square ' + IntToStr(Int64(I) * I)));
    Root.AppendChild(Item);
  end;
end;

destructor TXmlDocumentProducer.Destroy;
begin
  FDoc.Free;
  inherited Destroy;
end;

procedure TXmlDocumentProducer.Write(const AOut: TStream);
begin
  WriteXML(FDoc, AOut);
end;

/// a header block with one content-type field
function ContentTypeHeaders(const AValue: string): THeaderBlock;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Name := 'content-type';
  Result[0].Value := AValue;
end;

procedure TXmlStreamHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Producer: TXmlDocumentProducer;
begin
  Producer := TXmlDocumentProducer.Create(cItemCount);
  try
    AResponse.SendHeaders(200, ContentTypeHeaders('application/xml'), False);
    AResponse.SetBodyWriter(BodyWriterFromStream(Producer.Write));
    // Finish runs the producer, so the document is still needed until it returns
    AResponse.Finish;
  finally
    Producer.Free;
  end;
end;

var
  Server: IHttp2Server;
  Line: string;
begin
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(8080)
    .WithClearTextAllowed(True)
    .WithHandler(TXmlStreamHandler.Create)
    .Build;
  Server.Start;
  Writeln('the server listens on port ', Server.Port, ' (h2c)');
  Writeln('a GET answers an XML document of ', cItemCount, ' items');
  Writeln('press Enter to stop');
  Readln(Line);
  Server.Stop;
end.
