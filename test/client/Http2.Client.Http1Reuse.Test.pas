{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, reuse
notes:
  - This unit tests that an HTTP/1 connection with unread bytes after a body is not reused.
---
}
unit Http2.Client.Http1Reuse.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1, Http2.Client.Pool.Types, Http2.Client.Pool.Http1, Http2.Client.ClearText.Support;

type
  THttp1ReuseTest = class(TTestCase)
  published
    procedure TestExtraBytesAfterBodyRetireConnection;
    procedure TestNormalExchangeKeepsConnectionReusable;
  end;

implementation

procedure THttp1ReuseTest.TestExtraBytesAfterBodyRetireConnection;
var
  Sock: TScriptSocket;
  H1: THttp1Connection;
  Wire: IPooledConnection;
  Req: TStreamRequest;
  R: IHttpResponse;
  Acquired: Boolean;
  Buf: array[0..255] of Byte;
  N: Integer;
  Body, Chunk: string;
begin
  Sock := TScriptSocket.Create;
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok' +
    'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'evil!');
  H1 := THttp1Connection.Create(Sock, 500);
  Wire := THttp1PooledConnection.Create(H1, 'http://a.example');
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/x');
  R := Wire.Acquire(Req, 500, Acquired);
  AssertTrue('the first request was acquired', Acquired);
  repeat
    N := R.Body.Read(Buf[0], SizeOf(Buf));
  until N <= 0;
  AssertTrue('the first body reached its end', R.Body.Eof);
  R := nil;
  // the extra bytes must not become the response to request 2
  R := Wire.Acquire(Req, 500, Acquired);
  if Acquired then
  begin
    Body := '';
    repeat
      N := R.Body.Read(Buf[0], SizeOf(Buf));
      if N > 0 then
      begin
        SetString(Chunk, PAnsiChar(@Buf[0]), N);
        Body := Body + Chunk;
      end;
    until N <= 0;
    AssertTrue('request 2 must not read the extra bytes', Body <> 'evil!');
  end;
  R := nil;
  Wire := nil;
end;

procedure THttp1ReuseTest.TestNormalExchangeKeepsConnectionReusable;
var
  Sock: TScriptSocket;
  H1: THttp1Connection;
  Wire: IPooledConnection;
  Req: TStreamRequest;
  R: IHttpResponse;
  Acquired: Boolean;
  Buf: array[0..255] of Byte;
  N: Integer;
begin
  Sock := TScriptSocket.Create;
  // the first response alone: no bytes follow its body
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'hi');
  H1 := THttp1Connection.Create(Sock, 500);
  Wire := THttp1PooledConnection.Create(H1, 'http://a.example');
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/x');
  R := Wire.Acquire(Req, 500, Acquired);
  AssertTrue('the first request was acquired', Acquired);
  repeat
    N := R.Body.Read(Buf[0], SizeOf(Buf));
  until N <= 0;
  AssertTrue('the first body reached its end', R.Body.Eof);
  R := nil;
  AssertFalse('a normal exchange keeps the connection open', Wire.Closed);
  // the peer answers the next request later, as a keep-alive peer does
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok');
  R := Wire.Acquire(Req, 500, Acquired);
  AssertTrue('the second request reuses the connection', Acquired);
  R := nil;
  Wire := nil;
end;

initialization
  RegisterTest(THttp1ReuseTest);
end.
