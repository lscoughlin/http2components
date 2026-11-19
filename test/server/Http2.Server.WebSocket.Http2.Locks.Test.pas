{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, lock order, send lock, connection lock, deadlock, live, test, fpcunit
notes:
  - This unit runs many WebSocket streams with large messages over one h2c connection.
    The IO thread returns stream credit under the connection lock while the send loop
    ends its pass. The test fails when a lock cycle between the send lock and the
    connection lock stops the connection.
  - Each wait has a deadline. A stopped connection fails the test and does not block the
    suite. After such a failure the test does not stop the server, because the stop of a
    server with a stopped connection waits for ever. The server object stays allocated.
---
}
/// Live test of the lock order of the send loop of an HTTP/2 connection
unit Http2.Server.WebSocket.Http2.Locks.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  mormot.core.base,
  Http2.Common.Body, Http2.Common.Headers, Http2.Server, Http2.Server.Errors,
  Http2.Server.Http1.RawClient, Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.H2Client;

type
  /// reads a whole inbound message and replies "ok <count>"
  // - a pause after each chunk keeps the reader slower than the sender
  TLockCountHandler = class(TInterfacedObject, IWsHandler)
  private
    FPauseMs: Integer;
  public
    constructor Create(const APauseMs: Integer);
    function Init(const ARequest: IServerRequest; const AOffered: TArray<string>;
      const ASession: IWsSession): TWsInitResult;
    procedure Message(const ASession: IWsSession; const AMessage: IBodyReader;
      const AText: Boolean);
    procedure Pong(const ASession: IWsSession; const AData: TBytes);
    procedure Closed(const ASession: IWsSession; const ACode: Word; const AReason: string;
      const AClean: Boolean);
    procedure Failed(const ASession: IWsSession; const E: Exception);
  end;

  /// accepts every request as a WebSocket; the path /slow adds a pause to the reader
  TLockRouter = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
  end;

  TWsHttp2LocksTest = class(TTestCase)
  published
    procedure TestManyStreamsWithBigMessagesKeepTheConnectionRunning;
  end;

implementation

const
  /// the number of parallel streams on the connection
  cStreams = 24;
  /// the size of the message of each stream
  cMessageBytes = 1048576;
  /// the size of one WebSocket fragment
  cFragBytes = 32768;
  /// the time for the whole exchange, in milliseconds
  cDeadlineMs = 30000;

var
  /// keeps a server alive that cannot stop, so that its destructor does not wait
  GLeakedServer: IHttp2Server;
  GLeakedRouter: IHttp2Handler;

{ TLockCountHandler }

constructor TLockCountHandler.Create(const APauseMs: Integer);
begin
  inherited Create;
  FPauseMs := APauseMs;
end;

function TLockCountHandler.Init(const ARequest: IServerRequest;
  const AOffered: TArray<string>; const ASession: IWsSession): TWsInitResult;
begin
  Result := TWsInitResult.Accepted;
end;

procedure TLockCountHandler.Message(const ASession: IWsSession;
  const AMessage: IBodyReader; const AText: Boolean);
var
  Buf: TChunkBuffer;
  N: Int64;
  More: Boolean;
  Reply: UTF8String;
  Bytes: TBytes;
begin
  N := 0;
  Buf := TChunkBuffer.Create;
  try
    repeat
      Buf.Reset;
      More := AMessage.ReadChunk(Buf);
      Inc(N, Buf.Size);
      if FPauseMs > 0 then
        Sleep(FPauseMs);
    until not More;
  finally
    Buf.Free;
  end;
  Reply := UTF8String('ok ' + IntToStr(N));
  Bytes := nil;
  SetLength(Bytes, Length(Reply));
  Move(Reply[1], Bytes[0], Length(Reply));
  ASession.Send(Bytes, True);
end;

procedure TLockCountHandler.Pong(const ASession: IWsSession; const AData: TBytes);
begin
end;

procedure TLockCountHandler.Closed(const ASession: IWsSession; const ACode: Word;
  const AReason: string; const AClean: Boolean);
begin
end;

procedure TLockCountHandler.Failed(const ASession: IWsSession; const E: Exception);
begin
end;

{ TLockRouter }

procedure TLockRouter.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
begin
  if ARequest.Path = '/slow' then
    AcceptWebSocket(ARequest, AResponse, TLockCountHandler.Create(2))
  else
    AcceptWebSocket(ARequest, AResponse, TLockCountHandler.Create(0));
end;

{ TWsHttp2LocksTest }

procedure TWsHttp2LocksTest.TestManyStreamsWithBigMessagesKeepTheConnectionRunning;
var
  Router: IHttp2Handler;
  Server: IHttp2Server;
  C: TH2WsClient;
  Ids: array of LongWord;
  Fields, F: THeaderBlock;
  Chunk: TBytes;
  Frags, R, Left, Sz: Int64;
  K, I: Integer;
  Opc: Byte;
  Deadline: QWord;
  Failure, Want: string;
  L: TStringList;
  Replied: array of Boolean;
  Done: Boolean;
begin
  Router := TLockRouter.Create;
  Server := LiveFactory(Router).WithMaxConcurrentStreams(256).WithStreamPoolSize(64)
    .WithServerLimits(TServerLimits.Create.WithMaxWsQueuedBytes(Int64(64) * 1073741824))
    .WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)
      .WithMaxMessageSize(2147483647).WithMaxFrameSize(1048576)
      .WithMaxFragments(100000000).WithPingIntervalMs(0).WithInlineLimit(65536)
      .WithInboundPipeBytes(67108864)
      .WithInboundStallMs(120000).WithOutboundStallMs(120000)
      .WithMessageBucket(TTokenBucketOptions.Create.WithCapacity(10000000)
        .WithRefillPerSecond(10000000))).Build;
  Server.Start;
  Failure := '';
  C := TH2WsClient.Create(Server.Port);
  try
    try
      for I := 1 to 50 do
      begin
        if C.PeerAdvertisesConnect then
          Break;
        C.Pump(100);
      end;
      AssertTrue('the server advertises the CONNECT protocol', C.PeerAdvertisesConnect);
      SetLength(Ids, cStreams);
      SetLength(Replied, cStreams);
      for K := 0 to cStreams - 1 do
      begin
        Ids[K] := LongWord(2 * K + 1);
        SetLength(F, 6);
        F[0].Name := ':method'; F[0].Value := 'CONNECT';
        F[1].Name := ':scheme'; F[1].Value := 'http';
        F[2].Name := ':path';
        if (K mod 2) = 0 then
          F[2].Value := '/fast'
        else
          F[2].Value := '/slow';
        F[3].Name := ':authority'; F[3].Value := 'localhost';
        F[4].Name := ':protocol'; F[4].Value := 'websocket';
        F[5].Name := 'sec-websocket-version'; F[5].Value := '13';
        C.OpenStream(Ids[K], F);
        AssertTrue('stream ' + IntToStr(Ids[K]) + ' opens',
          C.WaitHeaders(Ids[K], ResponseMs, Fields));
      end;
      // one fragment per stream in turn, so the IO thread returns credit for
      // every stream while the send loop of the connection runs
      Frags := (cMessageBytes + cFragBytes - 1) div cFragBytes;
      for R := 0 to Frags - 1 do
        for K := 0 to cStreams - 1 do
        begin
          Left := cMessageBytes - R * cFragBytes;
          Sz := cFragBytes;
          if Left < Sz then
            Sz := Left;
          SetLength(Chunk, Sz);
          FillChar(Chunk[0], Sz, $44);
          if R = 0 then
            Opc := WsOpBinary
          else
            Opc := WsOpContinuation;
          C.SendData(Ids[K], ClientFrame(Opc, R = Frags - 1, Chunk));
        end;
      Want := 'T:ok ' + IntToStr(cMessageBytes);
      Deadline := GetTickCount64 + cDeadlineMs;
      repeat
        C.Pump(20);
        Done := True;
        for K := 0 to cStreams - 1 do
        begin
          if Replied[K] then
            Continue;
          L := DecodeOutput(C.DataOf(Ids[K]));
          try
            for I := 0 to L.Count - 1 do
              if L[I] = Want then
                Replied[K] := True;
          finally
            L.Free;
          end;
          if not Replied[K] then
            Done := False;
        end;
      until Done or (GetTickCount64 > Deadline);
      if not Done then
        Failure := 'a reply is missing after ' + IntToStr(cDeadlineMs) + ' ms';
    except
      on E: Exception do
        Failure := E.ClassName + ': ' + E.Message;
    end;
  finally
    C.Free;
  end;
  if Failure <> '' then
  begin
    // the connection is stopped by a lock cycle, so Stop would wait for ever:
    // the server object stays allocated. The extra reference keeps the finalization
    // of this unit from destroying it, because the destructor stops the server
    GLeakedServer := Server;
    GLeakedRouter := Router;
    Server._AddRef;
    Fail('the connection stopped: ' + Failure);
  end;
  Server.Stop;
end;

initialization
  RegisterTest(TWsHttp2LocksTest);

end.
