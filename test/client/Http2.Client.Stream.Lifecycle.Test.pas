{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client stream test from the source project
---
}
unit Http2.Client.Stream.Lifecycle.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.ConnectionThread.Test, Http2.Client.Stream.Support;

type
  TStreamLeaseLifecycleTest = class(TStreamLeaseTestBase)
  published
    procedure TestRstMidBodySurfacesFromRead;
    procedure TestBlockedBodyReadSurfacesConnectionFailure;
    procedure TestInvalidTransitionsRaise;
    procedure TestCleanupHappensExactlyOnce;
    procedure TestConnectionFailureReachesLeaseExactlyOnce;
    procedure TestStartOnADeadConnectionLeavesNothingRegistered;
    procedure TestGoAwayMarksHigherStreamRetryable;
    procedure TestEndToEndSingleLeaseOverMockedConnection;
    procedure TestDispatchAndFailOverRealConnection;
  end;

implementation

procedure TStreamLeaseLifecycleTest.TestRstMidBodySurfacesFromRead;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Empty: THeaderBlock;
  Got: EHttpStreamError;
  Raised: Boolean;
  GotStreamId: LongWord;
  GotCode: THttp2ErrorCode;
  Buf: array[0..7] of Byte;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Empty := nil;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Empty,
          Lease.StreamId, False));
      finally
        Enc.Free;
      end;
      AssertTrue('headers received as a normal value',
        Lease.WaitForResponseHeader(1000));

      Conn.DispatchStreamFrame(BuildRstStreamFrame(Lease.StreamId, ecCancel));
      Raised := False;
      Got := nil;
      GotStreamId := 0;
      GotCode := ecNoError;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpStreamError do
        begin
          Raised := True;
          Got := E;
          GotStreamId := E.StreamId;
          GotCode := E.ErrorCode;
        end;
      end;
      AssertTrue('RST surfaces from Read, not from Send', Raised);
      AssertEquals('stream id attached to the error', Lease.StreamId,
        GotStreamId);
      AssertEquals('wire code mapped', Ord(ecCancel), Ord(GotCode));
      AssertTrue('lease records the reset', Lease.RstReceived);
      AssertEquals('raw wire code recorded', Ord(ecCancel),
        Ord(Lease.RstCode));
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestBlockedBodyReadSurfacesConnectionFailure;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Empty: THeaderBlock;
  Driver: TFailingDriver;
  Buf: array[0..7] of Byte;
  Raised: Boolean;
  IsTimeout: Boolean;
  IsConnError: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Empty := nil;
        // a 200 response with a body still open: the read below blocks
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Empty,
          Lease.StreamId, False));
      finally
        Enc.Free;
      end;
      AssertTrue('headers received as a normal value',
        Lease.WaitForResponseHeader(1000));

      // block in ReadBody; the driver fails the connection underneath it
      Driver := TFailingDriver.Create(Conn, 150);
      try
        Driver.Start;
        IsTimeout := False;
        IsConnError := False;
        try
          Lease.ReadBody(Buf, SizeOf(Buf));
        except
          on E: EHttpConnectionError do IsConnError := True;
          on E: EHttpTimeout do IsTimeout := True;
        end;
      finally
        Driver.WaitFor;
        Driver.Free;
      end;
      AssertFalse('a dead connection is not reported as a timeout',
        IsTimeout);
      AssertTrue('the connection failure reaches the blocked read',
        IsConnError);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestInvalidTransitionsRaise;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      // DATA before HEADERS
      Raised := False;
      try
        Lease.SendData(BytesOf('x'), True);
      except
        on E: EHttpProtocolError do Raised := True;
      end;
      AssertTrue('DATA before HEADERS raises', Raised);

      Lease.Start;   // GET -> immediate half-close
      // a second HEADERS emission
      Raised := False;
      try
        Lease.SendHeaders;
      except
        on E: EHttpProtocolError do Raised := True;
      end;
      AssertTrue('second HEADERS raises', Raised);

      // DATA on the already half-closed local side
      Raised := False;
      try
        Lease.SendData(BytesOf('x'), True);
      except
        on E: EHttpProtocolError do Raised := True;
      end;
      AssertTrue('DATA after half-close raises', Raised);

      // RequestIsBodyless is observable through the local state
      AssertEquals('GET ends in local half-close',
        Ord(lsLocalHalfClosed), Ord(Lease.LocalState));
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestCleanupHappensExactlyOnce;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Empty: THeaderBlock;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      AssertEquals('registered on start', 1, Conn.StreamCount);
      Enc := THpackCodec.Create;
      try
        Empty := nil;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Empty,
          Lease.StreamId, True));   // END_STREAM on HEADERS
      finally
        Enc.Free;
      end;
      AssertTrue(Lease.WaitForResponseHeader(1000));
      AssertEquals('completed stream unregistered', 0, Conn.StreamCount);
      AssertEquals('exactly one unregister', 1, Lease.UnregisterCount);
      AssertEquals('exactly one release', 1, Lease.ReleaseCount);
      AssertEquals('both sides closed -> fully closed',
        Ord(lsClosed), Ord(Lease.LocalState));

      // a duplicate release must not unregister again
      Lease.ReleaseLease;
      Lease.ReleaseLease;
      AssertEquals('unregister still exactly once', 1, Lease.UnregisterCount);
      AssertEquals('release still exactly once', 1, Lease.ReleaseCount);
      AssertEquals('no leak', 0, Conn.StreamCount);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;


procedure TStreamLeaseLifecycleTest.TestConnectionFailureReachesLeaseExactlyOnce;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Buf: array[0..7] of Byte;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Conn.FailWith('socket reset', ecConnectError);
      AssertEquals('failure delivered to the lease exactly once', 1,
        Lease.FailCount);
      // the lease unregistered during the callback, so a second failure
      // fan-out must not reach it again
      Conn.FailWith('socket reset again', ecConnectError);
      AssertEquals('second fan-out does not re-enter the lease', 1,
        Lease.FailCount);

      Raised := False;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpConnectionError do Raised := True;
      end;
      AssertTrue('body read observes the connection failure', Raised);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestStartOnADeadConnectionLeavesNothingRegistered;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.FailWith('socket reset', ecConnectError);
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Raised := False;
      try
        Lease.Start;
      except
        on E: EHttpConnectionError do Raised := True;
      end;
      AssertTrue('Start fails at once on a dead connection', Raised);
      AssertEquals('the stream is not left in the connection map', 0,
        Conn.StreamCount);
      AssertEquals('unregistered exactly once', 1, Lease.UnregisterCount);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestGoAwayMarksHigherStreamRetryable;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Upper, Lower: TStreamLease;
  IUp, ILow: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    Lower := TStreamLease.Create(Conn, Alloc, Req);
    ILow := Lower;
    Upper := TStreamLease.Create(Conn, Alloc, Req);
    IUp := Upper;
    try
      Lower.Start;   // stream id 1
      Upper.Start;   // stream id 3
      AssertEquals('both streams registered', 2, Conn.StreamCount);
      Conn.MarkGoAway(1);
      AssertTrue('stream above last-id is retryable', Upper.Retryable);
      AssertFalse('stream at last-id is not retryable', Lower.Retryable);
      AssertEquals('unprocessed upper stream released', 1,
        Upper.ReleaseCount);
      AssertEquals('processed lower stream stays registered', 1,
        Conn.StreamCount);
      AssertEquals('processed lower stream not released by GOAWAY', 0,
        Lower.ReleaseCount);
    finally
      Lower.ReleaseLease;
      Upper.ReleaseLease;
      ILow := nil;
      IUp := nil;
    end;
  finally
    Alloc.Free;
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestEndToEndSingleLeaseOverMockedConnection;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Extra: array[0..0] of THttpHeaderField;
  H, Hx: TFrame;
  Body: string;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmPost, 'api.example:443')
      .WithPath('/submit')
      .WithBody(THttpBody.FromString('payload'));
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      // request: HEADERS + DATA
      AssertTrue(Conn.Outbound.Pop(H));
      AssertEquals('request HEADERS', Ord(ftHeaders), Ord(H.Header.FrameType));
      AssertTrue(Conn.Outbound.Pop(H));
      AssertTrue('request body ends the local side', H.IsEndStream);
      AssertFalse('no extra request frames', Conn.Outbound.TryPop(Hx));

      Enc := THpackCodec.Create;
      try
        Extra[0].Name := 'content-length';
        Extra[0].Value := '2';
        Extra[0].Sensitive := False;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Extra,
          Lease.StreamId, False));
      finally
        Enc.Free;
      end;
      AssertTrue(Lease.WaitForResponseHeader(1000));
      AssertEquals('200 OK', 200, Lease.StatusCode);
      Conn.DispatchStreamFrame(BuildDataFrame(Lease.StreamId, BytesOf('ok'),
        True));
      Body := ReadAllBody(Lease.Body);
      AssertEquals('full response body', 'ok', Body);
      AssertTrue('stream complete', Lease.Body.Eof);
      AssertEquals('cleanly unregistered once', 1, Lease.UnregisterCount);
      AssertEquals('no stream leak', 0, Conn.StreamCount);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseLifecycleTest.TestDispatchAndFailOverRealConnection;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Empty: THeaderBlock;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opened', Conn.WaitForState(csOpen, 2000));
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      // the peer answers on the wire; the connection thread routes HEADERS to
      // the lease through DispatchStreamFrame
      Enc := THpackCodec.Create;
      try
        Empty := nil;
        Sock.FeedFrame(ResponseHeadersFrame(Enc, '200', Empty, Lease.StreamId,
          False));
      finally
        Enc.Free;
      end;
      AssertTrue('lease received its frame via DispatchStreamFrame',
        Lease.WaitForResponseHeader(2000));
      AssertEquals('status decoded from the routed frame', 200,
        Lease.StatusCode);

      Conn.FailWith('boom', ecConnectError);
      AssertEquals('FailWith reached the lease exactly once', 1,
        Lease.FailCount);
      Conn.FailWith('boom again', ecConnectError);
      AssertEquals('second FailWith does not re-reach the lease', 1,
        Lease.FailCount);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TStreamLeaseLifecycleTest);
end.
