{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
/// http2components client example: open a WebSocket, send a text message, print the echo.
// - build: `make examples`
// - run:   bin/<target>/<profile>/examples-client/programs/websocket_echo wss://echo.websocket.org/ "hello"
//   or against the reference server:
//          python3 tools/client/validate/ws_servers.py --log /tmp/ws.log --plain-port 8601 &
//          bin/<target>/<profile>/examples-client/programs/websocket_echo ws://127.0.0.1:8601/echo "hello"
// - shows: IWebSocketRequest / IWebSocketListener, IHttpClient.Send, the
//   demand rule (nothing is delivered until Request), and the closing
//   handshake.  See doc/design/websocket.md.
program example_websocket_echo;

{$mode delphi}{$H+}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, SyncObjs, Http2.Client.Errors, Http2.Client,
  Http2.Client.WebSocket, Http2.Common, Http2.OpenSSL;

type
  /// prints what arrives and signals when the conversation is over
  TPrinter = class(TWebSocketListener)
  public
    Finished: TEvent;
    constructor Create;
    destructor Destroy; override;
    procedure OnOpen(const ASocket: IWebSocket); override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    procedure OnClose(const ASocket: IWebSocket; const AStatusCode: Integer;
      const AReason: string); override;
    procedure OnError(const ASocket: IWebSocket;
      const AError: Exception); override;
  end;

constructor TPrinter.Create;
begin
  inherited Create;
  Finished := TEvent.Create(nil, True, False, '');
end;

destructor TPrinter.Destroy;
begin
  Finished.Free;
  inherited Destroy;
end;

procedure TPrinter.OnOpen(const ASocket: IWebSocket);
begin
  // ask for the next messages; without this nothing is delivered
  ASocket.Request(4);
end;

procedure TPrinter.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  WriteLn('received: ', AText);
  // the echo arrived: start the closing handshake
  ASocket.Close(1000, 'done');
end;

procedure TPrinter.OnClose(const ASocket: IWebSocket;
  const AStatusCode: Integer; const AReason: string);
begin
  WriteLn('closed: ', AStatusCode, ' ', AReason);
  Finished.SetEvent;
end;

procedure TPrinter.OnError(const ASocket: IWebSocket; const AError: Exception);
begin
  WriteLn(StdErr, 'failed: ', AError.ClassName, ': ', AError.Message);
  Finished.SetEvent;
end;

var
  Client: IHttpClient;
  OriginTls, ProxyTls: ITLSContext;
  Printer: TPrinter;
  Listener: IWebSocketListener;
  Socket: IWebSocket;
  Message: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn(StdErr, 'usage: example_websocket_echo <ws-or-wss-url> [message]');
    Halt(2);
  end;
  Message := 'hello';
  if ParamCount >= 2 then
    Message := ParamStr(2);

  OriginTls := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithSystemTrust(True))
    .Build;
  ProxyTls := TOpenSSLTlsContextFactory.Create
    .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithSystemTrust(True))
    .Build;
  Client := THttpClientFactory.Create.WithTlsContext(OriginTls)
    .WithProxyTlsContext(ProxyTls).WithProxyEnvironmentVars.Build;
  Printer := TPrinter.Create;
  Listener := Printer;
  try
    Socket := Client.Send(TWebSocketRequest.Create(ParamStr(1), Listener)
      .WithSubprotocol('chat'));
    WriteLn('connected, subprotocol "', Socket.Subprotocol, '"');
    Socket.SendText(Message);
    if Printer.Finished.WaitFor(15000) <> wrSignaled then
    begin
      WriteLn(StdErr, 'no answer within 15 seconds');
      Socket.Abort;
      Halt(1);
    end;
  except
    on E: EHttpWebSocketHandshakeError do
    begin
      WriteLn(StdErr, 'the server refused the upgrade: ', E.StatusCode);
      Halt(1);
    end;
    on E: EHttpError do
    begin
      WriteLn(StdErr, E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
