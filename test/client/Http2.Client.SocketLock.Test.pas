{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, websocket, close, lock
notes:
  - this tests that the HTTP/1 pooled connection and the WebSocket close
    their socket after they release their lock
  - a socket close runs a probe on a second thread; the probe tries to take
    the lock that the closing thread must not hold
  - every wait has a bound
---
}
unit Http2.Client.SocketLock.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Tls, Http2.Client.Http1, Http2.Client.Pool.Types,
  Http2.Client.Pool.Http1, Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection;

type
  TAction = procedure of object;

  /// runs one action on its own thread and says when it ended
  TProbeThread = class(TThread)
  private
    FAction: TAction;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const AAction: TAction);
    destructor Destroy; override;
    property Done: TEvent read FDone;
  end;

  /// a socket with canned input. A Close runs the hook of the test.
  TProbeSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FInput: TBytes;
    FPos: Integer;
    FHook: TAction;
    FCloses: Integer;
  public
    constructor Create(const AInput: TBytes);
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
    property Hook: TAction read FHook write FHook;
    property Closes: Integer read FCloses;
  end;

  TSocketLockTest = class(TTestCase)
  private
    FFreeAtClose: Integer;
    FHeldAtClose: Integer;
    FWire: THttp1PooledConnection;
    FLockToTry: TCriticalSection;
    FTried: Boolean;
    FWsConn: IWebSocket;
    FSenderThread: TProbeThread;
    FSent: TEvent;
    FSentInHook: Boolean;
    FSendResult: string;
    FHookRan: TEvent;
    procedure TryTheLock;
    procedure OnHttp1Close;
    procedure SendOnce;
    procedure OnWsClose;
    function ProbeLock(const ALock: TCriticalSection): Boolean;
    procedure NewPooled(const ASock: TProbeSocket;
      out AWire: IPooledConnection);
    procedure CheckClosedFree(const ASock: TProbeSocket);
    function Request: TStreamRequest;
  published
    procedure TestHttp1DrainClosesOutsideTheLock;
    procedure TestHttp1ReleaseIfIdleClosesOutsideTheLock;
    procedure TestHttp1FailedExchangeClosesOutsideTheLock;
    procedure TestHttp1ClosesOnce;
    procedure TestWebSocketTransportClosesOutsideTheSendLock;
  end;

implementation

const
  cWaitMs = 10000;
  cHookWaitMs = 2000;
  cResponse = 'HTTP/1.1 200 OK'#13#10'Content-Length: 4'#13#10#13#10'abcd';

{ TProbeThread }

constructor TProbeThread.Create(const AAction: TAction);
begin
  FAction := AAction;
  FDone := TEvent.Create(nil, True, False, '');
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TProbeThread.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TProbeThread.Execute;
begin
  try
    FAction();
  except
  end;
  FDone.SetEvent;
end;

{ TProbeSocket }

constructor TProbeSocket.Create(const AInput: TBytes);
begin
  inherited Create;
  FInput := AInput;
end;

function TProbeSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := Length(FInput) - FPos;
  if Result > ACount then
    Result := ACount;
  if Result <= 0 then
    Exit(0);
  Move(FInput[FPos], PByte(@ABuffer)^, Result);
  Inc(FPos, Result);
end;

function TProbeSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := ACount;
end;

procedure TProbeSocket.Close;
begin
  InterlockedIncrement(FCloses);
  if Assigned(FHook) then
    FHook();
end;

function TProbeSocket.GetConnected: Boolean;
begin
  Result := True;
end;

function TProbeSocket.GetConnectTimeoutMs: Integer;
begin
  Result := 1000;
end;

procedure TProbeSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
end;

function TProbeSocket.GetReadTimeoutMs: Integer;
begin
  Result := 1000;
end;

procedure TProbeSocket.SetReadTimeoutMs(const AValue: Integer);
begin
end;

function TProbeSocket.GetWriteTimeoutMs: Integer;
begin
  Result := 1000;
end;

procedure TProbeSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
end;

{ TSocketLockTest }

procedure TSocketLockTest.TryTheLock;
begin
  FTried := FLockToTry.TryEnter;
  if FTried then
    FLockToTry.Leave;
end;

function TSocketLockTest.ProbeLock(const ALock: TCriticalSection): Boolean;
var
  T: TProbeThread;
begin
  FLockToTry := ALock;
  FTried := False;
  T := TProbeThread.Create(TryTheLock);
  try
    AssertTrue('the probe ended', T.Done.WaitFor(cWaitMs) = wrSignaled);
    T.WaitFor;
  finally
    T.Free;
  end;
  Result := FTried;
end;

procedure TSocketLockTest.OnHttp1Close;
begin
  if ProbeLock(FWire.GetLock) then
    Inc(FFreeAtClose)
  else
    Inc(FHeldAtClose);
end;

procedure TSocketLockTest.NewPooled(const ASock: TProbeSocket;
  out AWire: IPooledConnection);
begin
  FWire := THttp1PooledConnection.Create(
    THttp1Connection.Create(ASock, 500), 'http://a.example');
  AWire := FWire;
  ASock.Hook := OnHttp1Close;
end;

procedure TSocketLockTest.CheckClosedFree(const ASock: TProbeSocket);
begin
  AssertTrue('the socket was closed', ASock.Closes > 0);
  AssertEquals('no close ran under the lock', 0, FHeldAtClose);
  AssertTrue('every close ran with the lock free', FFreeAtClose > 0);
end;

function TSocketLockTest.Request: TStreamRequest;
begin
  Result := TStreamRequest.Create('GET', 'a.example');
  Result := Result.WithScheme('http').WithPath('/x');
end;

function TextBytes(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if AText <> '' then
    Move(AText[1], Result[0], Length(AText));
end;

procedure TSocketLockTest.TestHttp1DrainClosesOutsideTheLock;
var
  Sock: TProbeSocket;
  Wire: IPooledConnection;
begin
  Sock := TProbeSocket.Create(nil);
  NewPooled(Sock, Wire);
  Wire.Drain;
  CheckClosedFree(Sock);
  Wire := nil;
end;

procedure TSocketLockTest.TestHttp1ReleaseIfIdleClosesOutsideTheLock;
var
  Sock: TProbeSocket;
  Wire: IPooledConnection;
  R: IHttpResponse;
  Acquired: Boolean;
  Buf: array[0..63] of Byte;
begin
  Sock := TProbeSocket.Create(TextBytes(cResponse));
  NewPooled(Sock, Wire);
  R := Wire.Acquire(Request, 500, Acquired);
  AssertTrue('acquired', Acquired);
  Wire.Drain;                        // busy: marks the entry, no close yet
  AssertEquals('no close while the body is unread', 0, Sock.Closes);
  while R.Body.Read(Buf[0], SizeOf(Buf)) > 0 do
    ;
  Wire.ReleaseIfIdle;
  CheckClosedFree(Sock);
  R := nil;
  Wire := nil;
end;

procedure TSocketLockTest.TestHttp1FailedExchangeClosesOutsideTheLock;
var
  Sock: TProbeSocket;
  Wire: IPooledConnection;
  R: IHttpResponse;
  Acquired, Failed: Boolean;
begin
  Sock := TProbeSocket.Create(nil);     // the peer sends nothing: EOF
  NewPooled(Sock, Wire);
  Failed := False;
  R := nil;
  try
    R := Wire.Acquire(Request, 500, Acquired);
  except
    Failed := True;
  end;
  AssertTrue('the exchange failed', Failed);
  CheckClosedFree(Sock);
  Wire := nil;
end;

procedure TSocketLockTest.TestHttp1ClosesOnce;
var
  Sock: TProbeSocket;
  Wire: IPooledConnection;
begin
  Sock := TProbeSocket.Create(nil);
  NewPooled(Sock, Wire);
  Wire.Drain;
  Wire.Drain;
  Wire.ReleaseIfIdle;
  AssertEquals('one close for three calls', 1, Sock.Closes);
  Wire := nil;
end;

procedure TSocketLockTest.SendOnce;
begin
  try
    FWsConn.SendText('x');
    FSendResult := 'sent';
  except
    on E: Exception do
      FSendResult := E.ClassName;
  end;
  FSent.SetEvent;
end;

procedure TSocketLockTest.OnWsClose;
begin
  // a sender on another thread: with the send lock free it ends at once with
  // "closed"; with the send lock held it waits until this close returns
  FSenderThread := TProbeThread.Create(SendOnce);
  FSentInHook := FSent.WaitFor(cHookWaitMs) = wrSignaled;
  FHookRan.SetEvent;
end;

procedure TSocketLockTest.TestWebSocketTransportClosesOutsideTheSendLock;
var
  Sock: TProbeSocket;
  RecRef: IWebSocketListener;
  Req: IWebSocketRequest;
  Input: TBytes;
begin
  // the peer sends a close frame (code 1000), then EOF
  SetLength(Input, 4);
  Input[0] := $88;
  Input[1] := $02;
  Input[2] := $03;
  Input[3] := $E8;
  Sock := TProbeSocket.Create(Input);
  RecRef := TWebSocketListener.Create;
  Req := TWebSocketRequest.Create('ws://a.example/x', RecRef);
  FSent := TEvent.Create(nil, True, False, '');
  FHookRan := TEvent.Create(nil, True, False, '');
  try
    FWsConn := TWebSocketConnection.Create(Sock,
      TBufferedReader.Create(Sock), Req, '', SecureRandomCardinal, False, nil);
    Sock.Hook := OnWsClose;
    (FWsConn as TWebSocketConnection).Start;
    AssertTrue('the transport was closed',
      FHookRan.WaitFor(cWaitMs) = wrSignaled);
    AssertTrue('the sender ended while the close ran', FSentInHook);
    AssertEquals('the sender saw a closed WebSocket',
      'EHttpWebSocketClosedError', FSendResult);
  finally
    FSent.SetEvent;
    if FSenderThread <> nil then
    begin
      FSenderThread.WaitFor;
      FSenderThread.Free;
    end;
    Sock.Hook := nil;
    FWsConn := nil;
    FSent.Free;
    FHookRan.Free;
  end;
end;

initialization
  RegisterTest(TSocketLockTest);
end.
