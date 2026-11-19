{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, http2, extended connect, rfc 8441, live, test, fpcunit
notes:
  - This unit tests the WebSocket handshake of RFC 8441 on a running server with a raw
    h2c frame client. It covers the SETTINGS rule, the validation rules for the
    pseudo-header :protocol, the refusals, Init, the echo, the close mapping and the
    flow control of a large message.
  - The waits are bounded polls and never a fixed sleep that decides a result.
---
}
/// Live tests of WebSocket over HTTP/2
unit Http2.Server.WebSocket.Http2.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Generics.Collections, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2.Server, Http2.Server.Errors, Http2.Common.Hpack, Http2.Common.Headers,
  Http2.Common.Frames, Http2.Server.Seam, Http2.Server.WebSocket.Frames, Http2.Server.WebSocket.Types,
  Http2.Server.Http1.RawClient, Http2.Server.WebSocket.TestKit, Http2.Server.WebSocket.Http1.Test,
  Http2.Server.WebSocket.H2Client;

type
  TWsHttp2Test = class(TTestCase)
  private
    FRecording: TRecordingHandler;
    FRecordingRef: IWsHandler;
    FRouter: TWsRouter;
    FRouterRef: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer(const AFactory: THttp2ServerFactory);
    function Factory: THttp2ServerFactory;
    function Status(const AFields: THeaderBlock): string;
    function Field(const AFields: THeaderBlock; const AName: string): string;
    function Open(out AClient: TH2WsClient; const AId: LongWord = 1;
      const AExtra: THeaderBlock = nil): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestSettingsAdvertiseConnectOnlyWithWebSockets;
    procedure TestExtendedConnectWithoutTheSettingIsAStreamError;
    procedure TestProtocolOnAnotherMethodIsAStreamError;
    procedure TestHandshakeAnswers200WithoutEndStream;
    procedure TestEchoOnTheStream;
    procedure TestAnOrdinaryGetAndAWebSocketShareAConnection;
    procedure TestManyStreamsOnOneConnection;
    procedure TestClientCloseIsAnsweredAndEndsTheStream;
    procedure TestEndStreamWithoutCloseIs1006;
    procedure TestRstStreamIs1006AndTheConnectionStays;
    procedure TestStopSendsGoingAway;
    procedure TestRefusalsKeepTheConnection;
    procedure TestInitRejectIs401AndTheConnectionStays;
    procedure TestInitGreetingAndSubprotocol;
    procedure TestTrailerOnAWebSocketStreamIsAStreamError;
    procedure TestLargeMessageUsesFlowControl;
    procedure TestTheDetachLimitAnswers503;
    procedure TestDetachedHandlerOutlivesTheLimit;
    procedure TestSendWsMessageStreamsBigMessage;
    procedure TestNoneModeStopsTheServer;
    procedure TestKeepFramesFalseCounts;
    procedure TestServerEndingTheConnectionEndsAWaitingSend;
  end;

implementation

{ TWsHttp2Test }

procedure TWsHttp2Test.SetUp;
begin
  FRecording := TRecordingHandler.Create;
  FRecordingRef := FRecording;
  FRouter := TWsRouter.Create;
  FRouterRef := FRouter;
  FRouter.Handler := FRecordingRef;
end;

procedure TWsHttp2Test.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FRouter.Handler := nil;
  FRouterRef := nil;
  FRecordingRef := nil;
end;

function TWsHttp2Test.Factory: THttp2ServerFactory;
begin
  Result := LiveFactory(FRouterRef).WithWebSockets(TWsOptions.Create.WithQueuedMessages(256));
end;

procedure TWsHttp2Test.StartServer(const AFactory: THttp2ServerFactory);
begin
  FServer := AFactory.Build;
  FServer.Start;
end;

function TWsHttp2Test.Status(const AFields: THeaderBlock): string;
begin
  Result := Field(AFields, ':status');
end;

function TWsHttp2Test.Field(const AFields: THeaderBlock; const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(AFields) do
    if AFields[I].Name = AName then
      Exit(AFields[I].Value);
  Result := '';
end;

function TWsHttp2Test.Open(out AClient: TH2WsClient; const AId: LongWord;
  const AExtra: THeaderBlock): Boolean;
var
  F: THeaderBlock;
begin
  AClient := TH2WsClient.Create(FServer.Port);
  AClient.OpenWebSocket(AId, AExtra);
  Result := AClient.WaitHeaders(AId, ResponseMs, F) and (Status(F) = '200');
end;

procedure TWsHttp2Test.TestSettingsAdvertiseConnectOnlyWithWebSockets;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenGet(1, '/hello');
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertTrue('SETTINGS_ENABLE_CONNECT_PROTOCOL is set', C.PeerAdvertisesConnect);
  finally
    C.Free;
  end;
  FServer.Stop;
  StartServer(LiveFactory(FRouterRef));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenGet(1, '/hello');
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertFalse('the setting is absent without WithWebSockets', C.PeerAdvertisesConnect);
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestExtendedConnectWithoutTheSettingIsAStreamError;
var
  C: TH2WsClient;
  Code: THttp2ErrorCode;
  F: THeaderBlock;
begin
  StartServer(LiveFactory(FRouterRef));
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue(C.WaitReset(1, ResponseMs, Code));
    AssertTrue(Code = ecProtocolError);
    // the connection stays open for the next request
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestProtocolOnAnotherMethodIsAStreamError;
var
  C: TH2WsClient;
  F: THeaderBlock;
  Code: THttp2ErrorCode;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    SetLength(F, 5);
    F[0].Name := ':method';
    F[0].Value := 'GET';
    F[1].Name := ':scheme';
    F[1].Value := 'http';
    F[2].Name := ':path';
    F[2].Value := '/ws';
    F[3].Name := ':authority';
    F[3].Value := 'localhost';
    F[4].Name := ':protocol';
    F[4].Value := 'websocket';
    C.OpenStream(1, F, True);
    AssertTrue(C.WaitReset(1, ResponseMs, Code));
    AssertTrue(Code = ecProtocolError);
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHttp2Test.TestHandshakeAnswers200WithoutEndStream;
var
  C: TH2WsClient;
  F: THeaderBlock;
  I: Integer;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('200', Status(F));
    for I := 0 to High(F) do
      AssertTrue('no HTTP/1.1 upgrade field: ' + F[I].Name,
        not (F[I].Name = 'upgrade') and not (F[I].Name = 'sec-websocket-accept'));
    AssertFalse('the stream stays open', C.WaitEnded(1, 200));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestEchoOnTheStream;
var
  C: TH2WsClient;
begin
  FRecording.Echo := True;
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendData(1, ClientText('hello over h2'));
    AssertTrue(C.WaitFrames(1, 'T:hello over h2'));
    C.SendData(1, ClientFrame(WsOpPing, True, BytesOf('abc')));
    AssertTrue(C.WaitFrames(1, 'O:616263'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestAnOrdinaryGetAndAWebSocketShareAConnection;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  FRecording.Echo := True;
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
    AssertTrue(C.WaitEnded(3));
    C.SendData(1, ClientText('still open'));
    AssertTrue(C.WaitFrames(1, 'T:still open'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestManyStreamsOnOneConnection;
var
  C: TH2WsClient;
  I, J: Integer;
  F: THeaderBlock;
begin
  FRecording.Echo := True;
  StartServer(Factory.WithMaxConcurrentStreams(128));
  C := TH2WsClient.Create(FServer.Port);
  try
    // a burst of CONNECT requests can pass the admission queue, so the client opens
    // the streams in groups of ten and waits for each group, as a careful client does
    for I := 0 to 99 do
    begin
      C.OpenWebSocket(LongWord(1 + 2 * I));
      if I mod 10 = 9 then
        for J := I - 9 to I do
          AssertTrue('stream ' + IntToStr(J), C.WaitHeaders(LongWord(1 + 2 * J), 10000, F));
    end;
    for I := 0 to 99 do
      C.SendData(LongWord(1 + 2 * I), ClientText('m' + IntToStr(I)));
    for I := 0 to 99 do
      AssertTrue('echo ' + IntToStr(I), C.WaitFrames(LongWord(1 + 2 * I), 'T:m' + IntToStr(I), 10000));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestClientCloseIsAnsweredAndEndsTheStream;
var
  C: TH2WsClient;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendData(1, ClientClose(1000, 'bye'));
    AssertTrue(C.WaitFrames(1, 'C:1000:'));
    AssertTrue('the server ends its half', C.WaitEnded(1));
    AssertTrue(WaitUntilText(FRecording, 'closed 1000 bye clean=True'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestEndStreamWithoutCloseIs1006;
var
  C: TH2WsClient;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendData(1, nil, True);
    AssertTrue('the session closed with 1006: ' + FRecording.AllText,
      WaitUntilText(FRecording, 'closed 1006'));
    AssertTrue('the server ends its half', C.WaitEnded(1));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestRstStreamIs1006AndTheConnectionStays;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.SendRst(1, ecCancel);
    AssertTrue(WaitUntilText(FRecording, 'closed 1006'));
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestStopSendsGoingAway;
var
  C: TH2WsClient;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    FServer.Stop;
    AssertTrue('Close 1001 reached the client', C.WaitFrames(1, 'C:1001:'));
    AssertTrue(WaitUntilText(FRecording, 'closed 1001'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestRefusalsKeepTheConnection;
var
  C: TH2WsClient;
  F, Extra: THeaderBlock;
begin
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    // a version the server does not speak
    SetLength(Extra, 1);
    Extra[0].Name := 'sec-websocket-version';
    Extra[0].Value := '12';
    C.OpenWebSocket(1, Extra);
    AssertTrue('version answer', C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('400', Status(F));
    AssertEquals('13', Field(F, 'sec-websocket-version'));
    // a foreign origin
    SetLength(Extra, 1);
    Extra[0].Name := 'origin';
    Extra[0].Value := 'https://evil.test';
    C.OpenWebSocket(3, Extra);
    AssertTrue('origin answer', C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('403', Status(F));
    AssertTrue('origin end', C.WaitEnded(3));
    // the connection still serves
    C.OpenGet(5, '/hello');
    AssertTrue('get after refusals ' + C.Dump, C.WaitHeaders(5, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
  AssertEquals('Init never ran', 0, FRecording.Count);
end;

procedure TWsHttp2Test.TestInitRejectIs401AndTheConnectionStays;
var
  C: TH2WsClient;
  F, H: THeaderBlock;
  Res: TWsInitResult;
begin
  Res := TWsInitResult.Rejected(401);
  SetLength(H, 1);
  H[0].Name := 'www-authenticate';
  H[0].Value := 'Basic realm="x"';
  Res.RejectHeaders := H;
  FRecording.InitResult := Res;
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    C.OpenWebSocket(1);
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('401', Status(F));
    AssertEquals('Basic realm="x"', Field(F, 'www-authenticate'));
    AssertTrue(C.WaitEnded(1));
    C.OpenGet(3, '/hello');
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('200', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestInitGreetingAndSubprotocol;
var
  C: TH2WsClient;
  F, Extra: THeaderBlock;
begin
  FRecording.InitResult := TWsInitResult.AcceptedWith('json');
  FRecording.InitSend := BytesOf('welcome');
  FRecording.InitSendText := True;
  StartServer(Factory);
  C := TH2WsClient.Create(FServer.Port);
  try
    SetLength(Extra, 1);
    Extra[0].Name := 'sec-websocket-protocol';
    Extra[0].Value := 'chat, json';
    C.OpenWebSocket(1, Extra);
    AssertTrue(C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('200', Status(F));
    AssertEquals('json', Field(F, 'sec-websocket-protocol'));
    AssertTrue(C.WaitFrames(1, 'T:welcome'));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestTrailerOnAWebSocketStreamIsAStreamError;
var
  C: TH2WsClient;
  T: THeaderBlock;
  Code: THttp2ErrorCode;
begin
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    SetLength(T, 1);
    T[0].Name := 'x-trailer';
    T[0].Value := '1';
    C.OpenStream(1, T, True);
    AssertTrue(C.WaitReset(1, ResponseMs, Code));
    AssertTrue(Code = ecProtocolError);
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestLargeMessageUsesFlowControl;
var
  C: TH2WsClient;
  Big, Wire: TBytes;
  I, Pos, N: Integer;
  Op: Byte;
  L: TStringList;
  Deadline: QWord;
begin
  FRecording.Echo := True;
  StartServer(Factory.WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)
    .WithMaxMessageSize(2 * 1024 * 1024)));
  AssertTrue(Open(C));
  try
    SetLength(Big, 400 * 1024);
    for I := 0 to High(Big) do
      Big[I] := Ord('a') + (I mod 20);
    Wire := nil;
    Pos := 0;
    while Pos < Length(Big) do
    begin
      N := Length(Big) - Pos;
      if N > 32768 then
        N := 32768;
      if Pos = 0 then
        Op := WsOpText
      else
        Op := WsOpContinuation;
      Wire := Cat(Wire, ClientFrame(Op, Pos + N >= Length(Big), Copy(Big, Pos, N)));
      Inc(Pos, N);
    end;
    C.SendData(1, Wire);
    Deadline := GetTickCount64 + 15000;
    repeat
      N := Length(C.DataOf(1));
      if N >= Length(Big) then
        Break;
      C.WaitFrames(1, 'never matches', 50);
    until GetTickCount64 > Deadline;
    L := DecodeOutput(C.DataOf(1));
    try
      AssertEquals(1, L.Count);
      AssertEquals(Length(Big) + 2, Length(L[0]));
    finally
      L.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestTheDetachLimitAnswers503;
var
  C: TH2WsClient;
  F: THeaderBlock;
begin
  StartServer(Factory.WithMaxDetachedStreams(1));
  AssertTrue(Open(C));
  try
    C.OpenWebSocket(3);
    AssertTrue(C.WaitHeaders(3, ResponseMs, F));
    AssertEquals('503', Status(F));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestDetachedHandlerOutlivesTheLimit;
var
  Router: TWsOutliveRouter;
  RouterRef: IHttp2Handler;
  Gated: TWsGatedHandler;
  GatedRef: IWsHandler;
  C: TH2WsClient;
  F: THeaderBlock;
begin
  FRecording.Echo := True;
  Router := TWsOutliveRouter.Create;
  RouterRef := Router;
  Gated := TWsGatedHandler.Create(FRecordingRef);
  GatedRef := Gated;
  Router.Handler := GatedRef;
  StartServer(LiveFactory(RouterRef).WithWebSockets(TWsOptions.Create.WithQueuedMessages(256))
    .WithServerLimits(TServerLimits.Create.WithMaxHandlerTimeMs(WsLimitMs)));
  C := TH2WsClient.Create(FServer.Port);
  try
    // the handler detaches, and its call and the handshake stay open past the limit
    C.OpenWebSocket(1);
    AssertTrue('the call runs past the limit', WaitOutlivePassed(Router));
    Gated.LetInit;
    AssertTrue('the handshake answers after the limit', C.WaitHeaders(1, ResponseMs, F));
    AssertEquals('200', Status(F));
    // the stream and the session stay up while the call is still open
    C.SendData(1, ClientText('after the limit'));
    AssertTrue('the session echoes after the limit', C.WaitFrames(1, 'T:after the limit'));
  finally
    Gated.LetInit;
    Router.LetReturn;
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestSendWsMessageStreamsBigMessage;
const
  BigBytes = 3 * 1024 * 1024;
var
  C: TH2WsClient;
  I: Integer;
  Found: Boolean;
  Deadline: QWord;
begin
  FRecording.Echo := False;
  StartServer(Factory.WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)
    .WithMaxMessageSize(8 * 1024 * 1024)));
  AssertTrue(Open(C));
  try
    C.SendWsMessage(1, BigBytes, 32768, $41);
    Deadline := GetTickCount64 + 15000;
    Found := False;
    repeat
      for I := 0 to FRecording.Count - 1 do
        if FRecording.Line(I) = 'msg B ' + IntToStr(BigBytes) then
          Found := True;
      if not Found then
        C.Pump(20);
    until Found or (GetTickCount64 > Deadline);
    AssertTrue('the handler saw the 3 MB message', Found);
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestNoneModeStopsTheServer;
const
  MegaBytes = 1024 * 1024;
var
  C: TH2WsClient;
  Received: Int64;
  Deadline: QWord;
begin
  FRecording.Echo := True;
  StartServer(Factory.WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)
    .WithMaxMessageSize(8 * 1024 * 1024).WithOutboundStallMs(60000)));
  AssertTrue(Open(C));
  try
    // no credit for the echo: the server stops at the window of the stream
    C.CreditMode := ccNone;
    C.SendWsMessage(1, MegaBytes, 32768, $43);
    AssertTrue('the echo starts', C.WaitDataCount(1, 1, 5000));
    // the stop is shown by the bound after a pause; the pause is not the decision
    Deadline := GetTickCount64 + 500;
    repeat
      C.Pump(20);
    until GetTickCount64 > Deadline;
    Received := C.DataCount(1);
    AssertTrue('the server stops at the window: ' + IntToStr(Received),
      Received <= 65535 + 16384);
    // credit the octets that arrived, then the rest must arrive
    C.CreditMode := ccAuto;
    C.SendWindowUpdate(0, LongWord(Received));
    C.SendWindowUpdate(1, LongWord(Received));
    AssertTrue('the rest of the echo arrives', C.WaitDataCount(1, MegaBytes, 15000));
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestKeepFramesFalseCounts;
var
  C: TH2WsClient;
begin
  FRecording.Echo := True;
  StartServer(Factory);
  AssertTrue(Open(C));
  try
    C.KeepFrames := False;
    // the echo of 1000 octets is one server frame: a 4 octet header and 1000 payload octets
    C.SendData(1, ClientText(StringOfChar('x', 1000)));
    AssertTrue('the echo is counted', C.WaitDataCount(1, 1004, 5000));
    AssertTrue('the count is the frame length: ' + IntToStr(C.DataCount(1)),
      C.DataCount(1) = 1004);
    AssertTrue('no DATA frame is kept', Length(C.DataOf(1)) = 0);
  finally
    C.Free;
  end;
end;

procedure TWsHttp2Test.TestServerEndingTheConnectionEndsAWaitingSend;
var
  C: TH2WsClient;
  Started, Elapsed: QWord;
  Raised: Boolean;
  Cause: string;
begin
  FRecording.Echo := False;
  // the server closes the message at 64 KB; the client then waits for windows that stay closed
  StartServer(Factory.WithWebSockets(TWsOptions.Create.WithQueuedMessages(256)
    .WithMaxMessageSize(64 * 1024)));
  AssertTrue(Open(C));
  try
    Raised := False;
    Cause := '';
    Started := GetTickCount64;
    try
      C.SendWsMessage(1, 3 * 1024 * 1024, 32768, $44);
    except
      on E: EH2ConnectionEnded do
      begin
        Raised := True;
        Cause := E.Message;
      end;
      on E: Exception do
        Cause := E.ClassName + ': ' + E.Message;
    end;
    Elapsed := GetTickCount64 - Started;
    AssertTrue('the send ends with EH2ConnectionEnded, not the window deadline: ' + Cause,
      Raised);
    AssertTrue('the send ends within about 2 s: ' + IntToStr(Elapsed) + ' ms',
      Elapsed < 2000);
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TWsHttp2Test);

end.
