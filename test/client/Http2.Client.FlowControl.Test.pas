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
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Messages, Http2.Client.Stream, Http2.Client,
  Http2.Client.MockSocket.Support;

type
  TFlowControlTest = class(TTestCase)
  published
    procedure TestLargeBodyEchoDoesNotStallTheReader;
  end;

implementation

const
  cBodySize = 4 * 1024 * 1024;
  cWaitMs = 20000;

type
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

procedure TFlowControlTest.TestLargeBodyEchoDoesNotStallTheReader;
var
  FactoryRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Worker: TEchoWorker;
  Sent: TBytes;
  I: Integer;
  Deadline: QWord;
begin
  // the server echoes each request DATA frame and returns window credit.
  // The client sends the whole body before it reads, so the echoed frames
  // (more than the 128 a lease queue once held) must queue without stopping
  // the connection reader from applying the WINDOW_UPDATE frames that open
  // the send window.
  FactoryRef := TMockSocketFactory.Create;
  (FactoryRef as TMockSocketFactory).SetResponse('200', nil, False);
  (FactoryRef as TMockSocketFactory).SetEcho(True);
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
