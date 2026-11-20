{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this tests the request fields and the answer rule of a WebSocket over HTTP/2 (RFC 8441 section 5)
---
}
unit Http2.Client.WebSocket.H2Handshake.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client.Errors, Http2.Common.Headers,
  Http2.Common.Status, Http2.Client.Stream.Types, Http2.Client.WebSocket,
  Http2.Client.WebSocket.H2Handshake;

type
  TWsH2RequestTest = class(TTestCase)
  private
    function BuildWith(const ASecure: Boolean; const AProtos: TArray<string>;
      const APairs: array of string): TStreamRequest;
    function BuildRaises(const AName, AValue: string): Boolean;
    function HasName(const ARequest: TStreamRequest; const AName: string): Boolean;
  published
    procedure TestWssRequestFields;
    procedure TestWsRequestUsesHttp;
    procedure TestPollAndResponseLimitSettings;
    procedure TestNoForbiddenFieldIsPresent;
    procedure TestSubprotocolListIsJoined;
    procedure TestNoSubprotocolFieldWhenListIsEmpty;
    procedure TestCallerHeaderNameIsLowerCase;
    procedure TestRestrictedCallerHeadersRaise;
    procedure TestAcceptEncodingRaises;
    procedure TestPseudoHeaderNameRaises;
    procedure TestLineBreakInValueRaises;
    procedure TestInvalidSubprotocolRaises;
  end;

  TWsH2ResponseTest = class(TTestCase)
  private
    function Check(const AStatus: Integer; const AExtra: array of string;
      const AOffered: TArray<string>; out AChosen: string): string;
  published
    procedure TestOkWithoutSubprotocol;
    procedure TestOfferedSubprotocolIsChosen;
    procedure TestNotOfferedSubprotocolGivesReason;
    procedure TestNoOfferGivesReasonForAnySubprotocol;
    procedure TestTwoSubprotocolsGiveReason;
    procedure TestExtensionsGiveReason;
    procedure TestContentLengthGivesReason;
    procedure TestStatusOtherThan200GivesReason;
    procedure TestAcceptFieldIsIgnored;
  end;

implementation

/// build a field list from name and value pairs
function PairsToFields(const A: array of string): TArray<TWsHeaderField>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A) div 2);
  for I := 0 to High(Result) do
  begin
    Result[I].Name := A[I * 2];
    Result[I].Value := A[I * 2 + 1];
  end;
end;

{ TWsH2RequestTest }

function TWsH2RequestTest.BuildWith(const ASecure: Boolean;
  const AProtos: TArray<string>; const APairs: array of string): TStreamRequest;
begin
  Result := WsBuildH2Request(ASecure, '/chat?room=1', 'example.com:8443',
    AProtos, PairsToFields(APairs));
end;

function TWsH2RequestTest.BuildRaises(const AName, AValue: string): Boolean;
var
  Fields: TArray<TWsHeaderField>;
  Req: TStreamRequest;
begin
  SetLength(Fields, 1);
  Fields[0].Name := AName;
  Fields[0].Value := AValue;
  Result := False;
  try
    Req := WsBuildH2Request(True, '/', 'example.com', nil, Fields);
  except
    on EHttpWebSocketError do
      Result := True;
  end;
end;

function TWsH2RequestTest.HasName(const ARequest: TStreamRequest;
  const AName: string): Boolean;
var
  Names: TArray<string>;
  I: Integer;
begin
  Result := False;
  Names := ARequest.Headers.Names;
  for I := 0 to High(Names) do
    if Names[I] = AName then
      Exit(True);
end;

procedure TWsH2RequestTest.TestWssRequestFields;
var
  Req: TStreamRequest;
begin
  Req := BuildWith(True, nil, []);
  AssertEquals('method', 'CONNECT', Req.Method);
  AssertEquals('protocol', 'websocket', Req.Protocol);
  AssertEquals('scheme', 'https', Req.Scheme);
  AssertEquals('path', '/chat?room=1', Req.Path);
  AssertEquals('authority', 'example.com:8443', Req.Authority);
  AssertTrue('keep open', Req.KeepOpen);
  AssertEquals('version', '13', Req.Headers.GetFirst(HeaderSecWebSocketVersion));
end;

procedure TWsH2RequestTest.TestWsRequestUsesHttp;
var
  Req: TStreamRequest;
begin
  Req := BuildWith(False, nil, []);
  AssertEquals('scheme', 'http', Req.Scheme);
  AssertEquals('protocol', 'websocket', Req.Protocol);
  AssertEquals('method', 'CONNECT', Req.Method);
end;

procedure TWsH2RequestTest.TestPollAndResponseLimitSettings;
var
  Req: TStreamRequest;
begin
  Req := BuildWith(True, nil, []);
  AssertEquals('poll time', 100, Req.BodyReadTimeoutMs);
  AssertTrue('poll time is set', Req.BodyReadTimeoutSet);
  AssertEquals('response limit', 0, Integer(Req.MaxResponseBytes));
  AssertTrue('response limit is set', Req.MaxResponseBytesSet);
  AssertFalse('no body', Req.Body.IsSet);
  AssertTrue('no body writer', Req.BodyWriter = nil);
  AssertTrue('no exchange observer', Req.Exchange = nil);
end;

procedure TWsH2RequestTest.TestNoForbiddenFieldIsPresent;
var
  Req: TStreamRequest;
  Forbidden: array[0..4] of string;
  I: Integer;
begin
  Req := BuildWith(True, ['chat'], ['Origin', 'https://example.com']);
  Forbidden[0] := HeaderConnection;
  Forbidden[1] := HeaderUpgrade;
  Forbidden[2] := HeaderSecWebSocketKey;
  Forbidden[3] := HeaderContentLength;
  Forbidden[4] := HeaderAcceptEncoding;
  for I := 0 to High(Forbidden) do
    AssertFalse(Forbidden[I], Req.Headers.Contains(Forbidden[I]));
  AssertTrue('origin is sent', Req.Headers.Contains(HeaderOrigin));
end;

procedure TWsH2RequestTest.TestSubprotocolListIsJoined;
var
  Req: TStreamRequest;
begin
  Req := BuildWith(True, ['chat', 'superchat'], []);
  AssertEquals('joined list', 'chat, superchat',
    Req.Headers.GetFirst(HeaderSecWebSocketProtocol));
end;

procedure TWsH2RequestTest.TestNoSubprotocolFieldWhenListIsEmpty;
var
  Req: TStreamRequest;
begin
  Req := BuildWith(True, nil, []);
  AssertFalse('no subprotocol field', Req.Headers.Contains(HeaderSecWebSocketProtocol));
end;

procedure TWsH2RequestTest.TestCallerHeaderNameIsLowerCase;
var
  Req: TStreamRequest;
begin
  Req := BuildWith(True, nil, ['X-Trace-Id', 'abc']);
  AssertTrue('lower-case name is stored', HasName(Req, 'x-trace-id'));
  AssertFalse('mixed-case name is not stored', HasName(Req, 'X-Trace-Id'));
  AssertEquals('value', 'abc', Req.Headers.GetFirst('x-trace-id'));
end;

procedure TWsH2RequestTest.TestRestrictedCallerHeadersRaise;
var
  Names: array[0..10] of string;
  I: Integer;
begin
  Names[0] := 'Host'; Names[1] := 'Upgrade'; Names[2] := 'connection';
  Names[3] := 'Content-Length'; Names[4] := 'Sec-WebSocket-Key';
  Names[5] := 'sec-websocket-version'; Names[6] := 'Sec-WebSocket-Protocol';
  Names[7] := 'Sec-WebSocket-Extensions'; Names[8] := 'Sec-WebSocket-Accept';
  Names[9] := 'Transfer-Encoding'; Names[10] := 'Expect';
  for I := 0 to High(Names) do
    AssertTrue(Names[I], BuildRaises(Names[I], 'x'));
end;

procedure TWsH2RequestTest.TestAcceptEncodingRaises;
begin
  AssertTrue('accept-encoding', BuildRaises('Accept-Encoding', 'gzip'));
end;

procedure TWsH2RequestTest.TestPseudoHeaderNameRaises;
begin
  AssertTrue('pseudo-header', BuildRaises(':path', '/'));
  AssertTrue('name with a space', BuildRaises('bad name', 'v'));
end;

procedure TWsH2RequestTest.TestLineBreakInValueRaises;
begin
  AssertTrue('line break', BuildRaises('X-Trace', 'a'#13#10'b'));
end;

procedure TWsH2RequestTest.TestInvalidSubprotocolRaises;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    WsBuildH2Request(True, '/', 'example.com', ['has space'], nil);
  except
    on EHttpWebSocketError do
      Raised := True;
  end;
  AssertTrue('subprotocol with a space', Raised);
end;

{ TWsH2ResponseTest }

function TWsH2ResponseTest.Check(const AStatus: Integer;
  const AExtra: array of string; const AOffered: TArray<string>;
  out AChosen: string): string;
begin
  Result := WsCheckH2Response(AStatus, PairsToFields(AExtra), AOffered, AChosen);
end;

procedure TWsH2ResponseTest.TestOkWithoutSubprotocol;
var
  Chosen: string;
begin
  AssertEquals('reason', '', Check(HttpStatusOk, [], nil, Chosen));
  AssertEquals('chosen', '', Chosen);
end;

procedure TWsH2ResponseTest.TestOfferedSubprotocolIsChosen;
var
  Chosen: string;
begin
  AssertEquals('reason', '',
    Check(HttpStatusOk, ['sec-websocket-protocol', 'superchat'],
      ['chat', 'superchat'], Chosen));
  AssertEquals('chosen', 'superchat', Chosen);
end;

procedure TWsH2ResponseTest.TestNotOfferedSubprotocolGivesReason;
var
  Chosen: string;
  Reason: string;
begin
  Reason := Check(HttpStatusOk, ['sec-websocket-protocol', 'other'],
    ['chat'], Chosen);
  AssertEquals('reason',
    'server selected subprotocol "other" that was not offered', Reason);
  AssertEquals('chosen', '', Chosen);
end;

procedure TWsH2ResponseTest.TestNoOfferGivesReasonForAnySubprotocol;
var
  Chosen: string;
begin
  AssertTrue('a subprotocol with no offer',
    Check(HttpStatusOk, ['sec-websocket-protocol', 'chat'], nil, Chosen) <> '');
end;

procedure TWsH2ResponseTest.TestTwoSubprotocolsGiveReason;
var
  Chosen: string;
begin
  AssertEquals('reason', 'server selected more than one subprotocol',
    Check(HttpStatusOk, ['sec-websocket-protocol', 'chat, superchat'],
      ['chat', 'superchat'], Chosen));
end;

procedure TWsH2ResponseTest.TestExtensionsGiveReason;
var
  Chosen: string;
begin
  AssertEquals('reason', 'server selected an extension that was not offered',
    Check(HttpStatusOk, ['sec-websocket-extensions', 'permessage-deflate'],
      nil, Chosen));
end;

procedure TWsH2ResponseTest.TestContentLengthGivesReason;
var
  Chosen: string;
  Reason: string;
begin
  Reason := Check(HttpStatusOk, ['content-length', '0'], nil, Chosen);
  AssertTrue('content-length is a reason', Reason <> '');
  AssertTrue('reason names the field', Pos(HeaderContentLength, Reason) > 0);
end;

procedure TWsH2ResponseTest.TestStatusOtherThan200GivesReason;
var
  Chosen: string;
begin
  AssertEquals('404', 'server answered 404 instead of 200',
    Check(HttpStatusNotFound, [], nil, Chosen));
  AssertEquals('403', 'server answered 403 instead of 200',
    Check(HttpStatusForbidden, [], nil, Chosen));
  AssertEquals('101', 'server answered 101 instead of 200',
    Check(HttpStatusSwitchingProtocols, [], nil, Chosen));
end;

procedure TWsH2ResponseTest.TestAcceptFieldIsIgnored;
var
  Chosen: string;
begin
  AssertEquals('accept field', '',
    Check(HttpStatusOk, ['sec-websocket-accept', 'anything'], nil, Chosen));
  AssertEquals('plain accept field', '',
    Check(HttpStatusOk, ['accept', 'text/plain'], nil, Chosen));
end;

initialization
  RegisterTest(TWsH2RequestTest);
  RegisterTest(TWsH2ResponseTest);

end.
