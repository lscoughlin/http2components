{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, test, fpcunit
notes:
  - This unit registers the shared protocol test cases.
---
}
unit Http2.Common.TestRunner;

{$mode delphi}{$H+}

interface

procedure RegisterTests;

implementation

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Http2.Common.Errors.Test,
  Http2.Common.Headers.ClientOrigin.Test,
  Http2.Common.Headers.ServerOrigin.Test,
  Http2.Common.Hpack.ClientOrigin.Test,
  Http2.Common.Hpack.ServerOrigin.Test,
  Http2.Common.HpackProps.ClientOrigin.Test,
  Http2.Common.HpackProps.ServerOrigin.Test,
  Http2.Common.Hpack.Directions.Test,
  Http2.Common.HpackInteger.Test,
  Http2.Common.Frames.ClientOrigin.Test,
  Http2.Common.Frames.ServerOrigin.Test,
  Http2.Common.FlowControl.ClientOrigin.Test,
  Http2.Common.FlowControl.ServerOrigin.Test,
  Http2.Common.Frames.Union.Test,
  Http2.Common.UnixPath.Test,
  Http2.Common.Uri.Test;

procedure RegisterTests;
begin
end;

end.
