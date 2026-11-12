{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, flow_control
notes:
  - this tests that the client reads WINDOW_UPDATE while a response queues up
---
}
unit Http2.Client.FlowControl.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, Generics.Collections, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Client.MockSocket.Frames,
  Http2.Client.Messages, Http2.Client.Stream, Http2.Client,
  Http2.Client.MockSocket.Support;

type
  TFlowControlTest = class(TTestCase)
  private
    FPeers: TObjectList<TObject>;
    procedure AttachEchoPeer(const ASocket: TMockSocket);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestLargeBodyEchoDoesNotStallTheReader;
  end;

implementation

const
  cBodySize = 4 * 1024 * 1024;
  cWaitMs = 20000;

type
  /// a server that echoes the request body and honours the client's receive
  /// windows: it sends response DATA only while both windows have credit, and
  /// the client must return that credit with WINDOW_UPDATE frames
  TEchoPeer = class
  private
    FSocket: TMockSocket;
    FStreamId: LongWord;
    FConnWindow: Int64;
    FStreamWindow: Int64;
    FPending: TBytes;
    FEnd: Boolean;
    FEndSent: Boolean;
    procedure Flush;
  public
    constructor Create(const ASocket: TMockSocket);
    procedure OnClientFrame(const AFrame: TFrame);
  end;

  /// sends the request and reads the echoed body on its own thread, so the
  /// test can bound the wait
  TEchoWorker = class(TThread)
  private
    FClient: IHttpClient;
    FSent: TBytes;
    FReceived: TBytes;
    FStatus: Integer;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const ASent: TBytes);
    property Received: TBytes read FReceived;
    property Status: Integer read FStatus;
    property Error: string read FError;
  end;

constructor TEchoWorker.Create(const AClient: IHttpClient;
  const ASent: TBytes);
begin
  FClient := AClient;
  FSent := ASent;
  FStatus := -1;
  inherited Create(False);
end;

procedure TEchoWorker.Execute;
var
  R: IHttpResponse;
  N, Count: LongInt;
  Buf: array[0..16383] of Byte;
begin
  try
    R := FClient.Send(THttpRequest.Create(hmPost, 'https://echo.example/x')
      .WithBody(THttpBody.FromBytes(FSent)));
    FStatus := R.StatusCode;
    SetLength(FReceived, Length(FSent));
    Count := 0;
    while True do
    begin
      N := R.Body.Read(Buf, SizeOf(Buf));
      if N <= 0 then
        Break;
      if Count + N <= Length(FReceived) then
        Move(Buf[0], FReceived[Count], N);
      Inc(Count, N);
    end;
    SetLength(FReceived, Count);
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

constructor TEchoPeer.Create(const ASocket: TMockSocket);
begin
  inherited Create;
  FSocket := ASocket;
  FConnWindow := 65535;
  FStreamWindow := 65535;
  FSocket.OnClientFrame := OnClientFrame;
end;

procedure TEchoPeer.Flush;
var
  N: Int64;
  Chunk: TBytes;
  Last: Boolean;
begin
  while (not FEndSent) and (FStreamId <> 0) do
  begin
    N := Length(FPending);
    if N > 16384 then N := 16384;
    if N > FConnWindow then N := FConnWindow;
    if N > FStreamWindow then N := FStreamWindow;
    Last := FEnd and (N = Length(FPending));
    if (N = 0) and not Last then
      Exit;
    Chunk := Copy(FPending, 0, N);
    FPending := Copy(FPending, N, Length(FPending) - N);
    Dec(FConnWindow, N);
    Dec(FStreamWindow, N);
    FSocket.FeedLocked(FrameToBytes(BuildDataFrame(FStreamId, Chunk, Last)));
    FEndSent := Last;
  end;
end;

procedure TEchoPeer.OnClientFrame(const AFrame: TFrame);
var
  Data: TBytes;
  Old: Integer;
begin
  case AFrame.Header.FrameType of
    ftHeaders:
      FStreamId := AFrame.Header.StreamId;
    ftData:
      begin
        Data := ExtractDataPayload(AFrame);
        Old := Length(FPending);
        SetLength(FPending, Old + Length(Data));
        if Length(Data) > 0 then
          Move(Data[0], FPending[Old], Length(Data));
        FEnd := FEnd or AFrame.IsEndStream;
        // the server reads the request body at once, so it returns credit
        if AFrame.DataLength > 0 then
        begin
          FSocket.FeedLocked(FrameToBytes(
            BuildWindowUpdateFrame(0, AFrame.DataLength)));
          FSocket.FeedLocked(FrameToBytes(
            BuildWindowUpdateFrame(FStreamId, AFrame.DataLength)));
        end;
      end;
    ftWindowUpdate:
      if AFrame.Header.StreamId = 0 then
        Inc(FConnWindow, ParseWindowUpdate(AFrame))
      else
        Inc(FStreamWindow, ParseWindowUpdate(AFrame));
  end;
  Flush;
end;

procedure TFlowControlTest.SetUp;
begin
  FPeers := TObjectList<TObject>.Create(True);
end;

procedure TFlowControlTest.TearDown;
begin
  FPeers.Free;
end;

procedure TFlowControlTest.AttachEchoPeer(const ASocket: TMockSocket);
begin
  FPeers.Add(TEchoPeer.Create(ASocket));
end;

procedure TFlowControlTest.TestLargeBodyEchoDoesNotStallTheReader;
var
  FactoryRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Worker: TEchoWorker;
  Sent: TBytes;
  I: Integer;
  Deadline: QWord;
begin
  // the server echoes the request body within the client's receive windows.
  // The client sends the whole body before it reads, so echoed frames queue
  // up (once more than the 128 a lease queue held) and the connection reader
  // must still apply the WINDOW_UPDATE frames that open the send window.
  FactoryRef := TMockSocketFactory.Create;
  (FactoryRef as TMockSocketFactory).SetResponse('200', nil, False);
  (FactoryRef as TMockSocketFactory).OnDial := AttachEchoPeer;
  Client := THttpClientFactory.Create.WithSocketFactory(FactoryRef).Build;
  SetLength(Sent, cBodySize);
  for I := 0 to High(Sent) do
    Sent[I] := Byte((I * 7) xor (I shr 8));
  Worker := TEchoWorker.Create(Client, Sent);
  Deadline := GetTickCount64 + QWord(cWaitMs);
  while (not Worker.Finished) and (GetTickCount64 < Deadline) do
    Sleep(10);
  // a stalled worker and its client stay blocked; leaking them is the price
  // of a test that fails in seconds instead of hanging
  if not Worker.Finished then
    Fail('the echo did not finish within ' + IntToStr(cWaitMs) + ' ms');
  AssertEquals('no error: ' + Worker.Error, '', Worker.Error);
  AssertEquals('status', 200, Worker.Status);
  AssertEquals('echoed size', cBodySize, Length(Worker.Received));
  AssertTrue('echoed bytes match',
    CompareMem(@Sent[0], @Worker.Received[0], cBodySize));
  Worker.Free;
  Client.Close;
end;

initialization
  RegisterTest(TFlowControlTest);
end.
