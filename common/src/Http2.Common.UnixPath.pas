{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, path
notes:
  - This unit holds the shared rule for a Unix socket path.
  - The server option record, the client factory and the proxy rule call it.
---
}
unit Http2.Common.UnixPath;

{$mode delphi}{$H+}

interface

const
  /// the longest socket path in bytes; sun_path holds 104 bytes on macOS
  cUnixPathMaxBytes = 103;

/// the empty text for a usable socket path, else a short text that names the
/// broken rule
// - the text never holds the path, so a log never holds a hostile string
function UnixPathProblem(const APath: string): string;

implementation

uses
  SysUtils;

function UnixPathProblem(const APath: string): string;
var
  LBytes: Integer;
begin
  Result := '';
  if APath = '' then
    Exit('the Unix socket path is empty');
  if APath[1] <> '/' then
    Exit('the Unix socket path is not absolute');
  if Pos(#0, APath) > 0 then
    Exit('the Unix socket path holds a NUL byte');
  LBytes := Length(UTF8Encode(APath));
  if LBytes > cUnixPathMaxBytes then
    Result := 'the Unix socket path is ' + IntToStr(LBytes) +
      ' bytes long; the limit is ' + IntToStr(cUnixPathMaxBytes);
end;

end.
