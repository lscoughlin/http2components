{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, test, fpcunit
notes:
  - This unit registers the test cases of the HTTP/2 server suite.
  - Each test unit registers its own cases in its initialization section.
---
}
/// fpcunit registration unit for the HTTP/2 server test suite
// - the console runner calls RegisterTests once, before the suite runs
// - a test unit joins the suite by its presence in the uses clause below
unit Http2.Server.TestRunner;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

/// registers every test case of the suite on the global test registry
procedure RegisterTests;

implementation

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  // each unit registers its test cases in its initialization section
  Http2.Server.Alpn.Test,
  Http2.Server.Async.Test,
  Http2.Server.Config.Test,
  Http2.Server.MoreConfig.Test,
  Http2.Server.Connection.Test,
  Http2.Server.Connection.Flow.Test,
  Http2.Server.Connection.Lifetime.Test,
  Http2.Server.Async.Age.Test,
  Http2.Server.WriteTimeout.Test,
  Http2.Server.AsyncCaps.Test,
  Http2.Server.Protocol.Server.Test,
  Http2.Server.Seam.Test,
  Http2.Server.Stream.Test,
  Http2.Server.StreamTimeouts.Test,
  Http2.Server.Limits.Test,
  Http2.Server.StreamPool.Test,
  Http2.Server.Detach.Test,
  Http2.Server.DetachLive.Test,
  Http2.Server.WebSocket.Frames.Test,
  Http2.Server.WebSocket.Parser.Test,
  Http2.Server.Sse.Test,
  Http2.Server.Sse.Encoder.Test,
  Http2.Server.SseLive.Test,
  Http2.Server.ResponseWriter.Test,
  Http2.Server.Http1.TestKit,
  Http2.Server.Http1.Head.Test,
  Http2.Server.Http1.Chunked.Test,
  Http2.Server.ChunkLine.Test,
  Http2.Server.Http1.RawClient,
  Http2.Server.Http1.Live.Test,
  Http2.Server.Http1.Config.Test,
  Http2.Server.BufferGrow.Test,
  Http2.Server.BodyBudget.Test,
  Http2.Server.Http1.Detach.Test,
  Http2.Server.Http1.Fuzz.Test,
  Http2.Server.WebSocket.Origin.Test,
  Http2.Server.WebSocket.TestKit,
  Http2.Server.WebSocket.Session.Test,
  Http2.Server.WebSocketBudget.Test,
  Http2.Server.WebSocket.Pool.Test,
  Http2.Server.WebSocket.Http1.Test,
  Http2.Server.WebSocket.Http2.Test,
  Http2.Server.ConnectProtocol.Test,
  Http2.Server.RequestPseudo.Test,
  Http2.Server.OutboundBudget.Test,
  Http2.Server.Output.Test,
  Http2.Server.OutputCaps.Test,
  Http2.Server.Licence.Test,
  Http2.Server.Encoding.Test,
  Http2.Server.Validation.Test,
  Http2.Server.Validation.Abuse.Test,
  Http2.Server.Admission.Test,
  Http2.Server.HandlerError.Test,
  Http2.Server.AccessLog.Test,
  Http2.Server.Mtls.Test,
  Http2.Server.H2Peer.Test,
  Http2.Server.H2Credit.Test,
  Http2.Server.H2Flow.Test,
  Http2.Server.H2Hpack.Test,
  Http2.Server.H2Lifecycle.Test,
  Http2.Server.ContentLength.Test,
  Http2.Server.H2Locks.Test,
  Http2.Server.WsHardening.Test,
  Http2.Server.Lifecycle.Test,
  Http2.Server.ConfigRanges.Test,
  Http2.Server.RapidResetGaps.Test,
  Http2.Server.Facade.Test,
  Http2.Server.Http1.Hardening.Test,
  Http2.Server.Runtime.Test,
  Http2.Server.TlsPolicy.Test,
  Http2.Server.ConfigUnix.Test,
  Http2.Server.Unix.Path.Test,
  Http2.Server.Unix.TestKit,
  Http2.Server.UnixServer.Test,
  Http2.Server.UnixOptions.Test,
  Http2.Server.UnixFacade.Test,
  Http2.Server.UnixProtocol.Test,
  Http2.Server.WebSocketHost.Test,
  Http2.Server.HandlerDeadline.Test,
  Http2.Server.Http1.Unfinished.Test,
  Http2.Server.Async.Trace.Test,
  Http2.Server.Http1.Fields.Test,
  Http2.Server.Async.Flight.Test;

const
  /// name of the top-level suite in the runner report
  cHttp2ServerSuiteName = 'Http2.Server';

procedure RegisterTests;
var
  Suite: TTestSuite;
begin
  Suite := TTestSuite.Create(cHttp2ServerSuiteName);
  GetTestRegistry.AddTest(Suite);
end;

end.
