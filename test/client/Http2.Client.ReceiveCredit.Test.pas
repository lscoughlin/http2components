{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, receive_credit, flow_control
notes:
  - this checks that the stream credit follows the read of the application
  - the peer in this unit obeys the windows that the client gives to it
---
}
unit Http2.Client.ReceiveCredit.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Generics.Collections, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Client.MockSocket.Frames,
  Http2.Client.Messages, Http2.Client, Http2.Client.MockSocket.Support;

type
  TReceiveCreditTest = class(TTestCase)
  private
    FPeers: TObjectList<TObject>;
    FTotals: TArray<Int64>;
    FEnds: TArray<Boolean>;
    FFactory: IHttp2SocketFactory;
    FClient: IHttpClient;
    procedure AttachPeer(const ASocket: TMockSocket);
    procedure Start(const ATotals: array of Int64;
      const AEnds: array of Boolean; const AQueueBytes: Int64);
    function Peer: TObject;
    function Get(const APath: string): IHttpResponse;
    function ReadBody(const AResponse: IHttpResponse; const ACount: Int64;
      const ASlow: Boolean): Int64;
    procedure Kick;
    function WaitSent(const AIndex: Integer; const ACount: Int64): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestAdvertisedInitialWindowIsTheDefaultQueueBytes;
    procedure TestAdvertisedInitialWindowEqualsTheOption;
    procedure TestNoStreamWindowUpdateUntilTheApplicationReads;
    procedure TestSlowReaderGetsEightMiBThroughTheQueue;
    procedure TestStalledReaderOnOneStreamDoesNotStopAnother;
  end;

implementation

const
  cQueueBytes = 1048576;
  cWaitMs = 10000;

type
  /// a server that sends a response body of a set size on each stream. It
  /// sends DATA only while both receive windows of the client have credit,
  /// and it counts every WINDOW_UPDATE of the client
  TDownloadPeer = class
  private
    FSocket: TMockSocket;
    FTotals: array of Int64;
    FEnds: array of Boolean;
    FDone: array of Boolean;
    FReady: array of Boolean;
    FPingAcks: Integer;
    FIds: array of LongWord;
    FSent: array of Int64;
    FWindows: array of Int64;
    FInitial: Int64;
    FConnWindow: Int64;
    FSettingsSeen: Boolean;
    FConnUpdates: Integer;
    FStreamUpdates: Integer;
    FMaxUnacked: Int64;
    function GetSent(AIndex: Integer): Int64;
    procedure Flush;
    procedure OpenStream(const AStreamId: LongWord);
  public
    constructor Create(const ASocket: TMockSocket;
      const ATotals: TArray<Int64>; const AEnds: TArray<Boolean>);
    destructor Destroy; override;
    procedure OnClientFrame(const AFrame: TFrame);
    property PingAcks: Integer read FPingAcks;
    property Initial: Int64 read FInitial;
    property ConnUpdates: Integer read FConnUpdates;
    property StreamUpdates: Integer read FStreamUpdates;
    property MaxUnacked: Int64 read FMaxUnacked;
    property Sent[AIndex: Integer]: Int64 read GetSent;
  end;

constructor TDownloadPeer.Create(const ASocket: TMockSocket;
  const ATotals: TArray<Int64>; const AEnds: TArray<Boolean>);
var
  I: Integer;
begin
  inherited Create;
  FSocket := ASocket;
  SetLength(FTotals, Length(ATotals));
  SetLength(FEnds, Length(ATotals));
  SetLength(FDone, Length(ATotals));
  SetLength(FReady, Length(ATotals));
  SetLength(FIds, Length(ATotals));
  SetLength(FSent, Length(ATotals));
  SetLength(FWindows, Length(ATotals));
  for I := 0 to High(ATotals) do
  begin
    FTotals[I] := ATotals[I];
    FEnds[I] := AEnds[I];
  end;
  FInitial := 65535;
  FConnWindow := 65535;
  FSocket.OnClientFrame := OnClientFrame;
end;

destructor TDownloadPeer.Destroy;
begin
  FSocket.OnClientFrame := nil;
  inherited Destroy;
end;

function TDownloadPeer.GetSent(AIndex: Integer): Int64;
begin
  Result := FSent[AIndex];
end;

procedure TDownloadPeer.OpenStream(const AStreamId: LongWord);
var
  I: Integer;
begin
  // the mock sends the response HEADERS after this hook; the DATA waits for a
  // ping ack of the client (see the ping handling in OnClientFrame)
  for I := 0 to High(FIds) do
    if FIds[I] = 0 then
    begin
      FIds[I] := AStreamId;
      FWindows[I] := FInitial;
      FDone[I] := FTotals[I] = 0;
      Exit;
    end;
end;

procedure TDownloadPeer.Flush;
var
  I: Integer;
  N, Left: Int64;
  Progress, Last: Boolean;
  Chunk: TBytes;
begin
  repeat
    Progress := False;
    for I := 0 to High(FIds) do
    begin
      if (FIds[I] = 0) or FDone[I] or not FReady[I] then
        Continue;
      Left := FTotals[I] - FSent[I];
      N := Left;
      if N > 16384 then N := 16384;
      if N > FConnWindow then N := FConnWindow;
      if N > FWindows[I] then N := FWindows[I];
      Last := FEnds[I] and (N = Left);
      if (N = 0) and not Last then
        Continue;
      Chunk := nil;
      SetLength(Chunk, N);
      FSocket.FeedLocked(FrameToBytes(BuildDataFrame(FIds[I], Chunk, Last)));
      FSent[I] := FSent[I] + N;
      FConnWindow := FConnWindow - N;
      FWindows[I] := FWindows[I] - N;
      if FInitial - FWindows[I] > FMaxUnacked then
        FMaxUnacked := FInitial - FWindows[I];
      FDone[I] := Last;
      Progress := True;
    end;
  until not Progress;
end;

procedure TDownloadPeer.OnClientFrame(const AFrame: TFrame);
var
  I: Integer;
  Credit: LongWord;
begin
  case AFrame.Header.FrameType of
    ftSettings:
      if (not AFrame.IsAck) and (not FSettingsSeen) then
      begin
        FSettingsSeen := True;
        FInitial := TConnectionSettings.Decode(AFrame.Payload).InitialWindowSize;
      end;
    ftHeaders:
      OpenStream(AFrame.Header.StreamId);
    ftPing:
      if AFrame.IsAck then
      begin
        for I := 0 to High(FIds) do
          FReady[I] := True;
        FPingAcks := FPingAcks + 1;
      end;
    ftWindowUpdate:
      begin
        Credit := ParseWindowUpdate(AFrame);
        if AFrame.Header.StreamId = 0 then
        begin
          FConnWindow := FConnWindow + Credit;
          FConnUpdates := FConnUpdates + 1;
        end
        else
        begin
          FStreamUpdates := FStreamUpdates + 1;
          for I := 0 to High(FIds) do
            if FIds[I] = AFrame.Header.StreamId then
              FWindows[I] := FWindows[I] + Credit;
        end;
      end;
  end;
  Flush;
end;

{ TReceiveCreditTest }

procedure TReceiveCreditTest.SetUp;
begin
  FPeers := TObjectList<TObject>.Create(True);
end;

procedure TReceiveCreditTest.TearDown;
begin
  if FClient <> nil then
    FClient.Close;
  FClient := nil;
  FPeers.Free;
end;

procedure TReceiveCreditTest.AttachPeer(const ASocket: TMockSocket);
begin
  FPeers.Add(TDownloadPeer.Create(ASocket, FTotals, FEnds));
end;

procedure TReceiveCreditTest.Start(const ATotals: array of Int64;
  const AEnds: array of Boolean; const AQueueBytes: Int64);
var
  I: Integer;
  Builder: THttpClientFactory;
begin
  SetLength(FTotals, Length(ATotals));
  SetLength(FEnds, Length(ATotals));
  for I := 0 to High(ATotals) do
  begin
    FTotals[I] := ATotals[I];
    FEnds[I] := AEnds[I];
  end;
  FFactory := TMockSocketFactory.Create;
  (FFactory as TMockSocketFactory).OnDial := AttachPeer;
  (FFactory as TMockSocketFactory).SetResponse('200', nil, FTotals[0] = 0);
  Builder := THttpClientFactory.Create.WithSocketFactory(FFactory);
  if AQueueBytes > 0 then
    Builder := Builder.WithMaxReceiveQueueBytes(AQueueBytes);
  FClient := Builder.Build;
end;

function TReceiveCreditTest.Peer: TObject;
begin
  Result := FPeers[0];
end;

function TReceiveCreditTest.Get(const APath: string): IHttpResponse;
begin
  Result := FClient.Send(THttpRequest.Create(hmGet,
    'https://download.example' + APath));
end;

function TReceiveCreditTest.ReadBody(const AResponse: IHttpResponse;
  const ACount: Int64; const ASlow: Boolean): Int64;
var
  Buf: array[0..16383] of Byte;
  N: LongInt;
  Mark: Int64;
begin
  Result := 0;
  Mark := 0;
  while Result < ACount do
  begin
    N := AResponse.Body.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    Inc(Result, N);
    Inc(Mark, N);
    if ASlow and (Mark >= 65536) then
    begin
      Mark := 0;
      Sleep(1);
    end;
  end;
end;

procedure TReceiveCreditTest.Kick;
var
  Before: Integer;
  Deadline: QWord;
begin
  Before := TDownloadPeer(Peer).PingAcks;
  (FFactory as TMockSocketFactory).Socket(0).EnqueuePing(
    TBytes.Create(1, 2, 3, 4, 5, 6, 7, 8), False);
  Deadline := GetTickCount64 + QWord(cWaitMs);
  while (TDownloadPeer(Peer).PingAcks = Before) and
        (GetTickCount64 < Deadline) do
    Sleep(5);
  AssertTrue('the client answered the ping', TDownloadPeer(Peer).PingAcks > Before);
end;

function TReceiveCreditTest.WaitSent(const AIndex: Integer;
  const ACount: Int64): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(cWaitMs);
  while GetTickCount64 < Deadline do
  begin
    if TDownloadPeer(Peer).Sent[AIndex] >= ACount then
      Exit(True);
    Sleep(5);
  end;
  Result := False;
end;

procedure TReceiveCreditTest.TestAdvertisedInitialWindowIsTheDefaultQueueBytes;
begin
  Start([0], [True], 0);
  AssertEquals('status', 200, Get('/a').StatusCode);
  AssertEquals('initial window', cQueueBytes, TDownloadPeer(Peer).Initial);
end;

procedure TReceiveCreditTest.TestAdvertisedInitialWindowEqualsTheOption;
begin
  Start([0], [True], 262144);
  AssertEquals('status', 200, Get('/a').StatusCode);
  AssertEquals('initial window', 262144, TDownloadPeer(Peer).Initial);
end;

procedure TReceiveCreditTest.TestNoStreamWindowUpdateUntilTheApplicationReads;
const
  cBody = 98304;
var
  R: IHttpResponse;
  Deadline: QWord;
begin
  Start([cBody], [False], 0);
  R := Get('/a');
  Kick;
  AssertTrue('the peer sent the body', WaitSent(0, cBody));
  Sleep(200);
  AssertTrue('the connection credit returned on arrival',
    TDownloadPeer(Peer).ConnUpdates > 0);
  AssertEquals('no stream credit before the read', 0,
    TDownloadPeer(Peer).StreamUpdates);
  AssertEquals('read', cBody, ReadBody(R, cBody, False));
  Deadline := GetTickCount64 + QWord(cWaitMs);
  while (TDownloadPeer(Peer).StreamUpdates = 0) and
        (GetTickCount64 < Deadline) do
    Sleep(5);
  AssertTrue('stream credit after the read',
    TDownloadPeer(Peer).StreamUpdates > 0);
end;

procedure TReceiveCreditTest.TestSlowReaderGetsEightMiBThroughTheQueue;
const
  cBody = 8 * 1024 * 1024;
var
  R: IHttpResponse;
begin
  Start([cBody], [True], 0);
  R := Get('/a');
  Kick;
  AssertEquals('status', 200, R.StatusCode);
  AssertEquals('body size', cBody, ReadBody(R, cBody + 1, True));
  AssertTrue('the peer never had more than the queue in flight',
    TDownloadPeer(Peer).MaxUnacked <= cQueueBytes);
end;

procedure TReceiveCreditTest.TestStalledReaderOnOneStreamDoesNotStopAnother;
var
  First, Second: IHttpResponse;
begin
  Start([3 * 1024 * 1024, 262144], [False, True], 0);
  First := Get('/a');
  Second := Get('/b');
  Kick;
  AssertTrue('the first stream fills its window',
    WaitSent(0, cQueueBytes));
  AssertEquals('second body', 262144, ReadBody(Second, 262145, False));
  AssertEquals('one connection', 1,
    (FFactory as TMockSocketFactory).Dials);
  Sleep(100);
  AssertEquals('the stalled stream stays at its window', cQueueBytes,
    TDownloadPeer(Peer).Sent[0]);
  AssertEquals('status', 200, First.StatusCode);
end;

initialization
  RegisterTest(TReceiveCreditTest);
end.
