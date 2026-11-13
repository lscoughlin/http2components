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
  Http2.Client.Concurrency.Test, Http2.Client.FlowControl.Test,Http2.Client.ConnectionLifecycle.Test,
  Http2.Client.ConnectionSettings.Test, Http2.Client.Connection.Receive.Test,
  Http2.Client.ConnectionThread.Test, Http2.Client.Encoding.Test,
  Http2.Client.HpackOrder.Test, Http2.Client.Http1.Test, Http2.Client.Http1Release.Test, Http2.Client.Http1Reuse.Test,
  Http2.Client.MockSocket.Observer.Test, Http2.Client.MockSocket.Hostile.Test, Http2.Client.MockSocket.Capture.Test, Http2.Client.MockSocket.Scenario.Test, Http2.Client.MutualTls.Accept.Test, Http2.Client.MutualTls.Reject.Test, Http2.Client.MutualTls.Routing.Test, Http2.Client.MutualTls.Request.Test, Http2.Client.MutualTls.Other.Test,
  Http2.Client.ObserverAdapters.Core.Test, Http2.Client.ObserverAdapters.Sink.Test, Http2.Client.PoolStats.Test,
  Http2.Client.ProbeOutcome.Test, Http2.Client.Proxy.Test,
  Http2.Client.ProxyClient.Builder.Test, Http2.Client.ProxyClient.Test, Http2.Client.ProxyLive.Test,
  Http2.Client.ProxyTransport.HttpConnect.Test, Http2.Client.ProxyTransport.Tls.Test, Http2.Client.Readers.Test,
  Http2.Client.Redirects.Methods.Test, Http2.Client.Redirects.Policy.Test, Http2.Client.Redirects.Test, Http2.Client.Request.Test,
  Http2.Client.RequestObserver.Core.Test, Http2.Client.Http1Observer.Test, Http2.Client.Clock.Hook.Test, Http2.Client.ArrivalStamp.Test, Http2.Client.Http1Arrival.Test, Http2.Client.MessageObserver.Test, Http2.Client.SseObservability.Test, Http2.Client.SigPipe.Test,
  Http2.Client.Socks.Test, Http2.Client.Sse.Parser.Test, Http2.Client.Sse.Reconnect.Test, Http2.Client.Stream.Core.Test, Http2.Client.Stream.Lifecycle.Test,
  Http2.Client.Timeouts.Test, Http2.Client.Tls.Test,
  Http2.Client.WebSocket.Codec.Test, Http2.Client.WebSocket.Handshake.Test, Http2.Client.WebSocketClient.Test,
  Http2.Client.WebSocketLive.Test, Http2.Client.WebSocketObservability.Core.Test,
  Http2.Client.WebSocketObservability.Lifecycle.Test,
  Http2.Client.Config.Security.Test,
  Http2.Client.Unix.TestKit, Http2.Client.UnixSocket.Test, Http2.Client.UnixDial.Test,
  Http2.Client.UnixClient.Test, Http2.Client.UnixClientWire.Test,
  Http2.Client.UnixClientProtocols.Test, Http2.Client.UnixProxyType.Test,
  Http2.Client.UnixProxyDial.Test, Http2.Client.UnixProxyClient.Test,
  Http2.Client.Url.Test,
  Http2.Client.ControlBytes.Test,
  Http2.Client.SseLimits.Test,
  Http2.Client.Redirect.Test,
  Http2.Client.Http1Strict.Test,
  Http2.Client.PoolDial.Test,
  Http2.Client.Receive.Test, Http2.Client.ReceiveCredit.Test,
  Http2.Client.PhaseDeadline.Test,
  Http2.Client.BodyLimits.Test,
  Http2.Client.HeaderLimits.Test,
  Http2.Client.ControlQueue.Test;

end.
