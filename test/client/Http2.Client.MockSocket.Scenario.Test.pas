{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves mock socket client tests from the source project
---
}
unit Http2.Client.MockSocket.Scenario.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Hpack, Http2.Client.Tls, Http2.Client.Observer,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages, Http2.Client, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport,
  Http2.Client.MockSocket.Frames;

type
  TMockSocketScenarioTest = class(TTestCase)
  private
    procedure WaitForWindowUpdates(const ASock: TMockSocket;
      out AConns, AStreams: Boolean);
  published
    procedure TestScenarioNormalGet;
    procedure TestScenarioMultiplex;
    procedure TestScenarioGoAway;
    procedure TestScenarioRstStream;
    procedure TestScenarioZeroWindowStallsBodyRead;
    procedure TestScenarioLargeBodyEmitsWindowUpdate;
    procedure TestScenarioMalformedFrameClosesConnection;
    procedure TestScenarioPushPromiseRejected;
    procedure TestScenarioFullSendPathOverMockSocket;
  end;

implementation

const
  /// bytes of the large body queued and read before END_STREAM is queued
  cFirstPart = 96000;

procedure TMockSocketScenarioTest.WaitForWindowUpdates(const ASock: TMockSocket;
  out AConns, AStreams: Boolean);
var
  Frames: TArray<TFrame>;
  I: Integer;
  Deadline: QWord;
begin
  // the connection worker thread writes a WINDOW_UPDATE after the read that
  // posted it, so the frame can reach the mock socket after the read returns.
  // poll until both kinds are written, or the bound expires; the caller then
  // asserts the flags as before
  Deadline := GetTickCount64 + 5000;
  while True do
  begin
    AConns := False;
    AStreams := False;
    Frames := ASock.OutboundFrames(True);
    for I := 0 to Length(Frames) - 1 do
      if Frames[I].Header.FrameType = ftWindowUpdate then
      begin
        if Frames[I].Header.StreamId = 0 then
          AConns := True;
        if Frames[I].Header.StreamId = 1 then
          AStreams := True;
      end;
    if (AConns and AStreams) or (GetTickCount64 >= Deadline) then
      Exit;
    Sleep(5);
  end;
end;

procedure TMockSocketScenarioTest.TestScenarioNormalGet;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Req: TStreamRequest;
  Body: string;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.SendSettings(TConnectionSettings.Defaults);
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443').WithPath('/');
    StartLease(Conn, Alloc, Req, Lease, IL);
    try
      Server.SendResponse(1, '200', BytesOfString('hello'), True);
      AssertTrue('response headers received',
        Lease.WaitForResponseHeader(2000));
      AssertEquals('status 200', 200, Lease.StatusCode);
      Body := ReadAllBodyText(Lease.Body);
      AssertEquals('response body', 'hello', Body);
      AssertTrue('body complete', Lease.Body.Eof);
    finally
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioMultiplex;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  L1, L2: TStreamLease;
  I1, I2: IConnectionStream;
  Req: TStreamRequest;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.SendSettings(TConnectionSettings.Defaults);
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443');
    StartLease(Conn, Alloc, Req, L1, I1);
    StartLease(Conn, Alloc, Req, L2, I2);
    try
      AssertTrue('both streams registered', Conn.StreamCount = 2);
      Server.ScenarioMultiplex([1, 3]);
      AssertTrue('stream 1 headers', L1.WaitForResponseHeader(2000));
      AssertTrue('stream 3 headers', L2.WaitForResponseHeader(2000));
      AssertEquals('stream 1 status', 200, L1.StatusCode);
      AssertEquals('stream 3 status', 200, L2.StatusCode);
    finally
      I1 := nil;
      I2 := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioGoAway;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.ScenarioGoAway(5);
    AssertTrue('GOAWAY moves the connection', Conn.WaitForState(csGoAway, 2000));
    AssertFalse('no new streams after GOAWAY', Conn.CanOpenStream);
    AssertEquals('last-stream-id recorded', LongWord(5),
      Conn.GoAwayLastStreamId);
    AssertTrue('a higher stream is retryable', Conn.IsStreamRetryable(7));
    AssertFalse('a lower stream is not retryable', Conn.IsStreamRetryable(3));
  finally
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioRstStream;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Req: TStreamRequest;
  Buf: array[0..7] of Byte;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.SendSettings(TConnectionSettings.Defaults);
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443');
    StartLease(Conn, Alloc, Req, Lease, IL);
    try
      Server.SendHeaders(1, '200', False);
      AssertTrue('headers received before the reset',
        Lease.WaitForResponseHeader(2000));
      Server.ScenarioRstStream(1, ecCancel);
      Raised := False;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpStreamError do Raised := True;
      end;
      AssertTrue('RST surfaces from the body read', Raised);
      AssertTrue('lease records the reset', Lease.RstReceived);
      AssertEquals('wire code recorded', Ord(ecCancel), Ord(Lease.RstCode));
    finally
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioZeroWindowStallsBodyRead;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Req: TStreamRequest;
  Buf: array[0..7] of Byte;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443');
    StartLease(Conn, Alloc, Req, Lease, IL);
    try
      Lease.TimeoutMs := 300;
      // peer grants a zero window, answers headers, and withholds DATA
      Server.ScenarioZeroWindow(1);
      AssertTrue('headers received', Lease.WaitForResponseHeader(2000));
      Raised := False;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpTimeout do Raised := True;
      end;
      AssertTrue('a starved body read times out rather than blocking forever',
        Raised);
    finally
      // the stream was never completed (headers only, no END_STREAM), so it
      // is still registered; release it BEFORE the connection tears down its
      // stream dictionary, or the lease's destructor re-enters a half-freed
      // connection
      Lease.ReleaseLease;
      Sock.UnstallReads;
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioLargeBodyEmitsWindowUpdate;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Req: TStreamRequest;
  N, Ofs, Got: Integer;
  Body, Rest: TBytes;
  Buf: array[0..16383] of Byte;
  Conns, Streams: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  Alloc := TStreamIdAllocator.Create;
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.SendSettings(TConnectionSettings.Defaults);
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443').WithPath('/');
    StartLease(Conn, Alloc, Req, Lease, IL);
    try
      // a body well past cWindowUpdateBatchSize (32768) forces the client to
      // replenish the consumed window; without the wiring the peer would
      // stall and the read would time out (interop A.7). The body is split
      // into frames no larger than the default SETTINGS_MAX_FRAME_SIZE.
      // the first part is queued without END_STREAM and read before the last
      // frame is queued. A stream-level WINDOW_UPDATE is due only while the
      // stream is open (TConnection.DataConsumed), so the stream must not see
      // END_STREAM before the consumer has read the first part. Queuing every
      // frame at once let a busy reader thread reach END_STREAM first.
      SetLength(Body, 100000);
      FillChar(Body[0], Length(Body), Ord('x'));
      Server.SendHeaders(1, '200', False);
      Ofs := 0;
      while Ofs < cFirstPart do
      begin
        Sock.EnqueueData(1, Copy(Body, Ofs, 16000), False);
        Inc(Ofs, 16000);
      end;
      AssertTrue('response headers received',
        Lease.WaitForResponseHeader(2000));
      AssertEquals('status 200', 200, Lease.StatusCode);
      // every queued frame is already inbound, so each Read returns data;
      // a missing frame ends the read with the body read timeout
      Got := 0;
      while Got < cFirstPart do
      begin
        N := Lease.Body.Read(Buf, SizeOf(Buf));
        AssertTrue('first part bytes arrive', N > 0);
        Inc(Got, N);
      end;
      AssertEquals('first part read', cFirstPart, Got);
      AssertFalse('body not complete before END_STREAM', Lease.Body.Eof);
      Sock.EnqueueData(1, Copy(Body, cFirstPart, Length(Body) - cFirstPart),
        True);
      Rest := ReadAllBodyBytes(Lease.Body);
      AssertEquals('full body read', Length(Body), Got + Length(Rest));
      AssertTrue('body complete', Lease.Body.Eof);
      // the worker thread writes the WINDOW_UPDATE frames asynchronously
      WaitForWindowUpdates(Sock, Conns, Streams);
      AssertTrue('a connection-level WINDOW_UPDATE was emitted', Conns);
      AssertTrue('a stream-level WINDOW_UPDATE was emitted', Streams);
    finally
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioMalformedFrameClosesConnection;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  try
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.ScenarioMalformedFrame;
    AssertTrue('the malformed frame closes the connection',
      Conn.WaitForState(csClosed, 2000));
    AssertEquals('a frame-size error was recorded', Ord(ecFrameSizeError),
      Ord(Conn.ErrorCode));
  finally
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioPushPromiseRejected;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  Server := TScriptedServer.Create(Sock);
  try
    AssertFalse('we advertise ENABLE_PUSH = 0',
      TConnectionSettings.Defaults.EnablePush);
    Conn.Start;
    AssertTrue('connection opens', Conn.WaitForState(csOpen, 2000));
    Server.ScenarioPushPromise(1, 3);
    AssertTrue('the PUSH_PROMISE closes the connection',
      Conn.WaitForState(csClosed, 2000));
    AssertEquals('a protocol error was recorded', Ord(ecProtocolError),
      Ord(Conn.ErrorCode));
  finally
    Server.Free;
    Conn.Free;
  end;
end;
procedure TMockSocketScenarioTest.TestScenarioFullSendPathOverMockSocket;
var
  Factory: TMockSocketFactory;      // non-owning view, valid while FactoryRef lives
  FactoryRef: IHttp2SocketFactory;  // owns the factory
  Client: IHttpClient;
  R: IHttpResponse;
  Sock: TMockSocket;
  Frames: TArray<TFrame>;
  SawHeaders, SawGoAway: Boolean;
  I: Integer;
begin
  // the S11 contract: the mock socket drives the FULL public Send path to
  // completion, with no real socket anywhere (IHttp2SocketFactory seam).
  FactoryRef := TMockSocketFactory.Create;
  Factory := FactoryRef as TMockSocketFactory;
  Factory.SetResponse('200', BytesOfString('payload'), True);
  Client := THttpClientFactory.Create
    .WithSocketFactory(FactoryRef)
    .Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://api.example/x'));
  AssertEquals('public Send returned the mock status', 200, R.StatusCode);
  AssertEquals('public Send streamed the mock body', 'payload',
    ReadAllBodyText(R.Body));
  AssertEquals('exactly one connection was dialled', 1, Factory.Dials);

  Sock := Factory.Socket(0);
  AssertTrue('the mock captured the client preface',
    Sock.WaitForWrites(2, 3000));
  Frames := Sock.OutboundFrames(True);
  SawHeaders := False;
  for I := 0 to Length(Frames) - 1 do
    if Frames[I].Header.FrameType = ftHeaders then
      SawHeaders := True;
  AssertTrue('the request HEADERS frame was captured on the wire',
    SawHeaders);

  Client.Close;
  Frames := Sock.OutboundFrames(True);
  SawGoAway := False;
  for I := 0 to Length(Frames) - 1 do
    if Frames[I].Header.FrameType = ftGoAway then
      SawGoAway := True;
  AssertTrue('Close sent a GOAWAY on the mock connection', SawGoAway);
  // ownership is entirely by interface; nothing to Free (the factory and its
  // handed-out mock sockets are refcounted)
  R := nil;
  Client := nil;
  FactoryRef := nil;
end;

initialization
  RegisterTest(TMockSocketScenarioTest);
end.
