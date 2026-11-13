{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, pool, dial
notes:
  - this tests that the pool dials outside its lock and reserves the slot
---
}
unit Http2.Client.PoolDial.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client, Http2.Client.Core,
  Http2.Client.ClearText.Support;

type
  /// a socket factory for HTTP/1.1 over TLS whose dial for the host
  /// slow.test waits for a test event.  Every other host gets a scripted
  /// socket at once (after an optional short delay).
  TBlockingDialFactory = class(TInterfacedObject, IHttp2SocketFactory,
    ICleartextSocketFactory)
  private
    FLock: TCriticalSection;
    FGate: TEvent;
    FStarted: TEvent;
    FDials: Integer;
    FInFlight: Integer;
    FMaxInFlight: Integer;
    FMaxLive: Integer;
    FFailNext: Integer;
    FDelayMs: Integer;
    FSockets: TList<IHttp2Socket>;
  public
    constructor Create;
    destructor Destroy; override;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
    function DialProtocol(const AHost: string; const APort: Word;
      const AScheme: string; const AHttp1Fallback: Boolean;
      const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
      out AProtocol: TNegotiatedProtocol): IHttp2Socket;
    /// lets a blocked dial for slow.test go on
    procedure OpenGate;
    /// waits until a dial for slow.test has started
    function WaitStarted(const ATimeoutMs: Integer): Boolean;
    function Dials: Integer;
    function MaxInFlight: Integer;
    /// the most sockets that were open at the same time (this one included)
    function MaxLive: Integer;
    property FailNext: Integer read FFailNext write FFailNext;
    property DelayMs: Integer read FDelayMs write FDelayMs;
  end;

  /// one Send on its own thread
  TDialSender = class(TThread)
  private
    FClient: IHttpClient;
    FUrl: string;
    FToken: ICancellationToken;
    FHold: TEvent;
    FStatus: Integer;
    FErrorClass: string;
    FDone: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const AUrl: string;
      const AToken: ICancellationToken = nil;
      const AHold: TEvent = nil);
    destructor Destroy; override;
    function WaitDone(const ATimeoutMs: Integer): Boolean;
    property Status: Integer read FStatus;
    property ErrorClass: string read FErrorClass;
  end;

  TPoolDialTest = class(TTestCase)
  private
    function Build(const AFactory: IHttp2SocketFactory;
      const AMaxPerHost, AMaxTotal: Integer): IHttpClient;
  published
    procedure TestSlowDialDoesNotBlockOtherOrigin;
    procedure TestTwentyThreadsNeverPassMaxConnectionsPerHost;
    procedure TestFailedDialFreesItsSlot;
    procedure TestCancelDuringDialKeepsTheConnectionAndRaisesCancel;
    procedure TestCloseDuringDialRaisesConnectionClosed;
  end;

implementation

const
  cOneResponse = 'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello';

{ TBlockingDialFactory }

constructor TBlockingDialFactory.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FGate := TEvent.Create(nil, True, False, '');
  FStarted := TEvent.Create(nil, True, False, '');
  FSockets := TList<IHttp2Socket>.Create;
end;

destructor TBlockingDialFactory.Destroy;
begin
  FGate.SetEvent;
  FSockets.Free;
  FStarted.Free;
  FGate.Free;
  FLock.Free;
  inherited Destroy;
end;

function TBlockingDialFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
var
  P: TNegotiatedProtocol;
begin
  Result := DialProtocol(AHost, APort, 'https', True, ctReject, ATimeoutMs, P);
end;

function TBlockingDialFactory.DialProtocol(const AHost: string;
  const APort: Word; const AScheme: string; const AHttp1Fallback: Boolean;
  const APolicy: TClearTextPolicy; const ATimeoutMs: Integer;
  out AProtocol: TNegotiatedProtocol): IHttp2Socket;
var
  S: TScriptSocket;
  Sock: IHttp2Socket;
  Fail: Boolean;
  Live: Integer;
begin
  AProtocol := npHttp1Tls;
  FLock.Acquire;
  try
    Inc(FDials);
    Inc(FInFlight);
    if FInFlight > FMaxInFlight then
      FMaxInFlight := FInFlight;
    // sockets that are still open count with the dials in flight
    Live := FInFlight;
    for Sock in FSockets do
      if Sock.Connected then
        Inc(Live);
    if Live > FMaxLive then
      FMaxLive := Live;
    Fail := FFailNext > 0;
    if Fail then
      Dec(FFailNext);
  finally
    FLock.Release;
  end;
  try
    if Fail then
      raise EHttpConnectionError.Create('scripted dial failure');
    if AHost = 'slow.test' then
    begin
      FStarted.SetEvent;
      FGate.WaitFor(20000);
    end
    else if FDelayMs > 0 then
      Sleep(FDelayMs);
    S := TScriptSocket.Create;
    S.Feed(cOneResponse);
    Result := S;
    FLock.Acquire;
    try
      FSockets.Add(Result);
    finally
      FLock.Release;
    end;
  finally
    FLock.Acquire;
    try
      Dec(FInFlight);
    finally
      FLock.Release;
    end;
  end;
end;

procedure TBlockingDialFactory.OpenGate;
begin
  FGate.SetEvent;
end;

function TBlockingDialFactory.WaitStarted(const ATimeoutMs: Integer): Boolean;
begin
  Result := FStarted.WaitFor(ATimeoutMs) = wrSignaled;
end;

function TBlockingDialFactory.Dials: Integer;
begin
  FLock.Acquire;
  try
    Result := FDials;
  finally
    FLock.Release;
  end;
end;

function TBlockingDialFactory.MaxLive: Integer;
begin
  FLock.Acquire;
  try
    Result := FMaxLive;
  finally
    FLock.Release;
  end;
end;

function TBlockingDialFactory.MaxInFlight: Integer;
begin
  FLock.Acquire;
  try
    Result := FMaxInFlight;
  finally
    FLock.Release;
  end;
end;

{ TDialSender }

constructor TDialSender.Create(const AClient: IHttpClient;
  const AUrl: string; const AToken: ICancellationToken;
  const AHold: TEvent);
begin
  FHold := AHold;
  FClient := AClient;
  FUrl := AUrl;
  FToken := AToken;
  FDone := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TDialSender.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TDialSender.Execute;
var
  R: IHttpResponse;
  Req: THttpRequest;
begin
  try
    try
      Req := THttpRequest.Create(hmGet, FUrl);
      if FToken <> nil then
        Req := Req.WithCancelToken(FToken);
      R := FClient.Send(Req);
      FStatus := R.StatusCode;
      // a held response keeps its connection busy, so its slot stays taken
      if FHold <> nil then
        FHold.WaitFor(30000);
      DrainBody(R);
    except
      on E: Exception do
        FErrorClass := E.ClassName;
    end;
  finally
    FDone.SetEvent;
  end;
end;

function TDialSender.WaitDone(const ATimeoutMs: Integer): Boolean;
begin
  Result := FDone.WaitFor(ATimeoutMs) = wrSignaled;
end;

{ TPoolDialTest }

function TPoolDialTest.Build(const AFactory: IHttp2SocketFactory;
  const AMaxPerHost, AMaxTotal: Integer): IHttpClient;
begin
  Result := THttpClientFactory.Create
    .WithSocketFactory(AFactory)
    .WithHttp1Fallback
    .WithMaxConnectionsPerHost(AMaxPerHost)
    .WithMaxTotalConnections(AMaxTotal)
    .WithConnectTimeout(20000).WithHeaderTimeout(20000)
    .Build;
end;

procedure TPoolDialTest.TestSlowDialDoesNotBlockOtherOrigin;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  A: TDialSender;
  B: TDialSender;
begin
  Factory := TBlockingDialFactory.Create;
  Client := Build(Factory, 4, 8);
  A := TDialSender.Create(Client, 'https://slow.test/x');
  B := nil;
  try
    AssertTrue('the slow dial started', Factory.WaitStarted(5000));
    B := TDialSender.Create(Client, 'https://fast.test/x');
    AssertTrue('a call for another origin returned while the slow dial ran',
      B.WaitDone(1000));
    AssertEquals('the other origin got its response', 200, B.Status);
    AssertFalse('the slow call is still dialling', A.WaitDone(50));
    AssertEquals('the slot of the slow dial is reserved', 1,
      (Client as THttpClient).Pool.DialingCount);
  finally
    Factory.OpenGate;
    A.WaitDone(5000);
    A.WaitFor;
    if B <> nil then
    begin
      B.WaitFor;
      B.Free;
    end;
  end;
  AssertEquals('the slow call ended without an error', '', A.ErrorClass);
  A.Free;
end;

procedure TPoolDialTest.TestTwentyThreadsNeverPassMaxConnectionsPerHost;
const
  cThreads = 20;
  cCap = 3;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  Hold: TEvent;
  W: array[0..cThreads - 1] of TDialSender;
  I, Got: Integer;
  Limit: QWord;
begin
  Factory := TBlockingDialFactory.Create;
  Factory.DelayMs := 30;
  Client := Build(Factory, cCap, 8);
  Hold := TEvent.Create(nil, True, False, '');
  try
    for I := 0 to cThreads - 1 do
      W[I] := TDialSender.Create(Client, 'https://fast.test/x', nil, Hold);
    try
      // the held responses keep their connections busy: exactly the cap
      // gets a response, the other callers wait for a slot
      Limit := GetTickCount64 + 10000;
      repeat
        Got := 0;
        for I := 0 to cThreads - 1 do
          if W[I].Status = 200 then
            Inc(Got);
        if Got < cCap then
          Sleep(5);
      until (Got >= cCap) or (GetTickCount64 > Limit);
      Sleep(300);       // time for a wrong extra dial to show
      AssertEquals('the cap of callers got a response', cCap, Got);
      AssertEquals('the factory dialled the cap and no more', cCap,
        Factory.Dials);
      AssertTrue('the dials in flight stayed within the cap',
        Factory.MaxInFlight <= cCap);
      AssertTrue('the open sockets stayed within the cap',
        Factory.MaxLive <= cCap);
      AssertEquals('the pool holds the cap', cCap,
        (Client as THttpClient).Pool.ConnectionCount);
      AssertEquals('no reservation is left', 0,
        (Client as THttpClient).Pool.DialingCount);
    finally
      Hold.SetEvent;
      Client.Close;
      for I := 0 to cThreads - 1 do
      begin
        W[I].WaitFor;
        W[I].Free;
      end;
    end;
  finally
    Hold.Free;
  end;
end;

procedure TPoolDialTest.TestFailedDialFreesItsSlot;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  Failed: Boolean;
  R: IHttpResponse;
begin
  Factory := TBlockingDialFactory.Create;
  Factory.FailNext := 1;
  Client := Build(Factory, 1, 1);
  Failed := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'https://fast.test/x'));
  except
    on E: Exception do
      Failed := True;
  end;
  AssertTrue('the failed dial raised', Failed);
  AssertEquals('the reservation was released', 0,
    (Client as THttpClient).Pool.DialingCount);
  AssertEquals('no connection was registered', 0,
    (Client as THttpClient).Pool.ConnectionCount);
  // the single slot is free again, so this call dials and succeeds
  R := Client.Send(THttpRequest.Create(hmGet, 'https://fast.test/x'));
  AssertEquals('the next call used the freed slot', 200, R.StatusCode);
  DrainBody(R);
  AssertEquals('no reservation is left', 0,
    (Client as THttpClient).Pool.DialingCount);
end;

procedure TPoolDialTest.TestCancelDuringDialKeepsTheConnectionAndRaisesCancel;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  Token: TCancellationToken;
  Hold: ICancellationToken;
  A: TDialSender;
begin
  Factory := TBlockingDialFactory.Create;
  Client := Build(Factory, 2, 4);
  Token := TCancellationToken.Create;
  Hold := Token;
  A := TDialSender.Create(Client, 'https://slow.test/x', Hold);
  try
    AssertTrue('the slow dial started', Factory.WaitStarted(5000));
    Token.Cancel;
    Factory.OpenGate;
    AssertTrue('the cancelled call ended', A.WaitDone(10000));
    AssertEquals('the call raised the cancel error',
      EHttpStreamError.ClassName, A.ErrorClass);
    AssertEquals('the reservation was released', 0,
      (Client as THttpClient).Pool.DialingCount);
    AssertEquals('the healthy connection went into the pool', 1,
      (Client as THttpClient).Pool.ConnectionCount);
  finally
    Factory.OpenGate;
    A.WaitFor;
    A.Free;
  end;
end;

procedure TPoolDialTest.TestCloseDuringDialRaisesConnectionClosed;
var
  Factory: TBlockingDialFactory;
  Client: IHttpClient;
  A: TDialSender;
begin
  Factory := TBlockingDialFactory.Create;
  Client := Build(Factory, 2, 4);
  A := TDialSender.Create(Client, 'https://slow.test/x');
  try
    AssertTrue('the slow dial started', Factory.WaitStarted(5000));
    Client.Close;
    Factory.OpenGate;
    AssertTrue('the call ended', A.WaitDone(10000));
    AssertEquals('the call raised the closed error',
      EHttpConnectionClosed.ClassName, A.ErrorClass);
    AssertEquals('the reservation was released', 0,
      (Client as THttpClient).Pool.DialingCount);
    AssertEquals('the new connection was not registered', 0,
      (Client as THttpClient).Pool.ConnectionCount);
  finally
    Factory.OpenGate;
    A.WaitFor;
    A.Free;
  end;
end;

initialization
  RegisterTest(TPoolDialTest);

end.
