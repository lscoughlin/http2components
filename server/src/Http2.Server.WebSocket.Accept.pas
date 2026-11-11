{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, accept, upgrade, handler, routing
notes:
  - AcceptWebSocket is called inside an ordinary request handler. Routing,
    authentication by cookie and the choice of the path stay in the handler, as RFC 6455
    section 4.2.2 steps 2 and 3 allow.
  - The function picks the handshake of the protocol that the response belongs to. These are
    the upgrade of RFC 6455 on HTTP/1.1 and the extended CONNECT of RFC 8441 on HTTP/2.
---
}
/// Accept a WebSocket upgrade inside a request handler
unit Http2.Server.WebSocket.Accept;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Server.Errors, Http2.Server.Seam, Http2.Server.WebSocket.Types;

/// accept the upgrade of this request and serve the WebSocket with AHandler
// - answers True when the session started; the handler then returns, and
//   IWsHandler.Init runs next on the streaming pool and decides the answer
// - answers False when an error response was sent; the handler then returns
// - raises EHttpError when the response belongs to no protocol that can upgrade
function AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AHandler: IWsHandler): Boolean;

implementation

uses
  Http2.Server.Http1.SocketChannel, Http2.Server.Http1.Upgrade,
  Http2.Server.StreamAdapters, Http2.Server.WebSocket.Http2;

function AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AHandler: IWsHandler): Boolean;
var
  Up1: IH1Upgradable;
  Up2: IH2Upgradable;
begin
  if Supports(AResponse, IH1Upgradable, Up1) then
    Exit(Http1AcceptWebSocket(ARequest, AResponse, Up1, AHandler));
  if Supports(AResponse, IH2Upgradable, Up2) then
    Exit(Http2AcceptWebSocket(ARequest, AResponse, Up2, AHandler));
  raise EHttpError.Create('this response cannot be upgraded to a WebSocket');
end;

end.
