{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - the client connection preface, moved from Http2.Client.Connection
---
}
unit Http2.Client.Connection.Preface;

{$mode delphi}{$H+}

interface

uses
  SysUtils;

/// the 24-byte client connection preface (RFC 7540 section 3.5)
function ClientPrefaceBytes: TBytes;

implementation

const
  cClientPreface: array[0..23] of Byte = (
    $50, $52, $49, $20, $2A, $20, $48, $54, $54, $50, $2F, $32, $2E, $30,
    $0D, $0A, $0D, $0A, $53, $4D, $0D, $0A, $0D, $0A);

function ClientPrefaceBytes: TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, SizeOf(cClientPreface));
  for I := 0 to High(cClientPreface) do
    Result[I] := cClientPreface[I];
end;

end.
