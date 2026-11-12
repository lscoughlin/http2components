{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test
notes:
  - This unit holds tests for a Unix socket.
  - The tests in this unit check that Build sets the socket path on the
    socket factory of the client, and that a request reaches the file.
---
}
/// Tests for the client request path over a Unix socket file that Build sets
// - each test runs its own listener on a fresh socket file, and removes the
//   file in TearDown
unit Http2.Client.UnixClientWire.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, BaseUnix, Sockets, fpcunit, testregistry,
  Http2.Client, Http2.Client.Messages, Http2.Client.Factory,
  Http2.Client.Tls.Types, Http2.Client.SocketFactory.Types,
  Http2.Client.Unix.TestKit;

type
  /// a listener on a socket file that records the request head and
  /// answers 200 with an empty body
  TRequestListener = class(TUnixListener)
  private
    FRequest: RawByteString;
  public
    /// reads the request head, then writes the answer
    procedure Serve(AFd: Integer); override;
    /// the request head that the listener read
    property Request: RawByteString read FRequest;
  end;

  /// a listener on a socket file that reads the HTTP/2 client preface and
  /// answers one empty SETTINGS frame
  TPrefaceListener = class(TUnixListener)
  private
    FPreface: RawByteString;
  public
    /// reads the preface, then writes the SETTINGS frame
    procedure Serve(AFd: Integer); override;
    /// the bytes that the listener read up to the end of the preface
    property Preface: RawByteString read FPreface;
  end;

  /// a loopback TCP listener that answers 200 to each connection
  TTcpAnswerListener = class(TThread)
  private
    FListenFd: Integer;
    FPort: Word;
  protected
    procedure Execute; override;
  public
    /// binds a loopback listener on a port that the kernel picks
    constructor Create;
    /// stops the accept loop and closes the listener
    destructor Destroy; override;
    /// the TCP port of the listener
    property Port: Word read FPort;
  end;

  /// an injected socket factory that records the dial and then fails it
  TRecordingSocketFactory = class(TInterfacedObject, IHttp2SocketFactory)
  private
    FHost: string;
    FPort: Word;
    FDials: Integer;
  public
    /// records the host and the port, then raises
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    /// the host of the last dial
    property Host: string read FHost;
    /// the port of the last dial
    property Port: Word read FPort;
    /// the number of dials
    property Dials: Integer read FDials;
  end;

  /// tests for the client request path over a Unix socket file
  TUnixClientWireTest = class(TTestCase)
  private
    FPath: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestRequestReachesTheListener;
    procedure TestInjectedFactoryIsNotTouched;
    procedure TestCopyBeforeWithUnixSocketStaysOnTcp;
    procedure TestAuthorityStaysTheUrlHost;
    procedure TestH2cPriorKnowledgeOverUnix;
  end;

implementation

const
  /// the HTTP/2 client connection preface, 24 bytes
  PrefaceMarker = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  /// the blank line that ends an HTTP/1.1 request head
  HeadEnd = #13#10#13#10;
  /// one SETTINGS frame with no settings: length 0, type 4, flags 0, stream 0
  EmptySettingsFrame = #0#0#0#4#0#0#0#0#0;
  /// the answer of the test listeners
  OkAnswer = 'HTTP/1.1 200 OK'#13#10'Content-Length: 0'#13#10 +
    'Connection: close'#13#10#13#10;

/// reads from a descriptor until AMarker arrives, the peer closes or the
/// timeout expires; returns what arrived
function ReadUntil(AFd: Integer; const AMarker: RawByteString;
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

{ TRequestListener }

procedure TRequestListener.Serve(AFd: Integer);
begin
  FRequest := ReadUntil(AFd, HeadEnd, 3000);
  WriteAll(AFd, OkAnswer);
end;

{ TPrefaceListener }

procedure TPrefaceListener.Serve(AFd: Integer);
begin
  FPreface := ReadUntil(AFd, PrefaceMarker, 3000);
  WriteAll(AFd, EmptySettingsFrame);
end;

{ TTcpAnswerListener }

constructor TTcpAnswerListener.Create;
var
  Addr: TInetSockAddr;
  Len: TSockLen;
  Opt: Integer;
begin
  inherited Create(True);
  FListenFd := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListenFd < 0 then
    raise Exception.Create('socket failed for the TCP listener');
  Opt := 1;
  fpSetSockOpt(FListenFd, SOL_SOCKET, SO_REUSEADDR, @Opt, SizeOf(Opt));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := 0;
  Addr.sin_addr.s_addr := htonl($7F000001);
  if fpBind(FListenFd, @Addr, SizeOf(Addr)) <> 0 then
  begin
    fpClose(FListenFd);
    raise Exception.Create('bind failed for the TCP listener');
  end;
  if fpListen(FListenFd, 4) <> 0 then
  begin
    fpClose(FListenFd);
    raise Exception.Create('listen failed for the TCP listener');
  end;
  Len := SizeOf(Addr);
  fpGetSockName(FListenFd, @Addr, @Len);
  FPort := ntohs(Addr.sin_port);
  Resume;
end;

destructor TTcpAnswerListener.Destroy;
begin
  Terminate;
  WaitFor;
  fpClose(FListenFd);
  inherited Destroy;
end;

procedure TTcpAnswerListener.Execute;
var
  Pfd: pollfd;
  Conn: Integer;
begin
  while not Terminated do
  begin
    Pfd.fd := FListenFd;
    Pfd.events := POLLIN;
    Pfd.revents := 0;
    if fpPoll(@Pfd, 1, 50) <= 0 then
      Continue;
    Conn := fpAccept(FListenFd, nil, nil);
    if Conn < 0 then
      Continue;
    try
      ReadUntil(Conn, HeadEnd, 3000);
      WriteAll(Conn, OkAnswer);
    finally
      fpClose(Conn);
    end;
  end;
end;

{ TRecordingSocketFactory }

function TRecordingSocketFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  FHost := AHost;
  FPort := APort;
  Inc(FDials);
  raise Exception.Create('recording factory: no socket');
end;

{ TUnixClientWireTest }

procedure TUnixClientWireTest.SetUp;
begin
  FPath := NewUnixTestPath;
end;

procedure TUnixClientWireTest.TearDown;
begin
  if FileExists(FPath) then
    DeleteFile(FPath);
end;

procedure TUnixClientWireTest.TestRequestReachesTheListener;
var
  L: TRequestListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  L := TRequestListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithClearText(ctHttp1).WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    AssertEquals('status', 200, R.StatusCode);
    AssertEquals('one connection on the file', 1, L.Accepted);
    AssertTrue('request line', Pos('GET /x HTTP/1.1', L.Request) = 1);
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixClientWireTest.TestInjectedFactoryIsNotTouched;
var
  L: TUnixListener;
  Rec: TRecordingSocketFactory;
  RecRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Failed: Boolean;
begin
  L := TUnixListener.Create(FPath);
  Rec := TRecordingSocketFactory.Create;
  RecRef := Rec;
  try
    Client := THttpClientFactory.Create.WithSocketFactory(RecRef)
      .WithUnixSocket(FPath).WithConnectTimeout(2000)
      .WithHeaderTimeout(2000).Build;
    Failed := False;
    try
      Client.Send(THttpRequest.Create(hmGet, 'https://example.test/x'));
    except
      Failed := True;
    end;
    AssertTrue('the recording factory fails the dial', Failed);
    AssertTrue('the injected factory was dialed', Rec.Dials > 0);
    AssertEquals('the URL host is dialed', 'example.test', Rec.Host);
    AssertEquals('the URL port is dialed', 443, Rec.Port);
    AssertEquals('the file is not dialed', 0, L.Accepted);
    Client.Close;
  finally
    RecRef := nil;
    L.Free;
  end;
end;

procedure TUnixClientWireTest.TestCopyBeforeWithUnixSocketStaysOnTcp;
var
  T: TTcpAnswerListener;
  U: TRequestListener;
  F0, F1: THttpClientFactory;
  C0, C1: IHttpClient;
  R0, R1: IHttpResponse;
begin
  T := TTcpAnswerListener.Create;
  U := TRequestListener.Create(FPath);
  try
    F0 := THttpClientFactory.Create.WithClearText(ctHttp1)
      .WithConnectTimeout(2000).WithHeaderTimeout(3000);
    F1 := F0.WithUnixSocket(FPath);
    C0 := F0.Build;
    C1 := F1.Build;
    R0 := C0.Send(THttpRequest.Create(hmGet,
      Format('http://127.0.0.1:%d/x', [T.Port])));
    AssertEquals('the copy made before WithUnixSocket answers', 200,
      R0.StatusCode);
    AssertEquals('the file is not dialed by the copy', 0, U.Accepted);
    R1 := C1.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    AssertEquals('the copy with the path answers', 200, R1.StatusCode);
    AssertEquals('the file is dialed by the copy with the path', 1,
      U.Accepted);
    C0.Close;
    C1.Close;
  finally
    U.Free;
    T.Free;
  end;
end;

procedure TUnixClientWireTest.TestAuthorityStaysTheUrlHost;
var
  L: TRequestListener;
  Client: IHttpClient;
  R: IHttpResponse;
begin
  L := TRequestListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithClearText(ctHttp1).WithConnectTimeout(2000)
      .WithHeaderTimeout(3000).Build;
    R := Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    AssertEquals('status', 200, R.StatusCode);
    AssertTrue('the Host header is the URL host',
      Pos('Host: example.test'#13#10, L.Request) > 0);
    Client.Close;
  finally
    L.Free;
  end;
end;

procedure TUnixClientWireTest.TestH2cPriorKnowledgeOverUnix;
var
  L: TPrefaceListener;
  Client: IHttpClient;
  Failed: Boolean;
begin
  L := TPrefaceListener.Create(FPath);
  try
    Client := THttpClientFactory.Create.WithUnixSocket(FPath)
      .WithClearText(ctPriorKnowledge).WithConnectTimeout(2000)
      .WithHeaderTimeout(2000).Build;
    // the listener answers only the SETTINGS frame, so the request fails
    // after the preface has arrived; the preface is what this test checks
    Failed := False;
    try
      Client.Send(THttpRequest.Create(hmGet, 'http://example.test/x'));
    except
      Failed := True;
    end;
    AssertTrue('the request ends without a response', Failed);
    AssertTrue('the client sent the HTTP/2 preface over the file',
      Pos(PrefaceMarker, L.Preface) = 1);
    Client.Close;
  finally
    L.Free;
  end;
end;

initialization
  RegisterTest(TUnixClientWireTest);
end.
