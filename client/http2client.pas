{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
// Package unit. The package file lists the units of this package.
unit http2client;

{$mode delphi}

interface

uses
  Http2.Client.Api,
  Http2.Client.Attempt,
  Http2.Client.BodyReader,
  Http2.Client.Body.Limits,
  Http2.Client.ClientCert,
  Http2.Client.Clock,
  Http2.Client.Config.Security,
  Http2.Client.Connection.Observer,
  Http2.Client.Connection.Queue,
  Http2.Client.Connection.SendCredit,
  Http2.Client.Connection.Credit,
  Http2.Client.Connection.HeaderBlock,
  Http2.Client.Connection.Thread,
  Http2.Client.Connection,
  Http2.Client.Core,
  Http2.Client.Defaults,
  Http2.Client.Encoding,
  Http2.Client.Errors,
  Http2.Client.Factory,
  Http2.Client.Http1.Body,
  Http2.Client.Http1,
  Http2.Client.Http1.Parse,
  Http2.Client.Identity,
  Http2.Client.IdentityHandle,
  Http2.Client.Messages,
  Http2.Client.Observer,
  Http2.Client.Pool.Http1,
  Http2.Client.Pool.Http2,
  Http2.Client.Pool.State,
  Http2.Client.Pool.Types,
  Http2.Client.Pool,
  Http2.Client.Proxy.Environment,
  Http2.Client.Proxy.Match,
  Http2.Client.Proxy.Types,
  Http2.Client.Proxy.Unix,
  Http2.Client.Proxy,
  Http2.Client.Redirect,
  Http2.Client.Request,
  Http2.Client.RequestObserver,
  Http2.Client.Response,
  Http2.Client.SigPipe,
  Http2.Client.SocketFactory.Types,
  Http2.Client.SocketFactory,
  Http2.Client.Socks,
  Http2.Client.Sse,
  Http2.Client.Stream.Exchange,
  Http2.Client.Stream.Send,
  Http2.Client.Stream.Types,
  Http2.Client.Stream.Receive,
  Http2.Client.Stream,
  Http2.Client.Tls.Plain,
  Http2.Client.Tls.Socket,
  Http2.Client.Tls.Tunnel,
  Http2.Client.Tls.Types,
  Http2.Client.Tls,
  Http2.Client.Upgrade,
  Http2.Client.Url,
  Http2.Client.WebSocket.Connection.Observer,
  Http2.Client.WebSocket.Connection.Open,
  Http2.Client.WebSocket.Connection.Types,
  Http2.Client.WebSocket.Connection,
  Http2.Client.WebSocket.Protocol,
  Http2.Client.WebSocket,
  Http2.Client;

implementation

end.
