{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
program Http2.Client.ApiProbe;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, TypInfo, Http2.Client;
var
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Request: THttpRequest;
  Reader: TResponseReader<string>;
begin
  Factory := THttpClientFactory.Create.WithMaxConnectionsPerHost(2);
  Client := Factory.Build;
  try
    Request := Default(THttpRequest).WithUrl('https://localhost/api').WithHeader('x-probe', 'one');
    Request := WithTextBody(Request, 'probe');
    if (Request.Authority <> 'localhost') or (Request.Path <> '/api') or
       (Request.Headers.GetFirst('x-probe') <> 'one') then Halt(1);
    if GUIDToString(GetTypeData(TypeInfo(IHttpClient))^.Guid) <>
       '{6B1C2D3E-4F50-4A61-9C72-000000000001}' then Halt(2);
    Reader := TResponseReader<string>.Create;
    Reader.Free;
  finally
    Client.Close;
  end;
end.
