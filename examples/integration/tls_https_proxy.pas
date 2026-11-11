{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: example, tls, https, proxy
notes:
  - Origin and HTTPS proxy legs use separate OpenSSL contexts.
  - Origin trust uses the operating system store.
  - Proxy trust uses the named PEM CA file.
---
}
program example_tls_https_proxy;
{$mode delphi}{$H+}{$interfaces com}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Http2.Client, Http2.Common, Http2.OpenSSL;
type
  TFixedHttpsProxy = class(TInterfacedObject, IProxySelector)
  private
    FProxy: IProxy;
  public
    constructor Create(const AHost: string; const APort: Word);
    function SelectProxy(const AUri: string): IProxy;
  end;
constructor TFixedHttpsProxy.Create(const AHost: string; const APort: Word);
begin
  inherited Create;
  FProxy := TProxy.Create(pkHttps, AHost, APort);
end;
function TFixedHttpsProxy.SelectProxy(const AUri: string): IProxy;
begin
  Result := FProxy;
end;
var
  OriginContext, ProxyContext: ITLSContext;
  Client: IHttpClient;
  Response: IHttpResponse;
  OriginPolicy, ProxyPolicy: TTlsClientPolicy;
begin
  if ParamCount < 4 then
  begin
    WriteLn(StdErr,
      'usage: tls_https_proxy <https-url> <proxy-host> <proxy-port> <proxy-ca.pem>');
    Halt(2);
  end;
  OriginPolicy := TTlsClientPolicy.SecureDefault.WithSystemTrust(True);
  ProxyPolicy := TTlsClientPolicy.SecureDefault
    .WithTrustAnchors([ParamStr(4)])
    .WithSystemTrust(False);
  OriginContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(OriginPolicy)
    .Build;
  ProxyContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(ProxyPolicy)
    .Build;
  Client := THttpClientFactory.Create
    .WithTlsContext(OriginContext)
    .WithProxyTlsContext(ProxyContext)
    .WithProxySelector(TFixedHttpsProxy.Create(ParamStr(2),
      Word(StrToInt(ParamStr(3)))))
    .Build;
  try
    Response := Client.Send(THttpRequest.Create(hmGet, ParamStr(1)));
    WriteLn('status: ', Response.StatusCode);
    WriteLn('body bytes: ', Length(ReadText(Response)));
  finally
    Client.Close;
  end;
end.
