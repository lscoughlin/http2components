{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, stream, reference count, close, reap, waker, test, fpcunit
notes:
  - This unit tests that the connection core drops its reference to a stream once.
    A sink of the stream asks for credit while the core ends all streams, and the
    write waker runs a flush on the same thread. The flush closes the cancelled
    stream inside the loop of the core. The loop then closes the same stream again.
  - The test holds two extra references. A core that drops its reference twice
    leaves one reference less than the holders own.
---
}
/// Tests of the single release of the core reference of a closed stream
unit Http2.Server.CloseStream.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server.Errors, Http2.Common.Frames, Http2.Server.Duplex,
  Http2.Server.Output, Http2.Server.Stream, Http2.Server.Connection,
  Http2.Server.H2Peer;

type
  /// a sink that asks the stream for credit when the stream is cancelled
  // - a session returns credit for the octets of a dropped message in the same way
  TCreditSink = class(TInterfacedObject, IChannelSink)
  private
    FStream: TServerStream;
  public
    constructor Create(const AStream: TServerStream);
    procedure BytesReceived(const AData; const ACount: Integer);
    procedure PeerClosed(const AClean: Boolean);
    procedure WriteDrained;
  end;

  /// a waker that flushes the core on the calling thread
  // - the waker of an async connection does the same: it drains the core and writes
  TFlushWaker = class(TInterfacedObject, IWriteWaker)
  private
    FCore: TServerConnectionCore;
  public
    constructor Create(const ACore: TServerConnectionCore);
    procedure Signal;
  end;

  TCloseStreamTest = class(TTestCase)
  private
    FPeer: TH2Peer;
  protected
    procedure TearDown; override;
  published
    procedure TestReentrantFlushDuringEndAllStreamsReleasesTheCoreReferenceOnce;
    procedure TestFlushInsideEndAllStreamsKeepsTheLoopAndTheReferences;
    procedure TestReentrantFlushDuringPeerResetReleasesTheCoreReferenceOnce;
  end;

implementation

{ TCreditSink }

constructor TCreditSink.Create(const AStream: TServerStream);
begin
  inherited Create;
  FStream := AStream;
end;

procedure TCreditSink.BytesReceived(const AData; const ACount: Integer);
begin
end;

procedure TCreditSink.PeerClosed(const AClean: Boolean);
begin
  // the credit call wakes the writer, and the waker flushes the core
  FStream.AddCredit(1);
end;

procedure TCreditSink.WriteDrained;
begin
end;

{ TFlushWaker }

constructor TFlushWaker.Create(const ACore: TServerConnectionCore);
begin
  inherited Create;
  FCore := ACore;
end;

procedure TFlushWaker.Signal;
begin
  FCore.DrainPending;
end;

{ TCloseStreamTest }

procedure TCloseStreamTest.TearDown;
begin
  if FPeer <> nil then
    FPeer.Core.SetWriteWaker(nil);
  FreeAndNil(FPeer);
end;

procedure TCloseStreamTest.TestReentrantFlushDuringEndAllStreamsReleasesTheCoreReferenceOnce;
var
  Stream: TServerStream;
  Sink: IChannelSink;
  Waker: IWriteWaker;
begin
  FPeer := TH2Peer.Create(TPeerOptions.Default);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  Stream := FPeer.Core.StreamById(1);
  AssertTrue('the stream is open', Stream <> nil);
  // two holders besides the core, as a handler and a channel are
  Stream.AddRef;
  Stream.AddRef;
  AssertEquals('the core and two holders', 3, Stream.RefCount);
  Sink := TCreditSink.Create(Stream);
  Stream.SetSink(Sink);
  Waker := TFlushWaker.Create(FPeer.Core);
  FPeer.Core.SetWriteWaker(Waker);
  // a WINDOW_UPDATE of 0 on the connection is a connection error: the core ends all
  // streams, and the cancel of the stream runs the sink inside that loop
  FPeer.SendWindowUpdate(0, 0);
  FPeer.Pump;
  // the stream is freed by the last release, so a count that is too low must not
  // reach the release calls below
  AssertEquals('the two holders still own the stream', 2, Stream.RefCount);
  Stream.SetSink(nil);
  Stream.ReleaseRef;
  Stream.ReleaseRef;
end;

procedure TCloseStreamTest.TestFlushInsideEndAllStreamsKeepsTheLoopAndTheReferences;
var
  S1, S3: TServerStream;
  Sink: IChannelSink;
  Waker: IWriteWaker;
begin
  FPeer := TH2Peer.Create(TPeerOptions.Default);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
  FPeer.SendGet(1, '/', False);
  FPeer.SendGet(3, '/', False);
  FPeer.Pump;
  S1 := FPeer.Core.StreamById(1);
  S3 := FPeer.Core.StreamById(3);
  AssertTrue('both streams are open', (S1 <> nil) and (S3 <> nil));
  // one holder besides the core on each stream
  S1.AddRef;
  S3.AddRef;
  // the stream of the lower index is cancelled and still in the list, so the flush
  // inside the loop closes it too, and the list shrinks by two entries
  S1.Cancel(ecCancel);
  Sink := TCreditSink.Create(S3);
  S3.SetSink(Sink);
  Waker := TFlushWaker.Create(FPeer.Core);
  FPeer.Core.SetWriteWaker(Waker);
  FPeer.SendWindowUpdate(0, 0);
  FPeer.Pump;
  AssertTrue('stream 1 is closed', FPeer.Core.StreamById(1) = nil);
  AssertTrue('stream 3 is closed', FPeer.Core.StreamById(3) = nil);
  AssertEquals('stream 1 keeps its holder', 1, S1.RefCount);
  AssertEquals('stream 3 keeps its holder', 1, S3.RefCount);
  S3.SetSink(nil);
  S1.ReleaseRef;
  S3.ReleaseRef;
end;

procedure TCloseStreamTest.TestReentrantFlushDuringPeerResetReleasesTheCoreReferenceOnce;
var
  Stream: TServerStream;
  Sink: IChannelSink;
  Waker: IWriteWaker;
begin
  FPeer := TH2Peer.Create(TPeerOptions.Default);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
  FPeer.SendGet(1, '/', False);
  FPeer.Pump;
  Stream := FPeer.Core.StreamById(1);
  AssertTrue('the stream is open', Stream <> nil);
  Stream.AddRef;
  Stream.AddRef;
  Sink := TCreditSink.Create(Stream);
  Stream.SetSink(Sink);
  Waker := TFlushWaker.Create(FPeer.Core);
  FPeer.Core.SetWriteWaker(Waker);
  // the reset cancels the stream, the sink asks for credit, and the flush closes it
  FPeer.SendRst(1, ecCancel);
  FPeer.Pump;
  AssertTrue('the stream is closed', FPeer.Core.StreamById(1) = nil);
  AssertEquals('the two holders still own the stream', 2, Stream.RefCount);
  Stream.SetSink(nil);
  Stream.ReleaseRef;
  Stream.ReleaseRef;
end;

initialization
  RegisterTest(TCloseStreamTest);

end.
