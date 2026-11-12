{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The socket options of a Unix connection skip the TCP options, and the peer
    text of a Unix connection takes the Unix text.
  - Each test uses a path under /tmp that TearDown removes.
---
}
unit Http2.Server.UnixOptions.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads, BaseUnix, Sockets,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  mormot.core.base, mormot.net.sock,
  Http2.Server.Config.Socket, Http2.Server.Async.Socket,
  Http2.Server.Async.Events, Http2.Server.Unix.TestKit;

type
  /// the socket options and the peer text of a Unix connection
  TUnixOptionsTest = class(TTestCase)
  private
    FPath: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestApplyOptionsOnUnixSocketPairRaisesNothing;
    procedure TestApplyOptionsOnTcpStillSetsNoDelay;
    procedure TestPeerTextTakesTheUnixText;
    procedure TestPeerTextOfTcpIsUnchanged;
  end;

implementation

{$IFDEF UNIX}
/// the value of TCP_NODELAY on a socket
function TcpNoDelayOf(const ASocket: TNetSocket): Integer;
var
  Len: TSockLen;
begin
  Result := 0;
  Len := SizeOf(Result);
  if fpgetsockopt(TSocket(PtrUInt(ASocket)), IPPROTO_TCP, TCP_NODELAY,
    @Result, @Len) <> 0 then
    Result := -1;
end;
{$ENDIF}

procedure TUnixOptionsTest.SetUp;
begin
  FPath := NewUnixTestPath;
end;

procedure TUnixOptionsTest.TearDown;
begin
  if FPath <> '' then
    DeleteFile(FPath);
end;

procedure TUnixOptionsTest.TestApplyOptionsOnUnixSocketPairRaisesNothing;
{$IFDEF UNIX}
var
  Listener, Accepted: TSocket;
  Addr: TUnixSockAddr;
  Client: TNetSocket;
  Options: TSocketOptions;
begin
  // a connected Unix pair: the client is wrapped, the accepted end is raw
  Listener := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  AssertTrue('the listener is made', Listener >= 0);
  Client := nil;
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.family := AF_UNIX;
    Move(FPath[1], Addr.path[0], Length(FPath));
    AssertTrue('the listener binds',
      fpBind(Listener, PSockAddr(@Addr), SizeOf(Addr)) = 0);
    AssertTrue('the listener listens', fpListen(Listener, 1) = 0);
    Client := TNetSocket(PtrUInt(UnixConnect(FPath, 2000)));
    AssertTrue('the client connects', PtrUInt(Client) <> PtrUInt(-1));
    Accepted := fpAccept(Listener, nil, nil);
    AssertTrue('the server accepts', Accepted >= 0);
    try
      Options := TSocketOptions.Create
        .WithTcpNoDelay(True)
        .WithKeepAliveIdleSec(60)
        .WithSendBufferBytes(32768)
        .WithRecvBufferBytes(32768);
      // a Unix socket has no TCP options; the call must not raise
      ApplySocketOptions(Client, Options, True);
    finally
      fpClose(Accepted);
    end;
  finally
    if Client <> nil then
      Client.ShutdownAndClose(False);
    fpClose(Listener);
  end;
end;
{$ELSE}
begin
  Fail('Unix sockets are not supported on this target');
end;
{$ENDIF}

procedure TUnixOptionsTest.TestApplyOptionsOnTcpStillSetsNoDelay;
{$IFDEF UNIX}
var
  Listener, Client: TNetSocket;
  Addr: TNetAddr;
  Options: TSocketOptions;
begin
  Listener := nil;
  Client := nil;
  try
    AssertTrue('the listener binds', NewSocket('127.0.0.1', '0', nlTcp,
      True, 0, 0, 0, 0, Listener, @Addr, False) = nrOk);
    AssertTrue('the client connects', NewSocket('127.0.0.1',
      RawUtf8(IntToStr(Addr.Port)), nlTcp, False, 2000, 0, 0, 0, Client,
      nil, False) = nrOk);
    Options := TSocketOptions.Create.WithTcpNoDelay(True);
    ApplySocketOptions(Client, Options, False);
    AssertTrue('no-delay is on', TcpNoDelayOf(Client) <> 0);
    ApplySocketOptions(Client, TSocketOptions.Create.WithTcpNoDelay(False),
      False);
    AssertEquals('no-delay is off', 0, TcpNoDelayOf(Client));
  finally
    if Client <> nil then
      Client.ShutdownAndClose(False);
    if Listener <> nil then
      Listener.ShutdownAndClose(False);
  end;
end;
{$ELSE}
begin
  Fail('Unix sockets are not supported on this target');
end;
{$ENDIF}

procedure TUnixOptionsTest.TestPeerTextTakesTheUnixText;
begin
  AssertEquals('the Unix text alone', 'unix:pid=7',
    PeerAddressText('', 0, 'unix:pid=7'));
  AssertEquals('the Unix text wins over an IP text', 'unix:pid=7',
    PeerAddressText('1.2.3.4', 0, 'unix:pid=7'));
  AssertEquals('the bare Unix text', 'unix',
    PeerAddressText('', 0, 'unix'));
end;

procedure TUnixOptionsTest.TestPeerTextOfTcpIsUnchanged;
begin
  AssertEquals('the IP text', '1.2.3.4', PeerAddressText('1.2.3.4', 0, ''));
  AssertEquals('the loopback text', '127.0.0.1',
    PeerAddressText('', cLocalhost32, ''));
  AssertEquals('no text', '', PeerAddressText('', 0, ''));
end;

initialization
  RegisterTest(TUnixOptionsTest);

end.
