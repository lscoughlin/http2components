{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, queue, QueuedMessages, flow control, 1008, test, fpcunit
notes:
  - This unit tests the queue cap of a WebSocket session over HTTP/2 with the default
    QueuedMessages. A handler blocks in its first Message call. A window-respecting
    client sends a burst of small messages while the handler is blocked, and then the
    handler is released.
  - The test expects that the server neither closes the session with 1008 nor drops a
    message, because the client keeps to the window.
  - The test runs on a raw h2c frame client (TH2WsClient) that answers every DATA frame
    with a WINDOW_UPDATE at once.
  - The waits are bounded polls. The burst gets 1 s to arrive while the handler is blocked.
---
}
/// Tests of the queue cap of WebSocket over HTTP/2 with a burst of small messages
unit Http2.Server.WebSocket.QueueBurst.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2.Server, Http2.Server.Errors, Http2.Common.Headers,
  Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types,
  Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.TestKit,
  Http2.Server.WebSocket.Http1.Test, Http2.Server.WebSocket.H2Client,
  Http2.Server.Http1.RawClient;

type
  /// tests of a burst of small messages against the default queue of a session
  TWsQueueBurstTest = class(TTestCase)
  private
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer;
    function OpenSocket(out AClient: TH2WsClient): Boolean;
    function OpenHttp1(out AClient: TRawHttp): Boolean;
    procedure AssertDeliveredInOrder(const ACount: Integer);
    function DeliveredCount: Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestBurstOfSmallMessagesWhileTheHandlerBlocks;
    procedure TestBurstOnHttp1IsClosedAt1008;
  end;

implementation

const
  /// the messages of the burst
  BurstCount = 100;
  /// the time that the burst gets to arrive while the handler is blocked
  BurstArrivalMs = 1000;
  /// the time limit of the delivery after the handler is released
  DeliveryMs = 10000;

{ TWsQueueBurstTest }

procedure TWsQueueBurstTest.SetUp;
begin
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
end;

procedure TWsQueueBurstTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
end;

procedure TWsQueueBurstTest.StartServer;
begin
  // the default options: QueuedMessages is 16, and the message bucket holds 10000 tokens
  FServer := LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create).Build;
  FServer.Start;
end;

function TWsQueueBurstTest.OpenSocket(out AClient: TH2WsClient): Boolean;
var
  F: THeaderBlock;
begin
  AClient := TH2WsClient.Create(FServer.Port);
  AClient.OpenWebSocket(1);
  Result := AClient.WaitHeaders(1, ResponseMs, F) and (Length(F) > 0);
  if Result then
    Result := (F[0].Name = ':status') and (F[0].Value = '200');
end;

function TWsQueueBurstTest.OpenHttp1(out AClient: TRawHttp): Boolean;
var
  H: TRawResponse;
begin
  AClient := TRawHttp.Create(FServer.Port);
  AClient.Send('GET /ws HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
    'Upgrade: websocket' + CRLF + 'Connection: Upgrade' + CRLF +
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' + CRLF +
    'Sec-WebSocket-Version: 13' + CRLF + CRLF);
  Result := AClient.ReadHead(ResponseMs, H) and (H.Status = 101);
end;

function TWsQueueBurstTest.DeliveredCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FRecording.Count - 1 do
    if Copy(FRecording.Line(I), 1, 6) = 'msg T ' then
      Inc(Result);
end;

procedure TWsQueueBurstTest.AssertDeliveredInOrder(const ACount: Integer);
var
  I, K: Integer;
  Line: string;
begin
  K := 0;
  for I := 0 to FRecording.Count - 1 do
  begin
    Line := FRecording.Line(I);
    if Copy(Line, 1, 6) = 'msg T ' then
    begin
      Inc(K);
      AssertEquals('message ' + IntToStr(K) + ' is in order',
        Format('msg T m%.3d', [K]), Line);
    end;
  end;
  AssertEquals('every message of the burst reached Message', ACount, K);
end;

procedure TWsQueueBurstTest.TestBurstOfSmallMessagesWhileTheHandlerBlocks;
var
  C: TH2WsClient;
  Gate: PRTLEvent;
  Wire: TBytes;
  I: Integer;
  Deadline: QWord;
  L: TStringList;
begin
  Gate := RTLEventCreate;
  try
    FRecording.Gate := Gate;
    StartServer;
    AssertTrue('the handshake answers 200', OpenSocket(C));
    try
      Wire := nil;
      for I := 1 to BurstCount do
        Wire := Cat(Wire, ClientText(Format('m%.3d', [I])));
      // the client keeps to the window: 100 small messages are about 1 KiB, well inside
      // the 64 KiB stream window, so SendData returns at once
      C.SendData(1, Wire);
      // the handler is blocked in its first Message call; the burst gets time to arrive
      Deadline := GetTickCount64 + BurstArrivalMs;
      repeat
        C.Pump(20);
      until GetTickCount64 > Deadline;
      // release the handler and wait for the deliveries
      RTLEventSetEvent(Gate);
      Deadline := GetTickCount64 + DeliveryMs;
      repeat
        C.Pump(20);
      until (DeliveredCount >= BurstCount) or (GetTickCount64 > Deadline);
      L := DecodeOutput(C.DataOf(1));
      try
        AssertTrue('no close frame with 1008 for a window-respecting client; the server sent: ' +
          StringReplace(Trim(L.Text), LineEnding, ' | ', [rfReplaceAll]) +
          '; messages that reached Message: ' + IntToStr(DeliveredCount),
          Pos('C:1008', L.Text) = 0);
      finally
        L.Free;
      end;
      AssertDeliveredInOrder(BurstCount);
    finally
      C.Free;
    end;
  finally
    // the handler must not wait on the gate when the server stops
    RTLEventSetEvent(Gate);
    if FServer <> nil then
    begin
      FServer.Stop;
      FServer := nil;
    end;
    RTLEventDestroy(Gate);
    FRecording.Gate := nil;
  end;
end;

procedure TWsQueueBurstTest.TestBurstOnHttp1IsClosedAt1008;
var
  C: TRawHttp;
  Gate: PRTLEvent;
  Wire, Got: TBytes;
  I: Integer;
  Deadline: QWord;
  L: TStringList;
  Closed: Boolean;
begin
  // HTTP/1.1 has no window, so the queue cap closes the session (design: no flow control)
  Gate := RTLEventCreate;
  try
    FRecording.Gate := Gate;
    StartServer;
    AssertTrue('the upgrade answers 101', OpenHttp1(C));
    try
      Wire := nil;
      for I := 1 to BurstCount do
        Wire := Cat(Wire, ClientText(Format('m%.3d', [I])));
      C.Send(TextOf(Wire));
      // the octets of the server are kept: the close frame can arrive while the handler is blocked
      Got := nil;
      Closed := False;
      Deadline := GetTickCount64 + BurstArrivalMs;
      repeat
        Got := Cat(Got, BytesOf(C.ReadSome(20)));
      until GetTickCount64 > Deadline;
      RTLEventSetEvent(Gate);
      Deadline := GetTickCount64 + DeliveryMs;
      repeat
        Got := Cat(Got, BytesOf(C.ReadSome(50)));
        L := DecodeOutput(Got);
        try
          Closed := Pos('C:1008', L.Text) > 0;
        finally
          L.Free;
        end;
      until Closed or (GetTickCount64 > Deadline);
      L := DecodeOutput(Got);
      try
        AssertTrue('the session closes with 1008 after the burst; octets received: ' +
          IntToStr(Length(Got)) + '; frames: ' +
          StringReplace(Trim(L.Text), LineEnding, ' | ', [rfReplaceAll]), Closed);
      finally
        L.Free;
      end;
      AssertTrue('the queue cap drops the messages that wait: ' +
        IntToStr(DeliveredCount) + ' of ' + IntToStr(BurstCount) + ' reached Message',
        DeliveredCount < BurstCount);
    finally
      C.Free;
    end;
  finally
    RTLEventSetEvent(Gate);
    if FServer <> nil then
    begin
      FServer.Stop;
      FServer := nil;
    end;
    RTLEventDestroy(Gate);
    FRecording.Gate := nil;
  end;
end;

initialization
  RegisterTest(TWsQueueBurstTest);

end.
