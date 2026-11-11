{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Pool.Types;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  SyncObjs,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.Tls;


type
  IPooledConnection = interface
    function ActiveStreams: Integer;
    /// eligible = open(ing) and below the per-connection stream cap
    function Eligible: Boolean;
    /// register a lease under the connection lock and block until response
    /// HEADERS are decoded. AAcquired is False when the connection became
    /// ineligible, so the pool retries with another connection.
    function Acquire(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer; out AAcquired: Boolean): IHttpResponse;
    /// adopt the h2c upgrade request (RFC 7540 section 3.2): the peer already
    /// received it as stream 1, so nothing is re-sent and the response arrives
    /// on stream 1.  Only an HTTP/2 entry implements this (an HTTP/1.1 entry
    /// raises EHttpProtocolError).
    function AcquireUpgraded(const ARequest: TStreamRequest;
      const ATimeoutMs: Integer): IHttpResponse;
    /// the transport is finished (peer closed it, a failure was observed, or
    /// the codec consumed it); the pool may drop the entry once ActiveStreams
    /// is 0.  Protocol-neutral replacement for inspecting Conn.State.
    function Closed: Boolean;
    /// stop accepting new leases; close now when idle, else when the last
    /// outstanding body is released
    procedure Drain;
    /// close a drained connection once its last stream is gone (called when a
    /// response body is released)
    procedure ReleaseIfIdle;
    function GetConn: TConnection;
    function GetOrigin: string;
    function GetLock: TCriticalSection;
    /// stable per-connection identity used to key the idle-time map; an
    /// HTTP/1.1 entry has no TConnection, so it keys on its codec object
    function GetKey: Pointer;
    property Conn: TConnection read GetConn;
    property Origin: string read GetOrigin;
    property Lock: TCriticalSection read GetLock;
    property Key: Pointer read GetKey;
  end;
  TConnectionStats = record
    Protocol: TNegotiatedProtocol;
    State: TConnectionState;
    AgeMs, IdleMs: Int64;
    ActiveStreams: Integer;
    /// the peer's settings; 0 for HTTP/1.1
    PeerMaxConcurrentStreams: LongWord;
    PeerInitialWindowSize: LongWord;
    PeerMaxFrameSize: LongWord;
  end;
  TOriginStats = record
    Origin: string;
    Connections, IdleConnections, ActiveStreams, PendingAcquires: Integer;
    Details: TArray<TConnectionStats>;
  end;
  TPoolStats = record
    Connections, IdleConnections, ActiveStreams, PendingAcquires: Integer;
    PerOrigin: TArray<TOriginStats>;
  end;

implementation


end.
