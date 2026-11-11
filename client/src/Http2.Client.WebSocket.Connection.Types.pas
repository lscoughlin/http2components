{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket
notes:
  - This unit owns WebSocket session attempt contracts.
---
}
unit Http2.Client.WebSocket.Connection.Types;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.RequestObserver, Http2.Client.WebSocket;

type
  TWsSessionEnd = record
    ClosedBy: TCloseInitiator;
    CloseCode: Integer;
    CloseReason: string;
    Error: Exception;
    Abandoned: Boolean;
    BytesIn, BytesOut: Int64;
  end;

  IWebSocketAttempt = interface
    ['{7D1E5A02-3B94-4C6F-8E21-5A0C9B3D6F20}']
    function HandshakeHeaders: TArray<TWsHeaderField>;
    procedure HandshakeWritten;
    procedure HandshakeAccepted(const AStatus: Integer;
      const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
    procedure SessionEnded(const AEnd: TWsSessionEnd);
  end;

implementation

end.
