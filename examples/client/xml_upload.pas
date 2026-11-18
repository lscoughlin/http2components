{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
/// http2components client example: upload an XML document that a producer writes as the body.
// - build: `task examples`
// - run:   bin/<target>/<profile>/examples-client/programs/xml_upload https://nghttp2.org/httpbin/post
// - shows: BodyWriterFromStream (Http2.Common.Body.Producers) turns code that writes to a TStream
//   into a request body. The client runs the producer on the thread of the call. Each chunk
//   of the output goes to the wire when the producer writes it, so the document is never
//   copied into one buffer.
// - note:  WriteXML writes the document to the stream that the producer gets. The stream
//   blocks the producer while the connection is full (backpressure).
program example_xml_upload;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DOM, XMLWrite,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client, Http2.Common, Http2.Common.Body, Http2.Common.Body.Producers, Http2.OpenSSL;

type
  /// the producer of the upload: it writes the document to the stream that it gets
  TDocumentProducer = class
  private
    FDoc: TXMLDocument;
  public
    constructor Create(const ADoc: TXMLDocument);
    procedure Write(const AOut: TStream);
  end;

constructor TDocumentProducer.Create(const ADoc: TXMLDocument);
begin
  inherited Create;
  FDoc := ADoc;
end;

procedure TDocumentProducer.Write(const AOut: TStream);
begin
  WriteXML(FDoc, AOut);
end;

var
  Client: IHttpClient;
  TlsContext: ITLSContext;
  Url: string;
  Response: IHttpResponse;
  Sent: TXMLDocument;
  Root, Item: TDOMNode;
  Producer: TDocumentProducer;
  Writer: IBodyWriter;
  I: Integer;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: example_xml_upload <url>');
    Halt(2);
  end;
  Url := ParamStr(1);

  // 1. build a document with many items; the document is written only as the body is sent
  Sent := TXMLDocument.Create;
  Producer := TDocumentProducer.Create(Sent);
  try
    Root := Sent.CreateElement('items');
    Sent.AppendChild(Root);
    for I := 1 to 500 do
    begin
      Item := Sent.CreateElement('item');
      TDOMElement(Item).SetAttribute('n', IntToStr(I));
      Item.AppendChild(Sent.CreateTextNode('value ' + IntToStr(I)));
      Root.AppendChild(Item);
    end;

    // 2. the producer becomes the body; the request sets its own content type
    Writer := BodyWriterFromStream(Producer.Write, cReadChunkBytes);

    // 3. send the request and read the response status
    TlsContext := TOpenSSLTlsContextFactory.Create
      .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithSystemTrust(True))
      .Build;
    Client := THttpClientFactory.Create.WithTlsContext(TlsContext)
      .WithMaxConnectionsPerHost(1).Build;
    try
      Response := Client.Send(THttpRequest.Create(hmPost, Url)
        .WithHeader('content-type', 'application/xml')
        .WithBodyWriter(Writer));
      WriteLn('status: ', Response.StatusCode);
      WriteLn('response bytes: ', Length(ReadText(Response)));
    except
      on E: EHttpError do
      begin
        WriteLn(StdErr, 'request failed: ', E.ClassName, ': ', E.Message);
        Halt(1);
      end;
    end;
    Client.Close;
  finally
    Sent.Free;
    Producer.Free;
  end;
end.
