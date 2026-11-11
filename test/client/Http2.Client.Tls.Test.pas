{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves TLS transport tests
---
}
unit Http2.Client.Tls.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, sockets, baseunix,
  mormot.lib.openssl11, Http2.Client.Errors, Http2.Client.Tls, Http2.Client.Tls.Support;
type
  TTlsTest = class(TTestCase)
  protected
    procedure SetUp; override;
  published
    // 05.1 interface / mock proof
    procedure TestMockSatisfiesIHttp2Socket;
    // 05.4 ALPN wire bytes and verification
    procedure TestAlpnWireBytesAreExact;
    procedure TestAlpnProtocolListOfTwo;
    procedure TestAlpnOfferForStrictOffersH2Only;          // 13.5
    procedure TestAlpnOfferForFallbackOffersHttp11Too;     // 13.5
    procedure TestAlpnNegotiatedNameMapsKnownAndUnknown;   // 13.5
    procedure TestAlpnNameDecodes;
    procedure TestRequireH2AlpnAcceptsH2;
    procedure TestRequireH2AlpnRejectsHttp11;
    procedure TestRequireH2AlpnRejectsNothing;
    procedure TestEstablishWithHttp11Raises;
    procedure TestEstablishWithNothingRaises;
    procedure TestEstablishWithH2Succeeds;
    // 05.6 SNI
    procedure TestSniHostPropagated;
    // 05.5 verification toggle
    procedure TestVerifyModeForInsecureIsNone;
    procedure TestVerifyModeForSecureIsPeer;
    procedure TestInsecureToggleReachesCtx;
    procedure TestSecureDefaultRejectsSelfSigned;
    procedure TestInsecureAcceptsSelfSigned;    // 05.7 timeouts / short reads
    procedure TestSocketReadFullyReassemblesSplitPayload;
    procedure TestSocketReadFullyMapsTimeout;
    procedure TestTlsReadReassemblesChunks;
    // 05.8 OpenSSL availability
    procedure TestOpenSslAvailability;
    // proxy CONNECT tunnel
    procedure TestConnectTunnelSendsRequestAndSucceeds;
    procedure TestConnectTunnelRejectsNon2xx;
    // integration (opt-in)
    procedure TestLiveNghttpdAlpnIfEnabled;
  end;

implementation

procedure TTlsTest.SetUp;
begin
  // load OpenSSL once on the main thread before any worker thread calls into
  // it; OpenSslIsAvailable is documented thread-safe but the first load must
  // not race two callers
  if not OpenSslIsAvailable then
  begin
    // nothing to do; the tests that need TLS self-skip
  end;
end;

procedure TTlsTest.TestMockSatisfiesIHttp2Socket;
var
  Sock: IHttp2Socket;
begin
  Sock := TMockSocket.Create;
  AssertTrue('mock reports connected', Sock.Connected);
  Sock.ConnectTimeoutMs := 7;
  AssertEquals('connect timeout round-trip', 7, Sock.ConnectTimeoutMs);
  Sock.Close;
  AssertFalse('mock reports closed', Sock.Connected);
  AssertEquals('mock write echoes count', 4, Sock.Write(Pointer(nil)^, 4));
end;

procedure TTlsTest.TestAlpnWireBytesAreExact;
var
  Wire: TBytes;
begin
  Wire := AlpnProtocolList(['h2']);
  AssertEquals('wire length', 3, Length(Wire));
  AssertEquals('length byte', $02, Wire[0]);
  AssertEquals('h', $68, Wire[1]);
  AssertEquals('2', $32, Wire[2]);
end;

procedure TTlsTest.TestAlpnProtocolListOfTwo;
var
  Wire: TBytes;
begin
  Wire := AlpnProtocolList(['h2', 'http/1.1']);
  AssertEquals('total length', 1 + 2 + 1 + 8, Length(Wire));
  AssertEquals('h2 length', $02, Wire[0]);
  AssertEquals('second length', 8, Wire[3]);
  AssertEquals('second first char', Ord('h'), Wire[4]);
end;

procedure TTlsTest.TestAlpnOfferForStrictOffersH2Only;
var
  Wire: TBytes;
begin
  // fallback off (the strict default) offers "h2" alone (doc/design/fallback.md
  // "Negotiation" step 2)
  Wire := AlpnOfferFor(False);
  AssertEquals('strict offer is 3 bytes', 3, Length(Wire));
  AssertEquals('strict offer length byte', $02, Wire[0]);
  AssertEquals('strict offer spells h2', 'h2',
    AlpnSelectedName(RawPtrOf(Wire) + 1, 2));
end;

procedure TTlsTest.TestAlpnOfferForFallbackOffersHttp11Too;
var
  Wire: TBytes;
begin
  // fallback on offers "h2" then "http/1.1", in that preference order
  Wire := AlpnOfferFor(True);
  AssertEquals('fallback offer is 12 bytes', 1 + 2 + 1 + 8, Length(Wire));
  AssertEquals('h2 is first', $02, Wire[0]);
  AssertEquals(' then http/1.1', 8, Wire[3]);
  AssertEquals('http/1.1 bytes follow', 'http/1.1',
    AlpnSelectedName(RawPtrOf(Wire) + 4, 8));
end;

procedure TTlsTest.TestAlpnNegotiatedNameMapsKnownAndUnknown;
begin
  // only the two known names survive; anything else (including the empty
  // selection) normalises to '' so the caller applies its fallback policy
  AssertEquals('h2 is kept', 'h2', AlpnNegotiatedName('h2'));
  AssertEquals('http/1.1 is kept', 'http/1.1', AlpnNegotiatedName('http/1.1'));
  AssertEquals('empty maps to empty', '', AlpnNegotiatedName(''));
  AssertEquals('an unknown protocol maps to empty', '',
    AlpnNegotiatedName('spdy/3.1'));
end;

procedure TTlsTest.TestAlpnNameDecodes;
var
  B: TBytes;
begin
  B := BytesOf('h2');
  AssertEquals('decodes h2', 'h2', AlpnSelectedName(RawPtrOf(B), Length(B)));
  B := nil;
  AssertEquals('nil decodes empty', '', AlpnSelectedName(RawPtrOf(B), 0));
end;

procedure TTlsTest.TestRequireH2AlpnAcceptsH2;
var
  B: TBytes;
begin
  B := BytesOf('h2');
  RequireH2Alpn(RawPtrOf(B), Length(B)); // must not raise
  AssertTrue('h2 accepted', True);
end;

procedure TTlsTest.TestRequireH2AlpnRejectsHttp11;
var
  B: TBytes;
  Raised: Boolean;
begin
  B := BytesOf('http/1.1');
  Raised := False;
  try
    RequireH2Alpn(RawPtrOf(B), Length(B));
  except
    on E: EHttpProtocolError do
      Raised := True;
  end;
  AssertTrue('http/1.1 raises EHttpProtocolError', Raised);
end;

procedure TTlsTest.TestRequireH2AlpnRejectsNothing;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    RequireH2Alpn(nil, 0);
  except
    on E: EHttpProtocolError do
      Raised := True;
  end;
  AssertTrue('no selection raises EHttpProtocolError', Raised);
end;

procedure TTlsTest.TestEstablishWithHttp11Raises;
var
  Sock: TFakeTlsSocket;
  Raised: Boolean;
begin
  Sock := TFakeTlsSocket.Create(TMockSocket.Create, 'example.com', True);
  try
    Sock.SetAlpnBytes(BytesOf('http/1.1'));
    Raised := False;
    try
      Sock.Establish;
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('http/1.1 peer fails the handshake', Raised);
    AssertFalse('not connected after ALPN failure', Sock.Connected);
  finally
    Sock.Free;
  end;
end;

procedure TTlsTest.TestEstablishWithNothingRaises;
var
  Sock: TFakeTlsSocket;
  Raised: Boolean;
begin
  Sock := TFakeTlsSocket.Create(TMockSocket.Create, 'example.com', True);
  try
    Raised := False;
    try
      Sock.Establish;
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('peer selecting nothing fails the handshake', Raised);
  finally
    Sock.Free;
  end;
end;

procedure TTlsTest.TestEstablishWithH2Succeeds;
var
  Sock: TFakeTlsSocket;
begin
  Sock := TFakeTlsSocket.Create(TMockSocket.Create, 'example.com', True);
  try
    Sock.SetAlpnBytes(BytesOf('h2'));
    Sock.Establish;
    AssertEquals('selected protocol recorded', 'h2', Sock.SelectedProtocol);
    AssertTrue('connected after successful handshake', Sock.Connected);
  finally
    Sock.Free;
  end;
end;

procedure TTlsTest.TestSniHostPropagated;
var
  Sock: TFakeTlsSocket;
begin
  Sock := TFakeTlsSocket.Create(TMockSocket.Create, 'origin.example', False);
  try
    Sock.SetAlpnBytes(BytesOf('h2'));
    Sock.Establish;
    AssertEquals('SNI host set from origin host', 'origin.example', Sock.SniHost);
    AssertTrue('hostname verification applied in secure mode',
      Sock.HostnameVerified);
  finally
    Sock.Free;
  end;
end;

procedure TTlsTest.TestVerifyModeForInsecureIsNone;
begin
  AssertEquals('insecure maps to SSL_VERIFY_NONE', SSL_VERIFY_NONE,
    SslVerifyModeFor(True));
end;

procedure TTlsTest.TestVerifyModeForSecureIsPeer;
begin
  AssertEquals('secure maps to SSL_VERIFY_PEER', SSL_VERIFY_PEER,
    SslVerifyModeFor(False));
end;

procedure TTlsTest.TestInsecureToggleReachesCtx;
var
  Sock: TFakeTlsSocket;
begin
  Sock := TFakeTlsSocket.Create(TMockSocket.Create, 'example.com', True);
  try
    Sock.SetAlpnBytes(BytesOf('h2'));
    Sock.Establish;
    AssertEquals('insecure context uses SSL_VERIFY_NONE', SSL_VERIFY_NONE,
      Sock.VerifyMode);
    AssertFalse('hostname verification skipped when insecure',
      Sock.HostnameVerified);
  finally
    Sock.Free;
  end;
end;

procedure TTlsTest.TestSecureDefaultRejectsSelfSigned;
var
  R: TRealHandshakeResult;
begin
  if not OpenSslIsAvailable then
  begin
    AssertTrue('OpenSSL unavailable; skipped', True);
    Exit;
  end;
  R := RunRealHandshake(False);
  if R.Skipped then
  begin
    AssertTrue('test certs unavailable; skipped', True);
    Exit;
  end;
  AssertTrue('secure client rejected the self-signed server', R.Raised);
  AssertFalse('rejection is a crypto/connection failure, not just ALPN',
    R.WasProtocolError);
end;

procedure TTlsTest.TestInsecureAcceptsSelfSigned;
var
  R: TRealHandshakeResult;
begin
  if not OpenSslIsAvailable then
  begin
    AssertTrue('OpenSSL unavailable; skipped', True);
    Exit;
  end;
  R := RunRealHandshake(True);
  if R.Skipped then
  begin
    AssertTrue('test certs unavailable; skipped', True);
    Exit;
  end;
  // in insecure mode the self-signed certificate is accepted: the handshake
  // reaches the ALPN check, which is the only thing still missing here
  AssertTrue('insecure client got past certificate verification',
    R.WasProtocolError);
end;

procedure TTlsTest.TestSocketReadFullyReassemblesSplitPayload;
var
  a, b: Integer;
  got: array[0..4] of Byte;
  th: TWriterThread;
begin
  AssertTrue('socketpair created', MakeSocketPair(a, b));
  try
    // first fragment available immediately, second arrives after a delay, so
    // a single recv cannot satisfy the request and the read loop must iterate
    RawSend(b, 'AB');
    th := TWriterThread.Create(b, BytesOf('CDE'), 40);
    th.Start;
    AssertEquals('read fully reassembles split payload',
      5, SocketReadFully(a, 5, 2000, got));
    AssertTrue('first byte A', got[0] = Ord('A'));
    AssertTrue('last byte E', got[4] = Ord('E'));
    th.WaitFor;
    th.Free;
  finally
    fpClose(a);
    fpClose(b);
  end;
end;

procedure TTlsTest.TestSocketReadFullyMapsTimeout;
var
  a, b: Integer;
  buf: array[0..0] of Byte;
  Raised: Boolean;
  t0: QWord;
begin
  AssertTrue('socketpair created', MakeSocketPair(a, b));
  try
    // idle socket: the deadline must surface as EHttpTimeout
    t0 := GetTickCount64;
    Raised := False;
    try
      SocketReadFully(a, 1, 120, buf);
    except
      on E: EHttpTimeout do
        Raised := True;
    end;
    AssertTrue('stalled read raises EHttpTimeout', Raised);
    AssertTrue('timeout honoured roughly', GetTickCount64 - t0 >= 100);
  finally
    fpClose(a);
    fpClose(b);
  end;
end;

procedure TTlsTest.TestTlsReadReassemblesChunks;
var
  Sock: TFakeTlsSocket;
  got: array[0..4] of Byte;
begin
  Sock := TFakeTlsSocket.Create(TMockSocket.Create, 'example.com', True);
  try
    Sock.SetAlpnBytes(BytesOf('h2'));
    Sock.Establish;
    // the TLS read loop must reassemble two short SSL_read results
    Sock.AddReadChunk(BytesOf('AB'));
    Sock.AddReadChunk(BytesOf('CDE'));
    AssertEquals('TLS read reassembles chunks', 5, Sock.Read(got, 5));
    AssertTrue('first byte A', got[0] = Ord('A'));
    AssertTrue('last byte E', got[4] = Ord('E'));
  finally
    Sock.Free;
  end;
end;

procedure TTlsTest.TestOpenSslAvailability;
begin
  // documents the runtime contract: OPENSSL_LIBPATH drives dynamic loading
  if OpenSslIsAvailable then
    AssertTrue('OpenSSL version reported', OpenSslVersionText <> '')
  else
    AssertTrue('OpenSSL absent without OPENSSL_LIBPATH (documented)', True);
end;

procedure TTlsTest.TestLiveNghttpdAlpnIfEnabled;
var
  Sock: IHttp2Socket;
begin
  if GetEnvironmentVariable('HTTP2_TLS_ITEST') <> '1' then
  begin
    AssertTrue('live nghttpd test skipped (set HTTP2_TLS_ITEST=1)', True);
    Exit;
  end;
  Sock := TTlsSocket.Dial('127.0.0.1', 8443, True, 3000);
  try
    AssertTrue('live TLS connection established', Sock.Connected);
    AssertEquals('nghttpd negotiated h2',
      'h2', (Sock as TTlsSocket).SelectedProtocol);
  finally
    Sock.Close;
  end;
end;

procedure TTlsTest.TestConnectTunnelSendsRequestAndSucceeds;
var
  listenFd: Integer;
  port: Word;
  Sock: IHttp2Socket;
  Server: TLoopbackProxyServer;
begin
  if not MakeLoopbackListener(listenFd, port) then
    raise EHttpConnectionError.Create(
      'could not create a loopback listener for the tunnel test');
  Server := TLoopbackProxyServer.Create(listenFd,
    'HTTP/1.1 200 Connection established'#13#10#13#10);
  Server.Start;
  Sleep(30);
  try
    Sock := TPlainSocket.Create('origin.example', 443, 2000,
      '127.0.0.1', port);
    AssertTrue('tunnel socket connected', Sock.Connected);
    Sock.Close;
    Server.WaitFor;
    AssertTrue('proxy saw a CONNECT request',
      Pos('CONNECT origin.example:443 HTTP/1.1', string(Server.Request)) = 1);
    AssertTrue('CONNECT carries a Host header',
      Pos('Host: origin.example:443', string(Server.Request)) > 0);
  finally
    Server.Free;
    fpClose(listenFd);
  end;
end;

procedure TTlsTest.TestConnectTunnelRejectsNon2xx;
var
  listenFd: Integer;
  port: Word;
  Sock: IHttp2Socket;
  Failed: Boolean;
  Server: TLoopbackProxyServer;
begin
  if not MakeLoopbackListener(listenFd, port) then
    raise EHttpConnectionError.Create(
      'could not create a loopback listener for the tunnel test');
  Server := TLoopbackProxyServer.Create(listenFd,
    'HTTP/1.1 403 Forbidden'#13#10#13#10);
  Server.Start;
  Sleep(30);
  Failed := False;
  try
    try
      Sock := TPlainSocket.Create('origin.example', 443, 2000,
        '127.0.0.1', port);
      Sock.Close;
    except
      on E: EHttpConnectionError do
        Failed := Pos('proxy CONNECT failed', E.Message) > 0;
    end;
  finally
    Server.WaitFor;
    Server.Free;
    fpClose(listenFd);
  end;
  AssertTrue('non-2xx CONNECT raises a connection error', Failed);
end;


initialization
  RegisterTest(TTlsTest);
end.
