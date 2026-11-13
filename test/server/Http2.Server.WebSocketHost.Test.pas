{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, host, allow-list, dns rebinding, fpcunit
notes:
  - This unit tests the host allow-list of a WebSocket upgrade. An empty list turns
    the check off. A non-empty list accepts only an exact match of the host and the
    port, in lower case.
---
}
/// Unit tests for the host allow-list of Http2.Server.WebSocket.Origin
unit Http2.Server.WebSocketHost.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Server.WebSocket.Origin;

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

initialization
  RegisterTest(TWsHostTest);

end.
