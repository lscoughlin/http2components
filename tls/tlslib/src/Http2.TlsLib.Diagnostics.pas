{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, tlslib, diagnostics
notes:
  - This unit exposes active provider object counts for bounded lifecycle tests.
---
}
unit Http2.TlsLib.Diagnostics;

{$mode delphi}{$H+}

interface

type
  TTlsLibResourceCounts = record
    Contexts: Integer;
    Sessions: Integer;
    Credentials: Integer;
    Engines: Integer;
  end;

function TlsLibActiveResourceCounts: TTlsLibResourceCounts;
procedure TlsLibCountContext(const ADelta: Integer);
procedure TlsLibCountSession(const ADelta: Integer);
procedure TlsLibCountCredential(const ADelta: Integer);
procedure TlsLibCountEngine(const ADelta: Integer);

implementation

var
  ActiveContexts: LongInt;
  ActiveSessions: LongInt;
  ActiveCredentials: LongInt;
  ActiveEngines: LongInt;

function TlsLibActiveResourceCounts: TTlsLibResourceCounts;
begin
  Result.Contexts := ActiveContexts;
  Result.Sessions := ActiveSessions;
  Result.Credentials := ActiveCredentials;
  Result.Engines := ActiveEngines;
end;

procedure TlsLibCountContext(const ADelta: Integer);
begin
  if ADelta > 0 then InterlockedIncrement(ActiveContexts)
  else InterlockedDecrement(ActiveContexts);
end;

procedure TlsLibCountSession(const ADelta: Integer);
begin
  if ADelta > 0 then InterlockedIncrement(ActiveSessions)
  else InterlockedDecrement(ActiveSessions);
end;

procedure TlsLibCountCredential(const ADelta: Integer);
begin
  if ADelta > 0 then InterlockedIncrement(ActiveCredentials)
  else InterlockedDecrement(ActiveCredentials);
end;

procedure TlsLibCountEngine(const ADelta: Integer);
begin
  if ADelta > 0 then InterlockedIncrement(ActiveEngines)
  else InterlockedDecrement(ActiveEngines);
end;

end.
