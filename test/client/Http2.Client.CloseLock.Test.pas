{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, pool, close, lock, reader_thread
notes:
  - this tests that a close that joins a thread never runs under the pool lock
    or under the encoder lock
  - this tests that a callback on the reader thread can close the client and
    can drop the last reference to it
  - every wait has a bound; a test that fails leaks the object that it could
    not stop, so that the failure is reported and the run does not hang
---
}
unit Http2.Client.CloseLock.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Observer, Http2.Client, Http2.Client.Core,
  Http2.Client.Pool, Http2.Client.Pool.Types, Http2.Client.Pool.Http2,
  Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.PoolStats.Test;

type
  /// a pooled entry whose Drain waits for the test
  TBlockingDrainConnection = class(TInterfacedObject, IPooledConnection)
  private
    FEntered: TEvent;
    FRelease: TEvent;
  public
    constructor Create;
    destructor Destroy; override;
    function ActiveStreams: Integer;
    function Eligible: Boolean;
    function Acquire(const ARequest: TStreamRequest; const ATimeoutMs: Integer;
      out AAcquired: Boolean): IHttpResponse;
    function AcquireUpgraded(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer): IHttpResponse;
    function Closed: Boolean;
    procedure Drain;
    procedure ReleaseIfIdle;
    function GetConn: TConnection;
    function GetOrigin: string;
    function GetLock: TCriticalSection;
    function GetKey: Pointer;
    property Entered: TEvent read FEntered;
    property Gate: TEvent read FRelease;
  end;

  /// runs one pool operation on its own thread
  TPoolOpThread = class(TThread)
  private
    FPool: TConnectionPool;
    FReap: Boolean;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const APool: TConnectionPool; const AReap: Boolean);
    destructor Destroy; override;
    property Done: TEvent read FDone;
  end;

  /// takes the pool lock with ConnectionCount, or the encoder lock with
  /// TryEnter, and says if it got it
  TLockProbe = class(TThread)
  private
    FPool: TConnectionPool;
    FEncoderLock: TCriticalSection;
    FGot: Boolean;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const APool: TConnectionPool;
      const AEncoderLock: TCriticalSection);
    destructor Destroy; override;
    property Done: TEvent read FDone;
    property Got: Boolean read FGot;
  end;

  /// an observer that runs one action on the thread that calls it
  TActionObserver = class(TBaseObserver)
  public
    Client: THttpClient;
    Hold: IHttpClient;
    Armed: Boolean;
    DropOnFrame: Boolean;
    CloseOnFrame: Boolean;
    ProbeOnClose: Boolean;
    EncoderLock: TCriticalSection;
    Probe: TLockProbe;
    Returned: TEvent;
    constructor Create;
    destructor Destroy; override;
    procedure OnConnectionClose(const AMessage: string;
      const ACode: THttp2ErrorCode); override;
    procedure OnFrameIn(const AFrame: TFrame); override;
  end;

  /// a factory that keeps its last socket, so the test can feed it later
  TKeepSocketFactory = class(TInterfacedObject, IHttp2SocketFactory)
  private
    FSocket: TMockSocket;
    FKeep: IHttp2Socket;
  public
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    property Socket: TMockSocket read FSocket;
  end;

  TCloseLockTest = class(TTestCase)
  private
    function NewPool: TConnectionPool;
    procedure CheckPoolLockFree(const AOp: TPoolOpThread;
      const AFake: TBlockingDrainConnection; const APool: TConnectionPool);
  published
    procedure TestPoolCloseDrainsOutsideThePoolLock;
    procedure TestReapIdleDrainsOutsideThePoolLock;
    procedure TestDrainClosesOutsideTheEncoderLock;
    procedure TestCloseOnTheReaderThreadReturns;
    procedure TestLastReferenceDroppedOnTheReaderThread;
  end;

implementation

const
  cWaitMs = 5000;
  cOrigin = 'a.example tls= protocol=0:0';

{ keeps an object alive on purpose: a failed test must not free an object
  whose thread it could not stop, because the free would join that thread }
procedure Leak(const AObject: IInterface);
begin
  if AObject <> nil then
    AObject._AddRef;
end;

{ TBlockingDrainConnection }

constructor TBlockingDrainConnection.Create;
begin
  inherited Create;
  FEntered := TEvent.Create(nil, True, False, '');
  FRelease := TEvent.Create(nil, True, False, '');
end;

destructor TBlockingDrainConnection.Destroy;
begin
  FRelease.SetEvent;
  FRelease.Free;
  FEntered.Free;
  inherited Destroy;
end;

function TBlockingDrainConnection.ActiveStreams: Integer;
begin
  Result := 0;
end;

function TBlockingDrainConnection.Eligible: Boolean;
begin
  Result := True;
end;

function TBlockingDrainConnection.Acquire(const ARequest: TStreamRequest;
  const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
begin
  AAcquired := False;
  Result := nil;
end;

function TBlockingDrainConnection.AcquireUpgraded(
  const ARequest: TStreamRequest; const ATimeoutMs: Integer): IHttpResponse;
begin
  Result := nil;
end;

function TBlockingDrainConnection.Closed: Boolean;
begin
  Result := False;
end;

procedure TBlockingDrainConnection.Drain;
begin
  FEntered.SetEvent;
  FRelease.WaitFor(30000);
end;

procedure TBlockingDrainConnection.ReleaseIfIdle;
begin
end;

function TBlockingDrainConnection.GetConn: TConnection;
begin
  Result := nil;
end;

function TBlockingDrainConnection.GetOrigin: string;
begin
  Result := 'a.example';
end;

function TBlockingDrainConnection.GetLock: TCriticalSection;
begin
  Result := nil;
end;

function TBlockingDrainConnection.GetKey: Pointer;
begin
  Result := Pointer(Self);
end;

{ TPoolOpThread }

constructor TPoolOpThread.Create(const APool: TConnectionPool;
  const AReap: Boolean);
begin
  FPool := APool;
  FReap := AReap;
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TPoolOpThread.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TPoolOpThread.Execute;
begin
  try
    if FReap then
      FPool.ReapIdle
    else
      FPool.Close;
  finally
    FDone.SetEvent;
  end;
end;

{ TLockProbe }

constructor TLockProbe.Create(const APool: TConnectionPool;
  const AEncoderLock: TCriticalSection);
begin
  FPool := APool;
  FEncoderLock := AEncoderLock;
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TLockProbe.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TLockProbe.Execute;
begin
  try
    if FEncoderLock <> nil then
    begin
      FGot := FEncoderLock.TryEnter;
      if FGot then
        FEncoderLock.Release;
    end
    else
    begin
      FPool.ConnectionCount;
      FGot := True;
    end;
  finally
    FDone.SetEvent;
  end;
end;

{ TActionObserver }

constructor TActionObserver.Create;
begin
  inherited Create;
  Returned := TEvent.Create(nil, True, False, '');
end;

destructor TActionObserver.Destroy;
begin
  Returned.Free;
  inherited Destroy;
end;

procedure TActionObserver.OnConnectionClose(const AMessage: string;
  const ACode: THttp2ErrorCode);
begin
  if ProbeOnClose then
  begin
    ProbeOnClose := False;
    Probe := TLockProbe.Create(nil, EncoderLock);
    Probe.WaitFor;
  end;
end;

procedure TActionObserver.OnFrameIn(const AFrame: TFrame);
begin
  if not Armed then
    Exit;
  Armed := False;
  if CloseOnFrame then
    Client.Close                    // on the reader thread
  else if DropOnFrame then
    Hold := nil;                    // the last reference, on the reader thread
  Returned.SetEvent;
end;

{ TKeepSocketFactory }

function TKeepSocketFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  FSocket := TMockSocket.Create;
  FSocket.AutoRespondToRequestHeaders('200', nil, True);
  FSocket.EnqueueSettings(TConnectionSettings.Defaults);
  FKeep := FSocket;
  Result := FSocket;
end;

{ TCloseLockTest }

function TCloseLockTest.NewPool: TConnectionPool;
begin
  Result := TConnectionPool.Create(TSettingsMockFactory.Create(True), 2, 4, 8,
    50, 50, 1);
end;

{ the operation of AOp is blocked in the Drain of AFake: another thread must
  get the pool lock now }
procedure TCloseLockTest.CheckPoolLockFree(const AOp: TPoolOpThread;
  const AFake: TBlockingDrainConnection; const APool: TConnectionPool);
var
  Probe: TLockProbe;
  Got: Boolean;
begin
  Probe := TLockProbe.Create(APool, nil);
  try
    Got := Probe.Done.WaitFor(cWaitMs) = wrSignaled;
    AFake.Gate.SetEvent;         // so that a failure still unwinds
    AssertTrue('the pool lock is free while a Drain is blocked', Got);
    AssertTrue('the operation ends once the Drain ends',
      AOp.Done.WaitFor(cWaitMs) = wrSignaled);
  finally
    AFake.Gate.SetEvent;
    AOp.WaitFor;
    Probe.WaitFor;
    Probe.Free;
  end;
end;

procedure TCloseLockTest.TestPoolCloseDrainsOutsideThePoolLock;
var
  Pool: TConnectionPool;
  Fake: TBlockingDrainConnection;
  Ref: IPooledConnection;
  Op: TPoolOpThread;
begin
  Pool := NewPool;
  Fake := TBlockingDrainConnection.Create;
  Ref := Fake;
  try
    Pool.AddForTest(cOrigin, Ref);
    Op := TPoolOpThread.Create(Pool, False);
    try
      AssertTrue('Close reaches the Drain',
        Fake.Entered.WaitFor(cWaitMs) = wrSignaled);
      CheckPoolLockFree(Op, Fake, Pool);
    finally
      Fake.Gate.SetEvent;
      Op.WaitFor;
      Op.Free;
    end;
  finally
    Ref := nil;
    Pool.Free;
  end;
end;

procedure TCloseLockTest.TestReapIdleDrainsOutsideThePoolLock;
var
  Pool: TConnectionPool;
  Fake: TBlockingDrainConnection;
  Ref: IPooledConnection;
  Op: TPoolOpThread;
  Limit: QWord;
begin
  Pool := NewPool;                  // the idle timeout is 1 ms
  Fake := TBlockingDrainConnection.Create;
  Ref := Fake;
  try
    Pool.AddForTest(cOrigin, Ref);
    Pool.TouchForTest(Ref);         // from now on the entry is idle
    // ReapIdle drains the entry once 1 ms has passed: the first call that
    // runs late enough ends in the blocked Drain
    Limit := GetTickCount64 + cWaitMs;
    Op := TPoolOpThread.Create(Pool, True);
    try
      while Fake.Entered.WaitFor(1) <> wrSignaled do
      begin
        if Op.Done.WaitFor(0) = wrSignaled then
        begin
          Op.WaitFor;
          Op.Free;
          Op := TPoolOpThread.Create(Pool, True);
        end;
        if GetTickCount64 >= Limit then
          Break;
      end;
      AssertTrue('ReapIdle reaches the Drain',
        Fake.Entered.WaitFor(cWaitMs) = wrSignaled);
      CheckPoolLockFree(Op, Fake, Pool);
    finally
      Fake.Gate.SetEvent;
      Op.WaitFor;
      Op.Free;
    end;
  finally
    Ref := nil;
    Pool.Free;
  end;
end;

procedure TCloseLockTest.TestDrainClosesOutsideTheEncoderLock;
var
  Sock: TMockSocket;
  Conn: TConnection;
  H: IPooledConnection;
  Obs: TActionObserver;
  ObsRef: IHttp2Observer;
begin
  Sock := TMockSocket.Create;
  Sock.EnqueueSettings(TConnectionSettings.Defaults);
  Conn := TConnection.Create(Sock);
  Obs := TActionObserver.Create;
  ObsRef := Obs;
  Conn.Notifications.SetObserver(ObsRef);
  H := THttpConnection.Create(Conn, 'a.example', 8);
  Obs.EncoderLock := H.GetLock;
  Obs.ProbeOnClose := True;
  Conn.Start;
  H.Drain;                          // the close emits OnConnectionClose
  AssertTrue('the close ran', Obs.Probe <> nil);
  AssertTrue('another thread takes the encoder lock during the close',
    Obs.Probe.Got);
  Obs.Probe.Free;
  H := nil;
end;

procedure TCloseLockTest.TestCloseOnTheReaderThreadReturns;
var
  Obs: TActionObserver;
  ObsRef: IHttp2Observer;
  Client: IHttpClient;
  Factory: TKeepSocketFactory;
  FactoryRef: IHttp2SocketFactory;
  Ping: TBytes;
begin
  Obs := TActionObserver.Create;
  ObsRef := Obs;
  Factory := TKeepSocketFactory.Create;
  FactoryRef := Factory;
  Client := THttpClientFactory.Create
    .WithSocketFactory(FactoryRef).WithObserver(ObsRef).Build;
  Obs.Client := Client as THttpClient;
  ReadAllBodyBytes(Client.Send(
    THttpRequest.Create(hmGet, 'https://api.example/x')).Body);
  // the connection is idle and in the pool; the next frame makes the
  // reader thread call Client.Close
  SetLength(Ping, 8);
  FillChar(Ping[0], 8, 0);
  Obs.CloseOnFrame := True;
  Obs.Armed := True;
  Factory.Socket.EnqueuePing(Ping, False);
  if Obs.Returned.WaitFor(cWaitMs) <> wrSignaled then
  begin
    Leak(Client);
    Leak(ObsRef);
    Fail('Client.Close did not return on the reader thread');
  end;
  Client.Close;                     // from this thread: joins the reader
end;

procedure TCloseLockTest.TestLastReferenceDroppedOnTheReaderThread;
var
  Obs: TActionObserver;
  ObsRef: IHttp2Observer;
  Client: IHttpClient;
  Factory: TKeepSocketFactory;
  FactoryRef: IHttp2SocketFactory;
  Ping: TBytes;
  Limit: QWord;
begin
  Obs := TActionObserver.Create;
  ObsRef := Obs;
  Factory := TKeepSocketFactory.Create;
  FactoryRef := Factory;
  Client := THttpClientFactory.Create
    .WithSocketFactory(FactoryRef).WithObserver(ObsRef).Build;
  ReadAllBodyBytes(Client.Send(
    THttpRequest.Create(hmGet, 'https://api.example/x')).Body);
  // the observer now owns the only reference to the client
  Obs.DropOnFrame := True;
  Obs.Hold := Client;
  Client := nil;
  SetLength(Ping, 8);
  FillChar(Ping[0], 8, 0);
  Obs.Armed := True;
  Factory.Socket.EnqueuePing(Ping, False);
  if Obs.Returned.WaitFor(cWaitMs) <> wrSignaled then
  begin
    Leak(Obs.Hold);
    Leak(ObsRef);
    Fail('the callback that drops the last reference did not return');
  end;
  // the connection frees itself on a cleanup thread, after the reader ends
  Limit := GetTickCount64 + cWaitMs;
  while (PendingConnectionCleanups > 0) and (GetTickCount64 < Limit) do
    TThread.Yield;
  AssertEquals('the cleanup thread ended', 0, PendingConnectionCleanups);
end;

initialization
  RegisterTest(TCloseLockTest);

end.
