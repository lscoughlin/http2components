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
  Http2.Server, Http2.Common, Http2.Server.Config.Limits,
  Http2.OpenSSL, Http2.TlsLib;

type
  TFixedHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  TProviderObserver = class(TInterfacedObject, IHttp2ServerObserver)
  public
    Accepted: Integer;
    procedure OnEvent(const AEvent: TServerEvent);
  end;

procedure TProviderObserver.OnEvent(const AEvent: TServerEvent);
begin
  if AEvent.Kind = seConnectionAccepted then
    InterlockedIncrement(Accepted);
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

function ClientAuth(const AValue: string): TTlsClientAuthMode;
begin
  if (AValue = '') or (AValue = 'none') then
    Exit(tlsAuthNone);
  if AValue = 'request' then
    Exit(tlsAuthRequest);
  if AValue = 'require' then
    Exit(tlsAuthRequire);
  raise Exception.Create('client auth mode must be none, request, or require');
end;

function PositiveEnvironmentValue(const AName: string;
  const ADefault: Integer): Integer;
var
  Value: string;
  Parsed: Int64;
begin
  Value := GetEnvironmentVariable(AName);
  if Value = '' then
    Exit(ADefault);
  if not TryStrToInt64(Value, Parsed) or (Parsed < 1) or
     (Parsed > High(Integer)) then
    raise Exception.Create(AName + ' must be an integer in 1..2147483647');
  Result := Parsed;
end;

var
  Identity: ITLSIdentity;
  Policy: TTlsServerPolicy;
  Context: ITLSContext;
  Server: IHttp2Server;
  Observer: IHttp2ServerObserver;
  ProviderObserver: TProviderObserver;
  Provider: string;
  AuthMode: TTlsClientAuthMode;
  TrustAnchor: string;
  Line: string;
  HandshakeTimeoutMs, MaxConnections: Integer;
  Limits: TServerLimits;
begin
  if (ParamCount < 4) or (ParamCount > 6) then
  begin
    WriteLn(StdErr, 'usage: Http2.Server.ProviderLive <openssl|tlslib> <certificate> <key> <1.2|1.3> [none|request|require [trust-anchor.pem]]');
    Halt(2);
  end;
  try
    HandshakeTimeoutMs := PositiveEnvironmentValue(
      'HTTP2_TEST_HANDSHAKE_TIMEOUT_MS', 0);
    MaxConnections := PositiveEnvironmentValue(
      'HTTP2_TEST_MAX_CONNECTIONS', 10000);
    Limits := TServerLimits.Create.WithMaxConnections(MaxConnections);
    Provider := ParamStr(1);
    if Provider = 'tlslib' then
      Identity := TTlsLibIdentity.FromPemFiles(ParamStr(2), ParamStr(3))
    else if Provider = 'openssl' then
      Identity := TOpenSSLIdentity.FromPemFiles(ParamStr(2), ParamStr(3))
    else
      raise Exception.Create('provider must be openssl or tlslib');
    AuthMode := tlsAuthNone;
    if ParamCount >= 5 then
      AuthMode := ClientAuth(ParamStr(5));
    TrustAnchor := '';
    if ParamCount = 6 then
      TrustAnchor := ParamStr(6);
    Policy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity)
      .WithVersions(Version(ParamStr(4)), Version(ParamStr(4)))
      .WithClientAuth(AuthMode);
    if TrustAnchor <> '' then
      Policy := Policy.WithTrustAnchors([TrustAnchor]);
    ProviderObserver := TProviderObserver.Create;
    Observer := ProviderObserver;
    if Provider = 'tlslib' then
      Context := TTlsLibContextFactory.Create.WithServerPolicy(Policy)
        .WithHandshakeTimeoutMs(HandshakeTimeoutMs).Build
    else
      Context := TOpenSSLTlsContextFactory.Create.WithServerPolicy(Policy)
        .WithHandshakeTimeoutMs(HandshakeTimeoutMs).Build;
    Server := THttp2ServerFactory.Create
      .WithHost('127.0.0.1')
      .WithPort(0)
      .WithClearTextAllowed(False)
      .WithTlsContext(Context)
      .WithHandler(TFixedHandler.Create)
      .WithHandlerThreads(2)
      .WithIOThreads(2)
      .WithServerLimits(Limits)
      .Build(Observer);
    Server.Start;
    WriteLn('READY port ', Server.Port);
    Flush(Output);
    while not EOF(Input) do
    begin
      ReadLn(Line);
      if SameText(Trim(Line), 'stats') then
      begin
        WriteLn('STATS accepted ', ProviderObserver.Accepted);
        Flush(Output);
      end
      else
        Break;
    end;
    Server.Stop;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'server error: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
