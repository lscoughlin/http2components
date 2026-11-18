{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - Imported from http2client source revision 709336f542cbedf9ce1ab67d83bddcfd560eb1c0.
  - Unit references use the common and client namespaces.
---
}
/// WebSocket (RFC 6455) protocol pieces with no I/O: the frame codec, message
/// assembly with incremental UTF-8 validation, the opening handshake, and the
/// public interfaces (doc/design/websocket.md).
// - depends on the RTL and Http2.Client.Errors only, like Http2.Client.Proxy
unit Http2.Client.WebSocket;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, sha1, base64, Http2.Client.Errors, Http2.Client.IdentityHandle,
  Http2.Common.Headers, Http2.Common.Status,
  Http2.Client.WebSocket.Protocol;

const
  /// frame opcodes (RFC 6455 section 5.2)
  cWsOpContinuation = Http2.Client.WebSocket.Protocol.cWsOpContinuation;
  cWsOpText         = Http2.Client.WebSocket.Protocol.cWsOpText;
  cWsOpBinary       = Http2.Client.WebSocket.Protocol.cWsOpBinary;
  cWsOpClose        = Http2.Client.WebSocket.Protocol.cWsOpClose;
  cWsOpPing         = Http2.Client.WebSocket.Protocol.cWsOpPing;
  cWsOpPong         = Http2.Client.WebSocket.Protocol.cWsOpPong;

  /// close status codes the client sends or reports
  cWsCloseNormal        = Http2.Client.WebSocket.Protocol.cWsCloseNormal;
  cWsCloseGoingAway     = Http2.Client.WebSocket.Protocol.cWsCloseGoingAway;
  cWsCloseProtocolError = Http2.Client.WebSocket.Protocol.cWsCloseProtocolError;
  cWsCloseUnsupported   = Http2.Client.WebSocket.Protocol.cWsCloseUnsupported;
  cWsCloseNoStatus      = Http2.Client.WebSocket.Protocol.cWsCloseNoStatus;   // never on the wire
  cWsCloseAbnormal      = Http2.Client.WebSocket.Protocol.cWsCloseAbnormal;   // never on the wire
  cWsCloseBadData       = Http2.Client.WebSocket.Protocol.cWsCloseBadData;
  cWsCloseTooBig        = Http2.Client.WebSocket.Protocol.cWsCloseTooBig;

  cWsGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
  cWsMaxControlPayload = Http2.Client.WebSocket.Protocol.cWsMaxControlPayload;
  /// a frame header declaring more than this is refused before allocation
  cWsMaxFrameBytes = Http2.Client.WebSocket.Protocol.cWsMaxFrameBytes;
  cWsDefaultMaxMessageBytes = Http2.Client.WebSocket.Protocol.cWsDefaultMaxMessageBytes;
  cWsDefaultCloseTimeoutMs = Http2.Client.WebSocket.Protocol.cWsDefaultCloseTimeoutMs;

type
  TWsMaskKey = Http2.Client.WebSocket.Protocol.TWsMaskKey;
  TMaskKeySource = Http2.Client.WebSocket.Protocol.TMaskKeySource;
  TWsFrame = Http2.Client.WebSocket.Protocol.TWsFrame;
  TWsHeaderField = record
    Name: string;
    Value: string;
  end;
  TWsDataKind = Http2.Client.WebSocket.Protocol.TWsDataKind;
  TWebSocketFrameParser = Http2.Client.WebSocket.Protocol.TWebSocketFrameParser;
  TWebSocketMessageAssembler = Http2.Client.WebSocket.Protocol.TWebSocketMessageAssembler;

const
  wkText = Http2.Client.WebSocket.Protocol.wkText;
  wkBinary = Http2.Client.WebSocket.Protocol.wkBinary;

procedure WsApplyMask(const AKey: TWsMaskKey; var ABuffer; const ACount: Integer;
  const APhase: Integer = 0);
function WsMaskKeyFromCardinal(const AValue: Cardinal): TWsMaskKey;
function WsEncodeFrame(const AOpcode: Byte; const AFin: Boolean;
  const APayload: TBytes; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;
function WsUtf8Check(const ABuffer: PByte; const ACount: Integer;
  out ASafeLen: Integer): Boolean;
function WsIsWireCloseCode(const ACode: Integer): Boolean;
procedure WsParseClosePayload(const APayload: TBytes; out ACode: Integer;
  out AReason: string);
function WsBuildClosePayload(const ACode: Integer;
  const AReason: string): TBytes;

{ handshake }

/// split a ws/wss (or http/https) URL.  ATarget is path and query ('/' when
/// empty); AAuthority is the Host header value.  Raises EHttpWebSocketError.
procedure WsParseUrl(const AUrl: string; out ASecure: Boolean;
  out AHost: string; out APort: Word; out ATarget, AAuthority: string);

function WsIsHttpToken(const AValue: string): Boolean;
function WsIsRestrictedHeader(const AName: string): Boolean;

function WsComputeAccept(const AKey: string): string;
/// base64 of 16 random octets
function WsNewKey(const ASource: TMaskKeySource): string;

function WsBuildHandshake(const ATarget, AAuthority, AKey: string;
  const ASubprotocols: TArray<string>;
  const AHeaders: TArray<TWsHeaderField>): TBytes;

/// check a handshake response.  Returns '' when it is acceptable (AChosen is
/// the selected subprotocol or ''), else the reason it is not.
function WsCheckResponse(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const AKey: string;
  const AOffered: TArray<string>; out AChosen: string): string;

{ public interfaces }

type
  IWebSocket = interface;

  /// receives what the server sends.  Every callback runs on the WebSocket's
  /// reader thread, one at a time, in wire order.
  IWebSocketListener = interface
    ['{5E0A7C11-3B2D-4F6A-9C41-8D7E1B2A0001}']
    procedure OnOpen(const ASocket: IWebSocket);
    /// a text fragment (the whole message when ALast and it is the first)
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean);
    procedure OnBytes(const ASocket: IWebSocket; const AData: TBytes;
      const ALast: Boolean);
    procedure OnPing(const ASocket: IWebSocket; const AData: TBytes);
    procedure OnPong(const ASocket: IWebSocket; const AData: TBytes);
    /// the server's close frame arrived (once)
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string);
    /// the connection failed after the handshake; AError is freed on return
    procedure OnError(const ASocket: IWebSocket; const AError: Exception);
  end;

  IWebSocket = interface
    ['{5E0A7C11-3B2D-4F6A-9C41-8D7E1B2A0002}']
    /// close the connection at once, without a close frame
    procedure Abort;
    /// allow AN more notifications to be delivered
    procedure Request(const AN: Integer);
    procedure SendPing(const AData: TBytes);
    procedure SendPong(const AData: TBytes);
    procedure SendBinary(const AData: TBytes; const ALast: Boolean = True);
    procedure SendText(const AText: string; const ALast: Boolean = True);
    /// begin the closing handshake
    procedure Close(const AStatusCode: Integer = cWsCloseNormal;
      const AReason: string = '');
    function GetInputClosed: Boolean;
    function GetOutputClosed: Boolean;
    function GetSubprotocol: string;
    function GetUrl: string;
    property InputClosed: Boolean read GetInputClosed;
    property OutputClosed: Boolean read GetOutputClosed;
    property Subprotocol: string read GetSubprotocol;
    property Url: string read GetUrl;
  end;

  /// an immutable request to open a WebSocket; every WithX returns a new one
  IWebSocketRequest = interface
    ['{5E0A7C11-3B2D-4F6A-9C41-8D7E1B2A0003}']
    function WithConnectTimeoutMs(const AMs: Integer): IWebSocketRequest;
    /// raises EHttpWebSocketError for a header the handshake owns
    function WithHeader(const AName, AValue: string): IWebSocketRequest;
    function WithSubprotocol(const AName: string): IWebSocketRequest;
    function WithSubprotocols(const ANames: TArray<string>): IWebSocketRequest;
    function WithCloseTimeoutMs(const AMs: Integer): IWebSocketRequest;
    function WithMaxMessageBytes(const ABytes: Int64): IWebSocketRequest;
    function WithPingIntervalMs(const AMs: Integer): IWebSocketRequest;
    /// request one more notification after each delivery
    function WithAutoRequest(const AEnable: Boolean = True): IWebSocketRequest;
    /// attach an opaque object that the request observer receives as
    /// THttpAttempt.Context (a parent span, a tenant); nil clears it
    function WithContext(const AContext: IInterface): IWebSocketRequest;
    /// present AIdentity to the origin on the wss connection, ahead of the
    /// client's selector and fixed identity (doc/design/mtls.md "Per-request
    /// identity"); never to a proxy.  Send raises EHttpTlsConfigError before
    /// dialling when it has expired.  nil clears it; ws ignores it
    function WithClientIdentity(const AIdentity: IClientIdentityHandle): IWebSocketRequest;
    function GetClientIdentity: IClientIdentityHandle;
    function GetUrl: string;
    function GetListener: IWebSocketListener;
    function GetHeaders: TArray<TWsHeaderField>;
    function GetSubprotocols: TArray<string>;
    function GetConnectTimeoutMs: Integer;
    function GetCloseTimeoutMs: Integer;
    function GetMaxMessageBytes: Int64;
    function GetPingIntervalMs: Integer;
    function GetAutoRequest: Boolean;
    function GetContext: IInterface;
    property ClientIdentity: IClientIdentityHandle read GetClientIdentity;
    property Url: string read GetUrl;
    property Listener: IWebSocketListener read GetListener;
    property Headers: TArray<TWsHeaderField> read GetHeaders;
    property Subprotocols: TArray<string> read GetSubprotocols;
    property ConnectTimeoutMs: Integer read GetConnectTimeoutMs;
    property CloseTimeoutMs: Integer read GetCloseTimeoutMs;
    property MaxMessageBytes: Int64 read GetMaxMessageBytes;
    property PingIntervalMs: Integer read GetPingIntervalMs;
    property AutoRequest: Boolean read GetAutoRequest;
    property Context: IInterface read GetContext;
  end;

  /// base class with empty callbacks; descend and override what is needed
  TWebSocketListener = class(TInterfacedObject, IWebSocketListener)
  public
    procedure OnOpen(const ASocket: IWebSocket); virtual;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); virtual;
    procedure OnBytes(const ASocket: IWebSocket; const AData: TBytes;
      const ALast: Boolean); virtual;
    procedure OnPing(const ASocket: IWebSocket; const AData: TBytes); virtual;
    procedure OnPong(const ASocket: IWebSocket; const AData: TBytes); virtual;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); virtual;
    procedure OnError(const ASocket: IWebSocket;
      const AError: Exception); virtual;
  end;

  TWebSocketRequest = class(TInterfacedObject, IWebSocketRequest)
  private
    FUrl: string;
    FListener: IWebSocketListener;
    FHeaders: TArray<TWsHeaderField>;
    FSubprotocols: TArray<string>;
    FConnectTimeoutMs: Integer;
    FCloseTimeoutMs: Integer;
    FMaxMessageBytes: Int64;
    FPingIntervalMs: Integer;
    FAutoRequest: Boolean;
    FContext: IInterface;
    FIdentity: IClientIdentityHandle;
    function Clone: TWebSocketRequest;
  public
    /// AUrl is ws, wss, http or https; AListener is required
    constructor Create(const AUrl: string; const AListener: IWebSocketListener);
    function WithConnectTimeoutMs(const AMs: Integer): IWebSocketRequest;
    function WithHeader(const AName, AValue: string): IWebSocketRequest;
    function WithSubprotocol(const AName: string): IWebSocketRequest;
    function WithSubprotocols(const ANames: TArray<string>): IWebSocketRequest;
    function WithCloseTimeoutMs(const AMs: Integer): IWebSocketRequest;
    function WithMaxMessageBytes(const ABytes: Int64): IWebSocketRequest;
    function WithPingIntervalMs(const AMs: Integer): IWebSocketRequest;
    function WithAutoRequest(const AEnable: Boolean = True): IWebSocketRequest;
    function WithContext(const AContext: IInterface): IWebSocketRequest;
    /// present AIdentity to the origin on the wss connection, ahead of the
    /// client's selector and fixed identity (doc/design/mtls.md "Per-request
    /// identity"); never to a proxy.  Send raises EHttpTlsConfigError before
    /// dialling when it has expired.  nil clears it; ws ignores it
    function WithClientIdentity(const AIdentity: IClientIdentityHandle): IWebSocketRequest;
    function GetClientIdentity: IClientIdentityHandle;
    function GetUrl: string;
    function GetListener: IWebSocketListener;
    function GetHeaders: TArray<TWsHeaderField>;
    function GetSubprotocols: TArray<string>;
    function GetConnectTimeoutMs: Integer;
    function GetCloseTimeoutMs: Integer;
    function GetMaxMessageBytes: Int64;
    function GetPingIntervalMs: Integer;
    function GetAutoRequest: Boolean;
    function GetContext: IInterface;
  end;

implementation

procedure WsApplyMask(const AKey: TWsMaskKey; var ABuffer;
  const ACount: Integer; const APhase: Integer);
begin
  Http2.Client.WebSocket.Protocol.WsApplyMask(AKey, ABuffer, ACount, APhase);
end;

function WsMaskKeyFromCardinal(const AValue: Cardinal): TWsMaskKey;
begin
  Result := Http2.Client.WebSocket.Protocol.WsMaskKeyFromCardinal(AValue);
end;

function WsEncodeFrame(const AOpcode: Byte; const AFin: Boolean;
  const APayload: TBytes; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;
begin
  Result := Http2.Client.WebSocket.Protocol.WsEncodeFrame(AOpcode, AFin,
    APayload, AMasked, AKey);
end;

function WsUtf8Check(const ABuffer: PByte; const ACount: Integer;
  out ASafeLen: Integer): Boolean;
begin
  Result := Http2.Client.WebSocket.Protocol.WsUtf8Check(ABuffer, ACount,
    ASafeLen);
end;

function WsIsWireCloseCode(const ACode: Integer): Boolean;
begin
  Result := Http2.Client.WebSocket.Protocol.WsIsWireCloseCode(ACode);
end;

procedure WsParseClosePayload(const APayload: TBytes; out ACode: Integer;
  out AReason: string);
begin
  Http2.Client.WebSocket.Protocol.WsParseClosePayload(APayload, ACode,
    AReason);
end;

function WsBuildClosePayload(const ACode: Integer;
  const AReason: string): TBytes;
begin
  Result := Http2.Client.WebSocket.Protocol.WsBuildClosePayload(ACode,
    AReason);
end;

{ handshake }

function WsIsHttpToken(const AValue: string): Boolean;
const
  Separators = '()<>@,;:\"/[]?={} ' + #9;
var
  I: Integer;
begin
  Result := AValue <> '';
  for I := 1 to Length(AValue) do
    if (Ord(AValue[I]) <= 32) or (Ord(AValue[I]) >= 127) or
       (Pos(AValue[I], Separators) > 0) then
      Exit(False);
end;

function WsIsRestrictedHeader(const AName: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(AName));
  Result := (L = HeaderHost) or (L = HeaderUpgrade) or (L = HeaderConnection) or
    (L = HeaderContentLength) or (L = HeaderTransferEncoding) or (L = HeaderExpect) or
    (Copy(L, 1, 14) = 'sec-websocket-');
end;

procedure WsParseUrl(const AUrl: string; out ASecure: Boolean;
  out AHost: string; out APort: Word; out ATarget, AAuthority: string);
var
  Scheme, Rest, Auth, HostPart, PortPart: string;
  P, Q, PortNum: Integer;
begin
  P := Pos('://', AUrl);
  if P < 2 then
    raise EHttpWebSocketError.CreateFmt('not an absolute URL: %s', [AUrl]);
  Scheme := LowerCase(Copy(AUrl, 1, P - 1));
  if (Scheme = 'ws') or (Scheme = 'http') then
    ASecure := False
  else if (Scheme = 'wss') or (Scheme = 'https') then
    ASecure := True
  else
    raise EHttpWebSocketError.CreateFmt(
      'unsupported scheme "%s" (ws, wss, http or https expected)', [Scheme]);
  Rest := Copy(AUrl, P + 3, MaxInt);
  if Pos('#', Rest) > 0 then
    raise EHttpWebSocketError.Create('a WebSocket URL has no fragment');
  Q := 0;
  for P := 1 to Length(Rest) do
    if Rest[P] in ['/', '?'] then
    begin
      Q := P;
      Break;
    end;
  if Q = 0 then
  begin
    Auth := Rest;
    ATarget := '/';
  end
  else
  begin
    Auth := Copy(Rest, 1, Q - 1);
    ATarget := Copy(Rest, Q, MaxInt);
    if ATarget[1] = '?' then
      ATarget := '/' + ATarget;
  end;
  P := Pos('@', Auth);
  if P > 0 then
    Auth := Copy(Auth, P + 1, MaxInt);       // userinfo is not sent
  PortPart := '';
  if (Auth <> '') and (Auth[1] = '[') then
  begin
    Q := Pos(']', Auth);
    if Q = 0 then
      raise EHttpWebSocketError.CreateFmt('bad IPv6 literal in %s', [AUrl]);
    HostPart := Copy(Auth, 2, Q - 2);
    if Copy(Auth, Q + 1, 1) = ':' then
      PortPart := Copy(Auth, Q + 2, MaxInt)
    else if Q < Length(Auth) then
      raise EHttpWebSocketError.CreateFmt('bad authority in %s', [AUrl]);
  end
  else
  begin
    Q := Pos(':', Auth);
    if Q > 0 then
    begin
      HostPart := Copy(Auth, 1, Q - 1);
      PortPart := Copy(Auth, Q + 1, MaxInt);
    end
    else
      HostPart := Auth;
  end;
  if HostPart = '' then
    raise EHttpWebSocketError.CreateFmt('no host in %s', [AUrl]);
  if PortPart = '' then
  begin
    if ASecure then PortNum := 443 else PortNum := 80;
  end
  else
  begin
    PortNum := StrToIntDef(PortPart, -1);
    if (PortNum < 1) or (PortNum > 65535) then
      raise EHttpWebSocketError.CreateFmt('bad port in %s', [AUrl]);
  end;
  AHost := HostPart;
  APort := Word(PortNum);
  if Pos(':', HostPart) > 0 then
    AAuthority := '[' + HostPart + ']'
  else
    AAuthority := HostPart;
  if (PortPart <> '') and not ((ASecure and (PortNum = 443)) or
     ((not ASecure) and (PortNum = 80))) then
    AAuthority := AAuthority + ':' + IntToStr(PortNum);
end;

function WsComputeAccept(const AKey: string): string;
var
  D: TSHA1Digest;
  S: string;
begin
  D := SHA1String(AKey + cWsGuid);
  SetLength(S, SizeOf(D));
  Move(D[0], S[1], SizeOf(D));
  Result := EncodeStringBase64(S);
end;

function WsNewKey(const ASource: TMaskKeySource): string;
var
  Raw: string;
  V: Cardinal;
  I: Integer;
begin
  SetLength(Raw, 16);
  for I := 0 to 3 do
  begin
    V := ASource();
    Move(V, Raw[1 + I * 4], 4);
  end;
  Result := EncodeStringBase64(Raw);
end;

function WsBuildHandshake(const ATarget, AAuthority, AKey: string;
  const ASubprotocols: TArray<string>;
  const AHeaders: TArray<TWsHeaderField>): TBytes;
var
  S: string;
  I: Integer;
begin
  S := 'GET ' + ATarget + ' HTTP/1.1'#13#10 +
    'Host: ' + AAuthority + #13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Key: ' + AKey + #13#10 +
    'Sec-WebSocket-Version: 13'#13#10;
  if Length(ASubprotocols) > 0 then
  begin
    S := S + 'Sec-WebSocket-Protocol: ';
    for I := 0 to High(ASubprotocols) do
    begin
      if I > 0 then
        S := S + ', ';
      S := S + ASubprotocols[I];
    end;
    S := S + #13#10;
  end;
  for I := 0 to High(AHeaders) do
    S := S + AHeaders[I].Name + ': ' + AHeaders[I].Value + #13#10;
  S := S + #13#10;
  SetLength(Result, Length(S));
  if S <> '' then
    Move(S[1], Result[0], Length(S));
end;

function FieldValues(const AFields: TArray<TWsHeaderField>;
  const AName: string): TArray<string>;
var
  I, N: Integer;
begin
  N := 0;
  SetLength(Result, Length(AFields));
  for I := 0 to High(AFields) do
    if SameText(AFields[I].Name, AName) then
    begin
      Result[N] := AFields[I].Value;
      Inc(N);
    end;
  SetLength(Result, N);
end;

function HasToken(const AValues: TArray<string>; const AToken: string): Boolean;
var
  I, P: Integer;
  V, Item: string;
begin
  Result := False;
  for I := 0 to High(AValues) do
  begin
    V := AValues[I];
    while V <> '' do
    begin
      P := Pos(',', V);
      if P = 0 then
      begin
        Item := V;
        V := '';
      end
      else
      begin
        Item := Copy(V, 1, P - 1);
        V := Copy(V, P + 1, MaxInt);
      end;
      if SameText(Trim(Item), AToken) then
        Exit(True);
    end;
  end;
end;

function WsCheckResponse(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const AKey: string;
  const AOffered: TArray<string>; out AChosen: string): string;
var
  Accept, Protos: TArray<string>;
  Items: TArray<string>;
  V, Item: string;
  P, I, N: Integer;
  Found: Boolean;
begin
  AChosen := '';
  if AStatus <> HttpStatusSwitchingProtocols then
    Exit(Format('server answered %d instead of 101', [AStatus]));
  if not HasToken(FieldValues(AFields, 'Upgrade'), 'websocket') then
    Exit('response has no "Upgrade: websocket"');
  if not HasToken(FieldValues(AFields, 'Connection'), 'upgrade') then
    Exit('response has no "Connection: Upgrade"');
  Accept := FieldValues(AFields, 'Sec-WebSocket-Accept');
  if (Length(Accept) <> 1) or (Trim(Accept[0]) <> WsComputeAccept(AKey)) then
    Exit('Sec-WebSocket-Accept does not match the key');
  if Length(FieldValues(AFields, 'Sec-WebSocket-Extensions')) > 0 then
    Exit('server selected an extension that was not offered');
  Protos := FieldValues(AFields, 'Sec-WebSocket-Protocol');
  if Length(Protos) = 0 then
    Exit('');
  // every value of every header line is one list item
  SetLength(Items, 0);
  for I := 0 to High(Protos) do
  begin
    V := Protos[I];
    while True do
    begin
      P := Pos(',', V);
      if P = 0 then
        Item := V
      else
        Item := Copy(V, 1, P - 1);
      N := Length(Items);
      SetLength(Items, N + 1);
      Items[N] := Trim(Item);
      if P = 0 then
        Break;
      V := Copy(V, P + 1, MaxInt);
    end;
  end;
  if Length(Items) <> 1 then
    Exit('server selected more than one subprotocol');
  Found := False;
  for I := 0 to High(AOffered) do
    if AOffered[I] = Items[0] then
      Found := True;
  if not Found then
    Exit(Format('server selected subprotocol "%s" that was not offered',
      [Items[0]]));
  AChosen := Items[0];
  Result := '';
end;

{ TWebSocketListener }

procedure TWebSocketListener.OnOpen(const ASocket: IWebSocket);
begin
end;

procedure TWebSocketListener.OnText(const ASocket: IWebSocket;
  const AText: string; const ALast: Boolean);
begin
end;

procedure TWebSocketListener.OnBytes(const ASocket: IWebSocket;
  const AData: TBytes; const ALast: Boolean);
begin
end;

procedure TWebSocketListener.OnPing(const ASocket: IWebSocket;
  const AData: TBytes);
begin
end;

procedure TWebSocketListener.OnPong(const ASocket: IWebSocket;
  const AData: TBytes);
begin
end;

procedure TWebSocketListener.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
end;

procedure TWebSocketListener.OnError(const ASocket: IWebSocket;
  const AError: Exception);
begin
end;

{ TWebSocketRequest }

constructor TWebSocketRequest.Create(const AUrl: string;
  const AListener: IWebSocketListener);
var
  Secure: Boolean;
  Host, Target, Auth: string;
  Port: Word;
begin
  inherited Create;
  if AListener = nil then
    raise EHttpWebSocketError.Create('a WebSocket request needs a listener');
  WsParseUrl(AUrl, Secure, Host, Port, Target, Auth);   // validates
  FUrl := AUrl;
  FListener := AListener;
  FCloseTimeoutMs := cWsDefaultCloseTimeoutMs;
  FMaxMessageBytes := cWsDefaultMaxMessageBytes;
end;

function TWebSocketRequest.Clone: TWebSocketRequest;
begin
  Result := TWebSocketRequest.Create(FUrl, FListener);
  Result.FHeaders := Copy(FHeaders);
  Result.FSubprotocols := Copy(FSubprotocols);
  Result.FConnectTimeoutMs := FConnectTimeoutMs;
  Result.FCloseTimeoutMs := FCloseTimeoutMs;
  Result.FMaxMessageBytes := FMaxMessageBytes;
  Result.FPingIntervalMs := FPingIntervalMs;
  Result.FAutoRequest := FAutoRequest;
  Result.FContext := FContext;
  Result.FIdentity := FIdentity;
end;

function TWebSocketRequest.WithConnectTimeoutMs(
  const AMs: Integer): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  if AMs < 0 then
    raise EHttpWebSocketError.Create('connect timeout cannot be negative');
  R := Clone;
  R.FConnectTimeoutMs := AMs;
  Result := R;
end;

function TWebSocketRequest.WithHeader(const AName,
  AValue: string): IWebSocketRequest;
var
  R: TWebSocketRequest;
  N: Integer;
begin
  if not WsIsHttpToken(AName) then
    raise EHttpWebSocketError.CreateFmt('"%s" is not a header name', [AName]);
  if WsIsRestrictedHeader(AName) then
    raise EHttpWebSocketError.CreateFmt(
      'header "%s" is set by the handshake and cannot be supplied', [AName]);
  if (Pos(#13, AValue) > 0) or (Pos(#10, AValue) > 0) then
    raise EHttpWebSocketError.Create('a header value cannot contain a line break');
  R := Clone;
  N := Length(R.FHeaders);
  SetLength(R.FHeaders, N + 1);
  R.FHeaders[N].Name := AName;
  R.FHeaders[N].Value := AValue;
  Result := R;
end;

function TWebSocketRequest.WithSubprotocol(
  const AName: string): IWebSocketRequest;
var
  R: TWebSocketRequest;
  N: Integer;
begin
  if not WsIsHttpToken(AName) then
    raise EHttpWebSocketError.CreateFmt(
      '"%s" is not a valid subprotocol name', [AName]);
  R := Clone;
  N := Length(R.FSubprotocols);
  SetLength(R.FSubprotocols, N + 1);
  R.FSubprotocols[N] := AName;
  Result := R;
end;

function TWebSocketRequest.WithSubprotocols(
  const ANames: TArray<string>): IWebSocketRequest;
var
  I: Integer;
begin
  Result := Self;
  for I := 0 to High(ANames) do
    Result := Result.WithSubprotocol(ANames[I]);
end;

function TWebSocketRequest.WithCloseTimeoutMs(
  const AMs: Integer): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  if AMs < 0 then
    raise EHttpWebSocketError.Create('close timeout cannot be negative');
  R := Clone;
  R.FCloseTimeoutMs := AMs;
  Result := R;
end;

function TWebSocketRequest.WithMaxMessageBytes(
  const ABytes: Int64): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  if ABytes < 0 then
    raise EHttpWebSocketError.Create('message limit cannot be negative');
  R := Clone;
  R.FMaxMessageBytes := ABytes;
  Result := R;
end;

function TWebSocketRequest.WithPingIntervalMs(
  const AMs: Integer): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  if AMs < 0 then
    raise EHttpWebSocketError.Create('ping interval cannot be negative');
  R := Clone;
  R.FPingIntervalMs := AMs;
  Result := R;
end;

function TWebSocketRequest.WithAutoRequest(
  const AEnable: Boolean): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  R := Clone;
  R.FAutoRequest := AEnable;
  Result := R;
end;

function TWebSocketRequest.WithContext(
  const AContext: IInterface): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  R := Clone;
  R.FContext := AContext;
  Result := R;
end;

function TWebSocketRequest.WithClientIdentity(
  const AIdentity: IClientIdentityHandle): IWebSocketRequest;
var
  R: TWebSocketRequest;
begin
  R := Clone;
  R.FIdentity := AIdentity;
  Result := R;
end;

function TWebSocketRequest.GetClientIdentity: IClientIdentityHandle;
begin
  Result := FIdentity;
end;

function TWebSocketRequest.GetUrl: string;
begin
  Result := FUrl;
end;

function TWebSocketRequest.GetListener: IWebSocketListener;
begin
  Result := FListener;
end;

function TWebSocketRequest.GetHeaders: TArray<TWsHeaderField>;
begin
  Result := Copy(FHeaders);
end;

function TWebSocketRequest.GetSubprotocols: TArray<string>;
begin
  Result := Copy(FSubprotocols);
end;

function TWebSocketRequest.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

function TWebSocketRequest.GetCloseTimeoutMs: Integer;
begin
  Result := FCloseTimeoutMs;
end;

function TWebSocketRequest.GetMaxMessageBytes: Int64;
begin
  Result := FMaxMessageBytes;
end;

function TWebSocketRequest.GetPingIntervalMs: Integer;
begin
  Result := FPingIntervalMs;
end;

function TWebSocketRequest.GetAutoRequest: Boolean;
begin
  Result := FAutoRequest;
end;

function TWebSocketRequest.GetContext: IInterface;
begin
  Result := FContext;
end;

end.
