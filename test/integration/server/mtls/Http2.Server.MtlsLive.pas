{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, live, validation, http2components, websocket
notes:
  - This program starts the server with TLS on loopback and drives it with the
    merged client facade. It checks the three client certificate
    modes, the identity that a handler reads, the refusal of a bad client, the
    HTTP/1.1 path and the WebSocket handshake over HTTP/1.1 and HTTP/2.
  - The client does not speak WebSocket over HTTP/2, so a small raw HTTP/2 client
    in Http2.Server.Mtls.Live.Raw opens the extended CONNECT stream.
  - The program is a validation run and puts no load on the server.
  - The first argument is the directory of the test PKI, made by
    tools/server/certs/make_mtls_pki.sh. The exit code is 0 when every check passed.
---
}
/// Live validation of mutual TLS with the merged client facade
program Http2.Server.MtlsLive;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  Http2.Server, Http2.Common, Http2.OpenSSL,
  Http2.Client.Errors, Http2.Client.ClientCert, Http2.Client.Stream,
  Http2.Client.Messages, Http2.Client, Http2.Client.WebSocket,
  Http2.Server.Mtls.Live.Server, Http2.Server.Mtls.Live.Raw,
  Http2.Server.Mtls.Live.Leak;

type
  /// the WebSocket listener: it sends one text message when open
  TSendOnOpen = class(TWebSocketListener)
  public
    Opened, Done: TEvent;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket;
      const AError: Exception); override;
  end;

var
  Pki: string;
  Passed, Failed: Integer;
  Handler: TMtlsHandler;
  HandlerRef: IHttp2Handler;
  WsHandler: TMtlsWsHandler;
  WsRef: IWsHandler;
  ClientTlsContext: ITLSContext;

constructor TSendOnOpen.Create;
begin
  inherited Create;
  Opened := TEvent.Create(nil, True, False, '');
  Done := TEvent.Create(nil, True, False, '');
end;

destructor TSendOnOpen.Destroy;
begin
  Done.Free;
  Opened.Free;
  inherited Destroy;
end;

procedure TSendOnOpen.OnOpen(const ASocket: IWebSocket);
begin
  ASocket.Request(4);
  Opened.SetEvent;
  ASocket.SendText('who am i');
end;

procedure TSendOnOpen.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  Done.SetEvent;
end;

procedure TSendOnOpen.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  Done.SetEvent;
end;

procedure Check(const AName: string; const ACondition: Boolean;
  const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(Passed);
    WriteLn('ok   ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('FAIL ', AName, ' ', ADetail);
  end;
end;

function Contains(const AText, AFragment: string): Boolean;
begin
  Result := Pos(AFragment, AText) > 0;
end;

function Identity(const AName: string): IClientIdentity;
begin
  Result := TOpenSSLIdentity.FromPemFiles(Pki + '/' + AName + '.crt',
    Pki + '/' + AName + '.key');
end;

/// one HTTP/2 GET with the merged client facade; a failure answers 'refused:<class>'
function ClientGet(const APort: Integer; const AName: string;
  const ARequests: Integer = 1): string;
var
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Response: IHttpResponse;
  i: Integer;
begin
  Result := '';
  try
    Factory := THttpClientFactory.Create
      .WithTlsContext(ClientTlsContext)
      .WithMaxConnectionsPerHost(1);
    if AName <> '' then
      Factory := Factory.WithClientIdentity(Identity(AName));
    Client := Factory.Build;
    try
      for i := 1 to ARequests do
      begin
        Response := Client.Send(THttpRequest.Create(hmGet,
          'https://127.0.0.1:' + IntToStr(APort) + '/id'));
        if Response.StatusCode <> 200 then
          Exit('status ' + IntToStr(Response.StatusCode));
        if i > 1 then
          Result := Result + ' | ';
        Result := Result + ReadText(Response);
      end;
    finally
      Client.Close;
    end;
  except
    on E: Exception do
      Result := 'refused:' + E.ClassName;
  end;
end;

/// check that saved session state cannot resume without fresh authentication
function SessionTicketPolicy(const APort: Integer; const AVersion,
  AProtocol: string): Boolean;
var
  Common, NoCertificate, Cmd: string;
begin
  Common := 'openssl s_client ' + AVersion + ' -connect 127.0.0.1:' + IntToStr(APort) +
    ' -alpn h2 -verify_return_error -verify_hostname localhost -CAfile ca.crt';
  NoCertificate := Common + ' -sess_in ' + AProtocol + '.pem';
  Common := Common + ' -cert alice.crt -key alice.key';
  Cmd := 'cd ' + Pki + ' && rm -f ' + AProtocol + '.pem ' + AProtocol +
    '-full.log ' + AProtocol + '-saved.log ' + AProtocol + '-no-cert.log && ' +
    '(sleep 1; printf Q) | ' + Common + ' -sess_out ' + AProtocol +
    '.pem >' + AProtocol + '-full.log 2>&1; ' +
    'full_status=$?; ' +
    'if [ "$full_status" -ne 0 ] || [ ! -s ' + AProtocol + '.pem ] || ' +
    '(! grep -q "^New, ' + AProtocol + '" ' + AProtocol + '-full.log) || ' +
    '(! grep -Eq "Verification: OK|Verify return code: 0 \\(ok\\)" ' +
    AProtocol + '-full.log); then cat ' + AProtocol + '-full.log; exit 1; fi; ' +
    '(sleep 1; printf Q) | ' + Common + ' -sess_in ' + AProtocol +
    '.pem >' + AProtocol + '-saved.log 2>&1; ' +
    'saved_status=$?; ' +
    'if [ "$saved_status" -ne 0 ] || ' +
    '(! grep -q "^New, ' + AProtocol + '" ' + AProtocol + '-saved.log) || ' +
    'grep -q "^Reused" ' + AProtocol + '-saved.log || ' +
    '(! grep -Eq "Verification: OK|Verify return code: 0 \\(ok\\)" ' +
    AProtocol + '-saved.log); then cat ' + AProtocol + '-saved.log; exit 1; fi; ' +
    '(sleep 1; printf Q) | ' + NoCertificate + ' >' + AProtocol +
    '-no-cert.log 2>&1; no_cert_status=$?; ' +
    'if [ "$no_cert_status" -eq 0 ] || ' +
    'grep -q "^New, ' + AProtocol + '" ' + AProtocol + '-no-cert.log || ' +
    'grep -q "^Reused" ' + AProtocol + '-no-cert.log || ' +
    '(! grep -Eiq "alert|handshake failure|certificate required" ' +
    AProtocol + '-no-cert.log); then cat ' + AProtocol + '-no-cert.log; exit 1; fi; ' +
    'echo "PASS ' + AProtocol + ' full handshake; saved attempt is full; no-cert attempt refused"; ' +
    'rm -f ' + AProtocol + '.pem ' + AProtocol + '-full.log ' + AProtocol +
    '-saved.log ' + AProtocol + '-no-cert.log';
  Result := ExecuteProcess('/bin/sh', ['-c', Cmd]) = 0;
end;

function Refused(const AText: string): Boolean;
begin
  Result := Copy(AText, 1, 8) = 'refused:';
end;

/// a WebSocket over HTTP/1.1 with the merged client facade
function ClientWsHttp1(const APort: Integer; const AName: string): Boolean;
var
  Factory: THttpClientFactory;
  Client: IHttpClient;
  Listener: TSendOnOpen;
  ListenerRef: IWebSocketListener;
  Socket: IWebSocket;
begin
  Result := False;
  try
    Factory := THttpClientFactory.Create.WithTlsContext(ClientTlsContext);
    if AName <> '' then
      Factory := Factory.WithClientIdentity(Identity(AName));
    Client := Factory.Build;
    try
      Listener := TSendOnOpen.Create;
      ListenerRef := Listener;
      Socket := Client.Send(TWebSocketRequest.Create('wss://127.0.0.1:' +
        IntToStr(APort) + '/ws', ListenerRef).WithAutoRequest);
      Result := WsHandler.MessageSeen.WaitFor(5000) = wrSignaled;
      Socket.Close;
      Listener.Done.WaitFor(2000);
    finally
      Client.Close;
    end;
  except
    on E: Exception do
      WriteLn('  ws http1: ', E.ClassName, ': ', E.Message);
  end;
end;

procedure RunNoneMode;
var
  R: TRawH2;
  W: TRawResult;
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
begin
  WriteLn('-- mode none');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthNone, '', False, ccpNone);
  try
    Body := ClientGet(Server.Port, '');
    Check('none: a client without a certificate is served', Body = 'none;principal=', Body);
    Body := ClientGet(Server.Port, 'alice');
    Check('none: a certificate that nobody asked for gives no identity',
      Body = 'none;principal=', Body);
    R := TRawH2.Create(Server.Port, nil);
    try
      W := R.Get('/id');
      Check('none: the raw HTTP/2 client is served',
        (not W.Refused) and (W.Body = 'none;principal='), W.Status + ' ' + W.Body);
    finally
      R.Free;
    end;
  finally
    Server.Stop;
  end;
end;

procedure RunOptionalMode;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
  R: TRawH2;
  W: TRawResult;
  CallsBefore: Integer;
begin
  WriteLn('-- mode optional, principal = common name');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthRequest, 'ca.crt', False,
    ccpCommonName);
  try
    Body := ClientGet(Server.Port, '');
    Check('optional: no certificate is served with a nil identity',
      Body = 'none;principal=', Body);
    Body := ClientGet(Server.Port, 'alice');
    Check('optional: a valid certificate gives the identity',
      Contains(Body, 'cn=alice;') and Contains(Body, 'principal=alice;'), Body);
    Check('optional: the subject keeps the organisation',
      Contains(Body, 'O=Example'), Body);
    Check('optional: the SAN names arrive',
      Contains(Body, 'dns=alice.example;') and
      Contains(Body, 'uri=spiffe://example.org/alice;') and
      Contains(Body, 'email=alice@example.org'), Body);
    Check('optional: the issuer is the test root', Contains(Body, 'CN=Test Root CA'), Body);
    CallsBefore := Handler.Calls;
    Body := ClientGet(Server.Port, 'mallory');
    Check('optional: a certificate of an unknown CA is refused', Refused(Body), Body);
    Check('optional: the refused client reached no handler', Handler.Calls = CallsBefore);
    // WebSocket over HTTP/2 without a certificate: the handshake succeeds and
    // the handler sees a nil identity, so it can answer 401 on its own
    WsHandler.Reset;
    R := TRawH2.Create(Server.Port, nil);
    try
      W := R.OpenWebSocket('/ws');
      Check('optional: WebSocket over HTTP/2 without a certificate opens',
        (not W.Refused) and (W.Status = '200'), W.Status);
      Check('optional: the WebSocket handler sees a nil identity',
        Copy(WsHandler.InitId, 1, 5) = 'none;', WsHandler.InitId);
    finally
      R.Free;
    end;
  finally
    Server.Stop;
  end;
end;

procedure RunRequiredMode;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body, First, Second: string;
  P: Integer;
  R: TRawH2;
  W: TRawResult;
  H1: TRawResult;
  CallsBefore, FailedBefore: Integer;
  Ident: IClientIdentity;
begin
  WriteLn('-- mode required, principal = subject DN');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthRequire, 'ca.crt', False,
    ccpSubjectDn);
  try
    CallsBefore := Handler.Calls;
    FailedBefore := Obs.Failed;
    Body := ClientGet(Server.Port, '');
    Check('required: no certificate is refused', Refused(Body), Body);
    Body := ClientGet(Server.Port, 'mallory');
    Check('required: a certificate of an unknown CA is refused', Refused(Body), Body);
    Body := ClientGet(Server.Port, 'selfie');
    Check('required: a self-signed certificate outside the trust is refused',
      Refused(Body), Body);
    // the expired certificate loads in the client but the client factory
    // refuses it at Build, so the raw client presents it
    Ident := Identity('expired');
    try
      R := TRawH2.Create(Server.Port, Ident);
      try
        W := R.Get('/id');
        Check('required: an expired certificate is refused', W.Refused, W.Status);
      finally
        R.Free;
      end;
    except
      on E: Exception do
        Check('required: an expired certificate is refused (at dial)', True);
    end;
    Sleep(300);
    Check('required: the refused clients reached no handler', Handler.Calls = CallsBefore,
      IntToStr(Handler.Calls - CallsBefore) + ' calls');
    Check('required: the observer counted each of the four failed handshakes',
      Obs.Failed - FailedBefore = 4, IntToStr(Obs.Failed - FailedBefore));
    Check('required: the stats count the failed handshakes',
      Server.Stats.TlsHandshakeFailedTotal = 4,
      IntToStr(Server.Stats.TlsHandshakeFailedTotal));

    Body := ClientGet(Server.Port, 'alice', 2);
    P := Pos(' | ', Body);
    First := Copy(Body, 1, P - 1);
    Second := Copy(Body, P + 3, MaxInt);
    Check('required: a valid certificate is served', Contains(First, 'cn=alice;'), Body);
    Check('required: the principal is the subject DN, most specific name last',
      Contains(First, 'dn=OU=Eng,O=Example,CN=alice;') and
      Contains(First, ';principal=OU=Eng,O=Example,CN=alice;'), First);
    Check('required: two requests on one connection show one identity',
      (First <> '') and (First = Second), Body);

    Body := ClientGet(Server.Port, 'special');
    Check('required: a comma in a DN value is escaped as RFC 4514 says',
      Contains(Body, 'CN=Doe\, Jane') and Contains(Body, 'O=Acme\, Inc'), Body);
    Check('required: TLS 1.2 uses fresh client authentication after a saved-session attempt',
      SessionTicketPolicy(Server.Port, '-tls1_2', 'TLSv1.2'));
    Check('required: TLS 1.3 uses fresh client authentication after a saved-session attempt',
      SessionTicketPolicy(Server.Port, '-tls1_3', 'TLSv1.3'));

    // HTTP/1.1 over TLS on the same listener
    H1 := RawHttp1Get(Server.Port, Identity('alice'), '/id');
    Check('required: HTTP/1.1 over TLS is served with the identity',
      (not H1.Refused) and (H1.Status = '200') and Contains(H1.Body, 'cn=alice;'),
      H1.Status + ' ' + H1.Body);
    H1 := RawHttp1Get(Server.Port, nil, '/id');
    Check('required: HTTP/1.1 without a certificate is refused', H1.Refused);

    // WebSocket over HTTP/2 (RFC 8441 extended CONNECT)
    WsHandler.Reset;
    R := TRawH2.Create(Server.Port, Identity('alice'));
    try
      W := R.OpenWebSocket('/ws');
      Check('required: WebSocket over HTTP/2 opens with a certificate',
        (not W.Refused) and (W.Status = '200'), W.Status);
      Check('required: Init sees the identity over HTTP/2',
        Contains(WsHandler.InitId, 'cn=alice;'), WsHandler.InitId);
      R.SendWsText('who am i');
      Check('required: the session still has the identity at the first message',
        (WsHandler.MessageSeen.WaitFor(5000) = wrSignaled) and
        Contains(WsHandler.MessageId, 'cn=alice;'), WsHandler.MessageId);
    finally
      R.Free;
    end;
    CallsBefore := Handler.Calls;
    try
      R := TRawH2.Create(Server.Port, nil);
      try
        W := R.OpenWebSocket('/ws');
        Check('required: WebSocket over HTTP/2 without a certificate is refused',
          W.Refused);
      finally
        R.Free;
      end;
    except
      on E: Exception do
        Check('required: WebSocket over HTTP/2 without a certificate is refused (at dial)', True);
    end;
    Check('required: that refusal reached no handler', Handler.Calls = CallsBefore);

    // WebSocket over HTTP/1.1 with the merged client facade
    WsHandler.Reset;
    Check('required: WebSocket over HTTP/1.1 delivers a message', ClientWsHttp1(Server.Port, 'alice'));
    Check('required: the HTTP/1.1 session sees the identity',
      Contains(WsHandler.InitId, 'cn=alice;') and Contains(WsHandler.MessageId, 'cn=alice;'),
      WsHandler.InitId + ' / ' + WsHandler.MessageId);
  finally
    Server.Stop;
  end;
end;

procedure RunLeakCheck;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  NoneGrowth, RequiredGrowth: Integer;

  /// the growth of the live X509 count over five handshakes of the client library
  // - five handshakes only: the check needs a repeat, not a load
  function Growth(const APort: Integer; const AName: string = 'alice'): Integer;
  var
    Baseline, i: Integer;
  begin
    // warm-up: the first handshake loads lazy state of OpenSSL
    ClientGet(APort, AName);
    Sleep(500);
    Baseline := LiveX509;
    for i := 1 to 5 do
      ClientGet(APort, AName);
    Sleep(800);
    Result := LiveX509 - Baseline;
  end;

begin
  WriteLn('-- the identity reader releases its X509 reference');
  if not InstallX509Counter then
  begin
    WriteLn('skip the X509 counter is not available');
    Exit;
  end;
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  // the first server never asks for a certificate, so the reader does not run.
  // Its growth is what the client library and the rest of the process keep
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthNone, '', False, ccpNone);
  try
    NoneGrowth := Growth(Server.Port);
    WriteLn('  growth over 5 handshakes of a client without a certificate: ',
      Growth(Server.Port, ''));
  finally
    Server.Stop;
  end;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthRequire, 'ca.crt', False,
    ccpSubjectDn);
  try
    RequiredGrowth := Growth(Server.Port);
  finally
    Server.Stop;
  end;
  WriteLn('  growth over 5 handshakes: no reader ', NoneGrowth, ', with reader ',
    RequiredGrowth);
  Check('the counter saw X509 objects', CreatedX509 > 0, IntToStr(CreatedX509));
  Check('leak: the reader keeps no X509 beyond what a server without it keeps',
    RequiredGrowth <= NoneGrowth,
    'no reader ' + IntToStr(NoneGrowth) + ', reader ' + IntToStr(RequiredGrowth));
end;

procedure RunSelfSignedTrust;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
begin
  WriteLn('-- required, trust file holds the root and a self-signed client');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthRequire,
    'trust-selfie.pem', False, ccpNone);
  try
    Body := ClientGet(Server.Port, 'selfie');
    Check('self-signed: a self-signed client in the trust file is served',
      Contains(Body, 'cn=selfie;'), Body);
    Body := ClientGet(Server.Port, 'alice');
    Check('self-signed: a client of the root is served as well',
      Contains(Body, 'cn=alice;'), Body);
    Body := ClientGet(Server.Port, 'mallory');
    Check('self-signed: an unknown CA stays refused', Refused(Body), Body);
  finally
    Server.Stop;
  end;
end;

procedure RunSystemStore;
var
  Obs: TMtlsObserver;
  ObsRef: IHttp2ServerObserver;
  Server: IHttp2Server;
  Body: string;
begin
  WriteLn('-- required, operating system store only');
  Obs := TMtlsObserver.Create;
  ObsRef := Obs;
  Server := BuildMtlsServer(Pki, HandlerRef, ObsRef, tlsAuthRequire, '', True, ccpNone);
  try
    // the test root is not in the system store of the host, and the live check
    // never changes that store. The client of the test root is refused, which
    // shows that the system store is the only anchor. A positive case needs a
    // certificate from a public CA and stays a documented gap
    Body := ClientGet(Server.Port, 'alice');
    Check('system store: a client of a private root is refused', Refused(Body), Body);
  finally
    Server.Stop;
  end;
end;

begin
  Pki := ParamStr(1);
  if (Pki = '') or not FileExists(Pki + '/ca.crt') then
  begin
    WriteLn(StdErr, 'usage: Http2.Server.MtlsLive <pki-directory>');
    Halt(2);
  end;
  ClientTlsContext := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(TTlsClientPolicy.SecureDefault
      .WithTrustAnchors([Pki + '/ca.crt']))
    .Build;
  SetRawTlsContext(ClientTlsContext);
  WsHandler := TMtlsWsHandler.Create;
  WsRef := WsHandler;
  Handler := TMtlsHandler.Create(WsRef);
  HandlerRef := Handler;
  RunNoneMode;
  RunOptionalMode;
  RunRequiredMode;
  RunSelfSignedTrust;
  RunSystemStore;
  RunLeakCheck;
  WriteLn;
  WriteLn('passed ', Passed, ', failed ', Failed);
  if Failed > 0 then
    Halt(1);
end.
