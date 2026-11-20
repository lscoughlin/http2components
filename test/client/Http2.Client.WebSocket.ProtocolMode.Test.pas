{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, websocket, protocol mode, extended connect, rfc 8441
notes:
  - this tests the protocol choice of THttpClient.Send for a WebSocket (wpmAuto, wpmHttp1, wpmHttp2)
  - wpmAuto never dials HTTP/2 for a WebSocket: it uses a live pooled HTTP/2 connection of the origin, else the HTTP/1.1 opening
  - an HTTP/1.1 opening is seen as a 101 answer with a wrong accept field, which the handshake refuses
    with EHttpWebSocketHandshakeError (status 101): the status proves that the Upgrade was written
  - a dial of the factory is counted as a TLS handshake; the pooled connection is made by a wpmHttp2 opening
---
}
unit Http2.Client.WebSocket.ProtocolMode.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames,
  Http2.Client.Tls, Http2.Client.Tls.Types, Http2.Client.Api, Http2.Client.Factory,
  Http2.Client.Proxy, Http2.Client.SocketFactory.Types, Http2.Client.WebSocket,
  Http2.Client.MockSocket.Support;

type
  /// a socket factory for the protocol choice: the ALPN name of the peer, the
  /// extended CONNECT setting, and the answer to the extended CONNECT are scripted
  TWsModeFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory, IHttp1SocketFactory)
  private
    FPeer: string;
    FConnect: Boolean;
    FStatus: string;
    FH2: TList<IHttp2Socket>;
    FHttp1: TList<IHttp2Socket>;
    FProtocolDials: Integer;
    FLastPolicy: TClearTextPolicy;
    FLastProtocol: TNegotiatedProtocol;
    function NewH2: IHttp2Socket;
  public
    /// APeer is the ALPN name the peer selects ('' for none); AConnect is the
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL the peer sends; AStatus answers the CONNECT
    constructor Create(const APeer: string; const AConnect: Boolean;
      const AStatus: string);
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    function DialHttp1(const AHost: string; const APort: Word;
      const AScheme: string; const ATimeoutMs: Integer;
      const AProxy: IProxy): IHttp2Socket;
    /// the socket of HTTP/2 dial AIndex (0 is the first)
    function H2Socket(const AIndex: Integer): TMockSocket;
    /// the socket of HTTP/1.1 dial AIndex (0 is the first)
    function Http1Socket(const AIndex: Integer): TMockSocket;
    property ProtocolDials: Integer read FProtocolDials;
    property LastPolicy: TClearTextPolicy read FLastPolicy;
    property LastProtocol: TNegotiatedProtocol read FLastProtocol;
    function Http1Dials: Integer;
    function H2Dials: Integer;
  end;

  TWsProtocolModeTest = class(TTestCase)
  private
    FFactory: TWsModeFactory;
    /// keeps the factory and its sockets alive after the client is closed
    FFactoryRef: IHttp2SocketFactory;
    FClient: IHttpClient;
    FListener: IWebSocketListener;
    FSocket: IWebSocket;
    /// the socket of an earlier opening in the same test (aborted by TearDown)
    FOther: IWebSocket;
    /// builds the client over a factory with the given script and cleartext policy
    procedure Build(const APeer: string; const AConnect: Boolean;
      const AStatus: string; const APolicy: TClearTextPolicy);
    /// opens AUrl in AMode; returns '' for an open socket (kept in FSocket), else
    /// 'handshake:<status>' for a handshake refusal, 'websocket' for an
    /// EHttpWebSocketError, 'protocol' for an EHttpProtocolError, or the class name
    function Attempt(const AUrl: string; const AMode: TWsProtocolMode): string;
    /// the HEADERS frames that the client sent on any stream of HTTP/2 dial AIndex
    function HeadersSent(const AIndex: Integer): Integer;
  protected
    procedure TearDown; override;
  published
    procedure TestDefaultModeIsAuto;
    procedure TestWithProtocolModeLeavesTheOriginal;
    procedure TestHttp1ModeNeverOffersH2;
    procedure TestHttp2ModeDialsH2;
    procedure TestHttp2ModeWithoutSettingRaises;
    procedure TestHttp2ModeRefusesAnHttp1Peer;
    procedure TestAutoWithHttp1OnlyPeerUsesUpgrade;
    procedure TestAutoWithNoAlpnPeerUsesUpgrade;
    procedure TestAutoWithNoPooledConnectionDoesNotDialH2;
    procedure TestAutoWithPooledH2UsesExtendedConnect;
    procedure TestAutoWithPooledH2WithoutSettingUsesHttp1;
    procedure TestRefusedConnectDoesNotFallBack;
    procedure TestCleartextWithoutPriorKnowledgeUsesHttp1;
    procedure TestCleartextWithPriorKnowledgeNoPoolUsesHttp1;
    procedure TestCleartextPooledWithPriorKnowledgeIsReused;
    procedure TestHttp2ModeCleartextNeedsPriorKnowledge;
  end;

implementation

const
  cWssUrl = 'wss://tunnel.test/chat';
  cWsUrl = 'ws://tunnel.test/chat';
  /// a 101 answer whose accept field is wrong: the handshake refuses it, so
  /// the status 101 shows that the HTTP/1.1 Upgrade was written
  cHttp1Answer = 'HTTP/1.1 101 Switching Protocols'#13#10 +
    'Upgrade: websocket'#13#10 + 'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: wrong'#13#10#13#10;

/// the octets of an ASCII text (one octet per character)
function ToBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

/// the text of octets (one character per octet)
function FromBytes(const ABytes: TBytes): string;
begin
  SetLength(Result, Length(ABytes));
  if Length(ABytes) > 0 then
    Move(ABytes[0], Result[1], Length(ABytes));
end;

{ TWsModeFactory }

constructor TWsModeFactory.Create(const APeer: string; const AConnect: Boolean;
  const AStatus: string);
begin
  inherited Create;
  FPeer := APeer;
  FConnect := AConnect;
  FStatus := AStatus;
  FH2 := TList<IHttp2Socket>.Create;
  FHttp1 := TList<IHttp2Socket>.Create;
end;

destructor TWsModeFactory.Destroy;
begin
  FH2.Free;
  FHttp1.Free;
  inherited Destroy;
end;

function TWsModeFactory.NewH2: IHttp2Socket;
var
  S: TMockSocket;
  Settings: TConnectionSettings;
begin
  S := TMockSocket.Create;
  // a 200 answer stays open (no END_STREAM); any other status ends the stream
  S.AutoRespondToRequestHeaders(FStatus, nil, FStatus <> '200');
  Settings := TConnectionSettings.Defaults;
  Settings.EnableConnectProtocol := FConnect;
  S.EnqueueSettings(Settings);
  FH2.Add(S);
  Result := S;
end;

function TWsModeFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  Result := NewH2;
end;

function TWsModeFactory.DialProtocol(const AHost: string; const APort: Word;
  const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
begin
  Inc(FProtocolDials);
  FLastPolicy := APolicy;
  if AScheme = 'http' then
  begin
    if APolicy <> ctPriorKnowledge then
      raise EHttpProtocolError.Create(
        'the test factory scripts a cleartext dial with prior knowledge only',
        ecProtocolError);
    AProtocol := npHttp2Cleartext;
  end
  else
    // the real mapping of the selected ALPN name: h2 is accepted; http/1.1 or
    // no name fails the strict check with EHttpProtocolError
    AProtocol := ProtocolForTlsAlpn(FPeer, AHttp1Fallback);
  FLastProtocol := AProtocol;
  Result := NewH2;
end;

function TWsModeFactory.DialHttp1(const AHost: string; const APort: Word;
  const AScheme: string; const ATimeoutMs: Integer;
  const AProxy: IProxy): IHttp2Socket;
var
  S: TMockSocket;
begin
  S := TMockSocket.Create;
  S.Feed(ToBytes(cHttp1Answer));
  FHttp1.Add(S);
  Result := S;
end;

function TWsModeFactory.H2Socket(const AIndex: Integer): TMockSocket;
begin
  Result := FH2[AIndex] as TMockSocket;
end;

function TWsModeFactory.Http1Socket(const AIndex: Integer): TMockSocket;
begin
  Result := FHttp1[AIndex] as TMockSocket;
end;

function TWsModeFactory.Http1Dials: Integer;
begin
  Result := FHttp1.Count;
end;

function TWsModeFactory.H2Dials: Integer;
begin
  Result := FH2.Count;
end;

{ TWsProtocolModeTest }

procedure TWsProtocolModeTest.Build(const APeer: string; const AConnect: Boolean;
  const AStatus: string; const APolicy: TClearTextPolicy);
begin
  FFactory := TWsModeFactory.Create(APeer, AConnect, AStatus);
  FFactoryRef := FFactory;
  FClient := THttpClientFactory.Create.WithSocketFactory(FFactoryRef)
    .WithClearText(APolicy).Build;
  FListener := TWebSocketListener.Create;
end;

function TWsProtocolModeTest.Attempt(const AUrl: string;
  const AMode: TWsProtocolMode): string;
begin
  Result := '';
  if FSocket <> nil then
    FOther := FSocket;
  FSocket := nil;
  try
    FSocket := FClient.Send(TWebSocketRequest.Create(AUrl, FListener)
      .WithProtocolMode(AMode));
  except
    on E: EHttpWebSocketHandshakeError do
      Result := 'handshake:' + IntToStr(E.StatusCode);
    on E: EHttpWebSocketError do
      Result := 'websocket';
    on E: EHttpProtocolError do
      Result := 'protocol';
    on E: Exception do
      Result := E.ClassName;
  end;
end;

function TWsProtocolModeTest.HeadersSent(const AIndex: Integer): Integer;
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Result := 0;
  Frames := FFactory.H2Socket(AIndex).OutboundFrames(True);
  for I := 0 to High(Frames) do
    if Frames[I].Header.FrameType = ftHeaders then
      Inc(Result);
end;

procedure TWsProtocolModeTest.TearDown;
begin
  if FSocket <> nil then
    FSocket.Abort;
  if FOther <> nil then
    FOther.Abort;
  FSocket := nil;
  FOther := nil;
  if FClient <> nil then
    FClient.Close;
  FClient := nil;
  FListener := nil;
  FFactoryRef := nil;
  FFactory := nil;
  inherited TearDown;
end;

procedure TWsProtocolModeTest.TestDefaultModeIsAuto;
var
  R: IWebSocketRequest;
begin
  R := TWebSocketRequest.Create(cWssUrl, TWebSocketListener.Create);
  AssertTrue('the default is wpmAuto', R.ProtocolMode = wpmAuto);
end;

procedure TWsProtocolModeTest.TestWithProtocolModeLeavesTheOriginal;
var
  Original, Changed: IWebSocketRequest;
begin
  Original := TWebSocketRequest.Create(cWssUrl, TWebSocketListener.Create);
  Changed := Original.WithProtocolMode(wpmHttp2);
  AssertTrue('the new request has wpmHttp2', Changed.ProtocolMode = wpmHttp2);
  AssertTrue('the original keeps wpmAuto', Original.ProtocolMode = wpmAuto);
end;

procedure TWsProtocolModeTest.TestHttp1ModeNeverOffersH2;
begin
  Build('h2', True, '200', ctReject);
  AssertEquals('handshake answer', 'handshake:101',
    Attempt(cWssUrl, wpmHttp1));
  AssertEquals('no TLS dial offers h2', 0, FFactory.ProtocolDials);
  AssertEquals('one HTTP/1.1 dial', 1, FFactory.Http1Dials);
  AssertTrue('the Upgrade was written',
    Pos('Upgrade: websocket', FromBytes(FFactory.Http1Socket(0).WrittenBytes)) > 0);
end;

procedure TWsProtocolModeTest.TestHttp2ModeDialsH2;
begin
  Build('h2', True, '200', ctReject);
  AssertEquals('the socket opened', '', Attempt(cWssUrl, wpmHttp2));
  AssertTrue('a socket is returned', FSocket <> nil);
  AssertEquals('one HTTP/2 dial', 1, FFactory.ProtocolDials);
  AssertTrue('the protocol is HTTP/2 over TLS', FFactory.LastProtocol = npHttp2Tls);
  AssertEquals('no HTTP/1.1 dial', 0, FFactory.Http1Dials);
  AssertTrue('the extended CONNECT was sent', HeadersSent(0) >= 1);
end;

procedure TWsProtocolModeTest.TestHttp2ModeWithoutSettingRaises;
begin
  Build('h2', False, '200', ctReject);
  AssertEquals('EHttpWebSocketError', 'websocket', Attempt(cWssUrl, wpmHttp2));
  AssertEquals('no HTTP/1.1 fallback', 0, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestHttp2ModeRefusesAnHttp1Peer;
begin
  Build('http/1.1', True, '200', ctReject);
  AssertEquals('an HTTP/2 refusal is a WebSocket error', 'websocket',
    Attempt(cWssUrl, wpmHttp2));
  AssertEquals('no HTTP/1.1 fallback', 0, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestAutoWithHttp1OnlyPeerUsesUpgrade;
begin
  Build('http/1.1', True, '200', ctReject);
  AssertEquals('handshake answer', 'handshake:101', Attempt(cWssUrl, wpmAuto));
  AssertEquals('no HTTP/2 dial for wpmAuto', 0, FFactory.ProtocolDials);
  AssertEquals('one HTTP/1.1 dial', 1, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestAutoWithNoAlpnPeerUsesUpgrade;
begin
  Build('', True, '200', ctReject);
  AssertEquals('handshake answer', 'handshake:101', Attempt(cWssUrl, wpmAuto));
  AssertEquals('one HTTP/1.1 dial', 1, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestAutoWithNoPooledConnectionDoesNotDialH2;
begin
  // wpmAuto never dials HTTP/2 for a WebSocket: one dial, the HTTP/1.1 Upgrade
  Build('h2', True, '200', ctReject);
  AssertEquals('handshake answer', 'handshake:101', Attempt(cWssUrl, wpmAuto));
  AssertEquals('no TLS dial offers h2', 0, FFactory.ProtocolDials);
  AssertEquals('no HTTP/2 connection', 0, FFactory.H2Dials);
  AssertEquals('one handshake in all', 1, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestAutoWithPooledH2UsesExtendedConnect;
begin
  // a wpmHttp2 opening leaves its pooled connection in place
  Build('h2', True, '200', ctReject);
  AssertEquals('the first socket opened', '', Attempt(cWssUrl, wpmHttp2));
  FOther := FSocket;
  FSocket := nil;
  AssertEquals('the second socket opened', '', Attempt(cWssUrl, wpmAuto));
  AssertTrue('a socket is returned', FSocket <> nil);
  AssertEquals('one HTTP/2 dial in all', 1, FFactory.ProtocolDials);
  AssertEquals('one HTTP/2 connection in all', 1, FFactory.H2Dials);
  AssertEquals('no HTTP/1.1 dial', 0, FFactory.Http1Dials);
  AssertTrue('two extended CONNECTs on the pooled connection',
    HeadersSent(0) >= 2);
end;

procedure TWsProtocolModeTest.TestAutoWithPooledH2WithoutSettingUsesHttp1;
begin
  // the pooled connection has no setting: wpmAuto takes the HTTP/1.1 opening
  Build('h2', False, '200', ctReject);
  AssertEquals('wpmHttp2 is refused', 'websocket', Attempt(cWssUrl, wpmHttp2));
  AssertEquals('handshake answer', 'handshake:101', Attempt(cWssUrl, wpmAuto));
  AssertEquals('one HTTP/2 dial in all', 1, FFactory.ProtocolDials);
  AssertEquals('one HTTP/2 connection in all', 1, FFactory.H2Dials);
  AssertEquals('one HTTP/1.1 dial', 1, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestRefusedConnectDoesNotFallBack;
begin
  Build('h2', True, '404', ctReject);
  AssertEquals('the refusal is a handshake failure', 'handshake:404',
    Attempt(cWssUrl, wpmHttp2));
  AssertEquals('the pooled connection answers the same way', 'handshake:404',
    Attempt(cWssUrl, wpmAuto));
  AssertEquals('no HTTP/1.1 dial after a refusal', 0, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestCleartextWithoutPriorKnowledgeUsesHttp1;
begin
  Build('', True, '200', ctReject);
  AssertEquals('handshake answer', 'handshake:101', Attempt(cWsUrl, wpmAuto));
  AssertEquals('no HTTP/2 dial for ws', 0, FFactory.ProtocolDials);
  AssertEquals('one HTTP/1.1 dial', 1, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestCleartextWithPriorKnowledgeNoPoolUsesHttp1;
begin
  // prior knowledge alone does not dial for wpmAuto: no pooled connection, HTTP/1.1
  Build('', True, '200', ctPriorKnowledge);
  AssertEquals('handshake answer', 'handshake:101', Attempt(cWsUrl, wpmAuto));
  AssertEquals('no HTTP/2 dial', 0, FFactory.ProtocolDials);
  AssertEquals('one HTTP/1.1 dial', 1, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestCleartextPooledWithPriorKnowledgeIsReused;
begin
  Build('', True, '200', ctPriorKnowledge);
  AssertEquals('the wpmHttp2 socket opened', '', Attempt(cWsUrl, wpmHttp2));
  FOther := FSocket;
  FSocket := nil;
  AssertEquals('the wpmAuto socket opened', '', Attempt(cWsUrl, wpmAuto));
  AssertTrue('a socket is returned', FSocket <> nil);
  AssertEquals('one HTTP/2 dial in all', 1, FFactory.ProtocolDials);
  AssertTrue('the protocol is HTTP/2 cleartext',
    FFactory.LastProtocol = npHttp2Cleartext);
  AssertEquals('no HTTP/1.1 dial', 0, FFactory.Http1Dials);
end;

procedure TWsProtocolModeTest.TestHttp2ModeCleartextNeedsPriorKnowledge;
begin
  Build('', True, '200', ctReject);
  AssertEquals('EHttpWebSocketError', 'websocket', Attempt(cWsUrl, wpmHttp2));
  AssertEquals('no dial was made', 0, FFactory.ProtocolDials);
end;

initialization
  RegisterTest(TWsProtocolModeTest);
end.
