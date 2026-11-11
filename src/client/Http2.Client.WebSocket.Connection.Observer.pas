{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, observer
notes:
  - This unit owns WebSocket session end notifications.
---
}
unit Http2.Client.WebSocket.Connection.Observer;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.RequestObserver,
  Http2.Client.WebSocket.Connection.Types;

procedure ReportWebSocketSessionEnd(const AAttempt: IWebSocketAttempt;
  var AEnded: LongInt; const AClosedBy: TCloseInitiator;
  const ACode: Integer; const AReason: string; const AError: Exception;
  const AAbandoned: Boolean; const ABytesIn, ABytesOut: Int64);

implementation

procedure ReportWebSocketSessionEnd(const AAttempt: IWebSocketAttempt;
  var AEnded: LongInt; const AClosedBy: TCloseInitiator;
  const ACode: Integer; const AReason: string; const AError: Exception;
  const AAbandoned: Boolean; const ABytesIn, ABytesOut: Int64);
var
  Info: TWsSessionEnd;
begin
  if InterlockedCompareExchange(AEnded, 1, 0) <> 0 then
    Exit;
  if AAttempt = nil then
    Exit;
  Info.ClosedBy := AClosedBy;
  Info.CloseCode := ACode;
  Info.CloseReason := AReason;
  Info.Error := AError;
  Info.Abandoned := AAbandoned;
  Info.BytesIn := ABytesIn;
  Info.BytesOut := ABytesOut;
  try
    AAttempt.SessionEnded(Info);
  except
    // The attempt guards observer callbacks.
  end;
end;

end.
