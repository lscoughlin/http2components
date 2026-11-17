{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, websocket, example, stream, body writer
notes:
  - This example serves a WebSocket on port 8085. The text message query starts a
    stream of 1000 rows. A row is the text "row N" and a line feed.
  - The writer yields 20 rows for each chunk, so the message has 50 fragments. The last
    chunk comes with a False answer, which ends the message with no empty call.
  - Another text message is answered with unknown. A binary message is ignored.
  - Optional arguments: the host (default 127.0.0.1) and the port (default 8085). The
    server runs until the caller presses Enter.
---
}
/// A WebSocket server that streams a message of 1000 rows
program ws_stream;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  mormot.core.base,
  Http2.Common.Body,
  Http2.Server;

const
  TotalRows = 1000;
  RowsPerChunk = 20;

type
  /// a body writer that yields the rows of the message, RowsPerChunk rows per chunk
  TRowWriter = class(TInterfacedObject, IBodyWriter)
  private
    FNext: Integer;
  public
    constructor Create;
    function NextChunk(const ABuffer: TStream): Boolean;
  end;

  /// the handler of the server: it upgrades every request, and it answers the messages
  TRouter = class(TInterfacedObject, IHttp2Handler, IWsHandler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AData: TBytes;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word;
      const AReason: string; const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

constructor TRowWriter.Create;
begin
  inherited Create;
  FNext := 1;
end;

function TRowWriter.NextChunk(const ABuffer: TStream): Boolean;
var
  Last, I: Integer;
  Chunk: UTF8String;
begin
  Last := FNext + RowsPerChunk - 1;
  if Last > TotalRows then
    Last := TotalRows;
  Chunk := '';
  for I := FNext to Last do
    Chunk := Chunk + 'row ' + UTF8String(IntToStr(I)) + #10;
  ChunkAppendText(ABuffer, Chunk);
  FNext := Last + 1;
  // the octets of a False call are the last chunk; the library sends them and ends
  // the message, so no empty call follows
  Result := FNext <= TotalRows;
end;

procedure TRouter.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  // a False answer means that an error response went out
  AcceptWebSocket(ARequest, AResponse, Self);
end;

function TRouter.Init(const ARequest: IServerRequest; const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin Result := TWsInitResult.Accepted; end;

procedure TRouter.Message(const ASession: IWsSession; const AData: TBytes;
  const AText: Boolean);
var
  Writer: IBodyWriter;
begin
  if not AText then
    Exit;
  if TEncoding.UTF8.GetString(AData) = 'query' then
  begin
    // a refused stream means that another stream of the session runs
    Writer := TRowWriter.Create;
    ASession.SendStream(Writer, True);
  end
  else
    ASession.Send(TEncoding.UTF8.GetBytes('unknown'), True);
end;

procedure TRouter.Pong(const ASession: IWsSession; const AData: TBytes);
begin end;

procedure TRouter.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
  WriteLn('session ', ASession.Id, ' closed with ', ACode, ' ', AReason);
end;

procedure TRouter.Failed(const ASession: IWsSession; const E: Exception);
begin
  WriteLn('session ', ASession.Id, ' failed: ', E.Message);
end;

var
  Server: IHttp2Server;
  Line, Host: string;
  Port: Integer;
begin
  Host := '127.0.0.1';
  if ParamCount >= 1 then
    Host := ParamStr(1);
  Port := 8085;
  if ParamCount >= 2 then
    Port := StrToIntDef(ParamStr(2), 8085);
  Server := THttp2ServerFactory.Create
    .WithMaxConcurrentStreams(256)
    .WithHost(Host)
    .WithPort(Port)
    .WithClearTextAllowed(True)
    .WithHandler(TRouter.Create)
    .WithWebSockets(TWsOptions.Create)
    .Build;
  Server.Start;
  WriteLn('WebSocket stream on http://', Host, ':', Server.Port, '/ ; press Enter to stop');
  Flush(Output);
  ReadLn(Line);
  Server.Stop;
end.
