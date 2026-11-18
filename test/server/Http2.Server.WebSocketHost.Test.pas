{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, host, allow-list, dns rebinding, fpcunit, live, http1, http2
notes:
  - This unit tests the host allow-list of a WebSocket upgrade. An empty list turns
    the check off. A non-empty list accepts only an exact match of the host and the
    port, in lower case.
  - The live cases run a server with the allow-list and perform the handshake over
    HTTP/1.1 and over HTTP/2. A host that the list does not hold gets 403 before Init
    runs. A listed host or an empty list gets 101 (HTTP/1.1) or 200 (HTTP/2).
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Unit tests for the host allow-list of Http2.Server.WebSocket.Origin
unit Http2.Server.WebSocketHost.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  Http2.Server, Http2.Server.Seam, Http2.Server.Errors, Http2.Common.Hpack, Http2.Common.Headers,
  Http2.Server.Http1.RawClient, Http2.Server.WebSocket.Options,
  Http2.Server.WebSocket.Origin, Http2.Server.WebSocket.Http1.Test,
  Http2.Server.WebSocket.Http2.Test, Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.H2Client;

type
  TWsHostTest = class(TTestCase)
  published
    procedure TestEmptyListAcceptsEveryHost;
    procedure TestExactMatchIgnoresCase;
    procedure TestRebindIsRefused;
    procedure TestPortMustMatch;
    procedure TestEntryWithoutPortMatchesTheDefaultPort;
    procedure TestIPv6Literal;
    procedure TestUnusableAuthorityIsRefusedByANonEmptyList;
  end;

  /// live cases: the 403 of a refused host, on HTTP/1.1 and on HTTP/2
  TWsHostLiveTest = class(TTestCase)
  private
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AAllowed: TArray<string>);
    function Http1Status: Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestHttp1RefusesAHostOutsideTheList;
    procedure TestHttp1AcceptsAListedHost;
    procedure TestHttp1EmptyListAcceptsTheHost;
    procedure TestHttp2RefusesAHostOutsideTheList;
    procedure TestHttp2AcceptsAListedHost;
    procedure TestHttp2EmptyListAcceptsTheHost;
  end;

implementation

function Allowed(const A: array of string): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 0 to High(A) do
    Result[I] := A[I];
end;

procedure TWsHostTest.TestEmptyListAcceptsEveryHost;
begin
  AssertTrue('the check is off', WsHostAllowed(nil, 'https', 'evil.test'));
  AssertTrue('the check is off, any port', WsHostAllowed(nil, 'http', 'evil.test:9999'));
  AssertTrue('the check is off, no host', WsHostAllowed(nil, 'https', ''));
end;

procedure TWsHostTest.TestExactMatchIgnoresCase;
var
  L: TArray<string>;
begin
  L := Allowed(['example.com:8080']);
  AssertTrue('the host in upper case', WsHostAllowed(L, 'http', 'EXAMPLE.com:8080'));
  AssertTrue('the exact host', WsHostAllowed(L, 'http', 'example.com:8080'));
end;

procedure TWsHostTest.TestRebindIsRefused;
var
  L: TArray<string>;
begin
  L := Allowed(['example.com:8080']);
  AssertFalse('a rebound host', WsHostAllowed(L, 'http', 'evil.test:8080'));
  AssertFalse('a host that only ends with the entry', WsHostAllowed(L, 'http', 'notexample.com:8080'));
  AssertFalse('a host that starts with the entry', WsHostAllowed(L, 'http', 'example.com.evil.test:8080'));
end;

procedure TWsHostTest.TestPortMustMatch;
var
  L: TArray<string>;
begin
  L := Allowed(['example.com:8080']);
  AssertFalse('another port', WsHostAllowed(L, 'http', 'example.com:9090'));
  AssertFalse('no port, the default of http is 80', WsHostAllowed(L, 'http', 'example.com'));
end;

procedure TWsHostTest.TestEntryWithoutPortMatchesTheDefaultPort;
var
  L: TArray<string>;
begin
  L := Allowed(['example.com']);
  AssertTrue('https, no port', WsHostAllowed(L, 'https', 'example.com'));
  AssertTrue('https, the default port', WsHostAllowed(L, 'https', 'example.com:443'));
  AssertFalse('https, another port', WsHostAllowed(L, 'https', 'example.com:8443'));
  AssertFalse('https, the port of http', WsHostAllowed(L, 'https', 'example.com:80'));
  AssertTrue('http, the default port', WsHostAllowed(L, 'http', 'example.com:80'));
  AssertFalse('http, the port of https', WsHostAllowed(L, 'http', 'example.com:443'));
end;

procedure TWsHostTest.TestIPv6Literal;
var
  L: TArray<string>;
begin
  L := Allowed(['[::1]:8080']);
  AssertTrue('the literal and the port', WsHostAllowed(L, 'http', '[::1]:8080'));
  AssertFalse('another port', WsHostAllowed(L, 'http', '[::1]:9090'));
  AssertFalse('another literal', WsHostAllowed(L, 'http', '[::2]:8080'));
end;

procedure TWsHostTest.TestUnusableAuthorityIsRefusedByANonEmptyList;
var
  L: TArray<string>;
begin
  L := Allowed(['example.com']);
  AssertFalse('an empty authority', WsHostAllowed(L, 'https', ''));
  AssertFalse('a space in the authority', WsHostAllowed(L, 'https', 'a b'));
end;

{ TWsHostLiveTest }

// the handshake of the tests names the host localhost, with no port
// - the default port of http (80) is the port of the entry localhost
function UpgradeRequest: string;
begin
  Result := 'GET /ws HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
    'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF +
    'Sec-WebSocket-Version: 13' + CRLF + CRLF;
end;

function FieldOf(const AFields: THeaderBlock; const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
    if AFields[I].Name = AName then
      Exit(AFields[I].Value);
end;

procedure TWsHostLiveTest.SetUp;
begin
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
end;

procedure TWsHostLiveTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
end;

procedure TWsHostLiveTest.StartServer(const AAllowed: TArray<string>);
begin
  FServer := LiveFactory(FRouterRef).WithWebSockets(
    TWsOptions.Create.WithWsAllowedHosts(AAllowed)).Build;
  FServer.Start;
end;

function TWsHostLiveTest.Http1Status: Integer;
var
  C: TRawHttp;
  R: TRawResponse;
begin
  C := TRawHttp.Create(FServer.Port);
  try
    C.Send(UpgradeRequest);
    if C.ReadHead(ResponseMs, R) then
      Result := R.Status
    else
      Result := 0;
  finally
    C.Free;
  end;
end;

procedure TWsHostLiveTest.TestHttp1RefusesAHostOutsideTheList;
begin
  StartServer(TArray<string>.Create('example.com'));
  AssertEquals('the host localhost is not listed', 403, Http1Status);
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHostLiveTest.TestHttp1AcceptsAListedHost;
begin
  StartServer(TArray<string>.Create('localhost'));
  AssertEquals('the host localhost is listed', 101, Http1Status);
  AssertTrue('Init ran', WaitUntilText(FRecording, 'init /ws'));
end;

procedure TWsHostLiveTest.TestHttp1EmptyListAcceptsTheHost;
begin
  StartServer(nil);
  AssertEquals('the check is off', 101, Http1Status);
  AssertTrue('Init ran', WaitUntilText(FRecording, 'init /ws'));
end;

procedure TWsHostLiveTest.TestHttp2RefusesAHostOutsideTheList;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(TArray<string>.Create('example.com'));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue('the answer of the stream', C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('the authority localhost is not listed', '403', FieldOf(F, ':status'));
    AssertTrue('the stream ends', C.WaitEnded(1));
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHostLiveTest.TestHttp2AcceptsAListedHost;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(TArray<string>.Create('localhost'));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue('the answer of the stream', C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('the authority localhost is listed', '200', FieldOf(F, ':status'));
  finally
    C.Free;
  end;
  AssertTrue('Init ran', WaitUntilText(FRecording, 'init /ws'));
end;

procedure TWsHostLiveTest.TestHttp2EmptyListAcceptsTheHost;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(nil);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue('the answer of the stream', C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('the check is off', '200', FieldOf(F, ':status'));
  finally
    C.Free;
  end;
  AssertTrue('Init ran', WaitUntilText(FRecording, 'init /ws'));
end;

initialization
  RegisterTest(TWsHostTest);
  RegisterTest(TWsHostLiveTest);

end.
