{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this contains identity selector and client helpers for Mutual TLS tests
---
}
unit Http2.Client.MutualTls.Client.Support;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Sockets, BaseUnix, fpcunit, testregistry,
  mormot.core.base, mormot.core.os, mormot.lib.openssl11,
  Http2.Client.Errors, Http2.Client.ClientCert, Http2.Client.Proxy, Http2.Client.Tls, Http2.Client.Messages,
  Http2.Client.Stream,
  Http2.Client,
  Http2.Client.Sse, Http2.Client.WebSocket, Http2.Client.RequestObserver,
  Http2.Client.RequestObserver.Support, Http2.Client.MutualTls.Server.Support;

type
  TCountingSelector = class(TInterfacedObject, IClientIdentitySelector)
  private
    FProbe: THttpClient;
  public
    Calls: Integer;
    LastHost: string;
    LastPort: Word;
    LastThread: TThreadID;
    Answer: IClientIdentity;
    /// when ForPort is set, that port gets PortAnswer instead of Answer
    ForPort: Word;
    PortAnswer: IClientIdentity;
    Fail: Boolean;
    LockWasFree: Boolean;
    /// the call takes this long, so a concurrent request can arrive meanwhile
    DelayMs: Integer;
    function Select(const AHost: string; const APort: Word): IClientIdentity;
    procedure ProbeLockWith(const AClient: IHttpClient);
  end;

  /// one Send of a GET and a body read on its own thread
  TFetchThread = class(TThread)
  private
    FClient: IHttpClient;
    FUrl: string;
  protected
    procedure Execute; override;
  public
    Status: Integer;
    Failed: Boolean;
    constructor Create(const AClient: IHttpClient; const AUrl: string);
  end;

  /// an injected socket factory that cannot present identities (it does not
  /// implement IIdentitySocketFactory); counts its dials
  TPlainSocketFactory = class(TInterfacedObject, IHttp2SocketFactory)
  public
    Dials: Integer;
    function Dial(const AHost: string; const APort: Word;
      const ATimeoutMs: Integer): IHttp2Socket;
  end;

  /// routes every request, loopback included, through one proxy
  TFixedSelector = class(TInterfacedObject, IProxySelector)
  private
    FProxy: IProxy;
  public
    constructor Create(const AKind: TProxyKind; const APort: Word);
    function SelectProxy(const AUri: string): IProxy;
  end;

  TWsRecorder = class(TWebSocketListener)
  private
    FEvent: TEvent;
  public
    Text: string;
    constructor Create;
    destructor Destroy; override;
    procedure OnText(const ASocket: IWebSocket; const AText: string;
      const ALast: Boolean); override;
    function WaitText(const AMs: Integer): Boolean;
  end;


implementation

{ TCountingSelector }

type
  /// reads the pool statistics from a second thread: the read waits for the
  /// pool lock, so it finishes only if the lock is free
  TStatsProbe = class(TThread)
  private
    FClient: THttpClient;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: THttpClient);
  end;

constructor TStatsProbe.Create(const AClient: THttpClient);
begin
  FClient := AClient;
  inherited Create(False);
end;

procedure TStatsProbe.Execute;
begin
  FClient.PoolStats;
end;

function TCountingSelector.Select(const AHost: string;
  const APort: Word): IClientIdentity;
var
  Probe: TStatsProbe;
  Waited: Integer;
begin
  InterlockedIncrement(Calls);
  LastHost := AHost;
  LastPort := APort;
  LastThread := GetCurrentThreadId;
  if FProbe <> nil then
  begin
    Probe := TStatsProbe.Create(FProbe);
    Waited := 0;
    while (not Probe.Finished) and (Waited < 2000) do
    begin
      Sleep(5);
      Inc(Waited, 5);
    end;
    LockWasFree := Probe.Finished;
    Probe.WaitFor;
    Probe.Free;
  end;
  if DelayMs > 0 then
    Sleep(DelayMs);
  if Fail then
    raise Exception.Create('selector refused');
  if (ForPort <> 0) and (APort = ForPort) then
    Result := PortAnswer
  else
    Result := Answer;
end;

procedure TCountingSelector.ProbeLockWith(const AClient: IHttpClient);
begin
  FProbe := AClient as THttpClient;
end;

{ TFixedSelector }

constructor TFetchThread.Create(const AClient: IHttpClient;
  const AUrl: string);
begin
  FClient := AClient;
  FUrl := AUrl;
  inherited Create(False);
end;

procedure TFetchThread.Execute;
var
  Resp: IHttpResponse;
begin
  try
    Resp := FClient.Send(THttpRequest.Create(hmGet, FUrl));
    Status := Resp.StatusCode;
    ReadAllBodyBytes(Resp.Body);
  except
    Failed := True;
  end;
end;

function TPlainSocketFactory.Dial(const AHost: string; const APort: Word;
  const ATimeoutMs: Integer): IHttp2Socket;
begin
  InterlockedIncrement(Dials);
  raise EHttpConnectionError.Create('plain factory: no dialling in a test');
end;

constructor TFixedSelector.Create(const AKind: TProxyKind; const APort: Word);
begin
  inherited Create;
  FProxy := TProxy.Create(AKind, 'localhost', APort);
end;

function TFixedSelector.SelectProxy(const AUri: string): IProxy;
begin
  Result := FProxy;
end;

{ TWsRecorder }

constructor TWsRecorder.Create;
begin
  inherited Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TWsRecorder.Destroy;
begin
  FEvent.Free;
  inherited Destroy;
end;

procedure TWsRecorder.OnText(const ASocket: IWebSocket; const AText: string;
  const ALast: Boolean);
begin
  Text := AText;
  FEvent.SetEvent;
end;

function TWsRecorder.WaitText(const AMs: Integer): Boolean;
begin
  Result := FEvent.WaitFor(AMs) = wrSignaled;
end;

{ TMutualTlsTest }


end.
