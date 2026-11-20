{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this tests a stream lease that starts with an open request stream (KeepOpen, no body)
---
}
unit Http2.Client.Stream.OpenStart.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Stream.Types,
  Http2.Common.Frames, Http2.Client.MockSocket.Support, Http2.Client.MockSocket.TestSupport;

type
  TStreamOpenStartTest = class(TTestCase)
  private
    procedure OpenPeer(out ASock: TMockSocket; out AConn: TConnection;
      out AServer: TScriptedServer; out AAlloc: TStreamIdAllocator);
    procedure StartConnect(const AConn: TConnection; const AAlloc: TStreamIdAllocator;
      out ALease: TStreamLease; out AIL: IConnectionStream);
  published
    procedure TestKeepOpenConnectStartSendsHeadersOnly;
    procedure TestSendDataAfterKeepOpenStartSendsData;
    procedure TestEndSendAfterKeepOpenStartEndsStream;
    procedure TestGetStartStillEndsStreamWithHeaders;
    procedure TestPostWithBodyStillSendsTheBody;
  end;

implementation

/// the outbound frames of stream AStreamId, once ACount of them exist (bounded wait)
function WaitForStreamFrames(const ASock: TMockSocket; const AStreamId: LongWord;
  const ACount: Integer): TArray<TFrame>;
var
  Frames: TArray<TFrame>;
  Deadline: QWord;
  I, N: Integer;
begin
  Result := nil;
  Deadline := GetTickCount64 + 2000;
  while True do
  begin
    Frames := ASock.OutboundFrames(True);
    SetLength(Result, 0);
    for I := 0 to High(Frames) do
      if Frames[I].Header.StreamId = AStreamId then
      begin
        N := Length(Result);
        SetLength(Result, N + 1);
        Result[N] := Frames[I];
      end;
    if (Length(Result) >= ACount) or (GetTickCount64 >= Deadline) then
      Exit;
    Sleep(5);
  end;
end;

/// True when A and B hold the same octets
function SameOctets(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and
    ((Length(A) = 0) or (CompareByte(A[0], B[0], Length(A)) = 0));
end;

procedure TStreamOpenStartTest.OpenPeer(out ASock: TMockSocket; out AConn: TConnection;
  out AServer: TScriptedServer; out AAlloc: TStreamIdAllocator);
begin
  ASock := TMockSocket.Create;
  AConn := TConnection.Create(ASock);
  AServer := TScriptedServer.Create(ASock);
  AAlloc := TStreamIdAllocator.Create;
  AConn.Start;
  AssertTrue('connection opens', AConn.WaitForState(csOpen, 2000));
  AServer.SendSettings(TConnectionSettings.Defaults);
end;

/// start a CONNECT request for the WebSocket protocol with KeepOpen on stream 1
procedure TStreamOpenStartTest.StartConnect(const AConn: TConnection;
  const AAlloc: TStreamIdAllocator; out ALease: TStreamLease; out AIL: IConnectionStream);
var
  Req: TStreamRequest;
begin
  Req := TStreamRequest.Create('CONNECT', 'example.test:443')
    .WithScheme('https')
    .WithPath('/chat')
    .WithProtocol('websocket')
    .WithHeader('sec-websocket-version', '13')
    .WithKeepOpen;
  StartLease(AConn, AAlloc, Req, ALease, AIL);
end;

procedure TStreamOpenStartTest.TestKeepOpenConnectStartSendsHeadersOnly;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Frames: TArray<TFrame>;
begin
  OpenPeer(Sock, Conn, Server, Alloc);
  try
    StartConnect(Conn, Alloc, Lease, IL);
    try
      // Start returns with the stream open: no exception, one HEADERS frame
      AssertEquals('stream id is 1', LongWord(1), Lease.StreamId);
      Frames := WaitForStreamFrames(Sock, 1, 1);
      AssertEquals('one frame on stream 1', 1, Length(Frames));
      AssertEquals('frame is HEADERS', Ord(ftHeaders), Ord(Frames[0].Header.FrameType));
      AssertFalse('HEADERS has no END_STREAM', Frames[0].IsEndStream);
      AssertEquals('local state is headers sent', Ord(lsHeadersSent),
        Ord(Lease.LocalState));
    finally
      // the connection keeps the open stream in its map: release it first
      Lease.ReleaseLease;
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;

procedure TStreamOpenStartTest.TestSendDataAfterKeepOpenStartSendsData;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Frames: TArray<TFrame>;
begin
  OpenPeer(Sock, Conn, Server, Alloc);
  try
    StartConnect(Conn, Alloc, Lease, IL);
    try
      Lease.SendData(BytesOfString('ping'), False);
      Frames := WaitForStreamFrames(Sock, 1, 2);
      AssertEquals('HEADERS and one DATA frame on stream 1', 2, Length(Frames));
      AssertEquals('second frame is DATA', Ord(ftData), Ord(Frames[1].Header.FrameType));
      AssertFalse('DATA has no END_STREAM', Frames[1].IsEndStream);
      AssertTrue('DATA carries the octets sent',
        SameOctets(BytesOfString('ping'), ExtractDataPayload(Frames[1])));
      AssertEquals('local state is still headers sent', Ord(lsHeadersSent),
        Ord(Lease.LocalState));
    finally
      // the connection keeps the open stream in its map: release it first
      Lease.ReleaseLease;
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;

procedure TStreamOpenStartTest.TestEndSendAfterKeepOpenStartEndsStream;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Frames: TArray<TFrame>;
begin
  OpenPeer(Sock, Conn, Server, Alloc);
  try
    StartConnect(Conn, Alloc, Lease, IL);
    try
      Lease.SendData(BytesOfString('ping'), False);
      Lease.EndSend;
      Frames := WaitForStreamFrames(Sock, 1, 3);
      AssertEquals('HEADERS, DATA and the closing DATA on stream 1', 3, Length(Frames));
      AssertFalse('HEADERS has no END_STREAM', Frames[0].IsEndStream);
      AssertFalse('the data frame has no END_STREAM', Frames[1].IsEndStream);
      AssertEquals('closing frame is DATA', Ord(ftData), Ord(Frames[2].Header.FrameType));
      AssertTrue('closing DATA carries END_STREAM', Frames[2].IsEndStream);
      AssertEquals('closing DATA is empty', 0, Length(ExtractDataPayload(Frames[2])));
      AssertEquals('local state is half-closed', Ord(lsLocalHalfClosed),
        Ord(Lease.LocalState));
    finally
      // the connection keeps the open stream in its map: release it first
      Lease.ReleaseLease;
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;

procedure TStreamOpenStartTest.TestGetStartStillEndsStreamWithHeaders;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Req: TStreamRequest;
  Frames: TArray<TFrame>;
begin
  OpenPeer(Sock, Conn, Server, Alloc);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443').WithPath('/');
    StartLease(Conn, Alloc, Req, Lease, IL);
    try
      Frames := WaitForStreamFrames(Sock, 1, 1);
      AssertEquals('one frame on stream 1', 1, Length(Frames));
      AssertEquals('frame is HEADERS', Ord(ftHeaders), Ord(Frames[0].Header.FrameType));
      AssertTrue('GET HEADERS has END_STREAM', Frames[0].IsEndStream);
      AssertEquals('local state is half-closed', Ord(lsLocalHalfClosed),
        Ord(Lease.LocalState));
    finally
      // the connection keeps the open stream in its map: release it first
      Lease.ReleaseLease;
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;

procedure TStreamOpenStartTest.TestPostWithBodyStillSendsTheBody;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Server: TScriptedServer;
  Alloc: TStreamIdAllocator;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Req: TStreamRequest;
  Frames: TArray<TFrame>;
begin
  OpenPeer(Sock, Conn, Server, Alloc);
  try
    Req := TStreamRequest.WithMethod(hmPost, 'api.example:443').WithPath('/')
      .WithBody(THttpBody.FromString('hello'));
    StartLease(Conn, Alloc, Req, Lease, IL);
    try
      Frames := WaitForStreamFrames(Sock, 1, 2);
      AssertEquals('HEADERS and the body on stream 1', 2, Length(Frames));
      AssertFalse('HEADERS has no END_STREAM', Frames[0].IsEndStream);
      AssertEquals('second frame is DATA', Ord(ftData), Ord(Frames[1].Header.FrameType));
      AssertTrue('the body ends the stream', Frames[1].IsEndStream);
      AssertTrue('the body octets are sent',
        SameOctets(BytesOfString('hello'), ExtractDataPayload(Frames[1])));
    finally
      // the connection keeps the open stream in its map: release it first
      Lease.ReleaseLease;
      IL := nil;
    end;
  finally
    Alloc.Free;
    Server.Free;
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TStreamOpenStartTest);

end.
