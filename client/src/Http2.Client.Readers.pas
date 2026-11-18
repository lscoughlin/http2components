{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - Imported from http2client source revision 709336f542cbedf9ce1ab67d83bddcfd560eb1c0.
  - Unit references use the common and client namespaces.
---
}
/// Structured-format readers and senders for http2client: JSON and XML.
// - this unit is part of the http2client project (see doc/design/messages.md).
// - the 14-unit core library deliberately keeps no fpjson/fcl-xml dependency.
//   The structured formats therefore live here, in one optional unit. Add
//   `Http2.Client.Readers` to your uses clause only when you need JSON or XML.
// - fcl-json (fpjson/jsonparser) and fcl-xml (DOM/XMLRead/XMLWrite) are pure
//   Object Pascal units shipped with FPC, so linking this unit adds no C
//   dependency either.
// - Read helpers parse the whole response body. Send helpers attach a body and
//   the matching content-type, and are pure request builders: they never touch
//   the network. The returned object of every Read helper is CALLER-OWNED and
//   must be freed.
unit Http2.Client.Readers;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, TypInfo, DOM,
  fpjson, jsonparser,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client;

type
  /// reads a JSON body into a TJSONObject. The CALLER OWNS the returned object
  /// and must Free it. A body that does not parse as JSON, or that parses to a
  /// non-object value (an array, a number, a bare string), raises
  /// EHttpProtocolError with ecProtocolError.
  TJsonObjectReader = class(TInterfacedObject, IResponseReader<TJSONObject>)
  public
    /// parse AText as a JSON object; the caller owns the result
    class function Parse(const AText: string): TJSONObject; overload; static;
    /// read a response body to EOF and parse it as a JSON object
    function Read(const AResponse: IHttpResponse): TJSONObject; overload;
  end;

  /// reads a JSON body into any TJSONData descendant (TJSONObject, TJSONArray,
  /// TJSONString, TJSONNumber ...). The CALLER OWNS the result and must Free
  /// it. A body that does not parse as JSON raises EHttpProtocolError.
  TJsonReader<T: TJSONData> = class(TInterfacedObject, IResponseReader<T>)
  public
    /// parse AText as JSON and cast to T; the caller owns the result
    class function Parse(const AText: string): T; overload; static;
    /// read a response body to EOF and parse it as T
    function Read(const AResponse: IHttpResponse): T; overload;
  end;

  /// reads an XML body into a TXMLDocument. The CALLER OWNS the returned
  /// document and must Free it. A body that is not well-formed XML raises
  /// EHttpProtocolError (the fcl-xml EXMLReadError is not leaked).
  /// An `encoding="us-ascii"` (or `ascii`) declaration is rewritten to
  /// utf-8 before parsing, since fcl-xml rejects us-ascii but US-ASCII is a
  /// subset of UTF-8; every other declared encoding is passed through as-is.
  TXmlDocumentReader = class(TInterfacedObject, IResponseReader<TXMLDocument>)
  public
    /// parse AText as XML; the caller owns the result
    class function Parse(const AText: string): TXMLDocument; overload; static;
    /// read a response body to EOF and parse it as XML
    function Read(const AResponse: IHttpResponse): TXMLDocument; overload;
  end;

/// read a whole response body to EOF and parse it as a JSON object; the caller
/// owns the result (Free it)
function ReadJsonObject(const AResponse: IHttpResponse): TJSONObject;

/// read a whole response body to EOF and parse it as JSON; the caller owns the
/// result (Free it)
function ReadJsonData(const AResponse: IHttpResponse): TJSONData;

/// read a whole response body to EOF and parse it as XML; the caller owns the
/// result (Free it)
function ReadXmlDocument(const AResponse: IHttpResponse): TXMLDocument;

/// serialize AData and attach it as the request body, defaulting
/// `content-type: application/json` when none is set
function WithJsonBody(const ARequest: THttpRequest;
  const AData: TJSONData): THttpRequest;

/// attach AJson verbatim as the request body, defaulting
/// `content-type: application/json` when none is set
function WithJsonText(const ARequest: THttpRequest;
  const AJson: string): THttpRequest;

/// serialize ADoc and attach it as the request body, defaulting
/// `content-type: application/xml` when none is set
function WithXmlBody(const ARequest: THttpRequest;
  const ADoc: TXMLDocument): THttpRequest;

implementation

uses
  XMLRead, XMLWrite,
  Http2.Common.Body, Http2.Common.Body.Json, Http2.Common.Body.Xml;

{ the common format errors keep their text; the client adds the response prefix }

/// the client error of a format error of the common units
function ProtocolErrorOf(const AError: EBodyFormatError): EHttpProtocolError;
begin
  Result := EHttpProtocolError.Create('response ' + AError.Message, ecProtocolError);
end;

{ TJsonObjectReader }

class function TJsonObjectReader.Parse(const AText: string): TJSONObject;
var
  D: TJSONData;
begin
  try
    D := Http2.Common.Body.Json.ParseJson(AText);
  except
    on E: EBodyFormatError do
      raise ProtocolErrorOf(E);
  end;
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise EHttpProtocolError.Create(
      'response body is not a JSON object', ecProtocolError);
  end;
  Result := TJSONObject(D);
end;

function TJsonObjectReader.Read(const AResponse: IHttpResponse): TJSONObject;
begin
  if AResponse = nil then
    raise EHttpProtocolError.Create('response is nil', ecInternalError);
  Result := Parse(ReadText(AResponse));
end;

{ TJsonReader<T> }

class function TJsonReader<T>.Parse(const AText: string): T;
var
  D: TJSONData;
begin
  // the generic body converts the error itself: a generic cannot call an implementation routine
  try
    D := ParseJson(AText);
  except
    on E: EBodyFormatError do
      raise EHttpProtocolError.Create('response ' + E.Message, ecProtocolError);
  end;
  if not (D is T) then
  begin
    D.Free;
    raise EHttpProtocolError.CreateFmt(
      'response body is not a %s', [PTypeInfo(TypeInfo(T))^.Name]);
  end;
  Result := T(D);
end;

function TJsonReader<T>.Read(const AResponse: IHttpResponse): T;
begin
  if AResponse = nil then
    raise EHttpProtocolError.Create('response is nil', ecInternalError);
  Result := Parse(ReadText(AResponse));
end;

{ TXmlDocumentReader }

class function TXmlDocumentReader.Parse(const AText: string): TXMLDocument;
begin
  try
    Result := Http2.Common.Body.Xml.ParseXml(AText);
  except
    on E: EBodyFormatError do
      raise ProtocolErrorOf(E);
  end;
end;

function TXmlDocumentReader.Read(const AResponse: IHttpResponse): TXMLDocument;
begin
  if AResponse = nil then
    raise EHttpProtocolError.Create('response is nil', ecInternalError);
  // the document is parsed as the octets of the body arrive
  try
    Result := Http2.Common.Body.Xml.ReadXml(AResponse.Body);
  except
    on E: EBodyFormatError do
      raise ProtocolErrorOf(E);
  end;
end;

{ module helpers }

function ReadJsonObject(const AResponse: IHttpResponse): TJSONObject;
var
  R: IResponseReader<TJSONObject>;
begin
  R := TJsonObjectReader.Create;
  Result := R.Read(AResponse);
end;

function ReadJsonData(const AResponse: IHttpResponse): TJSONData;
var
  R: IResponseReader<TJSONData>;
begin
  R := TJsonReader<TJSONData>.Create;
  Result := R.Read(AResponse);
end;

function ReadXmlDocument(const AResponse: IHttpResponse): TXMLDocument;
var
  R: IResponseReader<TXMLDocument>;
begin
  R := TXmlDocumentReader.Create;
  Result := R.Read(AResponse);
end;

function WithJsonBody(const ARequest: THttpRequest;
  const AData: TJSONData): THttpRequest;
begin
  if AData = nil then
    raise EHttpProtocolError.Create('JSON body is nil', ecInternalError);
  Result := WithJsonText(ARequest, AData.AsJSON);
end;

function WithJsonText(const ARequest: THttpRequest;
  const AJson: string): THttpRequest;
begin
  if (ARequest.Headers = nil) or
     (not ARequest.Headers.Contains(HeaderContentType)) then
    Result := ARequest.WithHeader(HeaderContentType, 'application/json')
  else
    Result := ARequest;
  Result := WithTextBody(Result, AJson);
end;

function WithXmlBody(const ARequest: THttpRequest;
  const ADoc: TXMLDocument): THttpRequest;
var
  OutS: TStringStream;
begin
  if ADoc = nil then
    raise EHttpProtocolError.Create('XML document is nil', ecInternalError);
  OutS := TStringStream.Create('');
  try
    WriteXML(ADoc, OutS);
    if (ARequest.Headers = nil) or
       (not ARequest.Headers.Contains(HeaderContentType)) then
      Result := ARequest.WithHeader(HeaderContentType, 'application/xml')
    else
      Result := ARequest;
    Result := WithTextBody(Result, OutS.DataString);
  finally
    OutS.Free;
  end;
end;

end.
