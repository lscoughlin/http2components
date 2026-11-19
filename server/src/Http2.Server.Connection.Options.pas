{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, options, limits
notes:
  - This unit holds the options record of the connection core. The record
    carries every per-connection limit that the core needs.
  - Http2.Server.Connection.Core re-exports the type, so a unit that uses the
    core needs no other unit for the record.
---
}
/// The per-connection options of the HTTP/2 server connection core
unit Http2.Server.Connection.Options;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

type
  /// the per-connection values the core needs
  // - the factory fills every field; the core creates no default and holds no
  //   limit literal of its own
  TConnectionCoreOptions = record
    ConnectionWindow: LongInt;
    InitialStreamWindow: LongInt;
    MaxConcurrentStreams: LongWord;
    MaxFrameSize: LongWord;
    MaxHeaderListSize: LongWord;
    MaxHeaderTableSize: LongWord;
    MaxContinuations: LongWord;
    MaxHeaderBlockBytes: LongWord;
    InboundBufferLimit: Integer;
    OutboundBufferLimit: Integer;
    ConnectionUpdateThreshold: LongWord;
    StreamUpdateThreshold: LongWord;
    /// advertise SETTINGS_ENABLE_CONNECT_PROTOCOL and accept :protocol (RFC 8441)
    ConnectProtocol: Boolean;
    /// the most octets that the output queue of one connection may hold; a
    /// peer that does not read ends the connection above it. Zero sets no cap
    MaxOutputBytes: LongWord;
    /// how many requests one connection serves before it retires; 0 is off
    MaxStreams: LongWord;
    /// the most outbound frames that may wait for the peer; 0 is off
    MaxOutboundFrames: LongWord;
    /// the most outbound PING, SETTINGS and RST_STREAM frames that may
    /// wait for the peer; 0 is off
    MaxOutboundControlFrames: LongWord;
    /// the greatest size of an outbound DATA frame, in octets; 0 sends
    /// up to MaxFrameSize
    MaxDataFrameSizeOut: LongWord;
    /// the greatest wait for a read of a stream, in milliseconds; 0 keeps
    /// the stream default
    StreamReadTimeoutMs: Integer;
    /// the greatest wait for a write of a stream, in milliseconds; 0 keeps
    /// the stream default
    StreamWriteTimeoutMs: Integer;
    /// zero every field, so a caller that sets only the fields it uses
    /// leaves every other limit off
    class operator Initialize(var AOptions: TConnectionCoreOptions);
  end;

implementation

class operator TConnectionCoreOptions.Initialize(
  var AOptions: TConnectionCoreOptions);
begin
  FillChar(AOptions, SizeOf(AOptions), 0);
end;

end.
