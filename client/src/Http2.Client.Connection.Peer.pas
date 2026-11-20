{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, settings
notes:
  - records the first SETTINGS frame of the peer for the extended CONNECT check
  - the gate is set once for the wait and latches the connect setting
---
}
unit Http2.Client.Connection.Peer;

{$mode delphi}{$H+}

interface

uses
  SyncObjs;

type
  /// the wait for the peer SETTINGS of one connection
  // - the event is manual reset: once set, every waiter returns at once
  TPeerSettingsGate = class
  private
    FLock: TCriticalSection;
    FEvent: TEvent;
    FReceived: Boolean;
    FAllowsConnect: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    /// a peer SETTINGS frame was applied; AEnableConnect is its value of
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL (the value stays True once it is True)
    procedure NoteSettings(const AEnableConnect: Boolean);
    /// the connection failed or closed: waiters return at once
    procedure NoteFailed;
    /// wait up to ATimeoutMs for the first SETTINGS frame; False on timeout
    // - the caller gets False at once when the connection failed first
    function Wait(const ATimeoutMs: Integer): Boolean;
    /// True once a peer SETTINGS frame enabled the extended CONNECT
    function AllowsExtendedConnect: Boolean;
  end;

implementation

constructor TPeerSettingsGate.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEvent := TEvent.Create(nil, True, False, '');
  FReceived := False;
  FAllowsConnect := False;
end;

destructor TPeerSettingsGate.Destroy;
begin
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPeerSettingsGate.NoteSettings(const AEnableConnect: Boolean);
begin
  FLock.Acquire;
  try
    FReceived := True;
    if AEnableConnect then
      FAllowsConnect := True;
  finally
    FLock.Release;
  end;
  FEvent.SetEvent;
end;

procedure TPeerSettingsGate.NoteFailed;
begin
  FEvent.SetEvent;
end;

function TPeerSettingsGate.Wait(const ATimeoutMs: Integer): Boolean;
begin
  // a failed connection sets the event too, so this returns at once then
  FEvent.WaitFor(Cardinal(ATimeoutMs));
  FLock.Acquire;
  try
    Result := FReceived;
  finally
    FLock.Release;
  end;
end;

function TPeerSettingsGate.AllowsExtendedConnect: Boolean;
begin
  FLock.Acquire;
  try
    Result := FAllowsConnect;
  finally
    FLock.Release;
  end;
end;

end.
