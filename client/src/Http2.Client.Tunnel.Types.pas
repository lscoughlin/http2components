{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket, tunnel
notes:
  - This unit declares the interfaces of a tunnel over one HTTP/2 stream.
  - The unit has no WebSocket code, so that the connection pool does not depend on the WebSocket units.
---
}
unit Http2.Client.Tunnel.Types;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils;

type
  /// a byte tunnel over one HTTP/2 stream (RFC 8441 carries a WebSocket this way)
  IH2Tunnel = interface
    ['{C5B6FF99-C5D5-4DB8-AF35-FCB7F7A2B21A}']
    /// send AData as DATA; blocks for credit; raises EHttpConnectionError when the stream ended
    procedure SendData(const AData: TBytes);
    /// half-close: END_STREAM with no data
    procedure EndSend;
    /// wait up to ATimeoutMs for at least one octet; returns the count (1 to ACount),
    /// 0 at END_STREAM, -1 when the time passed with no octet
    function ReadSome(var ABuffer; ACount: Integer; ATimeoutMs: Integer): Integer;
    /// RST_STREAM with CANCEL; idempotent
    procedure Reset;
    /// true once both directions ended or the stream was reset
    function IsEnded: Boolean;
    /// true when the stream ended by RST_STREAM or by a connection failure
    function EndedAbnormally: Boolean;
    /// release the stream (idempotent)
    procedure Release;
  end;

  /// implemented by a socket over a tunnel that can end the stream at once
  IH2Abortable = interface
    ['{203FD7FA-63DD-445F-B786-82024BE00B05}']
    /// reset the stream with CANCEL and release it; no Close frame is sent
    procedure Abort;
  end;

implementation

end.
