{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
program Http2.Combined.ApiProbe;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, TypInfo, Http2.Common, Http2.Client, Http2.Server,
  Http2.Client.Stream, Http2.Client.Messages;
var
  Fields: Http2.Common.THeaderBlock;
  ServerFields: Http2.Server.THeaderBlock;
  Request: Http2.Client.THttpRequest;
  Response: Http2.Client.Messages.IHttpResponse;
  ClientWriter: Http2.Client.Stream.IBodyWriter;
  ServerWriter: Http2.Server.IBodyWriter;
  Headers: Http2.Common.IHttpHeaders;
  Caught: Boolean;
begin
  SetLength(Fields, 1);
  Fields[0].Name := 'x-common'; Fields[0].Value := 'shared';
  ServerFields := Fields;
  if ServerFields[0].Value <> 'shared' then Halt(1);
  Request := Default(Http2.Client.THttpRequest).WithHeader('x-common', 'shared');
  Headers := Request.Headers;
  if Headers.GetFirst('x-common') <> 'shared' then Halt(2);
  ClientWriter := nil; ServerWriter := nil; Response := nil;
  if (ClientWriter <> nil) or (ServerWriter <> nil) or (Response <> nil) then Halt(3);
  Caught := False;
  try
    raise Http2.Server.EHttpConnectionError.Create('probe');
  except
    on E: Http2.Common.EHttpError do Caught := True;
  end;
  if not Caught then Halt(4);
  if GUIDToString(GetTypeData(TypeInfo(IHttpResponse))^.Guid) <>
     '{8B1C2D3E-4F50-4A61-9C72-0123456789AB}' then Halt(5);
end.
