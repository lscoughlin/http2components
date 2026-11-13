{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: buffer, growth, overflow, http1
notes:
  - This unit holds the growth rule of the HTTP/1.1 buffers.
  - The rule computes the new length in Int64, so that a buffer above 1 GiB does
    not overflow the Integer type.
---
}
/// The growth rule of the HTTP/1.1 buffers
unit Http2.Server.Http1.Grow;

{$mode delphi}{$H+}

interface

/// the new length of a buffer that must hold ANeed octets and has ACurrent octets
// - returns ANeed when it fits in ACurrent
// - returns ANeed plus half of ANeed plus 256 when that sum is not above High(Integer)
// - returns ANeed when the sum is above High(Integer)
// - raises EHttpProtocolError with ecInternalError when ANeed is above High(Integer)
function GrownLength(const ANeed, ACurrent: Int64): Int64;

implementation

uses
  Http2.Common.Errors;

function GrownLength(const ANeed, ACurrent: Int64): Int64;
begin
  if ANeed <= ACurrent then
    Exit(ANeed);
  if ANeed > High(Integer) then
    raise EHttpProtocolError.Create(
      'the HTTP/1.1 buffer need is above the Integer limit', ecInternalError);
  Result := ANeed + ANeed div 2 + 256;
  if Result > High(Integer) then
    Result := ANeed;
end;

end.
