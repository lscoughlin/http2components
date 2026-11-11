{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: server, tls, provider, interoperability, live
notes:
  - This program starts one TLS HTTP/2 server with the selected provider.
  - The external validation script supplies a certificate, key and TLS range.
  - The response body is fixed for independent peer comparison.
---
}
/// A provider-specific TLS HTTP/2 server for independent peer checks
program Http2.Server.ProviderLive;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Http2.Server, Http2.Common, Http2.OpenSSL, Http2.TlsLib;

type
  TFixedHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

procedure TFixedHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
const
  BODY = 'provider-server-ok'#10;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Length(BODY));
  Move(BODY[1], Bytes[0], Length(BODY));
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Bytes);
  AResponse.Finish;
end;

function Version(const AValue: string): TTlsVersion;
begin
  if AValue = '1.2' then
    Exit(tls12);
  if AValue = '1.3' then
    Exit(tls13);
  raise Exception.Create('TLS version must be 1.2 or 1.3');
end;

var
  Identity: ITLSIdentity;
  Policy: TTlsServerPolicy;
  Context: ITLSContext;
  Server: IHttp2Server;
  Provider: string;
  Line: string;
begin
  if ParamCount <> 4 then
  begin
    WriteLn(StdErr, 'usage: Http2.Server.ProviderLive <openssl|tlslib> <certificate> <key> <1.2|1.3>');
    Halt(2);
  end;
  try
    Provider := ParamStr(1);
    if Provider = 'tlslib' then
      Identity := TTlsLibIdentity.FromPemFiles(ParamStr(2), ParamStr(3))
    else if Provider = 'openssl' then
      Identity := TOpenSSLIdentity.FromPemFiles(ParamStr(2), ParamStr(3))
    else
      raise Exception.Create('provider must be openssl or tlslib');
    Policy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity)
      .WithVersions(Version(ParamStr(4)), Version(ParamStr(4)));
    if Provider = 'tlslib' then
      Context := TTlsLibContextFactory.Create.WithServerPolicy(Policy).Build
    else
      Context := TOpenSSLTlsContextFactory.Create.WithServerPolicy(Policy).Build;
    Server := THttp2ServerFactory.Create
      .WithHost('127.0.0.1')
      .WithPort(0)
      .WithClearTextAllowed(False)
      .WithTlsContext(Context)
      .WithHandler(TFixedHandler.Create)
      .WithHandlerThreads(2)
      .WithIOThreads(2)
      .Build;
    Server.Start;
    WriteLn('READY port ', Server.Port);
    Flush(Output);
    ReadLn(Line);
    Server.Stop;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'server error: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
