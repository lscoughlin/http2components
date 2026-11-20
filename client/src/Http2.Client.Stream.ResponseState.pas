{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - the response state of a stream lease, moved from Http2.Client.Stream
---
}
unit Http2.Client.Stream.ResponseState;

{$mode delphi}{$H+}

interface

type
  /// the response (receive) side assembly state
  TResponseState = (rsIdle, rsBodyOpen, rsBodyComplete, rsFailed);

implementation

end.
