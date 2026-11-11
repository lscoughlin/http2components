{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, async, adapter
notes:
  - this program checks a raw transport adapter through the mORMot poll path
---
}
program RawPollStudy;

{$mode delphi}

uses
  cthreads,
  SysUtils,
  SyncObjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.text,
  mormot.core.threads,
  mormot.net.sock,
  mormot.net.async;

const
  CFlightSize = 4 * 1024 * 1024;
  CChunkSize = 16 * 1024;
  CTimeoutMs = 6000;

type
  TStudySignals = class
  public
    FirstOctet: TEvent;
    HandshakeReady: TEvent;
    ApplicationRead: TEvent;
    Expired: TEvent;
    Destroyed: TEvent;
    ContextTag: Byte;
    DestroyCount: Integer;
    PendingPeak: Integer;
    ExpiryElapsedMs: Int64;
    ExpiryIdleMs: Int64;
    ExpiredCount: Integer;
    ExpiredHandle: Integer;
    constructor Create(ATag: Byte);
    destructor Destroy; override;
  end;

  TStudySession = class
  private
    FSignals: TStudySignals;
    FContextTag: Byte;
    FInputCount: Integer;
    FLastInputAt: Int64;
    FOpen: Boolean;
    FOutput: TBytes;
    FOutputOffset: Integer;
  public
    constructor Create(ASignals: TStudySignals; AContextTag: Byte);
    procedure FeedCiphertext(ABuffer: Pointer; ALength: Integer);
    function TakeEncrypted(out AData: TBytes): Boolean;
    property Open: Boolean read FOpen;
    property OutputOffset: Integer read FOutputOffset;
  end;

  TStudyServer = class;

  TStudyConnection = class(TAsyncConnection)
  private
    FSignals: TStudySignals;
    FSession: TStudySession;
    FAcceptedAt: Int64;
    FSessionLock: TOSLock;
    function SendFirstFlight: Boolean;
  protected
    procedure AfterCreate; override;
    procedure BeforeDestroy; override;
  public
    constructor Create(aOwner: TAsyncConnections;
      const aRemoteIP: TNetAddr); override;
    procedure Recycle(const aRemoteIP: TNetAddr); override;
    function OnRead: TPollAsyncSocketOnReadWrite; override;
    function AfterWrite: TPollAsyncSocketOnReadWrite; override;
    function IsHandshakeExpired(ANow: Int64; out AElapsed,
      AIdleElapsed: Int64): Boolean;
  end;

  TStudyServer = class(TAsyncServer)
  private
    FSignals: TStudySignals;
  protected
    function GetLastOperationIdleSeconds: cardinal; override;
    procedure IdleEverySecond; override;
  public
    constructor Create(APort: Word; ASignals: TStudySignals);
    function HasPendingWrite: Boolean;
    property Signals: TStudySignals read FSignals;
  end;

constructor TStudySignals.Create(ATag: Byte);
var
  Prefix: string;
begin
  inherited Create;
  ContextTag := ATag;
  Prefix := Format('tls-adapter-study-%d-%d-', [GetProcessID, ATag]);
  FirstOctet := TEvent.Create(nil, True, False, Prefix + 'first');
  HandshakeReady := TEvent.Create(nil, True, False, Prefix + 'handshake');
  ApplicationRead := TEvent.Create(nil, True, False, Prefix + 'application');
  Expired := TEvent.Create(nil, True, False, Prefix + 'expired');
  Destroyed := TEvent.Create(nil, True, False, Prefix + 'destroyed');
end;

destructor TStudySignals.Destroy;
begin
  FreeAndNil(FirstOctet);
  FreeAndNil(HandshakeReady);
  FreeAndNil(ApplicationRead);
  FreeAndNil(Expired);
  FreeAndNil(Destroyed);
  inherited Destroy;
end;

constructor TStudySession.Create(ASignals: TStudySignals; AContextTag: Byte);
var
  I: Integer;
begin
  inherited Create;
  FSignals := ASignals;
  FContextTag := AContextTag;
  FLastInputAt := GetTickCount64;
  SetLength(FOutput, CFlightSize + 1);
  FOutput[0] := AContextTag;
  for I := 1 to High(FOutput) do
    FOutput[I] := Byte((I + AContextTag) mod 251);
end;

procedure TStudySession.FeedCiphertext(ABuffer: Pointer; ALength: Integer);
var
  I: Integer;
begin
  if not FOpen then
  begin
    for I := 0 to ALength - 1 do
    begin
      Inc(FInputCount);
      if FInputCount = 1 then
        FSignals.FirstOctet.SetEvent;
    end;
    FLastInputAt := GetTickCount64;
    if FInputCount >= 9 then
    begin
      FOpen := True;
      FSignals.HandshakeReady.SetEvent;
    end;
  end
  else if ALength > 0 then
  begin
    FLastInputAt := GetTickCount64;
    FSignals.ApplicationRead.SetEvent;
  end;
end;

function TStudySession.TakeEncrypted(out AData: TBytes): Boolean;
var
  N: Integer;
begin
  Result := FOutputOffset < Length(FOutput);
  if not Result then
    Exit;
  N := Length(FOutput) - FOutputOffset;
  if N > CChunkSize then
    N := CChunkSize;
  SetLength(AData, N);
  Move(FOutput[FOutputOffset], AData[0], N);
  Inc(FOutputOffset, N);
end;

constructor TStudyConnection.Create(aOwner: TAsyncConnections;
  const aRemoteIP: TNetAddr);
begin
  FSessionLock.Init;
  inherited Create(aOwner, aRemoteIP);
end;

procedure TStudyConnection.Recycle(const aRemoteIP: TNetAddr);
begin
  FSessionLock.Lock;
  try
    FreeAndNil(FSession);
  finally
    FSessionLock.UnLock;
  end;
  FSignals := nil;
  FAcceptedAt := 0;
  inherited Recycle(aRemoteIP);
end;

procedure TStudyConnection.AfterCreate;
begin
  inherited AfterCreate;
  Socket^.SendBufferSize := 4096;
  FSignals := TStudyServer(Owner).Signals;
  FSession := TStudySession.Create(FSignals, FSignals.ContextTag);
  FAcceptedAt := GetTickCount64;
end;

procedure TStudyConnection.BeforeDestroy;
begin
  FSessionLock.Lock;
  try
    FreeAndNil(FSession);
  finally
    FSessionLock.UnLock;
  end;
  if FSignals <> nil then
  begin
    InterlockedIncrement(FSignals.DestroyCount);
    FSignals.Destroyed.SetEvent;
  end;
  FSignals := nil;
  FSessionLock.Done;
  inherited BeforeDestroy;
end;

function TStudyConnection.IsHandshakeExpired(ANow: Int64;
  out AElapsed, AIdleElapsed: Int64): Boolean;
begin
  FSessionLock.Lock;
  try
    AElapsed := ANow - FAcceptedAt;
    if FSession = nil then
    begin
      AIdleElapsed := 0;
      exit(False);
    end;
    AIdleElapsed := ANow - FSession.FLastInputAt;
    Result := not FSession.Open and (AElapsed >= 1500);
  finally
    FSessionLock.UnLock;
  end;
end;

function TStudyConnection.SendFirstFlight: Boolean;
var
  Data: TBytes;
  HasData: Boolean;
begin
  FSessionLock.Lock;
  try
    HasData := (FSession <> nil) and FSession.Open and
      FSession.TakeEncrypted(Data);
  finally
    FSessionLock.UnLock;
  end;
  if not HasData then
  begin
    Result := True;
    Exit;
  end;
  Result := Owner.Sockets.Write(Self, @Data[0], Length(Data), CTimeoutMs);
end;

function TStudyConnection.OnRead: TPollAsyncSocketOnReadWrite;
begin
  Result := soContinue;
  if (FSession = nil) or (fRd.Len = 0) then
    Exit;
  FSessionLock.Lock;
  try
    FSession.FeedCiphertext(fRd.Buffer, fRd.Len);
  finally
    FSessionLock.UnLock;
  end;
  fRd.Reset;
  if not SendFirstFlight then
    Result := soClose;
end;

function TStudyConnection.AfterWrite: TPollAsyncSocketOnReadWrite;
var
  Data: TBytes;
  HasData: Boolean;
begin
  Result := soDone;
  FSessionLock.Lock;
  try
    HasData := (FSession <> nil) and FSession.TakeEncrypted(Data);
  finally
    FSessionLock.UnLock;
  end;
  if HasData then
  begin
    fWr.Append(@Data[0], Length(Data));
    Result := soContinue;
  end;
end;

function TStudyServer.GetLastOperationIdleSeconds: cardinal;
begin
  Result := 1;
end;

procedure TStudyServer.IdleEverySecond;
var
  Handles: array of Integer;
  I: Integer;
  C: TAsyncConnection;
  Expired: Boolean;
  Elapsed, IdleElapsed: Int64;
  NowMs: Int64;
begin
  inherited IdleEverySecond;
  NowMs := GetTickCount64;
  ConnectionLock.ReadOnlyLock;
  try
    SetLength(Handles, ConnectionCount);
    for I := 0 to ConnectionCount - 1 do
      Handles[I] := Connection[I].Handle;
  finally
    ConnectionLock.ReadOnlyUnLock;
  end;
  for I := 0 to High(Handles) do
  begin
    C := ConnectionFindAndLock(Handles[I], cReadOnly, nil);
    if C = nil then
      Continue;
    try
      Expired := TStudyConnection(C).IsHandshakeExpired(
        NowMs, Elapsed, IdleElapsed);
    finally
      ConnectionLock.ReadOnlyUnLock;
    end;
    if Expired then
    begin
      FSignals.ExpiryElapsedMs := Elapsed;
      FSignals.ExpiryIdleMs := IdleElapsed;
      FSignals.ExpiredHandle := Handles[I];
      if ConnectionRemove(Handles[I]) then
      begin
        InterlockedIncrement(FSignals.ExpiredCount);
        FSignals.Expired.SetEvent;
      end;
    end;
  end;
end;

function TStudyServer.HasPendingWrite: Boolean;
var
  I: Integer;
  C: TStudyConnection;
  Pending, Previous: Integer;
begin
  Result := False;
  ConnectionLock.ReadOnlyLock;
  try
    for I := 0 to ConnectionCount - 1 do
    begin
      C := TStudyConnection(Connection[I]);
      if not C.TryLock(False) then
        continue;
      try
        Pending := C.PendingWrite;
      finally
        C.UnLock(False);
      end;
      Previous := FSignals.PendingPeak;
      while Pending > Previous do
      begin
        Previous := InterlockedCompareExchange(FSignals.PendingPeak,
          Pending, Previous);
        if Previous < Pending then
          break;
      end;
      if Pending > 0 then
        Result := True;
    end;
  finally
    ConnectionLock.ReadOnlyUnLock;
  end;
end;

constructor TStudyServer.Create(APort: Word; ASignals: TStudySignals);
begin
  FSignals := ASignals;
  inherited Create(UInt32ToUtf8(APort), nil, nil, TStudyConnection,
    'raw-poll-study', nil, [], 2);
end;

function OpenClient(APort: Word): TNetSocket;
var
  Address: TNetAddr;
begin
  Address.Clear;
  if Address.SetFrom('127.0.0.1', UInt32ToUtf8(APort), nlTcp) <> nrOk then
    raise Exception.Create('loopback address setup failed');
  Result := Address.NewSocket(nlTcp);
  if Result = nil then
    raise Exception.Create('loopback socket creation failed');
  if Address.SocketConnect(Result, CTimeoutMs) <> nrOk then
    raise Exception.Create('loopback connect failed');
end;

procedure SendBytes(ASocket: TNetSocket; const AText: RawByteString);
var
  N: Integer;
begin
  N := Length(AText);
  if (ASocket.Send(@AText[1], N) <> nrOk) or (N <> Length(AText)) then
    raise Exception.Create('loopback send failed');
end;

procedure ReadFlight(ASocket: TNetSocket; ATag: Byte);
var
  Buffer: array[0..CChunkSize - 1] of Byte;
  N, Total, I: Integer;
  Start: Int64;
begin
  Total := 0;
  Start := GetTickCount64;
  while Total < CFlightSize + 1 do
  begin
    N := Length(Buffer);
    case ASocket.Recv(@Buffer, N) of
      nrOk:
        begin
          if N <= 0 then
            raise Exception.Create('empty read before flight completion');
          if (Total = 0) and (Buffer[0] <> ATag) then
            raise Exception.Create('listener context binding mismatch');
          for I := 0 to N - 1 do
            if Buffer[I] <> Byte((Total + I + ATag) mod 251) then
              if (Total + I <> 0) then
                raise Exception.Create('transport bytes were lost, duplicated, or changed');
          Inc(Total, N);
        end;
      nrRetry:
        if not (neRead in ASocket.WaitFor(1000, [neRead, neError])) then
          raise Exception.Create('timeout while reading handshake output');
      else
        raise Exception.Create('socket closed while reading handshake output');
    end;
    if GetTickCount64 - Start > CTimeoutMs then
      raise Exception.Create('handshake output deadline exceeded');
  end;
end;

procedure WaitForBackpressure(AServer: TStudyServer; AClient: TNetSocket);
var
  Start: Int64;
begin
  Start := GetTickCount64;
  repeat
    if AServer.HasPendingWrite then
      Exit;
    AClient.WaitFor(50, [neRead, neError]);
  until GetTickCount64 - Start >= 3000;
  raise Exception.Create('small socket buffer did not retain pending transport output');
end;

procedure RunStudy;
var
  Port: Word;
  S1, S2: TStudySignals;
  Server1, Server2: TStudyServer;
  Client1, Client2, Silent, Trickle: TNetSocket;
begin
  Port := 41000 + (GetProcessID mod 10000);
  S1 := TStudySignals.Create(1);
  S2 := TStudySignals.Create(2);
  Server1 := TStudyServer.Create(Port, S1);
  Server2 := TStudyServer.Create(Port + 1, S2);
  Server1.WaitStarted(5);
  Server2.WaitStarted(5);
  Client1 := nil;
  Client2 := nil;
  Silent := nil;
  Trickle := nil;
  try
    Client1 := OpenClient(Port);
    Client2 := OpenClient(Port + 1);
    Client1^.RecvBufferSize := 4096;
    Client2^.RecvBufferSize := 4096;
    SendBytes(Client1, 'A');
    SendBytes(Client2, 'A');
    if (S1.FirstOctet.WaitFor(2000) <> wrSignaled) or
       (S2.FirstOctet.WaitFor(2000) <> wrSignaled) then
      raise Exception.Create('split record first octet was not accepted');
    SendBytes(Client1, 'BCDEFGHI');
    SendBytes(Client2, 'BCDEFGHI');
    if (S1.HandshakeReady.WaitFor(2000) <> wrSignaled) or
       (S2.HandshakeReady.WaitFor(2000) <> wrSignaled) then
      raise Exception.Create('split record handshake did not complete');
    WaitForBackpressure(Server1, Client1);
    WaitForBackpressure(Server2, Client2);
    ReadFlight(Client1, 1);
    ReadFlight(Client2, 2);
    SendBytes(Client1, 'P');
    SendBytes(Client2, 'P');
    if (S1.ApplicationRead.WaitFor(2000) <> wrSignaled) or
       (S2.ApplicationRead.WaitFor(2000) <> wrSignaled) then
      raise Exception.Create('application bytes did not arrive after handshake');
    Silent := OpenClient(Port);
    if S1.Expired.WaitFor(3000) <> wrSignaled then
      raise Exception.Create('silent peer did not expire from accept deadline');
    if (S1.ExpiredCount <> 1) or (S1.ExpiryElapsedMs > 2500) then
      raise Exception.Create('silent peer exceeded the absolute deadline sweep bound');
    if Server1.ConnectionRemove(S1.ExpiredHandle) then
      raise Exception.Create('stale silent-peer handle removed a connection');
    Trickle := OpenClient(Port + 1);
    SendBytes(Trickle, 'A');
    Trickle.WaitFor(300, [neRead, neError]);
    SendBytes(Trickle, 'BC');
    Trickle.WaitFor(300, [neRead, neError]);
    SendBytes(Trickle, 'DE');
    Trickle.WaitFor(300, [neRead, neError]);
    SendBytes(Trickle, 'FG');
    Trickle.WaitFor(300, [neRead, neError]);
    SendBytes(Trickle, 'H');
    if S2.Expired.WaitFor(3000) <> wrSignaled then
      raise Exception.Create('trickle peer did not expire from the absolute deadline');
    if (S2.ExpiredCount <> 1) or (S2.ExpiryElapsedMs > 2500) or
       (S2.ExpiryIdleMs >= 1000) then
      raise Exception.Create('trickle peer was not expired by the absolute sweep');
    if Server2.ConnectionRemove(S2.ExpiredHandle) then
      raise Exception.Create('stale trickle-peer handle removed a connection');
    Server1.Shutdown;
    Server2.Shutdown;
    FreeAndNil(Server1);
    FreeAndNil(Server2);
    if (S1.Destroyed.WaitFor(2000) <> wrSignaled) or
       (S2.Destroyed.WaitFor(2000) <> wrSignaled) then
      raise Exception.Create('connection sessions did not release on stop');
    WriteLn('split input: 2 listeners passed');
    WriteLn('pending output without app write: 2 x ', CFlightSize + 1,
      ' bytes; pending queue peak=', S1.PendingPeak, '/', S2.PendingPeak);
    WriteLn('app input after handshake: 2 listeners passed');
    WriteLn('silent peer deadline: ', S1.ExpiryElapsedMs,
      ' ms from accept; sweep bound <= 2500 ms');
    WriteLn('trickle peer deadline: ', S2.ExpiryElapsedMs,
      ' ms from accept; last-input idle=', S2.ExpiryIdleMs, ' ms');
    WriteLn('listener stop: sessions released=', S1.DestroyCount, '/',
      S2.DestroyCount);
  finally
    if Client1 <> nil then
      Client1.ShutdownAndClose(False);
    if Client2 <> nil then
      Client2.ShutdownAndClose(False);
    if Silent <> nil then
      Silent.ShutdownAndClose(False);
    if Trickle <> nil then
      Trickle.ShutdownAndClose(False);
    FreeAndNil(Server1);
    FreeAndNil(Server2);
    FreeAndNil(S1);
    FreeAndNil(S2);
  end;
end;

begin
  RunStudy;
  WriteLn('raw poll adapter study passed');
end.
