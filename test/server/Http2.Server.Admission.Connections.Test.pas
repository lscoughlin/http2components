{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, admission, queue, handler pool, connections, test, fpcunit
notes:
  - This unit tests that one handler pool serves several connections.
  - Stream ids are per connection, so two connections can queue a stream with
    the same id. A reset on one connection removes the queued entry of that
    stream object only.
  - The handlers park on an RTLEvent, so no test waits on wall-clock time to
    decide an order.
---
}
/// Unit tests for the queue entries of several connections in one pool
unit Http2.Server.Admission.Connections.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Server.Seam, Http2.Server.Stream, Http2.Server.StreamHost,
  Http2.Server.Limits, Http2.Server.Config, Http2.Server.Admission,
  Http2.Server.Admission.Test;

type
  /// tests of the queue entries of two connections
  TAdmissionConnectionsTest = class(TTestCase)
  private
    FLockA: TCriticalSection;
    FLockB: TCriticalSection;
    FHost: IStreamHost;
    FClock: TManualMonotonicClock;
    FPool: THandlerPool;
    FFactory: THttp2ServerFactory;
    FStreams: TObjectList<TServerStream>;
    FGate: TBlockingHandler;
    function NewStream(const ALock: TCriticalSection;
      const AStreamId: LongWord): TServerStream;
    function WaitRefCount(const AStream: TServerStream;
      const ACount, ATimeoutMs: Integer): Boolean;
  public
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // a reset of stream 1 on connection A leaves the queued stream 1 of B
    procedure TestResetDoesNotRemoveStreamOfOtherConnection;
  end;

implementation

{ TAdmissionConnectionsTest }

procedure TAdmissionConnectionsTest.SetUp;
begin
  inherited SetUp;
  FLockA := TCriticalSection.Create;
  FLockB := TCriticalSection.Create;
  FHost := TNullHost.Create;
  FClock := TManualMonotonicClock.Create(0);
  FStreams := TObjectList<TServerStream>.Create(True);
  FPool := nil;
  FGate := nil;
end;

procedure TAdmissionConnectionsTest.TearDown;
begin
  if FGate <> nil then
    FGate.Release;
  FreeAndNil(FPool);
  FStreams.Free;
  FClock := nil;
  FHost := nil;
  FLockB.Free;
  FLockA.Free;
  inherited TearDown;
end;

function TAdmissionConnectionsTest.NewStream(const ALock: TCriticalSection;
  const AStreamId: LongWord): TServerStream;
begin
  Result := TServerStream.Create(AStreamId, ALock, FHost, 65536, 65536);
  FStreams.Add(Result);
end;

function TAdmissionConnectionsTest.WaitRefCount(const AStream: TServerStream;
  const ACount, ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while (AStream.RefCount <> ACount) and (GetTickCount64 < Deadline) do
    Sleep(1);
  Result := AStream.RefCount = ACount;
end;

procedure TAdmissionConnectionsTest.TestResetDoesNotRemoveStreamOfOtherConnection;
var
  Busy: TServerStream;
  StreamA, StreamB: TServerStream;
  Deadline: QWord;
begin
  FGate := TBlockingHandler.Create(bmGate);
  FFactory := THttp2ServerFactory.Create
    .WithHandlerThreads(1)
    .WithQueue(TQueueOptions.Create
      .WithDepth(4)
      .WithMaxWaitMs(600000)
      .WithRefusalMode(rmRefuseStream))
    .WithClock(FClock)
    .WithGracefulStopTimeout(500)
    .WithHandler(FGate);
  FPool := THandlerPool.Create(FFactory);

  // the one handler thread is busy with a stream of connection A
  Busy := NewStream(FLockA, 3);
  AssertEquals('the busy request queues', Ord(asQueued),
    Ord(FPool.Admit(Busy)));
  AssertTrue('the handler runs', WaitRefCount(Busy, 2, 2000));
  Deadline := GetTickCount64 + 2000;
  while (FGate.StartedCount < 1) and (GetTickCount64 < Deadline) do
    Sleep(1);
  AssertEquals('the handler started', 1, FGate.StartedCount);

  // stream 1 of connection A and stream 1 of connection B both wait
  StreamA := NewStream(FLockA, 1);
  StreamB := NewStream(FLockB, 1);
  // B is first in the queue, so a match by id alone would find B first
  AssertEquals('stream B queues', Ord(asQueued), Ord(FPool.Admit(StreamB)));
  AssertEquals('stream A queues', Ord(asQueued), Ord(FPool.Admit(StreamA)));
  AssertEquals('two requests wait', 2, FPool.QueueLength);
  AssertEquals('the queue holds one reference of A', 2, StreamA.RefCount);
  AssertEquals('the queue holds one reference of B', 2, StreamB.RefCount);

  // connection A resets its stream 1
  AssertTrue('the entry of A is removed',
    FPool.RemoveStream(StreamA));
  AssertEquals('one request waits', 1, FPool.QueueLength);
  AssertEquals('A dropped its queue reference', 1, StreamA.RefCount);
  AssertEquals('B keeps its queue reference', 2, StreamB.RefCount);

  // a handler is free: the stream of B runs, the stream of A never runs
  FGate.Release;
  Deadline := GetTickCount64 + 2000;
  while (FGate.StartedCount < 2) and (GetTickCount64 < Deadline) do
    Sleep(1);
  AssertEquals('the stream of B was handled', 2, FGate.StartedCount);
  AssertTrue('the handler saw a stream with id 1', FGate.HasId(1));
  AssertTrue('the handler of B ended and dropped its reference',
    WaitRefCount(StreamB, 1, 2000));
  AssertEquals('A was not touched again', 1, StreamA.RefCount);
  AssertEquals('the queue is empty', 0, FPool.QueueLength);
end;

initialization
  RegisterTest(TAdmissionConnectionsTest);

end.
