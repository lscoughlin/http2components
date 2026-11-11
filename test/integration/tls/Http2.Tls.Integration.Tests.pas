{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, integration, http2, provider, test
notes:
  - Runs bounded loopback HTTP/2 exchanges with both TLS providers.
---
}
program Http2TlsIntegrationTests;
{$mode delphi}{$H+}{$interfaces com}{$modeswitch advancedrecords}
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Http2.Common.Tls.Types, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Context, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Session, Http2.Common, Http2.Client, Http2.Server,
  Http2.OpenSSL, Http2.TlsLib;

const
  cCert = 'test/fixtures/client/certs/localhost.crt';
  cKey = 'test/fixtures/client/certs/localhost.key';
  cClientCert = 'test/fixtures/client/certs/mtls/client-chain.pem';
  cClientKey = 'test/fixtures/client/certs/mtls/client.key';
  cClientCa = 'test/fixtures/client/certs/mtls/ca.crt';
  cBody = 'tls integration response';
  cTimeoutMs = 5000;

type
  TProvider = (prOpenSSL, prTlsLib);
  TRequestThread = class(TThread)
  private
    FClient: IHttpClient;
    FPort: Integer;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const APort: Integer);
    property ErrorText: string read FErrorText;
  end;
  TEchoHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

var
  CaseCount: Integer;
  V: TTlsVersion;

procedure Check(const AValue: Boolean; const AMessage: string); forward;

constructor TRequestThread.Create(const AClient: IHttpClient; const APort: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
  FPort := APort;
end;

procedure TRequestThread.Execute;
var Response: IHttpResponse; Url: string;
begin
  try
    Url := 'https://localhost:' + IntToStr(FPort) + '/parallel';
    Response := FClient.Send(THttpRequest.Create(hmGet, Url));
    Check(Response.StatusCode = 200, 'concurrent request returned non-200');
    Check(ReadText(Response) = cBody, 'concurrent request body differs');
  except
    on E: Exception do FErrorText := E.ClassName + ': ' + E.Message;
  end;
end;

procedure Check(const AValue: Boolean; const AMessage: string);
begin
  if not AValue then raise Exception.Create(AMessage);
end;

function ProviderName(const AProvider: TProvider): string;
begin
  if AProvider = prOpenSSL then Result := 'OpenSSL' else Result := 'TlsLib';
end;

function LoadIdentity(const AProvider: TProvider; const AClient: Boolean): ITLSIdentity;
var CertFile, KeyFile: string;
begin
  if AClient then
  begin CertFile := cClientCert; KeyFile := cClientKey; end
  else
  begin CertFile := cCert; KeyFile := cKey; end;
  if AProvider = prOpenSSL then
    Result := TOpenSSLIdentity.FromPemFiles(CertFile, KeyFile)
  else
    Result := TTlsLibIdentity.FromPemFiles(CertFile, KeyFile);
end;

function ClientContext(const AProvider: TProvider; const AVersion: TTlsVersion): ITLSContext;
var
  Identity: ITLSIdentity;
  ClientPolicy: TTlsClientPolicy;
  OFactory: TOpenSSLTlsContextFactory;
  TFactory: TTlsLibContextFactory;
begin
  Identity := LoadIdentity(AProvider, True);
  ClientPolicy := TTlsClientPolicy.SecureDefault
    .WithTrustAnchors([cCert]).WithDefaultIdentity(Identity)
    .WithVersions(AVersion, AVersion);
  if AProvider = prOpenSSL then
  begin
    OFactory := TOpenSSLTlsContextFactory.Create.WithClientPolicy(ClientPolicy);
    Result := OFactory.Build;
  end
  else
  begin
    TFactory := TTlsLibContextFactory.Create.WithClientPolicy(ClientPolicy);
    Result := TFactory.Build;
  end;
end;

function ServerContext(const AProvider: TProvider; const AVersion: TTlsVersion): ITLSContext;
var
  Identity: ITLSIdentity;
  ServerPolicy: TTlsServerPolicy;
  OFactory: TOpenSSLTlsContextFactory;
  TFactory: TTlsLibContextFactory;
begin
  Identity := LoadIdentity(AProvider, False);
  ServerPolicy := TTlsServerPolicy.SecureDefault
    .WithServerIdentity(Identity).WithTrustAnchors([cClientCa])
    .WithClientAuth(tlsAuthRequire).WithVersions(AVersion, AVersion);
  if AProvider = prOpenSSL then
  begin
    OFactory := TOpenSSLTlsContextFactory.Create.WithServerPolicy(ServerPolicy);
    Result := OFactory.Build;
  end
  else
  begin
    TFactory := TTlsLibContextFactory.Create.WithServerPolicy(ServerPolicy);
    Result := TFactory.Build;
  end;
end;

function DualRoleContext(const AProvider: TProvider;
  const AVersion: TTlsVersion): ITLSContext;
var
  ClientIdentity, ServerIdentity: ITLSIdentity;
  ClientPolicy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  OFactory: TOpenSSLTlsContextFactory;
  TFactory: TTlsLibContextFactory;
begin
  ClientIdentity := LoadIdentity(AProvider, True);
  ServerIdentity := LoadIdentity(AProvider, False);
  ClientPolicy := TTlsClientPolicy.SecureDefault
    .WithTrustAnchors([cCert]).WithDefaultIdentity(ClientIdentity)
    .WithVersions(AVersion, AVersion);
  ServerPolicy := TTlsServerPolicy.SecureDefault
    .WithServerIdentity(ServerIdentity).WithTrustAnchors([cClientCa])
    .WithClientAuth(tlsAuthRequire).WithVersions(AVersion, AVersion);
  if AProvider = prOpenSSL then
  begin
    OFactory := TOpenSSLTlsContextFactory.Create
      .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy);
    Result := OFactory.Build;
  end
  else
  begin
    TFactory := TTlsLibContextFactory.Create
      .WithClientPolicy(ClientPolicy).WithServerPolicy(ServerPolicy);
    Result := TFactory.Build;
  end;
end;

procedure TEchoHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var Data: TBytes;
begin
  Data := TEncoding.UTF8.GetBytes(cBody);
  AResponse.SendHeaders(200, nil, False);
  AResponse.Write(Data);
  AResponse.Finish;
end;

function NewServer(const AProvider: TProvider; const AVersion: TTlsVersion;
  out AContext: ITLSContext): IHttp2Server;
var Factory: THttp2ServerFactory;
begin
  AContext := ServerContext(AProvider, AVersion);
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithTlsContext(AContext).WithClearTextAllowed(False)
    .WithHandler(TEchoHandler.Create).WithHandlerThreads(2).WithIOThreads(1);
  Result := Factory.Build;
  Result.Start;
end;

function NewServerWithContext(const AContext: ITLSContext): IHttp2Server;
var Factory: THttp2ServerFactory;
begin
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithTlsContext(AContext).WithClearTextAllowed(False)
    .WithHandler(TEchoHandler.Create).WithHandlerThreads(2).WithIOThreads(1);
  Result := Factory.Build;
  Result.Start;
end;

function NewClient(const AProvider: TProvider; const AVersion: TTlsVersion;
  out AContext: ITLSContext): IHttpClient;
var Factory: THttpClientFactory;
begin
  AContext := ClientContext(AProvider, AVersion);
  Factory := THttpClientFactory.Create.WithTlsContext(AContext)
    .WithConnectTimeout(cTimeoutMs).WithHeaderTimeout(cTimeoutMs);
  Result := Factory.Build;
end;

function NewClientWithContext(const AContext: ITLSContext): IHttpClient;
begin
  Result := THttpClientFactory.Create.WithTlsContext(AContext)
    .WithConnectTimeout(cTimeoutMs).WithHeaderTimeout(cTimeoutMs).Build;
end;

procedure FeedAll(const ASession: ITLSSession; const AData: TBytes);
var Offset, Accepted: SizeInt;
begin
  Offset := 0;
  while Offset < Length(AData) do
  begin
    Accepted := ASession.FeedEncrypted(AData, Offset, Length(AData) - Offset);
    if Accepted <= 0 then raise Exception.Create('TLS peer did not accept handshake input');
    Inc(Offset, Accepted);
  end;
end;

procedure Transfer(const AFrom, ATo: ITLSSession);
var Cipher: TBytes; Count: SizeInt;
begin
  SetLength(Cipher, 65536);
  repeat
    Count := AFrom.DrainEncrypted(Cipher, 0, Length(Cipher));
    if Count > 0 then
    begin
      SetLength(Cipher, Count);
      FeedAll(ATo, Cipher);
      SetLength(Cipher, 65536);
    end;
  until Count = 0;
end;

procedure RunSessionMetadata(const AClientProvider, AServerProvider: TProvider;
  const AVersion: TTlsVersion);
var
  ClientContextRef, ServerContextRef: ITLSContext;
  ClientSession, ServerSession: ITLSSession;
  ClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  ClientInfo, ServerInfo: TTlsNegotiatedInfo;
  Progress: TTlsProgress;
  Deadline: QWord;
  Subject, Fingerprint: string;
  Names: TArray<string>;
  I: Integer;
  HasLocalhost: Boolean;
begin
  if AClientProvider = AServerProvider then
  begin
    ClientContextRef := DualRoleContext(AClientProvider, AVersion);
    ServerContextRef := ClientContextRef;
  end
  else
  begin
    ClientContextRef := ClientContext(AClientProvider, AVersion);
    ServerContextRef := ServerContext(AServerProvider, AVersion);
  end;
  ClientOptions := Default(TTlsClientSessionOptions);
  ClientOptions.HostName := 'localhost';
  ClientOptions := ClientOptions.WithAlpns(['h2']);
  ServerOptions := Default(TTlsServerSessionOptions);
  ServerOptions := ServerOptions.WithAlpns(['h2']);
  ClientSession := ClientContextRef.CreateClientSession(ClientOptions);
  ServerSession := ServerContextRef.CreateServerSession(ServerOptions);
  ClientContextRef := nil;
  ServerContextRef := nil;
  try
    Deadline := GetTickCount64 + cTimeoutMs;
    while (ClientSession.State <> tssOpen) or (ServerSession.State <> tssOpen) do
    begin
      if GetTickCount64 >= Deadline then
        raise Exception.Create('provider-pair TLS handshake exceeded its deadline');
      Progress := ClientSession.Advance(GetTickCount64);
      Progress := ServerSession.Advance(GetTickCount64);
      Transfer(ClientSession, ServerSession);
      Transfer(ServerSession, ClientSession);
    end;
    ClientInfo := ClientSession.NegotiatedInfo;
    ServerInfo := ServerSession.NegotiatedInfo;
    Check(ClientInfo.Version = AVersion, 'client negotiated the requested TLS version');
    Check(ServerInfo.Version = AVersion, 'server negotiated the requested TLS version');
    Check((ClientInfo.SelectedAlpn = 'h2') and (ServerInfo.SelectedAlpn = 'h2'),
      'both peers negotiated h2');
    Check((ClientInfo.CipherName <> '') and (ServerInfo.CipherName <> ''),
      'both peers report a cipher');
    Check((ClientInfo.PeerCertificate <> nil) and
      ClientInfo.PeerCertificate.Verified, 'client verified the server certificate');
    Check((ServerInfo.PeerCertificate <> nil) and
      ServerInfo.PeerCertificate.Verified, 'server verified the client certificate');
    Check(ClientInfo.PeerCertificate.Leaf.Subject <>
      ServerInfo.PeerCertificate.Leaf.Subject,
      'client and server identities are separate');
    Subject := ClientInfo.PeerCertificate.Leaf.Subject;
    Fingerprint := ClientInfo.PeerCertificate.Leaf.FingerprintSha256;
    Check((Subject <> '') and (Fingerprint <> ''), 'peer metadata is populated');
    Names := ClientInfo.PeerCertificate.DnsNames;
    HasLocalhost := False;
    for I := 0 to High(Names) do
      if Names[I] = 'localhost' then HasLocalhost := True;
    Check(HasLocalhost, 'verified server metadata contains localhost SAN');
    ClientSession.Abort;
    ServerSession.Abort;
    ClientSession := nil;
    ServerSession := nil;
    Check((ClientInfo.PeerCertificate.Leaf.Subject = Subject) and
      (ClientInfo.PeerCertificate.Leaf.FingerprintSha256 = Fingerprint),
      'copied peer metadata survives session teardown');
    Inc(CaseCount);
  finally
    if ClientSession <> nil then ClientSession.Abort;
    if ServerSession <> nil then ServerSession.Abort;
  end;
end;

procedure RunHttpExchange(const AClientProvider, AServerProvider: TProvider;
  const AVersion: TTlsVersion);
var
  Server: IHttp2Server;
  Client: IHttpClient;
  ServerTls, ClientTls: ITLSContext;
  Response: IHttpResponse;
  Url: string;
  PairName: string;
begin
  RunSessionMetadata(AClientProvider, AServerProvider, AVersion);
  PairName := ProviderName(AClientProvider) + '/' + ProviderName(AServerProvider);
  Server := nil;
  Client := nil;
  ServerTls := nil;
  ClientTls := nil;
  try
    if AClientProvider = AServerProvider then
    begin
      ServerTls := DualRoleContext(AClientProvider, AVersion);
      ClientTls := ServerTls;
      Server := NewServerWithContext(ServerTls);
      Client := NewClientWithContext(ClientTls);
    end
    else
    begin
      Server := NewServer(AServerProvider, AVersion, ServerTls);
      Client := NewClient(AClientProvider, AVersion, ClientTls);
    end;
    ServerTls := nil;
    ClientTls := nil;
    Url := 'https://localhost:' + IntToStr(Server.Port) + '/tls-matrix';
    Response := Client.Send(THttpRequest.Create(hmGet, Url));
    Check(Response.StatusCode = 200, PairName + ' returned a non-200 status');
    Check(ReadText(Response) = cBody, PairName + ' returned a different response body');
    Inc(CaseCount);
  finally
    if Client <> nil then Client.Close;
    if Server <> nil then Server.Stop;
    ClientTls := nil;
    ServerTls := nil;
  end;
end;

procedure CheckResponse(const AClient: IHttpClient; const APort: Integer;
  const ALabel: string);
var Response: IHttpResponse; Url: string;
begin
  Url := 'https://localhost:' + IntToStr(APort) + '/listener';
  Response := AClient.Send(THttpRequest.Create(hmGet, Url));
  Check(Response.StatusCode = 200, ALabel + ' returned a non-200 status');
  Check(ReadText(Response) = cBody, ALabel + ' returned a different response body');
end;

procedure RunInterleavedListeners;
var
  OpenSslServer, TlsLibServer: IHttp2Server;
  OpenSslClient, TlsLibClient: IHttpClient;
  OpenSslServerTls, TlsLibServerTls: ITLSContext;
  OpenSslClientTls, TlsLibClientTls: ITLSContext;
  TlsLibSecondClient: IHttpClient;
  TlsLibContextRef: ITLSContext;
begin
  OpenSslServer := nil; TlsLibServer := nil;
  OpenSslClient := nil; TlsLibClient := nil;
  TlsLibSecondClient := nil;
  TlsLibContextRef := nil;
  try
    OpenSslServer := NewServer(prOpenSSL, tls13, OpenSslServerTls);
    TlsLibServer := NewServer(prTlsLib, tls13, TlsLibServerTls);
    TlsLibContextRef := TlsLibServerTls;
    OpenSslClient := NewClient(prOpenSSL, tls13, OpenSslClientTls);
    TlsLibClient := NewClient(prTlsLib, tls13, TlsLibClientTls);
    OpenSslServerTls := nil; TlsLibServerTls := nil;
    OpenSslClientTls := nil; TlsLibClientTls := nil;
    CheckResponse(OpenSslClient, OpenSslServer.Port, 'OpenSSL listener first accept');
    CheckResponse(TlsLibClient, TlsLibServer.Port, 'TlsLib listener first accept');
    CheckResponse(TlsLibClient, TlsLibServer.Port, 'TlsLib listener interleaved accept');
    OpenSslServer.Stop;
    OpenSslServer := nil;
    CheckResponse(TlsLibClient, TlsLibServer.Port,
      'TlsLib listener after OpenSSL listener stop');
    Inc(CaseCount, 4);
    TlsLibSecondClient := NewClientWithContext(TlsLibContextRef);
    TlsLibContextRef := nil;
    CheckResponse(TlsLibSecondClient, TlsLibServer.Port,
      'TlsLib listener accepts a new connection after OpenSSL listener stop');
    Inc(CaseCount);
  finally
    if OpenSslClient <> nil then OpenSslClient.Close;
    if TlsLibClient <> nil then TlsLibClient.Close;
    if TlsLibSecondClient <> nil then TlsLibSecondClient.Close;
    if OpenSslServer <> nil then OpenSslServer.Stop;
    if TlsLibServer <> nil then TlsLibServer.Stop;
    TlsLibContextRef := nil;
  end;
end;

procedure RunConcurrentSharedContext(const AProvider: TProvider;
  const AVersion: TTlsVersion);
var
  Context: ITLSContext;
  Server: IHttp2Server;
  ClientA, ClientB: IHttpClient;
  ThreadA, ThreadB: TRequestThread;
begin
  Context := DualRoleContext(AProvider, AVersion);
  Server := nil; ClientA := nil; ClientB := nil;
  ThreadA := nil; ThreadB := nil;
  try
    Server := NewServerWithContext(Context);
    ClientA := NewClientWithContext(Context);
    ClientB := NewClientWithContext(Context);
    Context := nil;
    ThreadA := TRequestThread.Create(ClientA, Server.Port);
    ThreadB := TRequestThread.Create(ClientB, Server.Port);
    ThreadA.Start;
    ThreadB.Start;
    ThreadA.WaitFor;
    ThreadB.WaitFor;
    Check(ThreadA.ErrorText = '', 'first concurrent request: ' + ThreadA.ErrorText);
    Inc(CaseCount);
    Check(ThreadB.ErrorText = '', 'second concurrent request: ' + ThreadB.ErrorText);
    Inc(CaseCount);
  finally
    if ThreadA <> nil then ThreadA.Free;
    if ThreadB <> nil then ThreadB.Free;
    if ClientA <> nil then ClientA.Close;
    if ClientB <> nil then ClientB.Close;
    if Server <> nil then Server.Stop;
    Context := nil;
  end;
end;

procedure RunMatrix;
var C, S: TProvider; V: TTlsVersion;
begin
  for V := Low(TTlsVersion) to High(TTlsVersion) do
    for C := Low(TProvider) to High(TProvider) do
      for S := Low(TProvider) to High(TProvider) do
        RunHttpExchange(C, S, V);
end;

begin
  try
    RunMatrix;
    RunInterleavedListeners;
    for V := Low(TTlsVersion) to High(TTlsVersion) do
    begin
      RunConcurrentSharedContext(prOpenSSL, V);
      RunConcurrentSharedContext(prTlsLib, V);
    end;
    WriteLn('PASS ', CaseCount, ' cases');
    WriteLn('TLS metadata, provider-pair HTTP/2, shared-context concurrency, listener interleave');
  except
    on E: Exception do
    begin
      WriteLn('FAIL after ', CaseCount, ' cases: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
