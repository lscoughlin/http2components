{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, plain_socket, pending_input, unix_socket
notes:
  - this checks the HasPendingInput poll of the plain socket
  - the test uses a real Unix socket. The peer keeps the accepted
    connection open until the test releases it, so the test controls
    when the peer writes and when it closes.
  - the waits are bounded polls on the readable state. No test sleeps.
---
}
unit Http2.Client.PlainSocketPending.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  Http2.Client.Tls.Plain, Http2.Client.Unix.TestKit;

type
  /// a peer that accepts one connection and keeps it open until released
  // - the peer signals Ready after the accept and waits for Release
  TPendingPeer = class(TUnixListener)
  public
    Ready: TEvent;
    Release: TEvent;
    /// the accepted descriptor; valid after Ready is signalled
    Fd: Integer;
    procedure Serve(AFd: Integer); override;
  end;

  /// tests for TPlainSocket.HasPendingInput on a real Unix socket
  TPlainSocketPendingTest = class(TTestCase)
  private
    FPath: string;
    FPeer: TPendingPeer;
    FReady: TEvent;
    FRelease: TEvent;
    FSock: TPlainSocket;
    /// starts the peer and connects the socket; the peer has accepted
    procedure Connect;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestNoDataIsNotPending;
    procedure TestWrittenOctetsArePending;
    procedure TestReadingTheOctetsClearsPending;
    procedure TestPeerCloseIsPending;
  end;

implementation

const
  cPendingOctets: RawByteString = 'hello';
  cPendingWaitMs = 2000;

/// waits, at most ATimeoutMs, until the descriptor is readable
function WaitReadable(AFd, ATimeoutMs: Integer): Boolean;
var
  Pfd: pollfd;
begin
  Pfd.fd := AFd;
  Pfd.events := POLLIN;
  Pfd.revents := 0;
  Result := fpPoll(@Pfd, 1, ATimeoutMs) > 0;
end;

{ TPendingPeer }

procedure TPendingPeer.Serve(AFd: Integer);
begin
  Fd := AFd;
  Ready.SetEvent;
  // bounded: a test that fails before the release still ends the thread
  Release.WaitFor(5000);
end;

{ TPlainSocketPendingTest }

procedure TPlainSocketPendingTest.SetUp;
begin
  FPath := NewUnixTestPath;
  FReady := TEvent.Create(nil, True, False, '');
  FRelease := TEvent.Create(nil, True, False, '');
  FPeer := nil;
  FSock := nil;
end;

procedure TPlainSocketPendingTest.TearDown;
begin
  if Assigned(FSock) then
  begin
    FSock.Close;
    FSock.Free;
    FSock := nil;
  end;
  if Assigned(FPeer) then
  begin
    // release the peer first, so that its Serve returns before the thread stops
    FRelease.SetEvent;
    FreeAndNil(FPeer);
  end;
  FreeAndNil(FRelease);
  FreeAndNil(FReady);
  if FileExists(FPath) then
    DeleteFile(FPath);
end;

procedure TPlainSocketPendingTest.Connect;
begin
  FPeer := TPendingPeer.Create(FPath);
  FPeer.Ready := FReady;
  FPeer.Release := FRelease;
  FSock := TPlainSocket.CreateUnix(FPath, cPendingWaitMs);
  AssertTrue('the peer accepts the connection',
    FReady.WaitFor(5000) = wrSignaled);
  AssertTrue('the socket is connected', FSock.GetConnected);
end;

procedure TPlainSocketPendingTest.TestNoDataIsNotPending;
begin
  Connect;
  AssertFalse('no data on the wire, so nothing is pending',
    FSock.HasPendingInput);
end;

procedure TPlainSocketPendingTest.TestWrittenOctetsArePending;
begin
  Connect;
  WriteAll(FPeer.Fd, cPendingOctets);
  AssertTrue('the peer data becomes readable',
    WaitReadable(FSock.Handle, cPendingWaitMs));
  AssertTrue('the 5 written octets are pending', FSock.HasPendingInput);
end;

procedure TPlainSocketPendingTest.TestReadingTheOctetsClearsPending;
var
  Reply: RawByteString;
begin
  Connect;
  WriteAll(FPeer.Fd, cPendingOctets);
  AssertTrue('the peer data becomes readable',
    WaitReadable(FSock.Handle, cPendingWaitMs));
  SetLength(Reply, 5);
  AssertEquals('the 5 octets are read', 5, FSock.Read(Reply[1], 5));
  AssertEquals('the octets are the ones written', 'hello', string(Reply));
  AssertFalse('nothing is pending after the read', FSock.HasPendingInput);
end;

procedure TPlainSocketPendingTest.TestPeerCloseIsPending;
var
  Octet: Byte;
begin
  Connect;
  // SHUT_WR sends the end of stream to the client and keeps the descriptor open
  AssertEquals('the peer shuts down its write side', 0,
    fpShutdown(FPeer.Fd, SHUT_WR));
  AssertTrue('the end of stream becomes readable',
    WaitReadable(FSock.Handle, cPendingWaitMs));
  AssertTrue('a closed peer counts as pending', FSock.HasPendingInput);
  AssertEquals('the read reports the end of stream', 0,
    FSock.ReadSome(Octet, 1));
end;

initialization
  RegisterTest(TPlainSocketPendingTest);

end.
