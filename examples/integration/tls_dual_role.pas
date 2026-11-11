{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: example, tls, openssl, dual-role
notes:
  - One OpenSSL context instance has client and server roles.
  - The client and server use the same context instance for a local request.
---
}
program example_tls_dual_role;
{$mode delphi}{$H+}{$interfaces com}{$modeswitch advancedrecords}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Http2.Client, Http2.Server, Http2.Common, Http2.OpenSSL;
type
  THelloHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;
procedure THelloHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  Body: TBytes;
begin
  Body := TEncoding.UTF8.GetBytes('shared TLS context' + sLineBreak);
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;
var
  Identity: ITLSIdentity;
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  Context: ITLSContext;
  Server: IHttp2Server;
  Client: IHttpClient;
  Response: IHttpResponse;
  Port: Word;
  Url: string;
begin
  if ParamCount < 3 then
  begin
    WriteLn(StdErr, 'usage: tls_dual_role <port> <server.crt> <server.key>');
    Halt(2);
  end;
  Port := Word(StrToInt(ParamStr(1)));
  Identity := TOpenSSLIdentity.FromPemFiles(ParamStr(2), ParamStr(3));
  ClientPolicy := TTlsClientPolicy.SecureDefault
    .WithTrustAnchors([ParamStr(2)])
    .WithPartialChain(True)
    .WithSystemTrust(False);
  ServerPolicy := TTlsServerPolicy.SecureDefault
    .WithServerIdentity(Identity);
  Context := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ClientPolicy)
    .WithServerPolicy(ServerPolicy)
    .Build;
  Server := THttp2ServerFactory.Create
    .WithHost('127.0.0.1')
    .WithPort(Port)
    .WithClearTextAllowed(False)
    .WithTlsContext(Context)
    .WithHandler(THelloHandler.Create)
    .Build;
  Client := THttpClientFactory.Create.WithTlsContext(Context).Build;
  try
    Server.Start;
    Url := 'https://localhost:' + IntToStr(Server.Port) + '/';
    Response := Client.Send(THttpRequest.Create(hmGet, Url));
    WriteLn('status: ', Response.StatusCode);
    WriteLn('response: ', ReadText(Response));
  finally
    Client.Close;
    Server.Stop;
  end;
end.
