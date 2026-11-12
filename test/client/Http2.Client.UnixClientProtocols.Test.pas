{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests check the other protocols and the policy over a socket file:
    a redirect, the cleartext rule, TLS, server-sent events and WebSocket.
---
}
/// Tests for the client protocols and policy over a Unix socket file
// - each test runs its own listener on a fresh socket file, and removes the
//   file in TearDown
unit Http2.Client.UnixClientProtocols.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets, SyncObjs, fpcunit, testregistry,
  mormot.lib.openssl11,
  Http2.Client.Errors, Http2.Client.Messages, Http2.Client,
  Http2.Client.Factory, Http2.Client.Tls.Types, Http2.Client.Sse,
  Http2.Client.WebSocket, Http2.Client.Tls.Support,
  Http2.Client.Test.OpenSSL.SigPipe, Http2.Client.Test.TlsContext,
  Http2.Client.Unix.TestKit;

type
  /// a listener on a socket file that answers a redirect to another host for
  /// the first connection and 200 for the second; it keeps both request heads
  TRedirectListener = class(TUnixListener)
  private
    FFirst: RawByteString;
    FSecond: RawByteString;
  public
    /// reads the request head, then writes the answer for its connection
    procedure Serve(AFd: Integer); override;
    /// the request head of the first connection
    property First: RawByteString read FFirst;
    /// the request head of the second connection
    property Second: RawByteString read FSecond;
  end;

  /// a listener on a socket file that answers a TLS handshake with the test
  /// certificate, then answers 200 to one HTTP/1.1 request
  TTlsAnswerListener = class(TUnixListener)
  private
    FRequest: RawByteString;
    FHandshake: Integer;
  public
    /// runs the server handshake, reads the request head, then answers
    procedure Serve(AFd: Integer); override;
    /// the request head that the listener read over TLS
    property Request: RawByteString read FRequest;
    /// the result of SSL_accept; 1 when the handshake succeeded
    property HandshakeResult: Integer read FHandshake;
  end;

  /// a listener on a socket file that answers 200 with two server-sent events
  TSseAnswerListener = class(TUnixListener)
  public
    /// reads the request head, then writes the event stream
    procedure Serve(AFd: Integer); override;
  end;

  /// a listener on a socket file that answers the WebSocket handshake and one
  /// text frame
  TWebSocketAnswerListener = class(TUnixListener)
  public
    /// reads the handshake, writes the 101 answer and one text frame
    procedure Serve(AFd: Integer); override;
  end;

  /// a WebSocket listener that keeps the first text message it receives
  TTextRecorder = class(TWebSocketListener)
  private
    FText: string;
    FGot: TEvent;
  public
    /// creates the event that signals the text message
    constructor Create;
    destructor Destroy; override;
    /// keeps the text and signals the waiting test
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    /// waits up to ATimeoutMs for the text message; True when it arrived
    function WaitForText(const ATimeoutMs: Integer): Boolean;
    /// the text message that arrived
    property Text: string read FText;
  end;

  /// tests for the client protocols and policy over a Unix socket file
  TUnixClientProtocolsTest = class(TTestCase)
  private
    FPath: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRedirectToOtherHostUsesSamePath;
    procedure TestStrictCleartextPolicyStillRejectsHttpUrl;
    procedure TestHttpsUrlOverUnixPathUsesTls;
    procedure TestSseOverUnix;
    procedure TestWebSocketOverUnix;
  end;

implementation

const
  /// the blank line that ends an HTTP/1.1 request head
  ProtoHeadEnd = #13#10#13#10;
  /// the answer of a listener that serves 200 with no body
  ProtoOkAnswer = 'HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10 +
    'Connection: close'#13#10#13#10;
  /// the first answer of the redirect listener
  ProtoRedirectAnswer = 'HTTP/1.1 302 Found'#13#10 +
    'Location: http://other.test/y'#13#10'Content-Length: 0'#13#10 +
    'Connection: close'#13#10#13#10;

/// reads from a descriptor until AMarker arrives, the peer closes or the
/// timeout expires; returns what arrived
function ProtoReadUntil(AFd: Integer; const AMarker: RawByteString;
  const ATimeoutMs: Integer): RawByteString;
var
  Pfd: pollfd;
  Buf: array[0..511] of Byte;
  N, Old: Integer;
begin
  Result := '';
  while Pos(AMarker, Result) = 0 do
  begin
    Pfd.fd := AFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    if fpPoll(@Pfd, 1, ATimeoutMs) <= 0 then
      Break;
    N := fpRecv(AFd, @Buf[0], SizeOf(Buf), 0);
    if N <= 0 then
      Break;
    Old := Length(Result);
    SetLength(Result, Old + N);
    Move(Buf[0], Result[Old + 1], N);
  end;
end;

/// reads over a TLS session until AMarker arrives, the peer closes or the
/// timeout expires; the descriptor of the session is polled first
function ProtoSslReadUntil(ASsl: PSSL; AFd: Integer;
  const AMarker: RawByteString; const ATimeoutMs: Integer): RawByteString;
var
  Pfd: pollfd;
  Buf: array[0..511] of Byte;
  N, Old: Integer;
begin
  Result := '';
  while Pos(AMarker, Result) = 0 do
  begin
    Pfd.fd := AFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    if fpPoll(@Pfd, 1, ATimeoutMs) <= 0 then
      Break;
    N := TestSslRead(ASsl, @Buf[0], SizeOf(Buf));
    if N <= 0 then
      Break;
    Old := Length(Result);
    SetLength(Result, Old + N);
    Move(Buf[0], Result[Old + 1], N);
  end;
end;

/// the value of the header AName in AHead, without the surrounding blanks;
/// the name is matched without regard to case
function ProtoHeaderOf(const AHead: RawByteString; const AName: string): string;
var
  Text, Low: string;
  P: Integer;
begin
  Result := '';
  Text := string(AHead);
  Low := LowerCase(Text);
  P := Pos(LowerCase(AName) + ':', Low);
  if P = 0 then
    Exit;
  P := P + Length(AName) + 1;
  Result := Copy(Text, P, Length(Text));
  Result := Trim(Copy(Result, 1, Pos(#13, Result) - 1));
end;

{ TRedirectListener }

procedure TRedirectListener.Serve(AFd: Integer);
var
  Head: RawByteString;
begin
  Head := ProtoReadUntil(AFd, ProtoHeadEnd, 3000);
  if Accepted = 1 then
  begin
    FFirst := Head;
    WriteAll(AFd, ProtoRedirectAnswer);
  end
  else
  begin
    FSecond := Head;
    WriteAll(AFd, ProtoOkAnswer);
  end;
end;

{ TTlsAnswerListener }

procedure TTlsAnswerListener.Serve(AFd: Integer);
var
  Ctx: PSSL_CTX;
  Ssl: PSSL;
  Answer: RawByteString;
begin
  Answer := ProtoOkAnswer;
  Ctx := SSL_CTX_new(TLS_server_method());
  try
    SSL_CTX_use_certificate_file(Ctx,
      PUtf8Char(UTF8String(TestCertPath('localhost.crt'))), SSL_FILETYPE_PEM);
    SSL_CTX_use_PrivateKey_file(Ctx,
      PUtf8Char(UTF8String(TestCertPath('localhost.key'))), SSL_FILETYPE_PEM);
    Ssl := SSL_new(Ctx);
    try
      SSL_set_fd(Ssl, AFd);
      FHandshake := TestSslAccept(Ssl);
      if FHandshake = 1 then
      begin
        FRequest := ProtoSslReadUntil(Ssl, AFd, ProtoHeadEnd, 3000);
        TestSslWrite(Ssl, Pointer(Answer), Length(Answer));
      end;
      TestSslShutdown(Ssl);
    finally
      SSL_free(Ssl);
    end;
  finally
    SSL_CTX_free(Ctx);
  end;
end;

{ TSseAnswerListener }

procedure TSseAnswerListener.Serve(AFd: Integer);
begin
  ProtoReadUntil(AFd, ProtoHeadEnd, 3000);
  WriteAll(AFd, 'HTTP/1.1 200 OK'#13#10 +
    'Content-Type: text/event-stream'#13#10 +
    'Cache-Control: no-cache'#13#10 +
    'Connection: close'#13#10#13#10 +
    'id: 1'#10'data: a'#10#10 +
    'id: 2'#10'data: b'#10#10);
end;

{ TWebSocketAnswerListener }

procedure TWebSocketAnswerListener.Serve(AFd: Integer);
var
  Head: RawByteString;
  Key: string;
begin
  Head := ProtoReadUntil(AFd, ProtoHeadEnd, 3000);
  Key := ProtoHeaderOf(Head, 'Sec-WebSocket-Key');
  WriteAll(AFd, 'HTTP/1.1 101 Switching Protocols'#13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Accept: ' + WsComputeAccept(Key) + #13#10#13#10);
  // one unmasked text frame: FIN with opcode 1, length 2, payload 'hi'
  WriteAll(AFd, #$81#2'hi');
end;

{ TTextRecorder }

constructor TTextRecorder.Create;
begin
  inherited Create;
  FGot := TEvent.Create(nil, True, False, '');
end;

destructor TTextRecorder.Destroy;
begin
  FGot.Free;
  inherited Destroy;
end;

procedure TTextRecorder.OnText(const ASocket: IWebSocket;
  const AText: string; const ALast: Boolean);
begin
  FText := AText;
  FGot.SetEvent;
end;

function TTextRecorder.WaitForText(const ATimeoutMs: Integer): Boolean;
begin
  Result := FGot.WaitFor(ATimeoutMs) = wrSignaled;
end;

{ TUnixClientProtocolsTest }

procedure TUnixClientProtocolsTest.SetUp;
begin
  FPath := NewUnixTestPath;
end;

procedure TUnixClientProtocolsTest.TearDown;
begin
  if FileExists(FPath) then
    DeleteFile(FPath);
end;

procedure TUnixClientProtocolsTest.TestRedirectToOtherHostUsesSamePath;
var
  L: TRedirectListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  L := TRedirectListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithClearText(ctHttp1).WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    AssertEquals('the redirected request answers', 200, R.StatusCode);
    AssertEquals('two connections reached the file', 2, L.Accepted);
    AssertTrue('the first request is for the original path',
      Pos('GET /x HTTP/1.1', L.First) = 1);
    AssertTrue('the second request is for the redirect target',
      Pos('GET /y HTTP/1.1', L.Second) = 1);
    AssertTrue('the second request names the other host',
      Pos('Host: other.test'#13#10, L.Second) > 0);
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixClientProtocolsTest.TestStrictCleartextPolicyStillRejectsHttpUrl;
var
  L: TUnixListener;
  Client: IHttpClient;
  Raised: Boolean;
  Code: Integer;
begin
  L := TUnixListener.Create(FPath);
  try
    // the default policy is ctReject: the path does not lift it (D6)
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithConnectTimeout(2000).Build;
    Raised := False;
    Code := -1;
    try
      Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    except
      on E: EHttpError do
      begin
        Raised := True;
        Code := Ord(E.ErrorCode);
      end;
    end;
    AssertTrue('a cleartext request over the path raises by default', Raised);
    AssertEquals('the error code is PROTOCOL_ERROR', Ord(ecProtocolError), Code);
    AssertEquals('the file is not dialed', 0, L.Accepted);
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixClientProtocolsTest.TestHttpsUrlOverUnixPathUsesTls;
var
  L: TTlsAnswerListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  if not OpenSslIsAvailable then
  begin
    AssertTrue('OpenSSL unavailable; skipped', True);
    Exit;
  end;
  if (not FileExists(TestCertPath('localhost.crt'))) or
     (not FileExists(TestCertPath('localhost.key'))) then
  begin
    AssertTrue('test certs unavailable; skipped', True);
    Exit;
  end;
  L := TTlsAnswerListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithTlsContext(OpenSslClientTestContext('', True))
      .WithHttp1Fallback.WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'https://example.test/x'));
    AssertEquals('status', 200, R.StatusCode);
    AssertEquals('one connection reached the file', 1, L.Accepted);
    AssertEquals('the TLS handshake succeeded on the file', 1,
      L.HandshakeResult);
    AssertTrue('the request arrived inside TLS',
      Pos('GET /x HTTP/1.1', L.Request) = 1);
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixClientProtocolsTest.TestSseOverUnix;
var
  L: TSseAnswerListener;
  Client: IHttpClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
begin
  L := TSseAnswerListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithClearText(ctHttp1).WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    Loop := TSseReconnectLoop.Create(Client,
      SseRequest('http://example.test/events'), 3);
    try
      AssertTrue('first event', Loop.Next(E));
      AssertEquals('the first payload', 'a', E.Data);
      AssertTrue('second event', Loop.Next(E));
      AssertEquals('the second payload', 'b', E.Data);
      AssertEquals('no reconnect was needed', 0, Loop.Reconnects);
      AssertEquals('one connection reached the file', 1, L.Accepted);
    finally
      Loop.Free;
    end;
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixClientProtocolsTest.TestWebSocketOverUnix;
var
  L: TWebSocketAnswerListener;
  Rec: TTextRecorder;
  RecRef: IWebSocketListener;
  WsReq: IWebSocketRequest;
  Client: IHttpClient;
  Sock: IWebSocket;
begin
  L := TWebSocketAnswerListener.Create(FPath);
  Rec := TTextRecorder.Create;
  RecRef := Rec;
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithConnectTimeout(2000).WithHeaderTimeout(3000).Build;
    // AutoRequest lets the frame reach the listener without an explicit demand
    WsReq := TWebSocketRequest.Create('ws://example.test/chat', RecRef)
      .WithAutoRequest(True);
    Sock := Client.Send(WsReq);
    AssertTrue('the text frame arrived over the file',
      Rec.WaitForText(3000));
    AssertEquals('the text payload', 'hi', Rec.Text);
    AssertEquals('one connection reached the file', 1, L.Accepted);
    Sock.Abort;
    Client.Close;
  finally
    RecRef := nil;
    L.Free;
  end;
end;

initialization
  RegisterTest(TUnixClientProtocolsTest);
end.
