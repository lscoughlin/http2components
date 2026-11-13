{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, body read timeout, server-sent events, sse idle
notes:
  - This unit pins the body-read deadline of the HTTP/1.1 client. A per-request
    body-read timeout (WithBodyReadTimeout, set by SseMaxIdleTimeMs) bounds each
    body read on HTTP/1.1, as it does on HTTP/2.
  - The socket in this unit simulates a silent peer. A read that finds no byte
    raises EHttpTimeout at once when the socket has a read timeout, so the tests
    take no wall-clock time and check the timeout value that each read used.
  - A timeout in the middle of a chunk loses no bytes (the rule of FU-10).
---
}
unit Http2.Client.Http1BodyTimeout.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Tls.Types, Http2.Client.Http1, Http2.Client.Sse,
  Http2.Client.ClearText.Support;

type
  /// a scripted socket whose peer can fall silent
  // - when the script is used up, a read waits for the peer. With a read
  //   timeout set, the read raises EHttpTimeout at once; without one, the read
  //   would block forever, so the socket raises EHttpConnectionClosed instead.
  //   SilentTimeoutMs keeps the read timeout that the last silent read used.
  TSilentSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FScript: TBytes;
    FPos: Integer;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
    FSilentReads: Integer;
    FSilentTimeoutMs: Integer;
  public
    constructor Create(const AReadTimeoutMs: Integer);
    /// append bytes that the peer sends next
    procedure Feed(const AText: string);
    function Read(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
    /// the number of reads that found the script used up
    property SilentReads: Integer read FSilentReads;
    /// the read timeout that the last silent read used
    property SilentTimeoutMs: Integer read FSilentTimeoutMs;
  end;

  THttp1BodyTimeoutTest = class(TTestCase)
  private
    function Chunk(const AData: string): string;
    function EventStream(const ABody: string): string;
  published
    procedure TestSseIdleLimitBoundsAnHttp1Read;
    procedure TestSseIdleLimitEndsTheStreamWithTheIdleError;
    procedure TestUnsetBodyReadTimeoutKeepsTheSocketTimeout;
    procedure TestZeroBodyReadTimeoutWaitsIndefinitely;
    procedure TestMidChunkTimeoutLosesNoBytes;
  end;

implementation

{ TSilentSocket }

constructor TSilentSocket.Create(const AReadTimeoutMs: Integer);
begin
  inherited Create;
  FReadTimeoutMs := AReadTimeoutMs;
end;

procedure TSilentSocket.Feed(const AText: string);
begin
  FScript := ConcatBytes(FScript, TextBytes(AText));
end;

function TSilentSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  Avail, N: Integer;
begin
  Avail := Length(FScript) - FPos;
  if Avail <= 0 then
  begin
    // the peer is silent: the read waits for the read timeout of the socket
    Inc(FSilentReads);
    FSilentTimeoutMs := FReadTimeoutMs;
    if FReadTimeoutMs > 0 then
      raise EHttpTimeout.Create('simulated read timeout');
    raise EHttpConnectionClosed.Create('a silent peer would block the read');
  end;
  N := ACount;
  if N > Avail then
    N := Avail;
  Move(FScript[FPos], PByte(@ABuffer)^, N);
  Inc(FPos, N);
  Result := N;
end;

function TSilentSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := ACount;
end;

procedure TSilentSocket.Close;
begin
end;

function TSilentSocket.GetConnected: Boolean;
begin
  Result := True;
end;

function TSilentSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TSilentSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TSilentSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TSilentSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TSilentSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TSilentSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

{ THttp1BodyTimeoutTest }

function THttp1BodyTimeoutTest.Chunk(const AData: string): string;
begin
  Result := LowerCase(IntToHex(Length(AData), 1)) + #13#10 + AData + #13#10;
end;

function THttp1BodyTimeoutTest.EventStream(const ABody: string): string;
begin
  Result := 'HTTP/1.1 200 OK'#13#10'Content-Type: text/event-stream'#13#10 +
    'Transfer-Encoding: chunked'#13#10#13#10 + Chunk(ABody);
end;

procedure THttp1BodyTimeoutTest.TestSseIdleLimitBoundsAnHttp1Read;
var
  Sock: TSilentSocket;
  Source: IHttpSseSource;
  H1: THttp1Connection;
  Req: TStreamRequest;
  Resp: IHttpResponse;
  E: TSseEvent;
begin
  // one event, then a silent peer. The socket timeout is 5000 ms; the SSE
  // idle limit of 300 ms must be the timeout of the body read.
  Sock := TSilentSocket.Create(5000);
  Sock.Feed(EventStream('data: one'#13#10#13#10));
  H1 := THttp1Connection.Create(Sock, 5000);
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/events').WithBodyReadTimeout(300);
  Resp := H1.Send(Req);
  Source := TSseSource.Create(Resp);
  try
    AssertTrue('the first event arrives', Source.ReadEvent(E));
    AssertEquals('the event data', 'one', string(E.Data));
    try
      Source.ReadEvent(E);
    except
      // the idle error is checked below
    end;
    AssertEquals('the silent read used the SSE idle limit', 300, Sock.SilentTimeoutMs);
    AssertEquals('one silent read', 1, Sock.SilentReads);
  finally
    Source.Close;
    H1.Free;
  end;
end;

procedure THttp1BodyTimeoutTest.TestSseIdleLimitEndsTheStreamWithTheIdleError;
var
  Sock: TSilentSocket;
  Source: IHttpSseSource;
  H1: THttp1Connection;
  Req: TStreamRequest;
  Resp: IHttpResponse;
  E: TSseEvent;
  Raised: Boolean;
begin
  Sock := TSilentSocket.Create(5000);
  Sock.Feed(EventStream('data: one'#13#10#13#10));
  H1 := THttp1Connection.Create(Sock, 5000);
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/events').WithBodyReadTimeout(300);
  Resp := H1.Send(Req);
  Source := TSseSource.Create(Resp);
  Raised := False;
  try
    AssertTrue('the first event arrives', Source.ReadEvent(E));
    try
      Source.ReadEvent(E);
    except
      on EHttpSseIdleTimeout do
        Raised := True;
    end;
    AssertTrue('the silent stream ends with EHttpSseIdleTimeout', Raised);
  finally
    Source.Close;
    H1.Free;
  end;
end;

procedure THttp1BodyTimeoutTest.TestUnsetBodyReadTimeoutKeepsTheSocketTimeout;
var
  Sock: TSilentSocket;
  H1: THttp1Connection;
  Req: TStreamRequest;
  Resp: IHttpResponse;
  Buf: array[0..63] of Byte;
  Raised: Boolean;
begin
  // no body-read timeout on the request: the historic behaviour holds, and the
  // body reads use the socket timeout (the header timeout) as before
  Sock := TSilentSocket.Create(5000);
  Sock.Feed(EventStream('data: one'#13#10#13#10));
  H1 := THttp1Connection.Create(Sock, 5000);
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/events');
  Resp := H1.Send(Req);
  Raised := False;
  try
    try
      while Resp.Body.Read(Buf[0], SizeOf(Buf)) > 0 do ;
    except
      on EHttpTimeout do
        Raised := True;
    end;
    AssertTrue('the silent body read raises the socket timeout', Raised);
    AssertEquals('the silent read used the socket timeout', 5000, Sock.SilentTimeoutMs);
  finally
    H1.Free;
  end;
end;

procedure THttp1BodyTimeoutTest.TestZeroBodyReadTimeoutWaitsIndefinitely;
var
  Sock: TSilentSocket;
  H1: THttp1Connection;
  Req: TStreamRequest;
  Resp: IHttpResponse;
  Buf: array[0..63] of Byte;
  Raised: Boolean;
begin
  // 0 means wait indefinitely: the socket read timeout is 0 during a silent read
  Sock := TSilentSocket.Create(5000);
  Sock.Feed(EventStream('data: one'#13#10#13#10));
  H1 := THttp1Connection.Create(Sock, 5000);
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/events').WithBodyReadTimeout(0);
  Resp := H1.Send(Req);
  Raised := False;
  try
    try
      while Resp.Body.Read(Buf[0], SizeOf(Buf)) > 0 do ;
    except
      on EHttpConnectionClosed do
        Raised := True;
    end;
    AssertTrue('the silent read would block', Raised);
    AssertEquals('the silent read has no timeout', 0, Sock.SilentTimeoutMs);
  finally
    H1.Free;
  end;
end;

procedure THttp1BodyTimeoutTest.TestMidChunkTimeoutLosesNoBytes;
var
  Sock: TSilentSocket;
  H1: THttp1Connection;
  Req: TStreamRequest;
  Resp: IHttpResponse;
  Buf: array[0..63] of Byte;
  N, Timeouts: Integer;
  Got: string;
  Chunk1: string;
begin
  // a four-byte chunk of which two bytes arrive; the peer is silent, then
  // sends the other two bytes and the end of the body
  Sock := TSilentSocket.Create(5000);
  Chunk1 := 'HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '4'#13#10'ab';
  Sock.Feed(Chunk1);
  H1 := THttp1Connection.Create(Sock, 5000);
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/x').WithBodyReadTimeout(300);
  Resp := H1.Send(Req);
  Got := '';
  Timeouts := 0;
  while True do
  begin
    N := -1;
    try
      N := Resp.Body.Read(Buf[0], SizeOf(Buf));
    except
      on EHttpTimeout do
      begin
        // the timeout is final for its read: the peer sends the rest now
        Inc(Timeouts);
        Sock.Feed('cd'#13#10'0'#13#10#13#10);
      end;
    end;
    if N < 0 then
      Continue;
    if N = 0 then
      Break;
    SetLength(Got, Length(Got) + N);
    Move(Buf[0], Got[Length(Got) - N + 1], N);
  end;
  H1.Free;
  AssertEquals('one timeout in the middle of the chunk', 1, Timeouts);
  AssertEquals('no byte is lost', 'abcd', Got);
end;

initialization
  RegisterTest(THttp1BodyTimeoutTest);
end.
