{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, release
notes:
  - This unit tests that an undrained HTTP/1 response retires its connection.
---
}
unit Http2.Client.Http1Release.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1, Http2.Client.Pool.Types, Http2.Client.Pool.Http1, Http2.Client.ClearText.Support;

type
  THttp1ReleaseTest = class(TTestCase)
  published
    procedure TestUndrainedReleaseMarksConnectionClosed;
    procedure TestDrainedReleaseKeepsConnectionOpen;
  end;

implementation

const
  cBody302 = 'HTTP/1.1 302 Found'#13#10'Content-Length: 1000'#13#10#13#10;

procedure THttp1ReleaseTest.TestUndrainedReleaseMarksConnectionClosed;
var
  Sock: TScriptSocket;
  H1: THttp1Connection;
  Wire: IPooledConnection;
  Req: TStreamRequest;
  R: IHttpResponse;
  Acquired: Boolean;
begin
  Sock := TScriptSocket.Create;
  Sock.Feed(cBody302 + StringOfChar('x', 1000));
  H1 := THttp1Connection.Create(Sock, 500);
  Wire := THttp1PooledConnection.Create(H1, 'http://a.example');
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/x');
  R := Wire.Acquire(Req, 500, Acquired);
  AssertTrue('the request was acquired', Acquired);
  AssertFalse('the body is not drained', R.Body.Eof);
  // release the response without reading the body
  R := nil;
  AssertTrue('an undrained release retires the connection', Wire.Closed);
  Wire := nil;
end;

procedure THttp1ReleaseTest.TestDrainedReleaseKeepsConnectionOpen;
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
  Sock.Feed('HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'hi' +
    'HTTP/1.1 200 OK'#13#10'Content-Length: 2'#13#10#13#10'ok');
  H1 := THttp1Connection.Create(Sock, 500);
  Wire := THttp1PooledConnection.Create(H1, 'http://a.example');
  Req := TStreamRequest.Create('GET', 'a.example');
  Req := Req.WithScheme('http').WithPath('/x');
  R := Wire.Acquire(Req, 500, Acquired);
  AssertTrue('the first request was acquired', Acquired);
  repeat
    N := R.Body.Read(Buf[0], SizeOf(Buf));
  until N <= 0;
  AssertTrue('the body reached its end', R.Body.Eof);
  R := nil;
  AssertFalse('a drained release keeps the connection', Wire.Closed);
  R := Wire.Acquire(Req, 500, Acquired);
  AssertTrue('the second request reuses the connection', Acquired);
  R := nil;
  Wire := nil;
end;

initialization
  RegisterTest(THttp1ReleaseTest);
end.
