{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, example, json, body reader, body writer
notes:
  - This example reads a JSON request body with ReadJson and answers with JsonBodyWriter.
  - A request body that is not JSON gets a 400 answer with a text body.
  - The writer serializes the value when the response pulls it, so the value is freed after Finish.
---
}
/// A server that echoes a JSON request body as a JSON response body
// - the program shows ReadJson on a request and JsonBodyWriter on a response
program json_echo;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpjson,
  Http2.Common.Body, Http2.Common.Body.Json, Http2.Common.Body.Text, Http2.Server;

type
  /// the handler of the example
  TJsonEchoHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

/// a header block with one content-type field
function ContentTypeHeaders(const AValue: string): THeaderBlock;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0].Name := 'content-type';
  Result[0].Value := AValue;
end;

procedure TJsonEchoHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Data: TJSONData;
begin
  try
    Data := ReadJson(ARequest);
  except
    on EBodyFormatError do
    begin
      AResponse.SendHeaders(400, ContentTypeHeaders('text/plain'), False);
      AResponse.SetBodyWriter(TextBodyWriter('the request body is not JSON'));
      AResponse.Finish;
      Exit;
    end;
  end;
  try
    AResponse.SendHeaders(200, ContentTypeHeaders('application/json'), False);
    AResponse.SetBodyWriter(JsonBodyWriter(Data));
    // Finish pulls the body, so the value is still needed until it returns
    AResponse.Finish;
  finally
    Data.Free;
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
    .WithHandler(TJsonEchoHandler.Create)
    .Build;
  Server.Start;
  Writeln('the server listens on port ', Server.Port, ' (h2c)');
  Writeln('a POST with a JSON body answers the same JSON');
  Writeln('press Enter to stop');
  Readln(Line);
  Server.Stop;
end.
