{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Defaults;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface



const
  /// documented factory defaults (doc/design/client-api.md "HttpClientFactory")
  ///
  /// Two connection caps apply (doc/design/architecture.md "resolved model"):
  /// MaxConnectionsPerHost is the reuse/parallelism budget for one authority
  /// (RFC 9113 section 9.1 says a client SHOULD NOT open more than one, but a
  /// small cap lets a small number of connections carry the load);
  /// MaxTotalConnections bounds the file descriptors and TLS memory across
  /// every origin.  MaxStreamsPerConnection is the per-connection request cap
  /// and is applied on top of the peer's SETTINGS_MAX_CONCURRENT_STREAMS.
  cDefaultMaxConnectionsPerHost   = 4;
  cDefaultMaxTotalConnections     = 32;
  cDefaultMaxStreamsPerConnection = 100;
  cDefaultFollowRedirects         = True;
  cDefaultMaxRedirects            = 10;
  cDefaultConnectTimeoutMs        = 10000;
  cDefaultHeaderTimeoutMs         = 30000;
  cDefaultIdleTimeoutMs           = 60000;
  /// the default TLS port; omitted from :authority when the URL port matches
  cDefaultHttpsPort               = 443;
  /// the default cleartext port (doc/design/fallback.md "Terms")
  cDefaultHttpPort                = 80;
  /// transparent retries allowed for an idempotent request on a refused stream
  cMaxTransparentRetries          = 2;
  /// a cancellable wait polls its token in slices of this many milliseconds
  cCancelPollSliceMs              = 20;
  /// default for the HTTP/1.1 ALPN fallback (doc/design/fallback.md)
  cDefaultHttp1Fallback           = False;
  /// an HTTP/1.1 connection carries one request at a time (doc/design/
  /// fallback.md "HTTP/1.1 codec"): the effective stream limit is 1, so the
  /// pool opens more connections for concurrency, bounded per host by
  /// MaxConnectionsPerHost and pool-wide by MaxTotalConnections
  cHttp1StreamLimit               = 1;

implementation


end.
