{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, observer
notes:
  - This unit owns thread-safe connection observer delivery.
---
}
unit Http2.Client.Connection.Observer;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SyncObjs, Http2.Client.Observer, Http2.Client.Errors,
  Http2.Common.Frames;

type
  TConnectionObserver = class
  private
    FLock: TCriticalSection;
    FObserver: IHttp2Observer;
    FCloseObserved: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function GetObserver: IHttp2Observer;
    procedure SetObserver(const AValue: IHttp2Observer);
    procedure EmitConnectionOpen;
    procedure EmitConnectionClose(const AMessage: string;
      const ACode: THttp2ErrorCode);
    procedure EmitGoAway(const ALastStreamId: LongWord;
      const ACode: THttp2ErrorCode);
    procedure EmitStreamOpen(const AStreamId: LongWord);
    procedure EmitStreamClose(const AStreamId: LongWord);
    procedure EmitFrameIn(const AFrame: TFrame);
    procedure EmitFrameOut(const AFrame: TFrame);
    procedure EmitWindowUpdate(const AStreamId, AIncrement: LongWord);
    procedure EmitRetry(const AStreamId: LongWord);
    procedure EmitDiscarded(const AFrame: TFrame; const AReason: string);
  end;

implementation

constructor TConnectionObserver.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FObserver := nil;
  FCloseObserved := False;
end;

destructor TConnectionObserver.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

{ observer fan-out }

function TConnectionObserver.GetObserver: IHttp2Observer;
begin
  FLock.Acquire;
  try
    Result := FObserver;
  finally
    FLock.Release;
  end;
end;

procedure TConnectionObserver.SetObserver(const AValue: IHttp2Observer);
begin
  FLock.Acquire;
  try
    FObserver := AValue;
  finally
    FLock.Release;
  end;
end;

procedure TConnectionObserver.EmitConnectionOpen;
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnConnectionOpen;
  except
    // an observer must never break the connection loop
  end;
end;

procedure TConnectionObserver.EmitConnectionClose(const AMessage: string;
  const ACode: THttp2ErrorCode);
var
  Obs: IHttp2Observer;
  Send: Boolean;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  FLock.Acquire;
  try
    Send := not FCloseObserved;
    FCloseObserved := True;
  finally
    FLock.Release;
  end;
  if not Send then
    Exit;
  try
    Obs.OnConnectionClose(AMessage, ACode);
  except
  end;
end;

procedure TConnectionObserver.EmitGoAway(const ALastStreamId: LongWord;
  const ACode: THttp2ErrorCode);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnGoAway(ALastStreamId, ACode);
  except
  end;
end;

procedure TConnectionObserver.EmitStreamOpen(const AStreamId: LongWord);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnStreamOpen(AStreamId);
  except
  end;
end;

procedure TConnectionObserver.EmitStreamClose(const AStreamId: LongWord);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnStreamClose(AStreamId);
  except
  end;
end;

procedure TConnectionObserver.EmitFrameIn(const AFrame: TFrame);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnFrameIn(AFrame);
  except
  end;
end;

procedure TConnectionObserver.EmitFrameOut(const AFrame: TFrame);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnFrameOut(AFrame);
  except
  end;
end;

procedure TConnectionObserver.EmitWindowUpdate(const AStreamId, AIncrement: LongWord);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnWindowUpdate(AStreamId, AIncrement);
  except
  end;
end;

procedure TConnectionObserver.EmitRetry(const AStreamId: LongWord);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnRetry(AStreamId);
  except
  end;
end;

procedure TConnectionObserver.EmitDiscarded(const AFrame: TFrame;
  const AReason: string);
var
  Obs: IHttp2Observer;
begin
  Obs := GetObserver;
  if Obs = nil then
    Exit;
  try
    Obs.OnDiscarded(AFrame, AReason);
  except
  end;
end;

end.
