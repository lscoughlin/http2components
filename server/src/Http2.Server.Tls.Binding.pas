{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, binding, server, listener
notes:
  - This unit binds a common TLS context to one server listener.
---
}
unit Http2.Server.Tls.Binding;
{$mode delphi}{$H+}{$interfaces com}
interface
uses Http2.Common.Tls.Context, Http2.Common.Tls.Session,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Types;
type
  ITlsServerBinding = interface(IInterface)
    ['{A148578B-164E-42E7-B695-04DC6A08724C}']
    function Context: ITLSContext;
    function CreateSession(const AStartedMs: Int64;
      const AAllowHttp11: Boolean): ITLSSession;
  end;
function NewTlsServerBinding(const AContext: ITLSContext): ITlsServerBinding;
function TlsHandshakeDeadline(const AStartedMs: Int64;
  const ATimeoutMs: Cardinal): Int64;
implementation
type
  TTlsServerBinding = class(TInterfacedObject, ITlsServerBinding)
  private FContext: ITLSContext;
  public
    constructor Create(const AContext: ITLSContext);
    destructor Destroy; override;
    function Context: ITLSContext;
    function CreateSession(const AStartedMs: Int64;
      const AAllowHttp11: Boolean): ITLSSession;
  end;
constructor TTlsServerBinding.Create(const AContext: ITLSContext);
var Info: TTlsContextInfo;
begin
  inherited Create;
  if AContext = nil then
    raise ETlsContextError.Create('The server TLS context is not assigned');
  Info := AContext.Info;
  if not (trServer in Info.Roles) then
    raise ETlsContextError.Create('The TLS context has no server role');
  FContext := AContext;
end;
destructor TTlsServerBinding.Destroy;
begin
  FContext := nil;
  inherited Destroy;
end;
function TTlsServerBinding.Context: ITLSContext;
begin
  Result := FContext;
end;
function TTlsServerBinding.CreateSession(const AStartedMs: Int64;
  const AAllowHttp11: Boolean): ITLSSession;
var O: TTlsServerSessionOptions; Alpns: TArray<string>;
begin
  O := Default(TTlsServerSessionOptions);
  O.HandshakeStartMs := AStartedMs;
  if AAllowHttp11 then
    Alpns := ['h2', 'http/1.1']
  else
    Alpns := ['h2'];
  O := O.WithAlpns(Alpns);
  Result := FContext.CreateServerSession(O);
end;
function NewTlsServerBinding(const AContext: ITLSContext): ITlsServerBinding;
begin
  Result := TTlsServerBinding.Create(AContext);
end;
function TlsHandshakeDeadline(const AStartedMs: Int64;
  const ATimeoutMs: Cardinal): Int64;
begin
  Result := 0;
  if ATimeoutMs = 0 then Exit;
  if AStartedMs > High(Int64) - Int64(ATimeoutMs) then
    Result := High(Int64)
  else
    Result := AStartedMs + ATimeoutMs;
end;
end.
