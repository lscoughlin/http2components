{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, socket, tunnel
notes:
  - This unit presents one HTTP/2 stream as an IHttp2Socket, so that the WebSocket connection runs over it unchanged.
  - A poll that finds no octet raises EHttpTimeout. The adapter never returns 0 for that case, because 0 means end of stream.
---
}
unit Http2.Client.WebSocket.H2Socket;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors, Http2.Client.Tls.Types, Http2.Client.Tunnel.Types;

type
  /// one tunnel presented as a socket (IHttp2Socket and IPartialReader)
  TH2StreamSocket = class(TInterfacedObject, IHttp2Socket, IPartialReader, IH2Abortable)
  private
    FTunnel: IH2Tunnel;
    FOpen: Boolean;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
  public
    constructor Create(const ATunnel: IH2Tunnel);
    /// read up to ACount octets; returns fewer only after some octets arrived
    function Read(var ABuffer; ACount: Integer): Integer;
    /// send all ACount octets as one tunnel send
    function Write(const ABuffer; ACount: Integer): Integer;
    /// half-close the stream once, then release it
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
    /// block for at least one octet; returns between 1 and ACount octets
    function ReadSome(var ABuffer; ACount: Integer): Integer;
    /// reset the stream with CANCEL, then release it
    procedure Abort;
  end;

implementation

constructor TH2StreamSocket.Create(const ATunnel: IH2Tunnel);
begin
  inherited Create;
  FTunnel := ATunnel;
  FOpen := True;
  FConnectTimeoutMs := cDefaultSocketTimeoutMs;
  FReadTimeoutMs := cDefaultSocketTimeoutMs;
  FWriteTimeoutMs := cDefaultSocketTimeoutMs;
end;

function TH2StreamSocket.Read(var ABuffer; ACount: Integer): Integer;
var
  Cur: PByte;
  N: Integer;
begin
  Result := 0;
  while Result < ACount do
  begin
    Cur := PByte(@ABuffer) + Result;
    N := FTunnel.ReadSome(Cur^, ACount - Result, FReadTimeoutMs);
    if N < 0 then
    begin
      // a poll that found octets earlier in this call returns them
      if Result > 0 then
        Exit;
      raise EHttpTimeout.CreateFmt('read timed out after %d ms', [FReadTimeoutMs]);
    end;
    if N = 0 then
      Exit; // END_STREAM
    Inc(Result, N);
  end;
end;

function TH2StreamSocket.Write(const ABuffer; ACount: Integer): Integer;
var
  Data: TBytes;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  if not GetConnected then
    raise EHttpConnectionError.Create('the WebSocket stream is closed');
  SetLength(Data, ACount);
  Move(ABuffer, Data[0], ACount);
  FTunnel.SendData(Data);
  Result := ACount;
end;

procedure TH2StreamSocket.Close;
begin
  if not FOpen then
    Exit;
  FOpen := False;
  try
    FTunnel.EndSend;
  finally
    FTunnel.Release;
  end;
end;

function TH2StreamSocket.GetConnected: Boolean;
begin
  Result := FOpen and not FTunnel.IsEnded;
end;

function TH2StreamSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TH2StreamSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TH2StreamSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TH2StreamSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TH2StreamSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TH2StreamSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

function TH2StreamSocket.ReadSome(var ABuffer; ACount: Integer): Integer;
begin
  if ACount <= 0 then
    Exit(0);
  Result := FTunnel.ReadSome(ABuffer, ACount, FReadTimeoutMs);
  if Result < 0 then
    raise EHttpTimeout.CreateFmt('read timed out after %d ms', [FReadTimeoutMs]);
end;

procedure TH2StreamSocket.Abort;
begin
  FOpen := False;
  try
    FTunnel.Reset;
  finally
    FTunnel.Release;
  end;
end;

end.
