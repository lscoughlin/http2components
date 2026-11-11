{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_runner
notes:
  - this registers the imported client unit tests
---
}
unit Http2.Client.TestRunner;

{$mode delphi}{$H+}

interface

implementation

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry, consoletestrunner,
  Http2.Client.BlockingQueue.Test, Http2.Client.ClearText.Test,
  Http2.Client.Api.Test, Http2.Client.Pool.Test, Http2.Client.Lifecycle.Test, Http2.Client.ClientCert.Test,
  Http2.Client.Concurrency.Test, Http2.Client.ConnectionLifecycle.Test,
  Http2.Client.ConnectionSettings.Test,
  Http2.Client.ConnectionThread.Test, Http2.Client.Encoding.Test,
  Http2.Client.HpackOrder.Test, Http2.Client.Http1.Test,
  Http2.Client.MockSocket, Http2.Client.MutualTls.Test,
  Http2.Client.ObserverAdapters.Core.Test, Http2.Client.ObserverAdapters.Sink.Test, Http2.Client.PoolStats.Test,
  Http2.Client.ProbeOutcome.Test, Http2.Client.Proxy.Test,
  Http2.Client.ProxyClient.Builder.Test, Http2.Client.ProxyClient.Test, Http2.Client.ProxyLive.Test,
  Http2.Client.ProxyTransport.HttpConnect.Test, Http2.Client.ProxyTransport.Tls.Test, Http2.Client.Readers.Test,
  Http2.Client.Redirects.Methods.Test, Http2.Client.Redirects.Policy.Test, Http2.Client.Redirects.Test, Http2.Client.Request.Test,
  Http2.Client.RequestObserver.Test, Http2.Client.SigPipe.Test,
  Http2.Client.Socks.Test, Http2.Client.Sse.Parser.Test, Http2.Client.Sse.Reconnect.Test, Http2.Client.Stream.Core.Test, Http2.Client.Stream.Lifecycle.Test,
  Http2.Client.Timeouts.Test, Http2.Client.Tls.Test,
  Http2.Client.WebSocket.Codec.Test, Http2.Client.WebSocket.Handshake.Test, Http2.Client.WebSocketClient.Test,
  Http2.Client.WebSocketLive.Test, Http2.Client.WebSocketObservability.Core.Test,
  Http2.Client.WebSocketObservability.Lifecycle.Test;

end.
