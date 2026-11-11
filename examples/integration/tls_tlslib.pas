{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: example, tls, tlslib, client
notes:
  - This program selects TlsLib and a PEM trust anchor.
  - TlsLib does not load the operating system trust store.
---
}
program example_tls_tlslib;
{$mode delphi}{$H+}{$interfaces com}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Http2.Client, Http2.Common, Http2.TlsLib;
var
  Policy: TTlsClientPolicy;
  Context: ITLSContext;
  Client: IHttpClient;
  Response: IHttpResponse;
begin
  if ParamCount < 2 then
  begin
    WriteLn(StdErr, 'usage: tls_tlslib <https-url> <ca.pem>');
    Halt(2);
  end;
  Policy := TTlsClientPolicy.SecureDefault
    .WithTrustAnchors([ParamStr(2)])
    .WithSystemTrust(False);
  Context := TTlsLibContextFactory.Create.WithClientPolicy(Policy).Build;
  Client := THttpClientFactory.Create.WithTlsContext(Context).Build;
  try
    Response := Client.Send(THttpRequest.Create(hmGet, ParamStr(1)));
    WriteLn('status: ', Response.StatusCode);
    WriteLn('body bytes: ', Length(ReadText(Response)));
  finally
    Client.Close;
  end;
end.
