{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Api;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  Http2.Client.Request,
  Http2.Client.Messages,
  Http2.Client.WebSocket;


type
  IHttpClient = interface
    ['{6B1C2D3E-4F50-4A61-9C72-000000000001}']
    function Send(const ARequest: THttpRequest): IHttpResponse; overload;
    /// open a WebSocket (doc/design/websocket.md); the connection is not
    /// pooled and outlives Close of this client until it is closed itself
    function Send(const ARequest: IWebSocketRequest): IWebSocket; overload;
    procedure Close;
  end;

implementation


end.
