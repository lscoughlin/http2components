{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, handshake request, snapshot
notes:
  - This unit holds the read-only copy of the handshake request that a WebSocket
    session gives to its handler. The copy stays valid after the transport stream
    of the request is gone.
---
}
/// A read-only copy of the handshake request of a WebSocket session
unit Http2.Server.WebSocket.Snapshot;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes,
  Http2.Common.Hpack, Http2.Server.Seam, Http2.Server.ClientCert;

type
  /// a read-only copy of the handshake request
  TWsRequestSnapshot = class(TInterfacedObject, IServerRequest)
  private
    FMethod, FScheme, FAuthority, FPath: string;
    FHeaders: THeaderBlock;
    FCancelled: Boolean;
    FPrincipal: string;
    FClientCert: IClientCertificate;
  public
    constructor Create(const ARequest: IServerRequest);
    procedure Cancel;
    function GetPrincipal: string;
    procedure SetPrincipal(const AValue: string);
    function GetClientCertificate: IClientCertificate;
    function Method: string;
    function Scheme: string;
    function Authority: string;
    function Path: string;
    function Headers: THeaderBlock;
    function Read(var ABuffer; const ACount: Integer): Integer;
    function ReadChunk(const ABuffer: TStream): Boolean;
    function BodyIsComplete: Boolean;
    function IsCancelled: Boolean;
    function StreamId: LongWord;
  end;

implementation

constructor TWsRequestSnapshot.Create(const ARequest: IServerRequest);
begin
  inherited Create;
  FMethod := ARequest.Method;
  FScheme := ARequest.Scheme;
  FAuthority := ARequest.Authority;
  FPath := ARequest.Path;
  FHeaders := Copy(ARequest.Headers);
  FPrincipal := ARequest.Principal;
  FClientCert := ARequest.ClientCertificate;
end;

function TWsRequestSnapshot.GetClientCertificate: IClientCertificate;
begin
  Result := FClientCert;
end;

function TWsRequestSnapshot.GetPrincipal: string;
begin
  Result := FPrincipal;
end;

procedure TWsRequestSnapshot.SetPrincipal(const AValue: string);
begin
  FPrincipal := AValue;
end;

procedure TWsRequestSnapshot.Cancel;
begin
  FCancelled := True;
end;

function TWsRequestSnapshot.Method: string;
begin
  Result := FMethod;
end;

function TWsRequestSnapshot.Scheme: string;
begin
  Result := FScheme;
end;

function TWsRequestSnapshot.Authority: string;
begin
  Result := FAuthority;
end;

function TWsRequestSnapshot.Path: string;
begin
  Result := FPath;
end;

function TWsRequestSnapshot.Headers: THeaderBlock;
begin
  Result := FHeaders;
end;

function TWsRequestSnapshot.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
end;

function TWsRequestSnapshot.ReadChunk(const ABuffer: TStream): Boolean;
begin
  Result := False;
end;

function TWsRequestSnapshot.BodyIsComplete: Boolean;
begin
  Result := True;
end;

function TWsRequestSnapshot.IsCancelled: Boolean;
begin
  Result := FCancelled;
end;

function TWsRequestSnapshot.StreamId: LongWord;
begin
  Result := 0;
end;

end.
