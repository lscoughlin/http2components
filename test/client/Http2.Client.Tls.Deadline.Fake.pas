{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, tls, fake, deadline
notes:
  - This fake session stays in handshake until its absolute deadline.
---
}
unit Http2.Client.Tls.Deadline.Fake;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  Http2.Common.Tls.Context, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Session, Http2.Common.Tls.Types;

type
  TTlsDeadlineContext = class(TInterfacedObject, ITLSContext)
  public
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function CreateClientSession(
      const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(
      const AOptions: TTlsServerSessionOptions): ITLSSession;
  end;

implementation

uses SysUtils;

type
  TTlsDeadlineSession = class(TInterfacedObject, ITLSSession)
  private
    FDeadlineMs: Int64;
    FState: TTlsSessionState;
  public
    constructor Create(const ADeadlineMs: Int64);
    function State: TTlsSessionState;
    function FeedEncrypted(const ABuffer: TBytes;
      const AOffset, ACount: SizeInt): SizeInt;
    function DrainEncrypted(var ABuffer: TBytes;
      const AOffset, ACapacity: SizeInt): SizeInt;
    function WritePlaintext(const ABuffer: TBytes;
      const AOffset, ACount: SizeInt): SizeInt;
    function ReadPlaintext(var ABuffer: TBytes;
      const AOffset, ACapacity: SizeInt): SizeInt;
    function PendingPlaintext: SizeInt;
    function Advance(const AMonotonicMs: Int64): TTlsProgress;
    procedure NotifyTransportEof;
    procedure BeginShutdown;
    procedure Abort;
    function NegotiatedInfo: TTlsNegotiatedInfo;
  end;

constructor TTlsDeadlineSession.Create(const ADeadlineMs: Int64);
begin
  inherited Create;
  FDeadlineMs := ADeadlineMs;
  FState := tssHandshaking;
end;

function TTlsDeadlineSession.State: TTlsSessionState;
begin Result := FState; end;

function TTlsDeadlineSession.FeedEncrypted(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin Result := ACount; end;

function TTlsDeadlineSession.DrainEncrypted(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin Result := 0; end;

function TTlsDeadlineSession.WritePlaintext(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin Result := 0; end;

function TTlsDeadlineSession.ReadPlaintext(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin Result := 0; end;

function TTlsDeadlineSession.PendingPlaintext: SizeInt;
begin Result := 0; end;

function TTlsDeadlineSession.Advance(const AMonotonicMs: Int64): TTlsProgress;
begin
  if (FDeadlineMs > 0) and (AMonotonicMs >= FDeadlineMs) then
  begin
    FState := tssFailed;
    raise ETlsSessionError.Create('fake handshake deadline expired', tecTimeout);
  end;
  Result := Default(TTlsProgress);
  Result.State := FState;
  Result.NeedInput := True;
end;

procedure TTlsDeadlineSession.NotifyTransportEof;
begin
  FState := tssFailed;
  raise ETlsSessionError.Create('fake transport EOF', tecTransportEof);
end;

procedure TTlsDeadlineSession.BeginShutdown;
begin FState := tssClosing; end;

procedure TTlsDeadlineSession.Abort;
begin FState := tssClosed; end;

function TTlsDeadlineSession.NegotiatedInfo: TTlsNegotiatedInfo;
begin
  if FState <> tssOpen then
    raise ETlsSessionError.Create('fake session is not open', tecProtocol);
  Result := Default(TTlsNegotiatedInfo);
end;

function TTlsDeadlineContext.BackendName: string;
begin Result := 'deadline-fake'; end;

function TTlsDeadlineContext.Capabilities: TTlsCapabilities;
begin
  Result := Default(TTlsCapabilities);
  Result.Roles := [trClient];
end;

function TTlsDeadlineContext.Info: TTlsContextInfo;
begin
  Result := Default(TTlsContextInfo);
  Result.Roles := [trClient];
  Result.HandshakeTimeoutMs := 90;
end;

function TTlsDeadlineContext.CreateClientSession(
  const AOptions: TTlsClientSessionOptions): ITLSSession;
begin
  Result := TTlsDeadlineSession.Create(AOptions.HandshakeDeadlineMs);
end;

function TTlsDeadlineContext.CreateServerSession(
  const AOptions: TTlsServerSessionOptions): ITLSSession;
begin
  raise ETlsContextError.Create('fake context has no server role');
end;

end.
