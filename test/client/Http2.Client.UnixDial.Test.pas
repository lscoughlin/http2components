{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests cover the client dial path that connects to a socket file.
---
}
/// Tests for the client dial path that connects to a Unix socket file
// - each test runs its own listener on a fresh socket file, and removes the
//   file in TearDown
unit Http2.Client.UnixDial.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Client.SocketFactory,
  Http2.Client.Test.TlsContext, Http2.Client.Unix.TestKit,
  Http2.Common.Tls.Context;

type
  /// a listener that reads one byte, then returns; the connection then closes
  TFirstByteListener = class(TUnixListener)
  private
    FHasByte: Boolean;
    FFirstByte: Byte;
  public
    /// keeps the first byte of the connection
    procedure Serve(AFd: Integer); override;
    /// waits up to ATimeoutMs for the first byte; returns True when it arrived
    function WaitForByte(const ATimeoutMs: Integer): Boolean;
    /// True when the listener has read a byte
    property HasByte: Boolean read FHasByte;
    /// the first byte of the connection, zero before any byte
    property FirstRecordByte: Byte read FFirstByte;
  end;

  /// tests for the client dial path to a Unix socket file
  TUnixDialTest = class(TTestCase)
  private
    FPath: string;
    FTlsContext: ITLSContext;
    FEcho: TUnixListener;
    FTls: TFirstByteListener;
    FKeep: array of IUnknown;
    procedure KeepAlive(const AObject: IUnknown);
    procedure StopListeners;
    procedure StartEchoListener;
    procedure StartTlsListener;
    function UnixFactory(const APath: string): TDefaultSocketFactory;
    function FactoryDial(const AKind: Integer; const AFactory: TDefaultSocketFactory;
      const AHost: string; out AError: string): Boolean;
    function ClassDial(const AKind: Integer; const AHost, APath: string;
      out AError: string): Boolean;
    procedure CheckDial(const AWhat: string; const AKind: Integer;
      const AUseFactory, ATls: Boolean);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestFactoryDial;
    procedure TestFactoryDialProtocol;
    procedure TestFactoryDialProtocolVia;
    procedure TestFactoryDialHttp1;
    procedure TestFactoryDialHttp1As;
    procedure TestFactoryDialProtocolViaAs;
    procedure TestTlsSocketDial;
    procedure TestTlsSocketDialWithAlpn;
    procedure TestTlsSocketDialCleartext;
    procedure TestTlsSocketDialVia;
    procedure TestTlsSocketDialWithAlpnVia;
    procedure TestTlsSocketDialCleartextVia;
    procedure TestSameListenerForAnyHost;
    procedure TestEmptyPathKeepsTcp;
    procedure TestCloneKeepsThePath;
  end;

implementation

procedure TFirstByteListener.Serve(AFd: Integer);
var
  Buf: Byte;
begin
  if fpRecv(AFd, @Buf, 1, 0) = 1 then
  begin
    FFirstByte := Buf;
    FHasByte := True;
  end;
end;

function TFirstByteListener.WaitForByte(const ATimeoutMs: Integer): Boolean;
var
  Left: Integer;
begin
  Left := ATimeoutMs;
  while (not FHasByte) and (Left > 0) do
  begin
    Sleep(10);
    Dec(Left, 10);
  end;
  Result := FHasByte;
end;

function WaitForAccepted(const AListener: TUnixListener; const ACount,
  ATimeoutMs: Integer): Boolean;
var
  Left: Integer;
begin
  Left := ATimeoutMs;
  while (AListener.Accepted < ACount) and (Left > 0) do
  begin
    Sleep(10);
    Dec(Left, 10);
  end;
  Result := AListener.Accepted >= ACount;
end;

/// a loopback TCP listener on a port that the kernel picks
function ListenTcpLoopback(out APort: Word): Integer;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Opt: Integer;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Result < 0 then
    raise Exception.Create('socket failed for the TCP listener');
  Opt := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @Opt, SizeOf(Opt));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;
  Addr.sin_addr.s_addr := htonl($7F000001);
  if fpBind(Result, @Addr, SizeOf(Addr)) <> 0 then
  begin
    fpClose(Result);
    raise Exception.Create('bind failed for the TCP listener');
  end;
  if fpListen(Result, 4) <> 0 then
  begin
    fpClose(Result);
    raise Exception.Create('listen failed for the TCP listener');
  end;
  Len := SizeOf(Addr);
  fpGetSockName(Result, @Addr, @Len);
  APort := ntohs(Addr.sin_port);
end;

{ TUnixDialTest }

procedure TUnixDialTest.KeepAlive(const AObject: IUnknown);
begin
  SetLength(FKeep, Length(FKeep) + 1);
  FKeep[High(FKeep)] := AObject;
end;

procedure TUnixDialTest.StopListeners;
begin
  if FEcho <> nil then
  begin
    FEcho.Free;
    FEcho := nil;
  end;
  if FTls <> nil then
  begin
    FTls.Free;
    FTls := nil;
  end;
end;

procedure TUnixDialTest.StartEchoListener;
begin
  StopListeners;
  FEcho := TUnixListener.Create(FPath);
end;

procedure TUnixDialTest.StartTlsListener;
begin
  StopListeners;
  FTls := TFirstByteListener.Create(FPath);
end;

function TUnixDialTest.UnixFactory(const APath: string): TDefaultSocketFactory;
var
  Base: TDefaultSocketFactory;
begin
  Base := TDefaultSocketFactory.Create('', False, '', 0, nil, nil, nil,
    FTlsContext, nil);
  KeepAlive(Base);
  Result := Base.WithUnixPath(APath);
  KeepAlive(Result);
end;

function TUnixDialTest.FactoryDial(const AKind: Integer;
  const AFactory: TDefaultSocketFactory; const AHost: string;
  out AError: string): Boolean;
var
  Sock: IHttp2Socket;
  Proto: TNegotiatedProtocol;
begin
  AError := '';
  Result := False;
  try
    case AKind of
      0: Sock := AFactory.Dial(AHost, 443, 2000);
      1: Sock := AFactory.DialProtocol(AHost, 80, 'http', False,
           ctPriorKnowledge, 2000, Proto);
      2: Sock := AFactory.DialProtocolVia(AHost, 443, 'https', False,
           ctReject, 2000, nil, Proto);
      3: Sock := AFactory.DialHttp1(AHost, 80, 'http', 2000, nil);
      4: Sock := AFactory.DialHttp1As(AHost, 443, 'https', 2000, nil, nil, False);
      5: Sock := AFactory.DialProtocolViaAs(AHost, 80, 'http', False,
           ctPriorKnowledge, 2000, nil, nil, False, Proto);
    end;
    Result := True;
    Sock.Close;
  except
    on E: Exception do
      AError := E.Message;
  end;
end;

function TUnixDialTest.ClassDial(const AKind: Integer; const AHost, APath: string;
  out AError: string): Boolean;
var
  Sock: IHttp2Socket;
begin
  AError := '';
  Result := False;
  try
    case AKind of
      0: Sock := TTlsSocket.Dial(AHost, 443, False, 2000, '', '', 0, nil,
           FTlsContext, APath);
      1: Sock := TTlsSocket.DialWithAlpn(AHost, 443,
           AlpnProtocolList([cHttp2AlpnProtocol]), False, 2000, '', '', 0, nil,
           FTlsContext, APath);
      2: Sock := TTlsSocket.DialCleartext(AHost, 80, 2000, '', 0, APath);
      3: Sock := TTlsSocket.DialVia(AHost, 443, False, 2000, '', nil, nil, nil,
           FTlsContext, nil, APath);
      4: Sock := TTlsSocket.DialWithAlpnVia(AHost, 443,
           AlpnProtocolList([cHttp2AlpnProtocol]), False, 2000, '', nil, nil,
           nil, FTlsContext, nil, False, APath);
      5: Sock := TTlsSocket.DialCleartextVia(AHost, 80, 2000, nil, False, '',
           nil, nil, APath);
    end;
    Result := True;
    Sock.Close;
  except
    on E: Exception do
      AError := E.Message;
  end;
end;

/// one dial method: the set path reaches the listener, and a missing path
/// fails with an error that names a Unix socket
procedure TUnixDialTest.CheckDial(const AWhat: string; const AKind: Integer;
  const AUseFactory, ATls: Boolean);
var
  Ok: Boolean;
  Err: string;
begin
  if ATls then
    StartTlsListener
  else
    StartEchoListener;
  if AUseFactory then
    Ok := FactoryDial(AKind, UnixFactory(FPath), 'tls.invalid', Err)
  else
    Ok := ClassDial(AKind, 'tls.invalid', FPath, Err);
  if ATls then
  begin
    // the listener reads the TLS record byte, then closes: the dial fails
    AssertFalse(AWhat + ': TLS dial fails at the handshake', Ok);
    AssertTrue(AWhat + ': the listener read a byte', FTls.WaitForByte(2000));
    AssertEquals(AWhat + ': first byte is a TLS record', $16,
      Integer(FTls.FirstRecordByte));
  end
  else
  begin
    AssertTrue(AWhat + ': cleartext dial succeeds: ' + Err, Ok);
    AssertTrue(AWhat + ': the listener accepted', WaitForAccepted(FEcho, 1, 2000));
  end;
  if AUseFactory then
    Ok := FactoryDial(AKind, UnixFactory(FPath + '.absent'), 'tls.invalid', Err)
  else
    Ok := ClassDial(AKind, 'tls.invalid', FPath + '.absent', Err);
  AssertFalse(AWhat + ': a missing path fails', Ok);
  AssertTrue(AWhat + ': error names a unix socket: ' + Err,
    Pos('unix socket', LowerCase(Err)) > 0);
end;

procedure TUnixDialTest.SetUp;
begin
  FPath := NewUnixTestPath;
  FTlsContext := OpenSslClientTestContext('', True);
  FEcho := nil;
  FTls := nil;
  SetLength(FKeep, 0);
end;

procedure TUnixDialTest.TearDown;
begin
  StopListeners;
  SetLength(FKeep, 0);
  FTlsContext := nil;
end;

procedure TUnixDialTest.TestFactoryDial;
begin
  CheckDial('Dial', 0, True, True);
end;

procedure TUnixDialTest.TestFactoryDialProtocol;
begin
  CheckDial('DialProtocol', 1, True, False);
end;

procedure TUnixDialTest.TestFactoryDialProtocolVia;
begin
  CheckDial('DialProtocolVia', 2, True, True);
end;

procedure TUnixDialTest.TestFactoryDialHttp1;
begin
  CheckDial('DialHttp1', 3, True, False);
end;

procedure TUnixDialTest.TestFactoryDialHttp1As;
begin
  CheckDial('DialHttp1As', 4, True, True);
end;

procedure TUnixDialTest.TestFactoryDialProtocolViaAs;
begin
  CheckDial('DialProtocolViaAs', 5, True, False);
end;

procedure TUnixDialTest.TestTlsSocketDial;
begin
  CheckDial('TTlsSocket.Dial', 0, False, True);
end;

procedure TUnixDialTest.TestTlsSocketDialWithAlpn;
begin
  CheckDial('TTlsSocket.DialWithAlpn', 1, False, True);
end;

procedure TUnixDialTest.TestTlsSocketDialCleartext;
begin
  CheckDial('TTlsSocket.DialCleartext', 2, False, False);
end;

procedure TUnixDialTest.TestTlsSocketDialVia;
begin
  CheckDial('TTlsSocket.DialVia', 3, False, True);
end;

procedure TUnixDialTest.TestTlsSocketDialWithAlpnVia;
begin
  CheckDial('TTlsSocket.DialWithAlpnVia', 4, False, True);
end;

procedure TUnixDialTest.TestTlsSocketDialCleartextVia;
begin
  CheckDial('TTlsSocket.DialCleartextVia', 5, False, False);
end;

procedure TUnixDialTest.TestSameListenerForAnyHost;
var
  Fac: TDefaultSocketFactory;
  Err1, Err2: string;
begin
  StartEchoListener;
  Fac := UnixFactory(FPath);
  // the host names do not resolve, so a DNS lookup would fail the dial
  AssertTrue('first host reaches the listener',
    FactoryDial(1, Fac, 'a.invalid', Err1));
  AssertTrue('second host reaches the listener',
    FactoryDial(3, Fac, 'b.invalid', Err2));
  AssertTrue('two connections accepted', WaitForAccepted(FEcho, 2, 2000));
  AssertEquals('one listener, two connections', 2, FEcho.Accepted);
end;

procedure TUnixDialTest.TestEmptyPathKeepsTcp;
var
  Listen, Conn: Integer;
  Port: Word;
  Fac: TDefaultSocketFactory;
  Sock: IHttp2Socket;
  Proto: TNegotiatedProtocol;
  Pfd: pollfd;
begin
  Listen := ListenTcpLoopback(Port);
  try
    Fac := TDefaultSocketFactory.Create('', False, '', 0, nil, nil, nil, nil, nil);
    KeepAlive(Fac);
    Sock := Fac.DialProtocol('127.0.0.1', Port, 'http', False,
      ctPriorKnowledge, 2000, Proto);
    Pfd.fd := Listen;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    AssertTrue('a TCP connection arrives', fpPoll(@Pfd, 1, 2000) > 0);
    Conn := fpAccept(Listen, nil, nil);
    AssertTrue('the TCP connection is accepted', Conn >= 0);
    if Conn >= 0 then
      fpClose(Conn);
    Sock.Close;
  finally
    fpClose(Listen);
  end;
end;

procedure TUnixDialTest.TestCloneKeepsThePath;
var
  Base, UnixFac: TDefaultSocketFactory;
  IdFac, TlsFac: TDefaultSocketFactory;
  Err, IdErr, TlsErr: string;
  IdOk, TlsOk: Boolean;
begin
  StartEchoListener;
  Base := TDefaultSocketFactory.Create('', False, '', 0, nil, nil, nil, nil, nil);
  KeepAlive(Base);
  UnixFac := Base.WithUnixPath(FPath);
  KeepAlive(UnixFac);
  IdFac := UnixFac.WithIdentity(nil, nil);
  KeepAlive(IdFac);
  IdOk := FactoryDial(1, IdFac, 'a.invalid', IdErr);
  AssertTrue('WithIdentity keeps the path: ' + IdErr, IdOk);
  AssertTrue('the accepted connection is on the path',
    WaitForAccepted(FEcho, 1, 2000));

  StartTlsListener;
  TlsFac := UnixFac.WithTlsContexts(FTlsContext, nil);
  KeepAlive(TlsFac);
  TlsOk := FactoryDial(0, TlsFac, 'tls.invalid', TlsErr);
  Err := TlsErr;
  AssertFalse('WithTlsContexts keeps the path: TLS dial fails: ' + Err, TlsOk);
  AssertTrue('the TLS listener read a byte', FTls.WaitForByte(2000));
  AssertEquals('first byte is a TLS record', $16, Integer(FTls.FirstRecordByte));
end;

initialization
  RegisterTest(TUnixDialTest);

end.
