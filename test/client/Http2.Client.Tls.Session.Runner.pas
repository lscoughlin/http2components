{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, tls, fake, test
notes:
  - This bounded runner checks the client session adapter with fake streams.
---
}
program Http2.Client.Tls.Session.Runner;

{$mode delphi}{$H+}{$interfaces com}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs, Http2.Client.Errors, Http2.Client.Tls.Socket,
  Http2.Client.Tls.Types, Http2.Client.Tls.Tunnel,
  Http2.Client.SocketFactory, Http2.Common.Tls.Types,
  Http2.Client.Proxy,
  Http2.Client.Pool, Http2.Client.Pool.Types,
  Http2.Client.SocketFactory.Types,
  Http2.Client.Test.Support,
  Http2.Client.ClientCert, Http2.Client.Stream,
  Http2.Client.Tls.Deadline.Fake,
  Http2.Client.Tls.ZeroFeed.Fake,
  mormot.core.os,
  Http2.Common.Tls.Context, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session,
  Http2.Test.Tls.Fake, Http2.Client.Tls.Session.TestSupport;

procedure TestDirectPump;
var
  Raw: TPartialStream;
  RawSocket: IHttp2Socket;
  Context: ITLSContext;
  Spy: TContextSpy;
  Socket: IHttp2Socket;
  Info: IHttp2TlsSocketInfo;
  Partial: IPartialReader;
  Reply: AnsiString;
  Wire, Input: TBytes;
  BeforeReads: Integer;
  Buffer: array[0..7] of Byte;
  N, Total: Integer;
begin
  Raw := TPartialStream.Create(3);
  RawSocket := Raw;
  Spy := TContextSpy.Create(TTlsFakeContext.Create([trClient],
    tlsAuthNone, 0));
  Context := Spy;
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Check(Supports(Socket, IHttp2TlsSocketInfo, Info), 'TLS metadata interface missing');
  Check(Info.SelectedProtocol = 'h2', 'fake ALPN metadata was not retained');
  BeforeReads := Raw.ReadCount;
  Input := Bytes('data');
  Check(Socket.Write(Input[0], Length(Input)) = Length(Input),
    'TLS socket did not accept the full plaintext write');
  Check(Raw.ReadCount = BeforeReads, 'a successful write read from the peer');
  Wire := Raw.Output;
  Check((Length(Wire) >= 4) and (Wire[0] = $16),
    'handshake output was not flushed through partial writes');
  Check((Wire[Length(Wire) - 4] = Ord('d')) and
    (Wire[Length(Wire) - 1] = Ord('a')),
    'plaintext output was lost across partial transport writes');
  Raw.Push(Bytes('reply'));
  Check(Supports(Socket, IPartialReader, Partial), 'partial-reader interface missing');
  Total := 0;
  while Total < 5 do
  begin
    N := Partial.ReadSome(Buffer[Total], 5 - Total);
    if N <= 0 then Break;
    Inc(Total, N);
  end;
  SetString(Reply, PAnsiChar(@Buffer[0]), Total);
  Check((Total = 5) and (Reply = 'reply'),
    'partial encrypted input was not delivered exactly once');
  Socket.Close;
  Socket := nil;
  RawSocket := nil;
  Context := nil;
end;

procedure TestIpLiteralOmitsSniAndApplicationReadHasNoHandshakeDeadline;
var
  Raw: TPartialStream;
  RawSocket: IHttp2Socket;
  Context: ITLSContext;
  Spy: TContextSpy;
  Socket: IHttp2Socket;
  Partial: IPartialReader;
  Buffer: array[0..3] of Byte;
  N, Total: Integer;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Spy := TContextSpy.Create(TTlsFakeContext.Create([trClient], tlsAuthNone, 0));
  Context := Spy;
  Socket := TTlsSocket.Create(RawSocket, '2001:db8::1', Context, nil,
    ['h2'], 30);
  Check(Spy.LastOptions.HostName = '2001:db8::1',
    'IPv6 hostname was not passed to the TLS context');
  Check(Spy.LastOptions.ServerName = '', 'IPv6 literal was sent as SNI');
  Sleep(40);
  Raw.Push(Bytes('late'));
  Check(Supports(Socket, IPartialReader, Partial),
    'partial-reader interface missing');
  Total := 0;
  while Total < Length(Buffer) do
  begin
    N := Partial.ReadSome(Buffer[Total], Length(Buffer) - Total);
    if N <= 0 then Break;
    Inc(Total, N);
  end;
  Check(Total = Length(Buffer),
    'application read used the expired handshake deadline');
  Socket.Close;
  Socket := nil;
  RawSocket := nil;
  Context := nil;
end;

procedure TestApplicationReadTimeoutSurvivesPeerInputPump;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Data: array[0..3] of Byte;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsZeroFeedContext.Create(
    TTlsFakeContext.Create([trClient], tlsAuthNone, 0), False, True, False);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  try
    FillChar(Data, SizeOf(Data), 0);
    Socket.ReadTimeoutMs := 123;
    Raw.Push(Bytes('peer'));
    Socket.Write(Data[0], SizeOf(Data));
    Check(Socket.ReadTimeoutMs = 123,
      'application read timeout was reset after the handshake');
  finally
    Socket.Close;
  end;
end;

procedure TestZeroFeedRetainsPendingCiphertext;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Partial: IPartialReader;
  Buffer: array[0..7] of Byte;
  Reply: AnsiString;
  N, Total: Integer;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsZeroFeedContext.Create(
    TTlsFakeContext.Create([trClient], tlsAuthNone, 0));
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Raw.Push(Bytes('reply'));
  Check(Supports(Socket, IPartialReader, Partial),
    'partial-reader interface missing');
  N := Partial.ReadSome(Buffer[0], 1);
  Check((N = 1) and (Buffer[0] = Ord('!')),
    'zero-feed control did not return to plaintext delivery');
  Total := 0;
  while Total < 5 do
  begin
    N := Partial.ReadSome(Buffer[Total], 5 - Total);
    if N <= 0 then Break;
    Inc(Total, N);
  end;
  SetString(Reply, PAnsiChar(@Buffer[0]), Total);
  Check((Total = 5) and (Reply = 'reply'),
    'ciphertext beyond a zero feed was lost or duplicated');
  Socket.Close;
end;

procedure TestZeroFeedRetriesAfterOutputDrain;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Partial: IPartialReader;
  Buffer: Byte;
  Wire: TBytes;
  N, BeforeWireLength: Integer;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsZeroFeedContext.Create(
    TTlsFakeContext.Create([trClient], tlsAuthNone, 0), True);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  BeforeWireLength := Length(Raw.Output);
  Raw.Push(Bytes('ciphertext'));
  Check(Supports(Socket, IPartialReader, Partial),
    'partial-reader interface missing');
  N := Partial.ReadSome(Buffer, 1);
  Check((N = 1) and (Buffer = Ord('!')),
    'TLS input was not retried after output drained');
  Wire := Raw.Output;
  Check((Length(Wire) = BeforeWireLength + 1) and
    (Wire[High(Wire)] = Ord('!')),
    'TLS output did not drain before retrying input');
  Socket.Close;
end;

procedure TestAbsoluteDeadlineUnderTrickleInput;
var
  Raw: TPartialStream;
  RawSocket: IHttp2Socket;
  Context: ITLSContext;
  Started, Elapsed: QWord;
  TimedOut: Boolean;
begin
  Raw := TPartialStream.Create;
  Raw.EnableTrickleReads(40);
  Raw.Push(Bytes('12345678'));
  RawSocket := Raw;
  Context := TTlsDeadlineContext.Create;
  Started := mormot.core.os.GetTickCount64;
  TimedOut := False;
  try
    TTlsSocket.Create(RawSocket, 'example.test', Context, nil, ['h2'], 200);
  except
    on E: EHttpTimeout do
      TimedOut := True;
  end;
  Elapsed := mormot.core.os.GetTickCount64 - Started;
  Check(TimedOut, 'trickled handshake did not fail with its absolute deadline');
  Check((Elapsed >= 90) and (Elapsed < 180),
    'handshake deadline moved when input arrived');
  Check(Raw.ReadCount <= 3,
    'handshake kept reading after its absolute deadline');
  Check(not Raw.GetConnected, 'deadline failure did not close its transport');
  RawSocket := nil;
  Context := nil;
end;

procedure TestExplicitNilIdentity;
var
  Raw: TPartialStream;
  RawSocket: IHttp2Socket;
  Inner: ITLSContext;
  Spy: TContextSpy;
  Socket: TTlsSocket;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Spy := TContextSpy.Create(TTlsFakeContext.Create([trClient], tlsAuthNone, 0));
  Inner := Spy;
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Inner, nil,
    ['h2'], 1000, True);
  Check(Spy.LastOptions.IdentitySelection = tisExplicit,
    'an explicit nil identity restored the context default');
  Check(Spy.LastOptions.Identity = nil, 'the explicit nil identity changed');
  Socket.Free;
  RawSocket := nil;
end;

procedure TestNestedPump;
var
  Raw: TPartialStream;
  RawSocket, ProxyTls, OriginTls: IHttp2Socket;
  Context: ITLSContext;
  Input, Wire: TBytes;
begin
  Raw := TPartialStream.Create(2);
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  ProxyTls := TTlsSocket.Create(RawSocket, 'proxy.test', Context, nil, [], 1000);
  OriginTls := TTlsSocket.Create(ProxyTls, 'origin.test', Context, nil, ['h2'], 1000);
  Input := Bytes('nested');
  Check(OriginTls.Write(Input[0], Length(Input)) = Length(Input),
    'nested TLS write failed');
  Wire := Raw.Output;
  Check(Length(Wire) > 8, 'nested session output did not reach the raw stream');
  OriginTls.Close;
  ProxyTls.Close;
end;

procedure TestAlpnPolicy;
begin
  Check(ProtocolForTlsAlpn('h2', False) = npHttp2Tls,
    'strict h2 ALPN was not accepted');
  Check(ProtocolForTlsAlpn('', True) = npHttp1Tls,
    'missing ALPN did not select enabled fallback');
  Check(ProtocolForTlsAlpn('http/1.1', True) = npHttp1Tls,
    'HTTP/1.1 ALPN fallback was not accepted');
  try
    ProtocolForTlsAlpn('', False);
    raise Exception.Create('strict mode accepted missing ALPN');
  except
    on E: EHttpProtocolError do ;
  end;
  try
    ProtocolForTlsAlpn('h3', True);
    raise Exception.Create('fallback mode accepted an unsupported ALPN');
  except
    on E: EHttpProtocolError do ;
  end;
end;

procedure TestContextValidationAndPoolKey;
var
  ServerContext, ClientContext: ITLSContext;
  Protocols: TProtocolSocketFactory;
  Protocol: TNegotiatedProtocol;
  Factory1, Factory2: TDefaultSocketFactory;
  Proxy: IProxy;
  IsStream: Boolean;
  Pool: TConnectionPool;
  PoolFactory: IHttp2SocketFactory;
  Connection1, Connection2, Picked: IPooledConnection;
  Key1, Key2: string;
begin
  ServerContext := TTlsFakeContext.Create([trServer], tlsAuthNone, 0);
  Protocols := TProtocolSocketFactory.Create('', False, '', 0, nil, nil,
    ServerContext, nil);
  try
    Protocols.DialProtocol('unresolved.invalid', 443, 'https', False,
      ctReject, 50, Protocol);
    raise Exception.Create('server-only context was accepted as client context');
  except
    on E: EHttpTlsConfigError do ;
  end;
  Protocols := TProtocolSocketFactory.Create('', False, '', 0, nil, nil,
    nil, nil);
  try
    Protocols.DialProtocol('unresolved.invalid', 443, 'https', False,
      ctReject, 50, Protocol);
    raise Exception.Create('missing origin context was accepted');
  except
    on E: EHttpTlsConfigError do ;
  end;
  Proxy := ParseProxyUrl('https://unresolved.invalid:443');
  try
    DialRoutedTransport('origin.invalid', 443, 50, Proxy, False, '', nil,
      IsStream, ServerContext);
    raise Exception.Create('server-only proxy context was accepted');
  except
    on E: EHttpTlsConfigError do ;
  end;
  ClientContext := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Factory1 := TDefaultSocketFactory.Create('', False, '', 0, nil, nil, nil,
    ClientContext, nil);
  Factory2 := TDefaultSocketFactory.Create('', False, '', 0, nil, nil, nil,
    ServerContext, nil);
  Check(Factory1.TlsContextPoolKey <> Factory2.TlsContextPoolKey,
    'different TLS contexts shared a pool discriminator');
  PoolFactory := Factory1;
  Pool := TConnectionPool.Create(PoolFactory, 2, 4, 8, 50, 50, 1000);
  try
    Key1 := 'https://same.example tls=' + Factory1.TlsContextPoolKey +
      ' protocol=0:0';
    Key2 := 'https://same.example tls=' + Factory2.TlsContextPoolKey +
      ' protocol=0:0';
    Connection1 := TFakePooledConnection.Create(Key1, 0, True);
    Connection2 := TFakePooledConnection.Create(Key2, 0, True);
    Pool.AddForTest(Key1, Connection1);
    Pool.AddForTest(Key2, Connection2);
    Picked := Pool.PickForTest(Key1);
    Check(Picked = Connection1,
      'pool did not pick the connection for the first TLS context');
    Picked := Pool.PickForTest(Key2);
    Check(Picked = Connection2,
      'pool reused a connection with a different TLS context');
  finally
    Pool.Free;
  end;
end;

procedure TestCleartextRoutesPassHttpsProxyContext;
var
  Context: ITLSContext;
  Factory: TProtocolSocketFactory;
  Proxy: IProxy;
  Protocol: TNegotiatedProtocol;
  Policy: TClearTextPolicy;
  TriedTransport: Boolean;
begin
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Proxy := TProxy.Create(pkHttps, '127.0.0.1', 1);
  Factory := TProtocolSocketFactory.Create('', False, '', 0, nil, nil,
    nil, Context);
  for Policy in [ctHttp1, ctPriorKnowledge] do
  begin
    TriedTransport := False;
    try
      Factory.DialProtocolViaAs('127.0.0.1', 80, 'http', False, Policy, 50,
        Proxy, nil, False, Protocol);
    except
      on E: EHttpTlsConfigError do
        raise Exception.Create('cleartext route lost the HTTPS proxy context');
      on E: Exception do
        TriedTransport := True;
    end;
    Check(TriedTransport,
      'cleartext HTTPS proxy route did not reach transport setup');
  end;
end;

procedure TestEofAndClose;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Buffer: Byte;
  Partial: IPartialReader;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil, ['h2'], 1000);
  try
    Check(Supports(Socket, IPartialReader, Partial), 'partial-reader interface missing');
    Partial.ReadSome(Buffer, 1);
    raise Exception.Create('abrupt EOF did not report a TLS failure');
  except
    on E: EHttpConnectionClosed do ;
  end;
  Socket.Close;
  Check(not Raw.GetConnected, 'closing a TLS socket did not close its transport');
end;

procedure TestSelectorRunsOutsidePoolLock;
var
  Context: ITLSContext;
  FactoryObj: TDefaultSocketFactory;
  Factory: IHttp2SocketFactory;
  Pool: TConnectionPool;
  Probe: TLockProbeSelector;
  Selector: IClientIdentitySelector;
  Request: TStreamRequest;
begin
  Context := TTlsFakeContext.Create([trServer], tlsAuthNone, 0);
  FactoryObj := TDefaultSocketFactory.Create('', False, '', 0, nil, nil,
    nil, Context, nil);
  Factory := FactoryObj;
  Pool := TConnectionPool.Create(Factory, 1, 1, 1, 50, 50, 1000);
  Probe := nil;
  try
    Probe := TLockProbeSelector.Create(Pool);
    Selector := Probe;
    Pool.IdentitySelector := Selector;
    Request := TStreamRequest.Create('GET', 'unresolved.invalid');
    try
      Pool.Acquire('https://unresolved.invalid', 'unresolved.invalid', 443,
        Request, 50);
      raise Exception.Create('server-only context unexpectedly dialled');
    except
      on E: EHttpTlsConfigError do ;
    end;
    Check(Probe.Calls = 1, 'identity selector was not called once for the dial');
    Check(Probe.PoolLockAvailable,
      'identity selector ran while the connection-pool lock was held');
    Probe.JoinProbe;
  finally
    if Probe <> nil then
      Probe.JoinProbe;
    Pool.Free;
  end;
end;

procedure TestConstructorFailureClosesTransport;
var
  Raw: TPartialStream;
  RawSocket: IHttp2Socket;
  Context: ITLSContext;
  Failed: Boolean;
begin
  Raw := TPartialStream.Create(0);
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Failed := False;
  try
    TTlsSocket.Create(RawSocket, 'example.test', Context, nil, ['h2'], 1000);
  except
    on E: EHttpConnectionClosed do
      Failed := True;
  end;
  Check(Failed, 'zero-progress encrypted write did not fail construction');
  Check(not Raw.GetConnected,
    'constructor failure did not close the transport');
  RawSocket := nil;
  Context := nil;
end;

procedure TestBlockedReadAllowsConcurrentWriteAndClose;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Reader: TTlsReadWorker;
  WriteWorker: TTlsWriteWorker;
  ReadStarted, WriteFinished: Boolean;
begin
  Raw := TPartialStream.Create;
  Raw.EnableReadBlocking;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Reader := TTlsReadWorker.Create(Socket);
  WriteWorker := nil;
  try
    Reader.Start;
    ReadStarted := Raw.WaitForReadStart(1000);
    Check(ReadStarted, 'TLS reader did not reach the blocked transport read');
    WriteWorker := TTlsWriteWorker.Create(Socket);
    WriteWorker.Start;
    WriteFinished := WriteWorker.WaitDone(300);
    Socket.Close;
    Check(WriteFinished,
      'a blocked TLS read prevented an application write from acquiring the session');
    Check(WriteWorker.Error = '', 'concurrent TLS write failed: ' + WriteWorker.Error);
    Check(Reader.WaitDone(1000), 'closing the transport did not unblock the TLS read');
  finally
    Socket.Close;
    if WriteWorker <> nil then WriteWorker.Free;
    Reader.Free;
    Socket := nil;
    RawSocket := nil;
    Context := nil;
  end;
end;

procedure TestReaderFailureWakesWaitingWriter;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Reader: TTlsReadWorker;
  Writer: TTlsWriteWorker;
begin
  Raw := TPartialStream.Create;
  Raw.EnableReadBlocking;
  RawSocket := Raw;
  Context := TTlsZeroFeedContext.Create(
    TTlsFakeContext.Create([trClient], tlsAuthNone, 0), False, True);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Reader := TTlsReadWorker.Create(Socket);
  Writer := TTlsWriteWorker.Create(Socket);
  try
    Reader.Start;
    Check(Raw.WaitForReadStart(1000),
      'reader did not reach the blocked transport read');
    Writer.Start;
    Sleep(20);
    Raw.ReleaseBlockedRead;
    Check(Reader.WaitDone(500), 'EOF did not release the transport reader');
    Check(Writer.WaitDone(500),
      'reader failure left the waiting writer blocked');
    Check(Pos('EHttpConnectionClosed', Reader.Error) > 0,
      'reader failure lost its transport EOF category');
    Check(Pos('EHttpConnectionClosed', Writer.Error) > 0,
      'waiting writer did not receive the reader EOF category');
  finally
    Socket.Close;
    Raw.ReleaseBlockedRead;
    Reader.Free;
    Writer.Free;
    Socket := nil;
    RawSocket := nil;
    Context := nil;
  end;
end;

procedure TestBackpressuredWriteAllowsConcurrentRead;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Reader: TTlsReadWorker;
  Writer: TTlsWriteWorker;
  ReadFinished, WriteFinished: Boolean;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Raw.EnableWriteBlocking;
  Raw.Push(Bytes('reply'));
  Reader := TTlsReadWorker.Create(Socket);
  Writer := TTlsWriteWorker.Create(Socket);
  try
    Writer.Start;
    Reader.Start;
    Check(Raw.WaitForWriteStart(1000),
      'TLS writer did not reach the blocked transport write');
    ReadFinished := Reader.WaitDone(500);
    Raw.ReleaseBlockedWrite;
    WriteFinished := Writer.WaitDone(1000);
    Check(ReadFinished,
      'backpressured TLS write prevented a concurrent read');
    Check(Reader.Error = '', 'concurrent TLS read failed: ' + Reader.Error);
    Check(WriteFinished, 'backpressured TLS write did not complete');
    Check(Writer.Error = '', 'backpressured TLS write failed: ' + Writer.Error);
  finally
    Socket.Close;
    Raw.ReleaseBlockedWrite;
    Reader.Free;
    Writer.Free;
    Socket := nil;
    RawSocket := nil;
    Context := nil;
  end;
end;

procedure TestWriteFailureRecoversPeerClientAuthAlert;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Payload, Alert: TBytes;
  GotAlert: Boolean;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Raw.FailNextWrite;
  // A benign record fragment arrives before the alert.  The recovery loop
  // must keep reading within its deadline instead of reporting the write
  // failure after only the first fragment.
  Alert := Bytes('ab');
  SetLength(Alert, Length(Alert) + 1);
  Alert[High(Alert)] := $FA;
  Raw.Push(Alert);
  Payload := Bytes('preface');
  GotAlert := False;
  try
    Socket.Write(Payload[0], Length(Payload));
  except
    on E: EHttpTlsClientAuthError do
      GotAlert := E.Alert = 'certificate required';
  end;
  Check(GotAlert,
    'write failure did not preserve the peer client-certificate alert');
  Socket.Close;
  Socket := nil;
  RawSocket := nil;
  Context := nil;
end;

procedure TestWriteFailureWithoutAlertKeepsOriginalError;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Payload: TBytes;
  Started, Elapsed: QWord;
  Preserved: Boolean;
begin
  Raw := TPartialStream.Create;
  Raw.EnableReadBlocking;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Socket.ReadTimeoutMs := 100;
  Raw.FailNextWrite;
  Payload := Bytes('preface');
  Started := mormot.core.os.GetTickCount64;
  Preserved := False;
  try
    Socket.Write(Payload[0], Length(Payload));
  except
    on E: EHttpConnectionClosed do
      Preserved := E.Message = 'scripted socket write failed';
  end;
  Elapsed := mormot.core.os.GetTickCount64 - Started;
  Check(Preserved, 'write failure without an alert changed the original error');
  Check(Raw.WaitForReadStart(100), 'bounded alert read did not start');
  Check(Elapsed >= 70, 'empty alert read skipped its configured timeout');
  Check(Elapsed < 500, 'peer-alert recovery exceeded its read deadline');
  Socket.Close;
  Socket := nil;
  RawSocket := nil;
  Context := nil;
end;

procedure TestWriteFailureDoesNotDeadlockWithBusyReader;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Reader: TTlsReadWorker;
  Writer: TTlsWriteWorker;
  Alert: TBytes;
begin
  Raw := TPartialStream.Create;
  Raw.EnableReadBlocking;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  Reader := TTlsReadWorker.Create(Socket);
  Writer := TTlsWriteWorker.Create(Socket);
  try
    Reader.Start;
    Check(Raw.WaitForReadStart(500), 'TLS reader did not block on peer input');
    SetLength(Alert, 1);
    Alert[0] := $FA;
    Raw.Push(Alert);
    Raw.FailNextWrite;
    Writer.Start;
    Check(Writer.WaitDone(500), 'TLS writer deadlocked behind the reader');
    Check(Pos('scripted socket write failed', Writer.Error) > 0,
      'busy-reader write did not retain its transport error');
    Raw.ReleaseBlockedRead;
    Check(Reader.WaitDone(500), 'reader did not consume the pending peer alert');
    Check(Pos('EHttpTlsClientAuthError', Reader.Error) > 0,
      'reader did not retain the peer client-auth alert');
  finally
    Socket.Close;
    Raw.ReleaseBlockedRead;
    Reader.Free;
    Writer.Free;
    Socket := nil;
    RawSocket := nil;
    Context := nil;
  end;
end;

procedure TestWriteFailureZeroFeedDoesNotRetryOutput;
var
  Raw: TPartialStream;
  RawSocket, Socket: IHttp2Socket;
  Context: ITLSContext;
  Payload, Input: TBytes;
  BeforeWrites: Integer;
  Started, Elapsed: QWord;
  Preserved: Boolean;
begin
  Raw := TPartialStream.Create;
  RawSocket := Raw;
  Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 0);
  Socket := TTlsSocket.Create(RawSocket, 'example.test', Context, nil,
    ['h2'], 1000);
  BeforeWrites := Raw.WriteCount;
  Raw.FailAllWrites;
  SetLength(Input, 1);
  Input[0] := $FB; // the fake TLS session leaves this input unconsumed
  Raw.Push(Input);
  Payload := Bytes('preface');
  Started := mormot.core.os.GetTickCount64;
  Preserved := False;
  try
    Socket.Write(Payload[0], Length(Payload));
  except
    on E: EHttpConnectionClosed do
      Preserved := E.Message = 'scripted socket write failed';
  end;
  Elapsed := mormot.core.os.GetTickCount64 - Started;
  Check(Preserved, 'zero-feed recovery changed the original write failure');
  Check(Raw.WriteCount = BeforeWrites + 1,
    'zero-feed recovery retried encrypted output');
  Check(Elapsed < 500, 'zero-feed recovery did not remain bounded');
  Socket.Close;
  Socket := nil;
  RawSocket := nil;
  Context := nil;
end;

var
  Cases: Integer;
begin
  Cases := 0;
  WriteLn('RUN direct-pump'); Flush(Output);
  TestDirectPump; Inc(Cases);
  WriteLn('RUN ip-sni-read-deadline'); Flush(Output);
  TestIpLiteralOmitsSniAndApplicationReadHasNoHandshakeDeadline; Inc(Cases);
  WriteLn('RUN read-timeout-retained'); Flush(Output);
  TestApplicationReadTimeoutSurvivesPeerInputPump; Inc(Cases);
  WriteLn('RUN zero-feed-retention'); Flush(Output);
  TestZeroFeedRetainsPendingCiphertext; Inc(Cases);
  WriteLn('RUN zero-feed-output-drain'); Flush(Output);
  TestZeroFeedRetriesAfterOutputDrain; Inc(Cases);
  WriteLn('RUN absolute-deadline-trickle'); Flush(Output);
  TestAbsoluteDeadlineUnderTrickleInput; Inc(Cases);
  WriteLn('RUN nil-identity'); Flush(Output);
  TestExplicitNilIdentity; Inc(Cases);
  WriteLn('RUN nested-pump'); Flush(Output);
  TestNestedPump; Inc(Cases);
  WriteLn('RUN alpn-policy'); Flush(Output);
  TestAlpnPolicy; Inc(Cases);
  WriteLn('RUN context-and-pool'); Flush(Output);
  TestContextValidationAndPoolKey; Inc(Cases);
  WriteLn('RUN cleartext-https-proxy-context'); Flush(Output);
  TestCleartextRoutesPassHttpsProxyContext; Inc(Cases);
  WriteLn('RUN eof-close'); Flush(Output);
  TestEofAndClose; Inc(Cases);
  WriteLn('RUN selector-lock'); Flush(Output);
  TestSelectorRunsOutsidePoolLock; Inc(Cases);
  WriteLn('RUN constructor-cleanup'); Flush(Output);
  TestConstructorFailureClosesTransport; Inc(Cases);
  WriteLn('RUN blocked-read-write-close'); Flush(Output);
  TestBlockedReadAllowsConcurrentWriteAndClose; Inc(Cases);
  WriteLn('RUN reader-failure-wakes-writer'); Flush(Output);
  TestReaderFailureWakesWaitingWriter; Inc(Cases);
  WriteLn('RUN backpressured-write-read'); Flush(Output);
  TestBackpressuredWriteAllowsConcurrentRead; Inc(Cases);
  WriteLn('RUN write-failure-auth-alert'); Flush(Output);
  TestWriteFailureRecoversPeerClientAuthAlert; Inc(Cases);
  WriteLn('RUN write-failure-preserved-deadline'); Flush(Output);
  TestWriteFailureWithoutAlertKeepsOriginalError; Inc(Cases);
  WriteLn('RUN write-failure-busy-reader'); Flush(Output);
  TestWriteFailureDoesNotDeadlockWithBusyReader; Inc(Cases);
  WriteLn('RUN write-failure-zero-feed'); Flush(Output);
  TestWriteFailureZeroFeedDoesNotRetryOutput; Inc(Cases);
  WriteLn('PASS ', Cases, ' cases');
end.
