{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_connection_test
notes:
  - this checks peer settings and shared encoder state
---
}
unit Http2.Client.ConnectionSettings.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Classes, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Common.Hpack, Http2.Client.Connection,
  Http2.Client.Connection.SendCredit,
  Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames, Http2.Client;

type
  TConnectionSettingsRegressionTest = class(TTestCase)
  published
    procedure TestHeaderDecoderUsesLocalSettings;
    procedure TestPooledConnectionCreatesEncoderLock;
    procedure TestHeaderTableSettingPreservesOtherPeerSettings;
    procedure TestSettingsFailureReleasesEncoderLock;
    procedure TestEveryFlowCreditWaiterReceivesItsOwnWake;
  end;

implementation

type
  TSendCreditWorker = class(TThread)
  private
    FConnection: TConnection;
    FStreamId: LongWord;
    FStarted: PRTLEvent;
    FDone: PRTLEvent;
    FStartedFlag: Boolean;
    FDoneFlag: Boolean;
    FGranted: LongWord;
    FErrorText: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConnection: TConnection;
      const AStreamId: LongWord);
    destructor Destroy; override;
    function WaitStarted(const ATimeoutMs: Integer): Boolean;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Granted: LongWord read FGranted;
    property ErrorText: string read FErrorText;
  end;

constructor TSendCreditWorker.Create(const AConnection: TConnection;
  const AStreamId: LongWord);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FConnection := AConnection;
  FStreamId := AStreamId;
  FStarted := RTLEventCreate;
  FDone := RTLEventCreate;
  FStartedFlag := False;
  FDoneFlag := False;
  FGranted := 0;
  FErrorText := '';
end;

destructor TSendCreditWorker.Destroy;
begin
  RTLEventDestroy(FStarted);
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TSendCreditWorker.Execute;
begin
  FStartedFlag := True;
  RTLEventSetEvent(FStarted);
  try
    FGranted := FConnection.AcquireSendCredit(FStreamId, 100, 2000, nil);
  except
    on E: Exception do
      FErrorText := E.ClassName + ': ' + E.Message;
  end;
  FDoneFlag := True;
  RTLEventSetEvent(FDone);
end;

function TSendCreditWorker.WaitStarted(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FStarted, ATimeoutMs);
  Result := FStartedFlag;
end;

function TSendCreditWorker.WaitDone(const ATimeoutMs: Integer): Boolean;
begin
  RTLEventWaitFor(FDone, ATimeoutMs);
  Result := FDoneFlag;
end;

procedure TConnectionSettingsRegressionTest.TestHeaderDecoderUsesLocalSettings;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Decoder: THpackCodec;
  Local: TConnectionSettings;
begin
  Sock := TMockSocket.Create;
  Local := TConnectionSettings.Defaults;
  Local.HeaderTableSize := 256;
  Local.MaxHeaderListSize := 8192;
  Conn := TConnection.Create(Sock, Local);
  Decoder := THpackCodec.Create;
  try
    Conn.HeaderDecoder := Decoder;
    AssertEquals('local table limit', LongWord(256), Decoder.DecoderMaxSize);
    AssertEquals('local header-list limit', LongWord(8192),
      Decoder.MaxHeaderListSize);
  finally
    Conn.Free;
    Decoder.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestPooledConnectionCreatesEncoderLock;
var
  Conn: TConnection;
  Pooled: THttpConnection;
begin
  Conn := TConnection.Create(TMockSocket.Create);
  Pooled := THttpConnection.Create(Conn, 'lock.example', 1);
  try
    AssertTrue('connection has its shared encoder lock',
      Conn.HeaderEncoderLock <> nil);
    AssertTrue('pool and connection use the same lock',
      Pooled.GetLock = Conn.HeaderEncoderLock);
  finally
    Pooled.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestHeaderTableSettingPreservesOtherPeerSettings;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Encoder: THpackCodec;
  EncoderLock: TCriticalSection;
  Peer: TConnectionSettings;
  Decoder: THpackCodec;
  Payload: TBytes;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Encoder := THpackCodec.Create;
  Decoder := THpackCodec.Create;
  EncoderLock := TCriticalSection.Create;
  Conn.HeaderEncoderLock := EncoderLock;
  Conn.HeaderEncoder := Encoder;
  Conn.HeaderDecoder := Decoder;
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Peer := TConnectionSettings.Defaults;
    Peer.InitialWindowSize := 1234;
    Peer.MaxConcurrentStreams := 7;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('first settings are acknowledged', Sock.WaitForWrites(3, 2000));
    SetLength(Payload, 6);
    Payload[0] := 0;
    Payload[1] := 1;
    Payload[2] := 0;
    Payload[3] := 0;
    Payload[4] := 1;
    Payload[5] := 0;
    Sock.FeedFrame(TFrame.Create(ftSettings, [], 0, Payload));
    AssertTrue('table setting is acknowledged', Sock.WaitForWrites(4, 2000));
    AssertEquals('initial window remains unchanged', LongWord(1234),
      Conn.PeerSettings.InitialWindowSize);
    AssertEquals('stream cap remains unchanged', LongWord(7),
      Conn.PeerSettings.MaxConcurrentStreams);
    AssertEquals('encoder applies peer table cap', LongWord(256),
      Encoder.EncoderMaxSize);
    AssertEquals('peer settings do not change local decoder cap',
      LongWord(4096), Decoder.DecoderMaxSize);
    AssertEquals('peer settings do not change local header-list cap',
      TConnectionSettings.Defaults.MaxHeaderListSize,
      Decoder.MaxHeaderListSize);
  finally
    Conn.Free;
    Encoder.Free;
    Decoder.Free;
    EncoderLock.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestSettingsFailureReleasesEncoderLock;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Encoder: THpackCodec;
  EncoderLock: TCriticalSection;
  Peer: TConnectionSettings;
  Payload: TBytes;
  Acquired: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Encoder := THpackCodec.Create;
  EncoderLock := TCriticalSection.Create;
  Conn.HeaderEncoderLock := EncoderLock;
  Conn.HeaderEncoder := Encoder;
  Conn.FlowControl.OpenStream(1);
  try
    Conn.Start;
    AssertTrue('preface and initial settings are written',
      Sock.WaitForWrites(2, 2000));
    Peer := TConnectionSettings.Defaults;
    Peer.InitialWindowSize := 1;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('first settings are acknowledged', Sock.WaitForWrites(3, 2000));

    SetLength(Payload, 4);
    Payload[0] := $7f;
    Payload[1] := $ff;
    Payload[2] := $ff;
    Payload[3] := $fe;
    Sock.FeedFrame(TFrame.Create(ftWindowUpdate, [], 1, Payload));
    Peer := Conn.PeerSettings;
    Peer.InitialWindowSize := 2;
    Sock.FeedFrame(BuildSettingsFrame(Peer));
    AssertTrue('invalid window change closes the connection',
      Conn.WaitForState(csClosed, 2000));
    Acquired := EncoderLock.TryEnter;
    if Acquired then
      EncoderLock.Leave;
    AssertTrue('settings failure releases encoder lock', Acquired);
  finally
    Conn.Free;
    Encoder.Free;
    EncoderLock.Free;
  end;
end;

procedure TConnectionSettingsRegressionTest.TestEveryFlowCreditWaiterReceivesItsOwnWake;
const
  WaiterCount = 4;
  StreamIds: array[0..WaiterCount - 1] of LongWord = (1, 3, 5, 7);
var
  I: Integer;
  Started: QWord;
  Registry: ISendCreditWaiterRegistry;
  Waiters: array[0..WaiterCount - 1] of ISendCreditWaiter;
  Sock: TMockSocket;
  Conn: TConnection;
  Workers: array[0..WaiterCount - 1] of TSendCreditWorker;
  Deadline: QWord;
begin
  Registry := NewSendCreditWaiterRegistry;
  for I := 0 to High(Waiters) do
  begin
    Waiters[I] := Registry.NewWaiter;
    Waiters[I].Register;
  end;
  Registry.WakeAll;
  for I := 0 to High(Waiters) do
  begin
    Started := GetTickCount64;
    Waiters[I].Wait(250);
    AssertTrue('waiter has its own pending wake ' + IntToStr(I),
      GetTickCount64 - Started < 100);
    Waiters[I] := nil;
  end;
  Registry := nil;

  FillChar(Workers, SizeOf(Workers), 0);
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    for I := 0 to High(StreamIds) do
      Conn.RegisterStream(StreamIds[I], nil);
    for I := 0 to High(Workers) do
    begin
      Workers[I] := TSendCreditWorker.Create(Conn, StreamIds[I]);
      Workers[I].Start;
    end;
    for I := 0 to High(Workers) do
      AssertTrue('credit sender started ' + IntToStr(I),
        Workers[I].WaitStarted(1000));
    Deadline := GetTickCount64 + 2000;
    while (Conn.SendCreditWaiterCount < WaiterCount) and
          (GetTickCount64 < Deadline) do
      Sleep(1);
    AssertEquals('all senders parked before peer SETTINGS', WaiterCount,
      Conn.SendCreditWaiterCount);
    Conn.ApplyPeerSettingsValue(TConnectionSettings.Defaults);
    for I := 0 to High(Workers) do
    begin
      AssertTrue('credit sender woke after peer SETTINGS ' + IntToStr(I),
        Workers[I].WaitDone(500));
      AssertEquals('no sender error ' + IntToStr(I), '', Workers[I].ErrorText);
      AssertEquals('each sender reserves its requested credit ' + IntToStr(I),
        100, Workers[I].Granted);
    end;
  finally
    for I := 0 to High(Workers) do
      if Workers[I] <> nil then
      begin
        Workers[I].WaitFor;
        Workers[I].Free;
      end;
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TConnectionSettingsRegressionTest);
end.
