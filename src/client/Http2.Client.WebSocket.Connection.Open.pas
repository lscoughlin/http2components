{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket
notes:
  - This unit owns the HTTP/1.1 WebSocket opening handshake.
---
}
unit Http2.Client.WebSocket.Connection.Open;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  Http2.Client.WebSocket, Http2.Client.Proxy, Http2.Client.Http1,
  Http2.Client.Tls.Types, Http2.Client.WebSocket.Connection.Types;

function OpenWebSocket(const AFactory: IHttp1SocketFactory;
  const ARequest: IWebSocketRequest; const AProxy: IProxy;
  const ADefaultConnectTimeoutMs: Integer;
  const AMask: TMaskKeySource = nil;
  const AAttempt: IWebSocketAttempt = nil): IWebSocket;

implementation

uses
  SysUtils, Classes, Http2.Client.Errors, Http2.Client.Tls,
  Http2.Client.WebSocket.Connection, Http2.Client.Messages,
  Http2.Common.Headers;

function OpenWebSocket(const AFactory: IHttp1SocketFactory;
  const ARequest: IWebSocketRequest; const AProxy: IProxy;
  const ADefaultConnectTimeoutMs: Integer;
  const AMask: TMaskKeySource; const AAttempt: IWebSocketAttempt): IWebSocket;
var
  Secure: Boolean;
  Host, Target, Authority, Key, Chosen, Why, Line, Version, Reason: string;
  Port: Word;
  Timeout, Status, I, N, Sent: Integer;
  Mask: TMaskKeySource;
  Sock: IHttp2Socket;
  Reader: TBufferedReader;
  Req, BodyBuf: TBytes;
  Raw: TArray<string>;
  Parsed: TArray<THttp1HeaderField>;
  Fields: TArray<TWsHeaderField>;
  HeaderLines, Body: string;
  TlsObj: TObject;
  Conn: TWebSocketConnection;
  Want: Integer;
begin
  Mask := AMask;
  if not Assigned(Mask) then
    Mask := SecureRandomCardinal;
  WsParseUrl(ARequest.Url, Secure, Host, Port, Target, Authority);
  Timeout := ARequest.ConnectTimeoutMs;
  if Timeout <= 0 then
    Timeout := ADefaultConnectTimeoutMs;
  Key := WsNewKey(Mask);
  if AAttempt <> nil then
    Req := WsBuildHandshake(Target, Authority, Key, ARequest.Subprotocols,
      AAttempt.HandshakeHeaders)
  else
    Req := WsBuildHandshake(Target, Authority, Key, ARequest.Subprotocols,
      ARequest.Headers);
  if Secure then
    Sock := AFactory.DialHttp1(Host, Port, 'https', Timeout, AProxy)
  else
    Sock := AFactory.DialHttp1(Host, Port, 'http', Timeout, AProxy);
  Reader := nil;
  try
    Sock.ReadTimeoutMs := Timeout;
    Sock.WriteTimeoutMs := Timeout;
    Sent := 0;
    while Sent < Length(Req) do
    begin
      N := Sock.Write(Req[Sent], Length(Req) - Sent);
      if N <= 0 then
        raise EHttpConnectionError.Create('WebSocket handshake write failed');
      Inc(Sent, N);
    end;
    if AAttempt <> nil then
      AAttempt.HandshakeWritten;
    Reader := TBufferedReader.Create(Sock);
    if not Reader.ReadLine(Line) then
      raise EHttpConnectionError.Create(
        'the connection closed during the WebSocket handshake');
    ParseStatusLine(Line, Version, Status, Reason);
    SetLength(Raw, 0);
    while True do
    begin
      if not Reader.ReadLine(Line) then
        raise EHttpConnectionError.Create(
          'the connection closed during the WebSocket handshake');
      if Line = '' then
        Break;
      if Length(Raw) >= cWsMaxHandshakeLines then
        raise EHttpProtocolError.Create(
          'too many handshake response headers', ecProtocolError);
      SetLength(Raw, Length(Raw) + 1);
      Raw[High(Raw)] := Line;
    end;
    Parsed := ParseHeaders(Raw);
    SetLength(Fields, Length(Parsed));
    HeaderLines := '';
    for I := 0 to High(Parsed) do
    begin
      Fields[I].Name := Parsed[I].Name;
      Fields[I].Value := Parsed[I].Value;
      HeaderLines := HeaderLines + Parsed[I].Name + ': ' + Parsed[I].Value + #10;
    end;
    Why := WsCheckResponse(Status, Fields, Key, ARequest.Subprotocols, Chosen);
    if Why <> '' then
    begin
      Body := '';
      Want := StrToIntDef(HeaderFieldValue(Parsed, 'Content-Length'), 0);
      if Want > cWsMaxHandshakeBody then
        Want := cWsMaxHandshakeBody;
      if Want > 0 then
        try
          SetLength(BodyBuf, Want);
          N := Reader.ReadExact(BodyBuf[0], Want);
          if N > 0 then
            SetString(Body, PAnsiChar(@BodyBuf[0]), N);
        except
          // the status and headers are what matter
        end;
      raise EHttpWebSocketHandshakeError.Create(
        'WebSocket handshake failed: ' + Why, Status, HeaderLines, Body);
    end;
    Conn := TWebSocketConnection.Create(Sock, Reader, ARequest, Chosen, Mask,
      Supports(Sock, TTlsSocket, TlsObj), AAttempt);
    Reader := nil;                    // owned by the connection now
  except
    Sock.Close;
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
