{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this tests the size limits, the retry cap and the idle time of server-sent events
---
}
/// Server-Sent Events limits (plan story S-24).
// - the parser tests are pure. The line, event and retry limits come from
//   TClientSecurityOptions, and a value of 0 turns a limit off.
// - the idle tests use a scripted client that implements IHttpClientOptions and
//   a scripted body that raises EHttpTimeout after a silence longer than the
//   idle limit. This is the same error that a body read raises on HTTP/2 when
//   its deadline passes.
unit Http2.Client.SseLimits.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Config.Security,
  Http2.Client.Stream, Http2.Client.Stream.Types, Http2.Client.Messages,
  Http2.Client, Http2.Client.WebSocket, Http2.Client.Sse,
  Http2.Client.Sse.Support, Http2.Common.Body;

type
  /// one scripted read: wait DelayMs, then return Text
  TScriptedItem = record
    DelayMs: Integer;
    Text: string;
  end;

  /// a body that yields its items in order and raises EHttpTimeout when one
  /// of them would wait longer than the idle limit (0 = no limit)
  // - deliberately NOT reference counted: the client owns the instances
  TScriptedBody = class(TBodyReaderBase, IHttpBodyStream)
  private
    FItems: TList<TScriptedItem>;
    FIndex: Integer;
    FIdleMs: Integer;
  public
    constructor Create(const AIdleMs: Integer);
    destructor Destroy; override;
    /// queue one read: wait ADelayMs, then yield AText
    function Add(const ADelayMs: Integer; const AText: string): TScriptedBody;
    function Read(var ABuffer; const ACount: LongInt): LongInt; override;
    function Eof: Boolean;
    function QueryInterface(constref AID: TGUID; out AObj): LongInt; cdecl;
    function _AddRef: LongInt; cdecl;
    function _Release: LongInt; cdecl;
  end;

  /// an IHttpClient that also reports security options (IHttpClientOptions)
  // - deliberately NOT reference counted: the test owns the instance
  TOptionsClient = class(TInterfacedObject, IHttpClient, IHttpClientOptions)
  private
    FBodies: TObjectList<TScriptedBody>;
    FRequests: TList<THttpRequest>;
    FIndex: Integer;
    FOptions: TClientSecurityOptions;
  public
    constructor Create(const AOptions: TClientSecurityOptions);
    destructor Destroy; override;
    function QueryInterface(constref AID: TGUID; out AObj): LongInt; cdecl;
    function _AddRef: LongInt; cdecl;
    function _Release: LongInt; cdecl;
    function Options: TClientSecurityOptions;
    /// queue one response body; the client owns it
    function AddBody(const AIdleMs: Integer): TScriptedBody;
    function Send(const ARequest: THttpRequest): IHttpResponse; overload;
    function Send(const ARequest: IWebSocketRequest): IWebSocket; overload;
    procedure Close;
    function RequestCount: Integer;
  end;

  /// runs one reconnect-loop Next in another thread
  TNextThread = class(TThread)
  public
    Loop: TSseReconnectLoop;
    Got: Boolean;
    Failed: Boolean;
    EndedTick: QWord;
    procedure Execute; override;
  end;

  TSseLimitsTest = class(TTestCase)
  published
    procedure TestLineOverLimitRaises;
    procedure TestLineAtLimitIsAccepted;
    procedure TestZeroLineLimitIsOff;
    procedure TestEventOverLimitRaises;
    procedure TestRetryIsCappedByOption;
    procedure TestCloseWakesTheReconnectWait;
    procedure TestIdleStreamRaisesIdleTimeout;
    procedure TestKeepAliveCommentsKeepStreamAlive;
    procedure TestBomIsStrippedAtStart;
  end;

implementation

{ TScriptedBody }

constructor TScriptedBody.Create(const AIdleMs: Integer);
begin
  inherited Create;
  FItems := TList<TScriptedItem>.Create;
  FIndex := 0;
  FIdleMs := AIdleMs;
end;

destructor TScriptedBody.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

function TScriptedBody.Add(const ADelayMs: Integer;
  const AText: string): TScriptedBody;
var
  Item: TScriptedItem;
begin
  Item.DelayMs := ADelayMs;
  Item.Text := AText;
  FItems.Add(Item);
  Result := Self;
end;

function TScriptedBody.Read(var ABuffer; const ACount: LongInt): LongInt;
var
  Item: TScriptedItem;
begin
  Result := 0;
  if FIndex >= FItems.Count then
    Exit;
  Item := FItems[FIndex];
  Inc(FIndex);
  if (FIdleMs > 0) and (Item.DelayMs > FIdleMs) then
  begin
    Sleep(FIdleMs);
    raise EHttpTimeout.Create('scripted silence past the read deadline');
  end;
  Sleep(Item.DelayMs);
  Result := Length(Item.Text);
  if Result > ACount then
    raise EHttpError.Create('scripted read larger than the buffer',
      ecInternalError);
  if Result > 0 then
    Move(Item.Text[1], ABuffer, Result);
end;

function TScriptedBody.Eof: Boolean;
begin
  Result := FIndex >= FItems.Count;
end;

function TScriptedBody.QueryInterface(constref AID: TGUID;
  out AObj): LongInt;
begin
  if GetInterface(AID, AObj) then
    Result := 0
  else
    Result := LongInt($80004002);        // E_NOINTERFACE
end;

function TScriptedBody._AddRef: LongInt;
begin
  Result := -1;                          // the client owns the instance
end;

function TScriptedBody._Release: LongInt;
begin
  Result := -1;                          // the client owns the instance
end;

{ TOptionsClient }

constructor TOptionsClient.Create(const AOptions: TClientSecurityOptions);
begin
  inherited Create;
  FBodies := TObjectList<TScriptedBody>.Create(True);
  FRequests := TList<THttpRequest>.Create;
  FIndex := 0;
  FOptions := AOptions;
end;

destructor TOptionsClient.Destroy;
begin
  FRequests.Free;
  FBodies.Free;
  inherited Destroy;
end;

function TOptionsClient.QueryInterface(constref AID: TGUID;
  out AObj): LongInt;
begin
  if GetInterface(AID, AObj) then
    Result := 0
  else
    Result := LongInt($80004002);        // E_NOINTERFACE
end;

function TOptionsClient._AddRef: LongInt;
begin
  Result := -1;                          // the test owns the instance
end;

function TOptionsClient._Release: LongInt;
begin
  Result := -1;                          // the test owns the instance
end;

function TOptionsClient.Options: TClientSecurityOptions;
begin
  Result := FOptions;
end;

function TOptionsClient.AddBody(const AIdleMs: Integer): TScriptedBody;
begin
  Result := TScriptedBody.Create(AIdleMs);
  FBodies.Add(Result);
end;

function TOptionsClient.Send(const ARequest: IWebSocketRequest): IWebSocket;
begin
  raise EHttpWebSocketError.Create('a scripted client opens no WebSocket');
end;

function TOptionsClient.Send(const ARequest: THttpRequest): IHttpResponse;
var
  Body: TScriptedBody;
begin
  FRequests.Add(ARequest);
  if FIndex < FBodies.Count then
    Body := FBodies[FIndex]
  else
    Body := TScriptedBody.Create(0);     // an empty stream: ends at once
  Inc(FIndex);
  Result := TStubResponse.Create(200,
    NewHeaders([HeaderContentType, cSseContentType]), Body);
end;

procedure TOptionsClient.Close;
begin
  // nothing to release
end;

function TOptionsClient.RequestCount: Integer;
begin
  Result := FRequests.Count;
end;

{ TNextThread }

procedure TNextThread.Execute;
var
  E: TSseEvent;
begin
  Failed := False;
  try
    Got := Loop.Next(E);
  except
    Failed := True;
  end;
  EndedTick := GetTickCount64;
end;

{ TSseLimitsTest }

procedure TSseLimitsTest.TestLineOverLimitRaises;
var
  P: TSseEventParser;
  Opts: TClientSecurityOptions;
  Events: TList<TSseEvent>;
  Raised: Boolean;
begin
  Opts := TClientSecurityOptions.Default.WithSseMaxLineBytes(1024);
  P := TSseEventParser.Create(Opts);
  Events := TList<TSseEvent>.Create;
  try
    Raised := False;
    try
      // a line of 1025 bytes with no line break
      P.Feed(StringOfChar('x', 1025), Events);
    except
      on E: EHttpSseTooLarge do Raised := True;
    end;
    AssertTrue('the over-long line raises EHttpSseTooLarge', Raised);
  finally
    Events.Free;
    P.Free;
  end;
end;

procedure TSseLimitsTest.TestLineAtLimitIsAccepted;
var
  P: TSseEventParser;
  Opts: TClientSecurityOptions;
  Events: TList<TSseEvent>;
begin
  Opts := TClientSecurityOptions.Default.WithSseMaxLineBytes(1024);
  P := TSseEventParser.Create(Opts);
  Events := TList<TSseEvent>.Create;
  try
    // exactly the limit: no error, and the line ends normally
    P.Feed(StringOfChar('x', 1024), Events);
    P.Feed(#10, Events);
    AssertEquals('an ignored field line completes no event', 0, Events.Count);
  finally
    Events.Free;
    P.Free;
  end;
end;

procedure TSseLimitsTest.TestZeroLineLimitIsOff;
var
  P: TSseEventParser;
  Opts: TClientSecurityOptions;
  Events: TList<TSseEvent>;
begin
  Opts := TClientSecurityOptions.Default.WithSseMaxLineBytes(0);
  P := TSseEventParser.Create(Opts);
  Events := TList<TSseEvent>.Create;
  try
    P.Feed('data: ' + StringOfChar('y', 5000) + #10#10, Events);
    AssertEquals('one event with the long line', 1, Events.Count);
    AssertEquals('its data is complete', 5000, Length(Events[0].Data));
  finally
    Events.Free;
    P.Free;
  end;
end;

procedure TSseLimitsTest.TestEventOverLimitRaises;
var
  P: TSseEventParser;
  Opts: TClientSecurityOptions;
  Events: TList<TSseEvent>;
  Text: string;
  I: Integer;
  Raised: Boolean;
begin
  Opts := TClientSecurityOptions.Default.WithSseMaxEventBytes(1024);
  P := TSseEventParser.Create(Opts);
  Events := TList<TSseEvent>.Create;
  try
    // many short data lines that together pass the event limit
    Text := '';
    for I := 1 to 30 do
      Text := Text + 'data: ' + StringOfChar('z', 90) + #10;
    Raised := False;
    try
      P.Feed(Text, Events);
    except
      on E: EHttpSseTooLarge do Raised := True;
    end;
    AssertTrue('the event over the limit raises EHttpSseTooLarge', Raised);
    AssertEquals('no event was dispatched', 0, Events.Count);
  finally
    Events.Free;
    P.Free;
  end;
end;

procedure TSseLimitsTest.TestRetryIsCappedByOption;
var
  C: TOptionsClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
begin
  C := TOptionsClient.Create(
    TClientSecurityOptions.Default.WithSseMaxRetryMs(150));
  C.AddBody(0).Add(0, 'retry: 2000000000' + #10 + 'data: a' + #10 + #10);
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('the first event', Loop.Next(E));
    AssertEquals('the server retry is cut to the option', 150, Loop.RetryMs);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseLimitsTest.TestCloseWakesTheReconnectWait;
var
  C: TOptionsClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  T: TNextThread;
  CloseTick: QWord;
begin
  C := TOptionsClient.Create(TClientSecurityOptions.Default);
  // the server asks for a 2 s wait before it reconnects
  C.AddBody(0).Add(0, 'retry: 2000' + #10 + 'data: a' + #10 + #10);
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  T := TNextThread.Create(True);
  try
    AssertTrue('the first event', Loop.Next(E));
    T.Loop := Loop;
    T.FreeOnTerminate := False;
    T.Start;
    // the thread reaches the 2 s wait: the first stream has ended
    Sleep(150);
    CloseTick := GetTickCount64;
    Loop.Close;
    T.WaitFor;
    AssertFalse('Next returns False once the loop is closed', T.Got);
    AssertFalse('no error was raised', T.Failed);
    AssertTrue('Close ends the wait within 100 ms',
      Int64(T.EndedTick - CloseTick) < 100);
  finally
    T.Free;
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseLimitsTest.TestIdleStreamRaisesIdleTimeout;
var
  C: TOptionsClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
  Raised: Boolean;
begin
  // the client's idle limit is 200 ms; the server then goes silent for 500 ms
  C := TOptionsClient.Create(
    TClientSecurityOptions.Default.WithSseMaxIdleTimeMs(200));
  C.AddBody(200).Add(0, 'data: a' + #10 + #10).Add(500, 'data: b' + #10 + #10);
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('the first event arrives', Loop.Next(E));
    AssertEquals('its payload', 'a', E.Data);
    Raised := False;
    try
      Loop.Next(E);
    except
      on X: EHttpSseIdleTimeout do Raised := True;
    end;
    AssertTrue('the silence raises EHttpSseIdleTimeout', Raised);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseLimitsTest.TestKeepAliveCommentsKeepStreamAlive;
var
  C: TOptionsClient;
  Loop: TSseReconnectLoop;
  E: TSseEvent;
begin
  // the idle limit is 300 ms; a comment every 100 ms resets it
  C := TOptionsClient.Create(
    TClientSecurityOptions.Default.WithSseMaxIdleTimeMs(300));
  C.AddBody(300)
    .Add(100, ': keepalive' + #10)
    .Add(100, ': keepalive' + #10)
    .Add(100, ': keepalive' + #10)
    .Add(100, ': keepalive' + #10)
    .Add(0, 'data: done' + #10 + #10);
  Loop := TSseReconnectLoop.Create(C,
    SseRequest('https://a.example/sse'), 5);
  try
    AssertTrue('the event after the comments arrives', Loop.Next(E));
    AssertEquals('the payload', 'done', E.Data);
  finally
    Loop.Free;
    C.Free;
  end;
end;

procedure TSseLimitsTest.TestBomIsStrippedAtStart;
var
  P: TSseEventParser;
  Events: TList<TSseEvent>;
begin
  P := TSseEventParser.Create;
  Events := TList<TSseEvent>.Create;
  try
    P.Feed(Chr($EF) + Chr($BB) + Chr($BF) + 'data: a' + #10 + #10, Events);
    AssertEquals('one event', 1, Events.Count);
    AssertEquals('the BOM is not data', 'a', Events[0].Data);
  finally
    Events.Free;
    P.Free;
  end;
end;

initialization
  RegisterTest(TSseLimitsTest);

end.
