{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, websocket, tunnel, lease
notes:
  - this checks the tunnel over a stream lease with the scripted frame peer of the mock socket tests
  - the tests of the GET lease use a request that ends on the local side
  - the tests of the open request stream use a KeepOpen lease (story A4): they send DATA, end the send side and park a sender for credit
  - the race tests start a parked sender and call Reset or Release while the sender waits for credit
---
}
unit Http2.Client.WebSocket.LeaseTunnel.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Errors,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Stream.Types,
  Http2.Client.Tunnel.Types, Http2.Client.WebSocket.LeaseTunnel,
  Http2.Client.MockSocket.Support, Http2.Client.MockSocket.Frames;

type
  /// calls Reset many times from its own thread
  TResetWorker = class(TThread)
  private
    FTunnel: IH2Tunnel;
    FFailed: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const ATunnel: IH2Tunnel);
    property Failed: Boolean read FFailed;
  end;

  /// sends AData through the tunnel from its own thread and records how the call ended
  TParkedSendWorker = class(TThread)
  private
    FTunnel: IH2Tunnel;
    FData: TBytes;
    FRaised: Boolean;
    FErrorText: string;
    FEndedAt: QWord;
  protected
    procedure Execute; override;
  public
    constructor Create(const ATunnel: IH2Tunnel; const AData: TBytes);
    /// True when SendData raised EHttpConnectionError
    property Raised: Boolean read FRaised;
    /// the class and the message of any other exception
    property ErrorText: string read FErrorText;
    /// the tick count when the call ended
    property EndedAt: QWord read FEndedAt;
  end;

  TLeaseTunnelTest = class(TTestCase)
  private
    FSock: TMockSocket;
    FConn: TConnection;
    FServer: TScriptedServer;
    FAlloc: TStreamIdAllocator;
    FLock: TCriticalSection;
    FLease: TStreamLease;
    FKeep: IConnectionStream;
    FTunnel: IH2Tunnel;
    /// open the GET lease, answer 200 without END_STREAM and build the tunnel
    procedure OpenTunnel;
    /// open a KeepOpen POST lease on stream 1 (HEADERS only), answer 200 and build the tunnel
    procedure OpenKeepOpenTunnel;
    /// start a KeepOpen POST lease on the next stream id; the caller holds ALease through AKeep
    procedure StartKeepOpenLease(out ALease: TStreamLease; out AKeep: IConnectionStream);
    /// send SETTINGS with the initial window AWindow and wait until the client applied it
    procedure SetPeerWindow(const AWindow: LongWord);
    /// the loop of the race tests: a parked sender, then Reset or Release from this thread
    procedure RunParkedSenderRaces(const AByReset: Boolean);
    /// count the frames of AType that the client wrote, waiting up to ATimeoutMs
    /// for at least AExpected of them
    function WaitForFrameCount(const AType: TFrameType; const AExpected,
      ATimeoutMs: Integer): Integer;
    /// read the octets that are ready; returns the ReadSome result
    function ReadSomeText(out AText: string): Integer;
    /// poll ReadSome until it returns a count other than -1, or the time passes
    function WaitForOctets(out AText: string; const ATimeoutMs: Integer): Integer;
    /// count the RST_STREAM frames that the client wrote, waiting up to ATimeoutMs
    /// for at least AExpected of them
    function WaitForRstCount(const AExpected, ATimeoutMs: Integer): Integer;
    function DataFrameCount: Integer;
    function RstCodeOfFirstFrame: THttp2ErrorCode;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestReadSomeDeliversThePeerData;
    procedure TestPollWithNoOctetGivesMinusOne;
    procedure TestPeerEndGivesZeroAndEnds;
    procedure TestPeerResetIsAbnormal;
    procedure TestResetPostsOneRstCancel;
    procedure TestResetTwiceAndReleasePostsOnce;
    procedure TestResetAfterPeerEndPostsNothing;
    procedure TestResetAfterReleasePostsOneRst;
    procedure TestResetFromTwoThreadsPostsOnce;
    procedure TestEndSendOnHalfClosedSideSendsNothing;
    procedure TestSendDataRaisesAfterPeerReset;
    procedure TestSendDataRaisesAfterRelease;
    procedure TestReadSomeRaisesAfterRelease;
    procedure TestTunnelNeedsThePoolLock;
    procedure TestOpenStreamSendDataIsDataWithoutEndStream;
    procedure TestOpenStreamEndSendEndsTheStream;
    procedure TestKeepOpenSendAfterPeerEndUsesCredit;
    procedure TestKeepOpenSendAfterPeerEndWithoutCreditRaisesAtOnce;
    procedure TestKeepOpenSendAfterLocalEndRaises;
    procedure TestSendOfThreeFrameSizesGivesThreeDataFrames;
    procedure TestSendBeyondWindowWaitsForWindowUpdate;
    procedure TestParkedSenderReturnsWithinOneSecondAfterReset;
    procedure TestParkedSenderReturnsWithinOneSecondAfterRelease;
    procedure TestParkedSenderRaceLoopForReset;
    procedure TestParkedSenderRaceLoopForRelease;
  end;

implementation

const
  /// the poll of the request: the body-read time of the WebSocket poll
  cPollMs = 100;
  /// number of races per race test
  cRaceLoops = 100;
  /// a parked sender that returns this late after Reset or Release fails the test
  cReturnLimitMs = 1000;

function ToBytes(const AText: string): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
    Result[I - 1] := Ord(AText[I]);
end;

{ TResetWorker }

constructor TResetWorker.Create(const ATunnel: IH2Tunnel);
begin
  inherited Create(True);
  FTunnel := ATunnel;
  FreeOnTerminate := False;
end;

procedure TResetWorker.Execute;
var
  I: Integer;
begin
  try
    for I := 1 to 100 do
      FTunnel.Reset;
  except
    FFailed := True;
  end;
end;

{ TParkedSendWorker }

constructor TParkedSendWorker.Create(const ATunnel: IH2Tunnel; const AData: TBytes);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FTunnel := ATunnel;
  FData := AData;
  FRaised := False;
  FErrorText := '';
  FEndedAt := 0;
end;

procedure TParkedSendWorker.Execute;
begin
  try
    FTunnel.SendData(FData);
  except
    on E: EHttpConnectionError do
      FRaised := True;
    on E: Exception do
      FErrorText := E.ClassName + ': ' + E.Message;
  end;
  FEndedAt := GetTickCount64;
end;

{ TLeaseTunnelTest }

procedure TLeaseTunnelTest.SetUp;
begin
  inherited SetUp;
  FSock := TMockSocket.Create;
  FConn := TConnection.Create(FSock);
  FServer := TScriptedServer.Create(FSock);
  FAlloc := TStreamIdAllocator.Create;
  FLock := TCriticalSection.Create;
  FConn.Start;
  AssertTrue('connection opens', FConn.WaitForState(csOpen, 2000));
  FServer.SendSettings(TConnectionSettings.Defaults);
end;

procedure TLeaseTunnelTest.TearDown;
begin
  FTunnel := nil;
  FKeep := nil;
  FLease := nil;
  FLock.Free;
  FAlloc.Free;
  FServer.Free;
  FConn.Free;
  inherited TearDown;
end;

procedure TLeaseTunnelTest.OpenTunnel;
var
  Req: TStreamRequest;
begin
  Req := TStreamRequest.WithMethod(hmGet, 'api.example:443').WithPath('/')
    .WithBodyReadTimeout(cPollMs);
  FLease := TStreamLease.Create(FConn, FAlloc, Req);
  FKeep := FLease;
  FLease.WaitLock := FLock;
  FLease.Start;
  FServer.SendHeaders(1, '200', False);
  FLock.Acquire;
  try
    AssertTrue('response headers received', FLease.WaitForResponseHeader(2000));
  finally
    FLock.Release;
  end;
  AssertEquals('status 200', 200, FLease.StatusCode);
  FTunnel := TLeaseTunnel.Create(FLease, FConn);
end;

procedure TLeaseTunnelTest.OpenKeepOpenTunnel;
begin
  StartKeepOpenLease(FLease, FKeep);
  FServer.SendHeaders(1, '200', False);
  FLock.Acquire;
  try
    AssertTrue('response headers received', FLease.WaitForResponseHeader(2000));
  finally
    FLock.Release;
  end;
  AssertEquals('status 200', 200, FLease.StatusCode);
  FTunnel := TLeaseTunnel.Create(FLease, FConn);
end;

procedure TLeaseTunnelTest.StartKeepOpenLease(out ALease: TStreamLease;
  out AKeep: IConnectionStream);
var
  Req: TStreamRequest;
begin
  Req := TStreamRequest.WithMethod(hmPost, 'api.example:443').WithPath('/')
    .WithKeepOpen.WithBodyReadTimeout(cPollMs);
  ALease := TStreamLease.Create(FConn, FAlloc, Req);
  AKeep := ALease;
  ALease.WaitLock := FLock;
  // the pool calls Start under its lock, as the pool does
  FLock.Acquire;
  try
    ALease.Start;
  finally
    FLock.Release;
  end;
end;

procedure TLeaseTunnelTest.SetPeerWindow(const AWindow: LongWord);
var
  Settings: TConnectionSettings;
  Deadline: QWord;
begin
  Settings := TConnectionSettings.Defaults;
  Settings.InitialWindowSize := AWindow;
  FServer.SendSettings(Settings);
  Deadline := GetTickCount64 + 2000;
  while (FConn.PeerSettings.InitialWindowSize <> AWindow) and
    (GetTickCount64 < Deadline) do
    Sleep(5);
  AssertEquals('the peer window is applied', AWindow,
    FConn.PeerSettings.InitialWindowSize);
end;

procedure TLeaseTunnelTest.RunParkedSenderRaces(const AByReset: Boolean);
var
  I, J, Slow: Integer;
  Lease: TStreamLease;
  Keep: IConnectionStream;
  Tunnel: IH2Tunnel;
  Worker: TParkedSendWorker;
  Started, Elapsed: QWord;
  Failures: string;
begin
  SetPeerWindow(0);
  Slow := 0;
  Failures := '';
  for I := 1 to cRaceLoops do
  begin
    StartKeepOpenLease(Lease, Keep);
    Tunnel := TLeaseTunnel.Create(Lease, FConn);
    Worker := TParkedSendWorker.Create(Tunnel, ToBytes('race'));
    try
      Worker.Start;
      // a varying delay moves the reset across the park of the sender
      for J := 1 to I mod 37 do
        Sleep(0);
      Started := GetTickCount64;
      if AByReset then
        Tunnel.Reset
      else
        Tunnel.Release;
      Worker.WaitFor;
      Elapsed := Worker.EndedAt - Started;
      if Worker.ErrorText <> '' then
        Failures := Failures + Format(' loop %d: %s;', [I, Worker.ErrorText]);
      if (not Worker.Raised) and (Worker.ErrorText = '') then
        Failures := Failures + Format(' loop %d: the send did not raise;', [I]);
      if Elapsed >= cReturnLimitMs then
      begin
        Inc(Slow);
        // the first slow return is the result: the later loops would wait too
        Break;
      end;
    finally
      Worker.Free;
    end;
    Tunnel := nil;
    Keep := nil;
    Lease := nil;
  end;
  AssertEquals('no sender raised another error:' + Failures, '', Trim(Failures));
  AssertEquals(Format('senders that returned %d ms or more after the stop (of %d races)',
    [cReturnLimitMs, cRaceLoops]), 0, Slow);
  AssertEquals('no DATA frame was sent', 0, WaitForFrameCount(ftData, 1, 100));
end;

function TLeaseTunnelTest.WaitForFrameCount(const AType: TFrameType;
  const AExpected, ATimeoutMs: Integer): Integer;
var
  Frames: TArray<TFrame>;
  I, Count: Integer;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    Count := 0;
    Frames := FSock.OutboundFrames(True);
    for I := 0 to High(Frames) do
      if Frames[I].Header.FrameType = AType then
        Inc(Count);
    if (Count >= AExpected) or (GetTickCount64 >= Deadline) then
      Exit(Count);
    Sleep(5);
  end;
end;

function TLeaseTunnelTest.ReadSomeText(out AText: string): Integer;
var
  Buf: array[0..63] of Byte;
begin
  Result := FTunnel.ReadSome(Buf, SizeOf(Buf), cPollMs);
  AText := '';
  if Result > 0 then
  begin
    SetLength(AText, Result);
    Move(Buf, AText[1], Result);
  end;
end;

function TLeaseTunnelTest.WaitForOctets(out AText: string;
  const ATimeoutMs: Integer): Integer;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  repeat
    Result := ReadSomeText(AText);
    if Result <> -1 then
      Exit;
  until GetTickCount64 >= Deadline;
end;

function TLeaseTunnelTest.WaitForRstCount(const AExpected,
  ATimeoutMs: Integer): Integer;
var
  Frames: TArray<TFrame>;
  I, Count: Integer;
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    Count := 0;
    Frames := FSock.OutboundFrames(True);
    for I := 0 to High(Frames) do
      if Frames[I].Header.FrameType = ftRstStream then
        Inc(Count);
    if (Count >= AExpected) or (GetTickCount64 >= Deadline) then
      Exit(Count);
    Sleep(5);
  end;
end;

function TLeaseTunnelTest.DataFrameCount: Integer;
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Result := 0;
  Frames := FSock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if Frames[I].Header.FrameType = ftData then
      Inc(Result);
end;

function TLeaseTunnelTest.RstCodeOfFirstFrame: THttp2ErrorCode;
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  Result := ecNoError;
  Frames := FSock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if Frames[I].Header.FrameType = ftRstStream then
    begin
      ParseRstStream(Frames[I], Result);
      Exit;
    end;
end;

procedure TLeaseTunnelTest.TestReadSomeDeliversThePeerData;
var
  Text: string;
begin
  OpenTunnel;
  FSock.EnqueueData(1, ToBytes('hello'), False);
  AssertEquals('five octets read', 5, WaitForOctets(Text, 2000));
  AssertEquals('octets in order', 'hello', Text);
  AssertFalse('the stream is not ended', FTunnel.IsEnded);
end;

procedure TLeaseTunnelTest.TestPollWithNoOctetGivesMinusOne;
var
  Text: string;
begin
  OpenTunnel;
  AssertEquals('a poll with no octet gives -1', -1, ReadSomeText(Text));
  AssertFalse('the stream is not ended by a poll', FTunnel.IsEnded);
  AssertFalse('the stream is not abnormal after a poll', FTunnel.EndedAbnormally);
  // a later DATA frame still reaches the reader
  FSock.EnqueueData(1, ToBytes('abc'), False);
  AssertEquals('the later octets arrive', 3, WaitForOctets(Text, 2000));
  AssertEquals('later octets', 'abc', Text);
end;

procedure TLeaseTunnelTest.TestPeerEndGivesZeroAndEnds;
var
  Text: string;
begin
  OpenTunnel;
  FSock.EnqueueData(1, ToBytes('x'), True);
  AssertEquals('the last octet', 1, WaitForOctets(Text, 2000));
  AssertEquals('the octet', 'x', Text);
  AssertEquals('END_STREAM gives 0', 0, WaitForOctets(Text, 2000));
  AssertTrue('the stream is ended', FTunnel.IsEnded);
  AssertFalse('a normal end is not abnormal', FTunnel.EndedAbnormally);
  AssertEquals('no RST for a normal end', 0, WaitForRstCount(1, 100));
end;

procedure TLeaseTunnelTest.TestPeerResetIsAbnormal;
var
  Text: string;
  Raised: Boolean;
begin
  OpenTunnel;
  FServer.SendRstStream(1, ecCancel);
  Raised := False;
  try
    WaitForOctets(Text, 2000);
  except
    on E: EHttpStreamError do
      Raised := True;
  end;
  AssertTrue('the reader raises the peer reset', Raised);
  AssertTrue('the stream ended abnormally', FTunnel.EndedAbnormally);
  AssertTrue('the stream is ended', FTunnel.IsEnded);
  Raised := False;
  try
    FTunnel.SendData(ToBytes('late'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('a send after the reset raises', Raised);
  FTunnel.Reset;
  AssertEquals('no RST for a reset that the peer sent', 0, WaitForRstCount(1, 100));
end;

procedure TLeaseTunnelTest.TestResetPostsOneRstCancel;
begin
  OpenTunnel;
  AssertFalse('the stream is open', FTunnel.IsEnded);
  FTunnel.Reset;
  AssertEquals('one RST_STREAM', 1, WaitForRstCount(1, 2000));
  AssertTrue('the code is CANCEL', RstCodeOfFirstFrame = ecCancel);
  AssertTrue('the tunnel is ended', FTunnel.IsEnded);
  AssertFalse('a local reset is not an abnormal end', FTunnel.EndedAbnormally);
end;

procedure TLeaseTunnelTest.TestResetTwiceAndReleasePostsOnce;
begin
  OpenTunnel;
  FTunnel.Reset;
  FTunnel.Reset;
  FTunnel.Release;
  FTunnel.Reset;
  FTunnel.Release;
  AssertEquals('one RST_STREAM for all calls', 1, WaitForRstCount(1, 2000));
  AssertEquals('still one after a short wait', 1, WaitForRstCount(2, 100));
end;

procedure TLeaseTunnelTest.TestResetAfterPeerEndPostsNothing;
var
  Text: string;
begin
  OpenTunnel;
  FSock.EnqueueData(1, ToBytes('x'), True);
  AssertEquals('the octet', 1, WaitForOctets(Text, 2000));
  AssertEquals('END_STREAM gives 0', 0, WaitForOctets(Text, 2000));
  FTunnel.Reset;
  AssertEquals('a closed stream takes no RST', 0, WaitForRstCount(1, 100));
  AssertTrue('the tunnel is ended', FTunnel.IsEnded);
end;

procedure TLeaseTunnelTest.TestResetAfterReleasePostsOneRst;
begin
  OpenTunnel;
  FTunnel.Release;
  AssertEquals('release sends nothing', 0, WaitForRstCount(1, 100));
  FTunnel.Reset;
  AssertEquals('reset after release sends one RST', 1, WaitForRstCount(1, 2000));
  AssertTrue('the tunnel is ended', FTunnel.IsEnded);
end;

procedure TLeaseTunnelTest.TestResetFromTwoThreadsPostsOnce;
var
  A, B: TResetWorker;
begin
  OpenTunnel;
  A := TResetWorker.Create(FTunnel);
  B := TResetWorker.Create(FTunnel);
  try
    A.Start;
    B.Start;
    A.WaitFor;
    B.WaitFor;
    AssertFalse('no call raised in thread A', A.Failed);
    AssertFalse('no call raised in thread B', B.Failed);
    AssertEquals('one RST_STREAM for 200 calls', 1, WaitForRstCount(1, 2000));
    AssertEquals('still one after a short wait', 1, WaitForRstCount(2, 100));
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TLeaseTunnelTest.TestEndSendOnHalfClosedSideSendsNothing;
var
  Raised: Boolean;
begin
  OpenTunnel;
  // the request of a GET ends on the local side: EndSend has nothing to send
  FTunnel.EndSend;
  FTunnel.EndSend;
  AssertEquals('no DATA frame from EndSend', 0, DataFrameCount);
  Raised := False;
  try
    FTunnel.SendData(ToBytes('no'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('SendData after the local side ended raises EHttpConnectionError', Raised);
  AssertEquals('no DATA frame from the refused send', 0, DataFrameCount);
end;

procedure TLeaseTunnelTest.TestSendDataRaisesAfterPeerReset;
var
  Text: string;
  Raised: Boolean;
begin
  OpenTunnel;
  FServer.SendRstStream(1, ecCancel);
  try
    WaitForOctets(Text, 2000);
  except
    // the reader raises the reset: the test checks the state after it
  end;
  Raised := False;
  try
    FTunnel.SendData(ToBytes('x'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('SendData after the peer reset raises', Raised);
  AssertEquals('no DATA after the reset', 0, DataFrameCount);
end;

procedure TLeaseTunnelTest.TestSendDataRaisesAfterRelease;
var
  Raised: Boolean;
begin
  OpenTunnel;
  FTunnel.Release;
  Raised := False;
  try
    FTunnel.SendData(ToBytes('x'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('SendData after release raises', Raised);
end;

procedure TLeaseTunnelTest.TestReadSomeRaisesAfterRelease;
var
  Text: string;
  Raised: Boolean;
begin
  OpenTunnel;
  FTunnel.Release;
  Raised := False;
  try
    ReadSomeText(Text);
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('ReadSome after release raises', Raised);
end;

procedure TLeaseTunnelTest.TestTunnelNeedsThePoolLock;
var
  Req: TStreamRequest;
  Lease: TStreamLease;
  Keep: IConnectionStream;
  Raised: Boolean;
  Tunnel: IH2Tunnel;
begin
  Req := TStreamRequest.WithMethod(hmGet, 'api.example:443').WithPath('/');
  Lease := TStreamLease.Create(FConn, FAlloc, Req);
  Keep := Lease;
  Raised := False;
  try
    Tunnel := TLeaseTunnel.Create(Lease, FConn);
  except
    on E: EHttpError do
      Raised := True;
  end;
  AssertTrue('a tunnel without the pool lock is refused', Raised);
  Tunnel := nil;
  Keep := nil;
end;

procedure TLeaseTunnelTest.TestOpenStreamSendDataIsDataWithoutEndStream;
var
  Frames: TArray<TFrame>;
  I: Integer;
begin
  OpenKeepOpenTunnel;
  FTunnel.SendData(ToBytes('ping'));
  AssertEquals('one DATA frame', 1, WaitForFrameCount(ftData, 1, 2000));
  Frames := FSock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if Frames[I].Header.FrameType = ftData then
      AssertFalse('DATA has no END_STREAM', Frames[I].IsEndStream);
  AssertFalse('the stream is open', FTunnel.IsEnded);
  AssertFalse('the stream is not abnormal', FTunnel.EndedAbnormally);
end;

procedure TLeaseTunnelTest.TestOpenStreamEndSendEndsTheStream;
var
  Frames: TArray<TFrame>;
  I, Last: Integer;
begin
  OpenKeepOpenTunnel;
  FTunnel.SendData(ToBytes('ping'));
  FTunnel.EndSend;
  FTunnel.EndSend;
  AssertEquals('DATA and the closing DATA', 2, WaitForFrameCount(ftData, 2, 2000));
  AssertEquals('no third DATA frame', 2, WaitForFrameCount(ftData, 3, 100));
  Frames := FSock.OutboundFrames(True);
  Last := -1;
  for I := 0 to High(Frames) do
    if Frames[I].Header.FrameType = ftData then
      Last := I;
  AssertTrue('the closing DATA carries END_STREAM', (Last >= 0) and Frames[Last].IsEndStream);
  AssertEquals('the closing DATA is empty', 0, Length(ExtractDataPayload(Frames[Last])));
  AssertFalse('the peer side is still open', FTunnel.IsEnded);
end;

procedure TLeaseTunnelTest.TestKeepOpenSendAfterPeerEndUsesCredit;
var
  Text: string;
  Frames: TArray<TFrame>;
  I: Integer;
begin
  OpenKeepOpenTunnel;
  FSock.EnqueueData(1, ToBytes('x'), True);
  AssertEquals('the octet', 1, WaitForOctets(Text, 2000));
  AssertEquals('END_STREAM gives 0', 0, WaitForOctets(Text, 2000));
  AssertFalse('the send side is still open', FTunnel.IsEnded);
  // the peer ended its side, but the window is open: the send goes out
  FTunnel.SendData(ToBytes('pong'));
  AssertEquals('one DATA frame for the send', 1, WaitForFrameCount(ftData, 1, 2000));
  Frames := FSock.OutboundFrames(True);
  for I := 0 to High(Frames) do
    if Frames[I].Header.FrameType = ftData then
      AssertFalse('the DATA has no END_STREAM', Frames[I].IsEndStream);
  AssertEquals('no RST_STREAM for the send', 0, WaitForRstCount(1, 100));
end;

procedure TLeaseTunnelTest.TestKeepOpenSendAfterPeerEndWithoutCreditRaisesAtOnce;
var
  Text: string;
  Raised: Boolean;
  Started, Elapsed: QWord;
begin
  SetPeerWindow(0);
  OpenKeepOpenTunnel;
  FSock.EnqueueData(1, ToBytes('x'), True);
  AssertEquals('the octet', 1, WaitForOctets(Text, 2000));
  AssertEquals('END_STREAM gives 0', 0, WaitForOctets(Text, 2000));
  Raised := False;
  Started := GetTickCount64;
  try
    FTunnel.SendData(ToBytes('pong'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  Elapsed := GetTickCount64 - Started;
  AssertTrue('a send without credit after the peer END raises', Raised);
  AssertTrue('the refusal does not wait for the credit timeout', Elapsed < 1000);
  AssertEquals('exactly one RST_STREAM', 1, WaitForRstCount(1, 2000));
  AssertEquals('the RST_STREAM carries CANCEL', Ord(ecCancel), Ord(RstCodeOfFirstFrame));
  Raised := False;
  try
    FTunnel.SendData(ToBytes('again'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('a second send raises too', Raised);
  AssertEquals('still one RST_STREAM', 1, WaitForRstCount(2, 100));
  AssertEquals('no DATA frame was sent', 0, DataFrameCount);
end;

procedure TLeaseTunnelTest.TestKeepOpenSendAfterLocalEndRaises;
var
  Raised: Boolean;
begin
  OpenKeepOpenTunnel;
  FTunnel.EndSend;
  AssertEquals('END_STREAM sent with an empty DATA frame', 1, WaitForFrameCount(ftData, 1, 2000));
  Raised := False;
  try
    FTunnel.SendData(ToBytes('no'));
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('a send after the local end raises', Raised);
  AssertEquals('no DATA after the local end', 1, WaitForFrameCount(ftData, 2, 100));
end;

procedure TLeaseTunnelTest.TestSendOfThreeFrameSizesGivesThreeDataFrames;
var
  Data: TBytes;
begin
  OpenKeepOpenTunnel;
  SetLength(Data, 3 * Integer(DefaultMaxFrameSize));
  FillChar(Data[0], Length(Data), Ord('z'));
  FTunnel.SendData(Data);
  AssertEquals('three DATA frames', 3, WaitForFrameCount(ftData, 3, 2000));
  AssertEquals('still three after a short wait', 3, WaitForFrameCount(ftData, 4, 100));
  AssertFalse('the stream is open', FTunnel.IsEnded);
end;

procedure TLeaseTunnelTest.TestSendBeyondWindowWaitsForWindowUpdate;
var
  Worker: TParkedSendWorker;
begin
  SetPeerWindow(4);
  OpenKeepOpenTunnel;
  Worker := TParkedSendWorker.Create(FTunnel, ToBytes('0123456789'));
  try
    Worker.Start;
    AssertEquals('the 4 octets of the window go out', 1,
      WaitForFrameCount(ftData, 1, 2000));
    Sleep(100);
    AssertFalse('the sender waits for credit', Worker.Finished);
    FServer.SendWindowUpdate(1, 6);
    Worker.WaitFor;
    AssertFalse('the send did not raise', Worker.Raised);
    AssertEquals('no other error', '', Worker.ErrorText);
    AssertEquals('the rest goes out as a second DATA frame', 2,
      WaitForFrameCount(ftData, 2, 2000));
  finally
    Worker.Free;
  end;
end;

procedure TLeaseTunnelTest.TestParkedSenderReturnsWithinOneSecondAfterReset;
var
  Worker: TParkedSendWorker;
  Started, Elapsed: QWord;
begin
  SetPeerWindow(0);
  OpenKeepOpenTunnel;
  Worker := TParkedSendWorker.Create(FTunnel, ToBytes('parked'));
  try
    Worker.Start;
    Sleep(200);
    AssertFalse('the sender is parked for credit', Worker.Finished);
    Started := GetTickCount64;
    FTunnel.Reset;
    Worker.WaitFor;
    Elapsed := Worker.EndedAt - Started;
    AssertTrue(Format('the parked sender returns within %d ms of Reset (it returned after %d ms)',
      [cReturnLimitMs, Elapsed]), Elapsed < cReturnLimitMs);
    AssertTrue('the parked send raises EHttpConnectionError', Worker.Raised);
    AssertEquals('no other error', '', Worker.ErrorText);
    AssertEquals('one RST_STREAM', 1, WaitForRstCount(1, 2000));
    AssertTrue('the code is CANCEL', RstCodeOfFirstFrame = ecCancel);
    AssertEquals('no DATA frame was sent', 0, WaitForFrameCount(ftData, 1, 100));
  finally
    Worker.Free;
  end;
end;

procedure TLeaseTunnelTest.TestParkedSenderReturnsWithinOneSecondAfterRelease;
var
  Worker: TParkedSendWorker;
  Started, Elapsed: QWord;
begin
  SetPeerWindow(0);
  OpenKeepOpenTunnel;
  Worker := TParkedSendWorker.Create(FTunnel, ToBytes('parked'));
  try
    Worker.Start;
    Sleep(200);
    AssertFalse('the sender is parked for credit', Worker.Finished);
    Started := GetTickCount64;
    FTunnel.Release;
    Worker.WaitFor;
    Elapsed := Worker.EndedAt - Started;
    AssertTrue(Format('the parked sender returns within %d ms of Release (it returned after %d ms)',
      [cReturnLimitMs, Elapsed]), Elapsed < cReturnLimitMs);
    AssertTrue('the parked send raises EHttpConnectionError', Worker.Raised);
    AssertEquals('no other error', '', Worker.ErrorText);
    AssertEquals('no DATA frame was sent', 0, WaitForFrameCount(ftData, 1, 100));
  finally
    Worker.Free;
  end;
end;

procedure TLeaseTunnelTest.TestParkedSenderRaceLoopForReset;
begin
  RunParkedSenderRaces(True);
end;

procedure TLeaseTunnelTest.TestParkedSenderRaceLoopForRelease;
begin
  RunParkedSenderRaces(False);
end;

initialization
  RegisterTest(TLeaseTunnelTest);

end.
