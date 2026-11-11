{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, server, connection_admission
notes:
  - This include reserves a connection slot before the first read is queued.
  - The connection claim releases on close and on object cleanup.
---
}
function THttp2AsyncServer.ConnectionNew(aSocket: TNetSocket;
  aConnection: TAsyncConnection; aAddAndSubscribe: Boolean): Boolean;
var
  Claim: IConnectionAdmissionClaim;
  Connection: THttp2AsyncConnection;
begin
  Claim := FAdmission.TryAcquire;
  if Claim = nil then
    Exit(False);
  Connection := THttp2AsyncConnection(aConnection);
  Connection.FServer := Self;
  Connection.FAdmissionClaim := Claim;
  Claim := nil;
  FCounters.ConnectionOpened;
  Connection.FCountedOpen := True;
  try
    ConnectionOpened;
    Result := inherited ConnectionNew(aSocket, aConnection, aAddAndSubscribe);
    if not Result then
      Connection.ReleaseAdmission;
  except
    Connection.ReleaseAdmission;
    raise;
  end;
end;

procedure THttp2AsyncServer.ConnectionOpened;
begin
  ReportOpened(FObserver);
end;

procedure THttp2AsyncServer.ConnectionClosed;
begin
  ReportClosed(FCounters, FObserver);
end;

procedure THttp2AsyncConnection.ReleaseAdmission;
begin
  try
    if FCountedOpen then
    begin
      FCountedOpen := False;
      if FServer <> nil then
        FServer.ConnectionClosed;
    end;
  finally
    FAdmissionClaim := nil;
  end;
end;
