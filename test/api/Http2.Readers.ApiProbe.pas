{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
program Http2.Readers.ApiProbe;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpjson, DOM, Http2.Client, Http2.Client.Readers;
var
  Json: TJSONObject;
  Xml: TXMLDocument;
  Request: THttpRequest;
begin
  Json := TJsonReader<TJSONObject>.Parse('{"value":30}');
  try
    if Json.Get('value', 0) <> 30 then Halt(1);
    Request := WithJsonBody(Default(THttpRequest).WithUrl('https://localhost/'), Json);
    if Request.Headers.GetFirst('content-type') <> 'application/json' then Halt(2);
  finally
    Json.Free;
  end;
  Xml := TXmlDocumentReader.Parse('<probe/>');
  try
    if Xml.DocumentElement.NodeName <> 'probe' then Halt(3);
  finally
    Xml.Free;
  end;
end.
