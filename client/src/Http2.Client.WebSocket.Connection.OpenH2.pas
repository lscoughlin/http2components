{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, extended connect, rfc 8441
notes:
  - This unit opens a WebSocket on one HTTP/2 stream (RFC 8441) of a pooled connection.
  - The result is nil when the connection speaks HTTP/1.1 or when the peer does not allow the extended CONNECT. The caller decides the fallback.
  - A refused answer raises EHttpWebSocketHandshakeError, as the HTTP/1.1 opening does.
---
}
unit Http2.Client.WebSocket.Connection.OpenH2;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  Http2.Client.Pool, Http2.Client.WebSocket, Http2.Client.Proxy, Http2.Client.Tls.Types,
  Http2.Client.Tls, Http2.Client.ClientCert, Http2.Client.WebSocket.Connection.Types;

/// open a WebSocket over an HTTP/2 stream of APool. AOutcome tells how the
/// connection was chosen: toTunnel gives the socket, the other outcomes that
/// return nil leave the fallback to the caller.
function OpenWebSocketH2(const APool: TConnectionPool; const ARequest: IWebSocketRequest;
  const AProxy: IProxy; const AIdentity: IClientIdentity; const ADefaultConnectTimeoutMs: Integer;
  const AMask: TMaskKeySource; const AAttempt: IWebSocketAttempt;
  out AOutcome: TTunnelOutcome; const APooledOnly: Boolean = False): IWebSocket;

implementation

uses
  SysUtils, Classes, Http2.Client.Errors, Http2.Client.Url, Http2.Client.Http1,
  Http2.Client.WebSocket.Connection, Http2.Client.WebSocket.H2Handshake,
  Http2.Client.WebSocket.H2Socket, Http2.Client.Tunnel.Types,
  Http2.Client.RequestObserver, Http2.Client.Stream.Types;

/// the header lines of the answer, one 'name: value' line each
function HeaderLinesOf(const AFields: TArray<TWsHeaderField>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
    Result := Result + AFields[I].Name + ': ' + AFields[I].Value + #10;
end;

function OpenWebSocketH2(const APool: TConnectionPool; const ARequest: IWebSocketRequest;
  const AProxy: IProxy; const AIdentity: IClientIdentity; const ADefaultConnectTimeoutMs: Integer;
  const AMask: TMaskKeySource; const AAttempt: IWebSocketAttempt;
  out AOutcome: TTunnelOutcome; const APooledOnly: Boolean): IWebSocket;
var
  Secure: Boolean;
  Host, Target, Authority, Origin, Why, Chosen, Body: string;
  Port: Word;
  Timeout, Status: Integer;
  Mask: TMaskKeySource;
  Req: TStreamRequest;
  Headers, Fields: TArray<TWsHeaderField>;
  Tunnel: IH2Tunnel;
  Sock: IHttp2Socket;
  Reader: TBufferedReader;
  Conn: TWebSocketConnection;
  Exch: IExchangeObserver;
  Proto: TNegotiatedProtocol;
begin
  Result := nil;
  Mask := AMask;
  if not Assigned(Mask) then
    Mask := SecureRandomCardinal;
  WsParseUrl(ARequest.Url, Secure, Host, Port, Target, Authority);
  Timeout := ARequest.ConnectTimeoutMs;
  if Timeout <= 0 then
    Timeout := ADefaultConnectTimeoutMs;
  if AAttempt <> nil then
    Headers := AAttempt.HandshakeHeaders
  else
    Headers := ARequest.Headers;
  Req := WsBuildH2Request(Secure, Target, Authority, ARequest.Subprotocols, Headers);
  // the pool key of a direct route is the origin, as the request path builds it
  Origin := OriginOfUrl(ARequest.Url) + ProxyRouteKey(AProxy);
  // APooledOnly: a live pooled HTTP/2 connection or nil (toHttp1); nothing is dialled
  if APooledOnly then
    Tunnel := APool.AcquireTunnelPooled(Origin, Host, Port, Req, Timeout, AProxy,
      AIdentity, AOutcome, Status, Fields, Body)
  else
    Tunnel := APool.AcquireTunnel(Origin, Host, Port, Req, Timeout, AProxy, AIdentity,
      AOutcome, Status, Fields, Body);
  if (AOutcome = toHttp1) or (AOutcome = toNoExtendedConnect) then
    Exit(nil);
  if AAttempt <> nil then
    AAttempt.HandshakeWritten;
  // the protocol is h2 for the attempt, also when the answer is refused
  if (AAttempt <> nil) and Supports(AAttempt, IExchangeObserver, Exch) then
  begin
    if Secure then
      Proto := npHttp2Tls
    else
      Proto := npHttp2Cleartext;
    Exch.RouteChosen(Proto, False);
  end;
  if AOutcome = toRefused then
    raise EHttpWebSocketHandshakeError.Create('WebSocket handshake failed: ' +
      Format('server answered %d instead of 200', [Status]),
      Status, HeaderLinesOf(Fields), Body);
  Reader := nil;
  Conn := nil;
  try
    Why := WsCheckH2Response(Status, Fields, ARequest.Subprotocols, Chosen);
    if Why <> '' then
      raise EHttpWebSocketHandshakeError.Create('WebSocket handshake failed: ' + Why,
        Status, HeaderLinesOf(Fields), '');
    Sock := TH2StreamSocket.Create(Tunnel);
    Reader := TBufferedReader.Create(Sock);
    Conn := TWebSocketConnection.Create(Sock, Reader, ARequest, Chosen, Mask,
      False, AAttempt);
    Reader := nil;                    // owned by the connection now
  except
    // the stream is open on the wire: a reset ends it, a release would leave it open
    Tunnel.Reset;
    Reader.Free;
    raise;
  end;
  Result := Conn;
  // the headers are reported before the reader thread exists, so no message
  // or end can precede them
  if AAttempt <> nil then
    AAttempt.HandshakeAccepted(Status, Fields, Chosen);
  Conn.Start;
end;

end.
