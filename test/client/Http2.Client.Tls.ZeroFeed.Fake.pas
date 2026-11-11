{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client, tls, fake, input
notes:
  - This fake session returns zero once before accepting encrypted input.
---
}
unit Http2.Client.Tls.ZeroFeed.Fake;

{$mode delphi}{$H+}{$interfaces com}

interface

uses
  SysUtils, Http2.Common.Tls.Context, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Session, Http2.Common.Tls.Types;

type
  TTlsZeroFeedContext = class(TInterfacedObject, ITLSContext)
  private
    FInner: ITLSContext;
    FRequireOutputDrain: Boolean;
    FRequireInputForWrite: Boolean;
    FReturnZeroOnce: Boolean;
  public
    constructor Create(const AInner: ITLSContext;
      const ARequireOutputDrain: Boolean = False;
      const ARequireInputForWrite: Boolean = False;
      const AReturnZeroOnce: Boolean = True);
    function BackendName: string;
    function Capabilities: TTlsCapabilities;
    function Info: TTlsContextInfo;
    function CreateClientSession(const AOptions: TTlsClientSessionOptions): ITLSSession;
    function CreateServerSession(const AOptions: TTlsServerSessionOptions): ITLSSession;
  end;

implementation

type
  TZeroFeedSession = class(TInterfacedObject, ITLSSession)
  private
    FInner: ITLSSession;
    FReturnPlaintext, FFeedZeroUsed, FRequireOutputDrain,
      FOutputDrainDone, FRequireInputForWrite, FInputAccepted: Boolean;
  public
    constructor Create(const AInner: ITLSSession;
      const ARequireOutputDrain, ARequireInputForWrite,
      AReturnZeroOnce: Boolean);
    function State: TTlsSessionState;
    function FeedEncrypted(const ABuffer: TBytes;
      const AOffset, ACount: SizeInt): SizeInt;
    function DrainEncrypted(var ABuffer: TBytes;
      const AOffset, ACapacity: SizeInt): SizeInt;
    function WritePlaintext(const ABuffer: TBytes;
      const AOffset, ACount: SizeInt): SizeInt;
    function ReadPlaintext(var ABuffer: TBytes;
      const AOffset, ACapacity: SizeInt): SizeInt;
    function Advance(const AMonotonicMs: Int64): TTlsProgress;
    procedure NotifyTransportEof;
    procedure BeginShutdown;
    procedure Abort;
    function NegotiatedInfo: TTlsNegotiatedInfo;
  end;

constructor TZeroFeedSession.Create(const AInner: ITLSSession;
  const ARequireOutputDrain, ARequireInputForWrite,
  AReturnZeroOnce: Boolean);
begin
  inherited Create;
  FInner := AInner;
  FRequireOutputDrain := ARequireOutputDrain;
  FRequireInputForWrite := ARequireInputForWrite;
  FFeedZeroUsed := not AReturnZeroOnce;
end;

function TZeroFeedSession.State: TTlsSessionState;
begin Result := FInner.State; end;

function TZeroFeedSession.FeedEncrypted(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin
  if not FFeedZeroUsed then
  begin
    FFeedZeroUsed := True;
    FReturnPlaintext := not FRequireOutputDrain;
    Exit(0);
  end;
  if FRequireOutputDrain and FFeedZeroUsed and not FOutputDrainDone then
    Exit(0);
  if FRequireOutputDrain then
    FReturnPlaintext := True;
  Result := FInner.FeedEncrypted(ABuffer, AOffset, ACount);
  FInputAccepted := Result > 0;
end;

function TZeroFeedSession.DrainEncrypted(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin
  if FRequireOutputDrain and FFeedZeroUsed and not FOutputDrainDone then
  begin
    if ACapacity = 0 then Exit(0);
    ABuffer[AOffset] := Ord('!');
    FOutputDrainDone := True;
    Exit(1);
  end;
  Result := FInner.DrainEncrypted(ABuffer, AOffset, ACapacity);
end;

function TZeroFeedSession.WritePlaintext(const ABuffer: TBytes;
  const AOffset, ACount: SizeInt): SizeInt;
begin
  if FRequireInputForWrite and not FInputAccepted then Exit(0);
  Result := FInner.WritePlaintext(ABuffer, AOffset, ACount);
end;

function TZeroFeedSession.ReadPlaintext(var ABuffer: TBytes;
  const AOffset, ACapacity: SizeInt): SizeInt;
begin
  if FReturnPlaintext then
  begin
    FReturnPlaintext := False;
    if ACapacity = 0 then Exit(0);
    ABuffer[AOffset] := Ord('!');
    Exit(1);
  end;
  Result := FInner.ReadPlaintext(ABuffer, AOffset, ACapacity);
end;

function TZeroFeedSession.Advance(const AMonotonicMs: Int64): TTlsProgress;
begin Result := FInner.Advance(AMonotonicMs); end;

procedure TZeroFeedSession.NotifyTransportEof;
begin FInner.NotifyTransportEof; end;
procedure TZeroFeedSession.BeginShutdown;
begin FInner.BeginShutdown; end;
procedure TZeroFeedSession.Abort;
begin FInner.Abort; end;
function TZeroFeedSession.NegotiatedInfo: TTlsNegotiatedInfo;
begin Result := FInner.NegotiatedInfo; end;

constructor TTlsZeroFeedContext.Create(const AInner: ITLSContext;
  const ARequireOutputDrain, ARequireInputForWrite,
  AReturnZeroOnce: Boolean);
begin
  inherited Create;
  FInner := AInner;
  FRequireOutputDrain := ARequireOutputDrain;
  FRequireInputForWrite := ARequireInputForWrite;
  FReturnZeroOnce := AReturnZeroOnce;
end;
function TTlsZeroFeedContext.BackendName: string;
begin Result := FInner.BackendName; end;
function TTlsZeroFeedContext.Capabilities: TTlsCapabilities;
begin Result := FInner.Capabilities; end;
function TTlsZeroFeedContext.Info: TTlsContextInfo;
begin Result := FInner.Info; end;
function TTlsZeroFeedContext.CreateClientSession(
  const AOptions: TTlsClientSessionOptions): ITLSSession;
begin
  Result := TZeroFeedSession.Create(FInner.CreateClientSession(AOptions),
    FRequireOutputDrain, FRequireInputForWrite, FReturnZeroOnce);
end;
function TTlsZeroFeedContext.CreateServerSession(
  const AOptions: TTlsServerSessionOptions): ITLSSession;
begin Result := FInner.CreateServerSession(AOptions); end;

end.
