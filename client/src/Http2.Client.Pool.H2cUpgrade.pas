{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, pool, h2c, upgrade
notes:
  - This unit holds the h2c Upgrade probe of the connection pool. The probe keeps no pool state.
---
}
unit Http2.Client.Pool.H2cUpgrade;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils,
  Http2.Client.Errors,
  Http2.Common.Status,
  Http2.Client.Tls,
  Http2.Client.Stream,
  Http2.Client.Stream.Types,
  Http2.Client.Observer,
  Http2.Client.Http1,
  Http2.Client.Upgrade;

/// write the h2c Upgrade request on Sock and read the answer head. True when the
/// answer is 101; AStatusLine is the status line of any other answer.
function TryH2cUpgrade(const Sock: IHttp2Socket;
  const ARequest: TStreamRequest; out AStatusLine: string): Boolean;

implementation

function TryH2cUpgrade(const Sock: IHttp2Socket;
  const ARequest: TStreamRequest; out AStatusLine: string): Boolean;
var
  Raw: TBytes;
  Ofs, N: Integer;
  Line, Version, Reason: string;
  Status, Lines: Integer;
begin
  // write the Upgrade request and read the response head byte by byte, so a
  // 101 leaves the HTTP/2 frames that FOLLOW the head untouched in the
  // socket.  The Upgrade and Connection headers cannot travel through
  // TStreamRequest.Headers (the shared map forbids connection-specific
  // fields), so the wire bytes are built here (doc/design/fallback.md
  // "h2c upgrade procedure").
  AStatusLine := '';
  Raw := BuildH2cUpgradeRequest(ARequest);
  Ofs := 0;
  while Ofs < Length(Raw) do
  begin
    N := Sock.Write(Raw[Ofs], Length(Raw) - Ofs);
    if N <= 0 then
      raise EHttpConnectionClosed.Create('h2c upgrade request write failed');
    Inc(Ofs, N);
  end;
  // the probe carries the request, so this is the moment it was written; the
  // declined and accepted paths report again after the response head was read
  if ARequest.Exchange <> nil then
    ARequest.Exchange.RequestWritten(Length(ARequest.Body.Data));
  if not ReadHeadLineBytewise(Sock, Line) then
    raise EHttpProtocolError.Create('peer closed during the h2c upgrade',
      ecProtocolError);
  ParseStatusLine(Line, Version, Status, Reason);
  Result := Status = HttpStatusSwitchingProtocols;
  if not Result then
  begin
    AStatusLine := Line;
    Exit;
  end;
  // the 101 head continues with Upgrade/Connection fields and the mandatory
  // empty line; consume them all before the socket becomes an HTTP/2
  // transport, else the connection thread frames those bytes as HTTP/2
  Lines := 0;
  while True do
  begin
    if not ReadHeadLineBytewise(Sock, Line) then
      raise EHttpProtocolError.Create('truncated 101 response head',
        ecProtocolError);
    if Line = '' then
      Break;
    Inc(Lines);
    if Lines > 64 then
      raise EHttpProtocolError.Create('101 response head is too large',
        ecProtocolError);
  end;
end;

end.
