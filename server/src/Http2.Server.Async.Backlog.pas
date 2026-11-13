{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, write progress, backlog, http1
notes:
  - This unit holds the write-progress rule of the HTTP/1.1 output backlog.
  - It was a block of the async server unit and moved here unchanged.
---
}
/// The write-progress rule of the HTTP/1.1 output backlog
unit Http2.Server.Async.Backlog;

{$mode delphi}{$H+}

interface

/// record the backlog of one sweep, and the time of progress
// - a backlog that is new or smaller than the last one is progress
procedure ObserveBacklogProgress(const ABacklog: Int64; const ANowMs: QWord;
  var ALastBacklog: Int64; var ALastProgressMs: QWord);

implementation

procedure ObserveBacklogProgress(const ABacklog: Int64; const ANowMs: QWord;
  var ALastBacklog: Int64; var ALastProgressMs: QWord);
begin
  if (ABacklog > 0) and ((ALastBacklog <= 0) or (ABacklog < ALastBacklog)) then
    ALastProgressMs := ANowMs;
  ALastBacklog := ABacklog;
end;

end.
