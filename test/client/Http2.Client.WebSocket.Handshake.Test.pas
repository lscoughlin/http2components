{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
unit Http2.Client.WebSocket.Handshake.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Client.Errors, Http2.Client.WebSocket;

type
  TWsHandshakeTest = class(TTestCase)
  private
    function Fields(const A: array of string): TArray<TWsHeaderField>;
    function Ok(const AStatus: Integer; const AExtra: array of string;
      const AOffered: TArray<string>; out AChosen: string): string;
  published
    procedure TestRfcAcceptVector;
    procedure TestKeyIs16OctetsBase64;
    procedure TestUrlForms;
    procedure TestUrlErrors;
    procedure TestRequestBytes;
    procedure TestRequestBytesIpv6AndSubprotocols;
    procedure TestAcceptMatrix;
    procedure TestSubprotocolMatrix;
    procedure TestRestrictedHeadersRejectedAtWithHeader;
  end;

  TWsRequestTest = class(TTestCase)
  published
    procedure TestWithXReturnsNewValues;
    procedure TestRequiresListener;
    procedure TestArgumentChecks;
    procedure TestUnitDependsOnRtlOnly;
  end;

implementation

function FixedKey: TWsMaskKey;
begin
  Result[0] := $37; Result[1] := $fa; Result[2] := $21; Result[3] := $3d;
end;

{ TWsFrameTest }

function TWsHandshakeTest.Fields(const A: array of string): TArray<TWsHeaderField>;
var
  I: Integer;
begin
  SetLength(Result, Length(A) div 2);
  for I := 0 to High(Result) do
  begin
    Result[I].Name := A[I * 2];
    Result[I].Value := A[I * 2 + 1];
  end;
end;

function TWsHandshakeTest.Ok(const AStatus: Integer;
  const AExtra: array of string; const AOffered: TArray<string>;
  out AChosen: string): string;
const
  Key = 'dGhlIHNhbXBsZSBub25jZQ==';
var
  F: TArray<TWsHeaderField>;
  Base: TArray<TWsHeaderField>;
  I: Integer;
begin
  Base := Fields(['Upgrade', 'websocket', 'Connection', 'Upgrade',
    'Sec-WebSocket-Accept', 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=']);
  F := Fields(AExtra);
  SetLength(Base, Length(Base) + Length(F));
  for I := 0 to High(F) do
    Base[Length(Base) - Length(F) + I] := F[I];
  Result := WsCheckResponse(AStatus, Base, Key, AOffered, AChosen);
end;

function FixedRandom: Cardinal;
begin
  Result := $01020304;
end;

procedure TWsHandshakeTest.TestRfcAcceptVector;
begin
  AssertEquals('s3pPLMBiTxaQ9kYGzzhZRbK+xOo=',
    WsComputeAccept('dGhlIHNhbXBsZSBub25jZQ=='));
end;

procedure TWsHandshakeTest.TestKeyIs16OctetsBase64;
var
  K: string;
begin
  K := WsNewKey(FixedRandom);
  AssertEquals('24 base64 characters', 24, Length(K));
  AssertEquals('padding', '==', Copy(K, 23, 2));
end;

procedure TWsHandshakeTest.TestUrlForms;
var
  Secure: Boolean;
  Host, Target, Auth: string;
  Port: Word;
begin
  WsParseUrl('ws://example.com', Secure, Host, Port, Target, Auth);
  AssertFalse(Secure); AssertEquals('example.com', Host);
  AssertEquals(80, Port); AssertEquals('/', Target); AssertEquals('example.com', Auth);
  WsParseUrl('wss://example.com:8443/chat?room=1', Secure, Host, Port, Target, Auth);
  AssertTrue(Secure); AssertEquals(8443, Port);
  AssertEquals('/chat?room=1', Target); AssertEquals('example.com:8443', Auth);
  WsParseUrl('wss://example.com:443/x', Secure, Host, Port, Target, Auth);
  AssertEquals('default port omitted', 'example.com', Auth);
  WsParseUrl('https://example.com?a=b', Secure, Host, Port, Target, Auth);
  AssertTrue(Secure); AssertEquals('/?a=b', Target);
  WsParseUrl('ws://[::1]:9000/x', Secure, Host, Port, Target, Auth);
  AssertEquals('::1', Host); AssertEquals(9000, Port);
  AssertEquals('[::1]:9000', Auth);
  WsParseUrl('ws://[2001:db8::1]/', Secure, Host, Port, Target, Auth);
  AssertEquals('[2001:db8::1]', Auth);
  WsParseUrl('ws://user:pw@host/p', Secure, Host, Port, Target, Auth);
  AssertEquals('userinfo dropped', 'host', Auth);
end;

procedure TWsHandshakeTest.TestUrlErrors;
  procedure Bad(const AUrl: string);
  var
    Secure: Boolean;
    Host, Target, Auth: string;
    Port: Word;
    Raised: Boolean;
  begin
    Raised := False;
    try
      WsParseUrl(AUrl, Secure, Host, Port, Target, Auth);
    except
      on EHttpWebSocketError do
        Raised := True;
    end;
    AssertTrue(AUrl, Raised);
  end;
begin
  Bad('ftp://host/');
  Bad('host/path');
  Bad('ws://');
  Bad('ws://host#frag');
  Bad('ws://host:0/');
  Bad('ws://host:99999/');
  Bad('ws://[::1/');
end;

procedure TWsHandshakeTest.TestRequestBytes;
var
  B: TBytes;
  S: string;
  H: TArray<TWsHeaderField>;
begin
  H := Fields(['Authorization', 'Bearer x']);
  B := WsBuildHandshake('/chat?x=1', 'example.com:8080',
    'dGhlIHNhbXBsZSBub25jZQ==', nil, H);
  SetString(S, PChar(@B[0]), Length(B));
  AssertEquals('GET /chat?x=1 HTTP/1.1'#13#10 +
    'Host: example.com:8080'#13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='#13#10 +
    'Sec-WebSocket-Version: 13'#13#10 +
    'Authorization: Bearer x'#13#10#13#10, S);
end;

procedure TWsHandshakeTest.TestRequestBytesIpv6AndSubprotocols;
var
  B: TBytes;
  S: string;
  P: TArray<string>;
begin
  SetLength(P, 2);
  P[0] := 'chat'; P[1] := 'superchat';
  B := WsBuildHandshake('/', '[::1]:9000', 'K', P, nil);
  SetString(S, PChar(@B[0]), Length(B));
  AssertTrue('host', Pos('Host: [::1]:9000'#13#10, S) > 0);
  AssertTrue('protocols', Pos('Sec-WebSocket-Protocol: chat, superchat'#13#10, S) > 0);
  AssertTrue('ends with blank line', Copy(S, Length(S) - 3, 4) = #13#10#13#10);
end;

procedure TWsHandshakeTest.TestAcceptMatrix;
var
  Chosen: string;
  Key: string;
begin
  Key := 'dGhlIHNhbXBsZSBub25jZQ==';
  AssertEquals('accepted', '', Ok(101, [], nil, Chosen));
  AssertTrue('200', Ok(200, [], nil, Chosen) <> '');
  AssertTrue('301', Ok(301, [], nil, Chosen) <> '');
  AssertTrue('401', Ok(401, [], nil, Chosen) <> '');
  AssertTrue('426', Ok(426, [], nil, Chosen) <> '');
  AssertEquals('Connection list', '',
    WsCheckResponse(101, Fields(['upgrade', 'WebSocket',
      'CONNECTION', 'keep-alive, Upgrade',
      'sec-websocket-accept', 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=']), Key, nil, Chosen));
  AssertTrue('Connection keep-alive only',
    WsCheckResponse(101, Fields(['Upgrade', 'websocket',
      'Connection', 'keep-alive',
      'Sec-WebSocket-Accept', 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=']), Key, nil, Chosen) <> '');
  AssertTrue('missing Upgrade',
    WsCheckResponse(101, Fields(['Connection', 'Upgrade',
      'Sec-WebSocket-Accept', 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=']), Key, nil, Chosen) <> '');
  AssertTrue('wrong accept',
    WsCheckResponse(101, Fields(['Upgrade', 'websocket', 'Connection', 'Upgrade',
      'Sec-WebSocket-Accept', 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=']), Key, nil, Chosen) <> '');
  AssertTrue('missing accept',
    WsCheckResponse(101, Fields(['Upgrade', 'websocket', 'Connection', 'Upgrade']),
      Key, nil, Chosen) <> '');
  AssertTrue('extension not offered', Ok(101,
    ['Sec-WebSocket-Extensions', 'permessage-deflate'], nil, Chosen) <> '');
end;

procedure TWsHandshakeTest.TestSubprotocolMatrix;
var
  Chosen: string;
  Offered: TArray<string>;
begin
  SetLength(Offered, 2);
  Offered[0] := 'chat'; Offered[1] := 'other';
  AssertEquals('listed', '', Ok(101, ['Sec-WebSocket-Protocol', 'chat'],
    Offered, Chosen));
  AssertEquals('chosen', 'chat', Chosen);
  AssertTrue('unlisted', Ok(101, ['Sec-WebSocket-Protocol', 'nope'],
    Offered, Chosen) <> '');
  AssertTrue('unsolicited', Ok(101, ['Sec-WebSocket-Protocol', 'chat'],
    nil, Chosen) <> '');
  AssertTrue('two in one line', Ok(101, ['Sec-WebSocket-Protocol', 'chat, other'],
    Offered, Chosen) <> '');
  AssertTrue('two lines', Ok(101, ['Sec-WebSocket-Protocol', 'chat',
    'Sec-WebSocket-Protocol', 'other'], Offered, Chosen) <> '');
  AssertEquals('none selected', '', Ok(101, [], Offered, Chosen));
  AssertEquals('', Chosen);
end;

procedure TWsHandshakeTest.TestRestrictedHeadersRejectedAtWithHeader;
var
  R: IWebSocketRequest;
  Names: array[0..8] of string;
  I: Integer;
  Raised: Boolean;
begin
  R := TWebSocketRequest.Create('ws://h/', TWebSocketListener.Create);
  Names[0] := 'Host'; Names[1] := 'Upgrade'; Names[2] := 'connection';
  Names[3] := 'Content-Length'; Names[4] := 'Sec-WebSocket-Key';
  Names[5] := 'sec-websocket-version'; Names[6] := 'Sec-WebSocket-Protocol';
  Names[7] := 'Sec-WebSocket-Extensions'; Names[8] := 'Sec-WebSocket-Accept';
  for I := 0 to High(Names) do
  begin
    Raised := False;
    try
      R.WithHeader(Names[I], 'x');
    except
      on EHttpWebSocketError do
        Raised := True;
    end;
    AssertTrue(Names[I], Raised);
  end;
  AssertEquals('other headers pass', 1,
    Length(R.WithHeader('Origin', 'http://h').Headers));
end;

{ TWsRequestTest }

procedure TWsRequestTest.TestWithXReturnsNewValues;
var
  A, B: IWebSocketRequest;
  Names: TArray<string>;
begin
  A := TWebSocketRequest.Create('ws://h/p', TWebSocketListener.Create);
  AssertEquals(5000, A.CloseTimeoutMs);
  AssertEquals(0, A.ConnectTimeoutMs);
  AssertEquals(cWsDefaultMaxMessageBytes, A.MaxMessageBytes);
  AssertFalse(A.AutoRequest);
  B := A.WithConnectTimeoutMs(250).WithSubprotocol('chat')
    .WithHeader('X-A', '1').WithAutoRequest.WithPingIntervalMs(900)
    .WithCloseTimeoutMs(10).WithMaxMessageBytes(77);
  AssertEquals('original unchanged', 0, A.ConnectTimeoutMs);
  AssertEquals(0, Length(A.Subprotocols));
  AssertEquals(0, Length(A.Headers));
  AssertEquals(250, B.ConnectTimeoutMs);
  AssertEquals('chat', B.Subprotocols[0]);
  AssertEquals('X-A', B.Headers[0].Name);
  AssertTrue(B.AutoRequest);
  AssertEquals(900, B.PingIntervalMs);
  AssertEquals(10, B.CloseTimeoutMs);
  AssertEquals(77, B.MaxMessageBytes);
  AssertEquals('ws://h/p', B.Url);
  Names := nil;
  SetLength(Names, 2);
  Names[0] := 'a'; Names[1] := 'b';
  AssertEquals(3, Length(B.WithSubprotocols(Names).Subprotocols));
end;

procedure TWsRequestTest.TestRequiresListener;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    TWebSocketRequest.Create('ws://h/', nil);
  except
    on EHttpWebSocketError do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

procedure TWsRequestTest.TestArgumentChecks;
var
  R: IWebSocketRequest;
  function Raises(const AWhat: Integer): Boolean;
  begin
    Result := False;
    try
      case AWhat of
        0: R.WithConnectTimeoutMs(-1);
        1: R.WithSubprotocol('has space');
        2: R.WithSubprotocol('');
        3: R.WithSubprotocol('a,b');
        4: R.WithHeader('bad name', 'v');
        5: R.WithHeader('X', 'a'#13#10'b');
        6: R.WithMaxMessageBytes(-1);
        7: R.WithPingIntervalMs(-1);
        8: TWebSocketRequest.Create('ftp://h/', TWebSocketListener.Create);
      end;
    except
      on EHttpWebSocketError do
        Result := True;
    end;
  end;
var
  I: Integer;
begin
  R := TWebSocketRequest.Create('ws://h/', TWebSocketListener.Create);
  for I := 0 to 8 do
    AssertTrue('case ' + IntToStr(I), Raises(I));
end;

procedure TWsRequestTest.TestUnitDependsOnRtlOnly;
var
  L: TStringList;
  I: Integer;
  S, Uses_: string;
  InUses: Boolean;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile('src/client/Http2.Client.WebSocket.Protocol.pas');
    InUses := False;
    Uses_ := '';
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if (not InUses) and (LowerCase(S) = 'uses') then
      begin
        InUses := True;
        Continue;
      end;
      if InUses then
      begin
        Uses_ := Uses_ + ' ' + S;
        if Pos(';', S) > 0 then
          Break;
      end;
    end;
    // Http2.Client.IdentityHandle is the TLS-free marker a request carries for a
    // client identity; it depends on nothing
    AssertTrue('RTL, Errors and the identity handle only: ' + Uses_,
      Pos('Http2.Client.', StringReplace(StringReplace(Uses_, 'Http2.Client.Errors', '', []),
        'Http2.Client.IdentityHandle', '', [])) = 0);
    AssertTrue('does not call Random', Pos('Random(', L.Text) = 0);
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TWsHandshakeTest);
  RegisterTest(TWsRequestTest);
end.
