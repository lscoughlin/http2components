{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: example, tls, openssl, client
notes:
  - This program selects the OpenSSL provider and operating system trust store.
---
}
program example_tls_openssl;
{$mode delphi}{$H+}{$interfaces com}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Http2.Client, Http2.Common, Http2.OpenSSL;
var
  Context: ITLSContext;
  Client: IHttpClient;
  Response: IHttpResponse;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: tls_openssl <https-url>');
    Halt(2);
  end;
  Context := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithSystemTrust(True))
    .Build;
  Client := THttpClientFactory.Create.WithTlsContext(Context).Build;
  try
    Response := Client.Send(THttpRequest.Create(hmGet, ParamStr(1)));
    WriteLn('status: ', Response.StatusCode);
    WriteLn('body bytes: ', Length(ReadText(Response)));
  finally
    Client.Close;
  end;
end.
