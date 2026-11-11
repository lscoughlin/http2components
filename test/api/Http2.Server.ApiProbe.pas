{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
program Http2.Server.ApiProbe;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, TypInfo, Http2.Server;
type
  TProbeHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
  end;
procedure TProbeHandler.Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
begin
  AResponse.SendHeaders(204, nil, True);
end;
var
  Factory: THttp2ServerFactory;
  Server: IHttp2Server;
  Writer: Http2.Server.IBodyWriter;
begin
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithClearTextAllowed(True).WithHandler(TProbeHandler.Create);
  if Factory.ProblemText <> '' then raise Exception.Create(Factory.ProblemText);
  Server := Factory.Build;
  if GUIDToString(GetTypeData(TypeInfo(IHttp2Server))^.Guid) <>
     '{7E1F0C11-0008-4A11-9C72-000000000508}' then Halt(2);
  Writer := nil;
  if Writer <> nil then Halt(3);
  Server.Stop;
end.
