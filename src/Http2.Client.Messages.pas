{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client
notes:
  - Imported from http2client source revision 709336f542cbedf9ce1ab67d83bddcfd560eb1c0.
  - Unit references use the common and client namespaces.
---
}
/// message-level interfaces shared by every client codec (plan S13)
// - doc/design/messages.md defines IHttpResponse, IHttpBodyStream and
//   IResponseReader<T>.  IHttpBodyStream lives in Http2.Client.Stream.pas (it is
//   wired to the HTTP/2 lease), so this unit only carries the transport
//   neutral parts: the response interface and the typed body reader.
// - The unit exists so a second codec (the HTTP/1.1 fallback of plan S13,
//   src/Http2.Client.Http1.pas) can implement IHttpResponse without depending on
//   Http2.Client.pas, which sits above it.  Without the split the dependency
//   would be circular: Http2.Client uses the codec to send, the codec would
//   use Http2.Client for the interface.
unit Http2.Client.Messages;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream;

type
  /// a response (doc/design/messages.md IHttpResponse). Pseudo-headers are
  /// surfaced through StatusCode, never through Headers.
  IHttpResponse = interface
    ['{8B1C2D3E-4F50-4A61-9C72-0123456789AB}']
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
    property StatusCode: LongInt read GetStatusCode;
    property Headers: IHttpHeaders read GetHeaders;
    property Body: IHttpBodyStream read GetBody;
  end;

  /// one dispatched Server-Sent Event (WHATWG "Dispatch the event")
  // - declared here, below the observer seam, so a per-message callback can
  //   carry a pointer to it; Http2.Client.Sse re-exports it under the same name.
  TSseEvent = record
    /// the event type; 'message' when the stream sent no `event:` field
    EventType: string;
    /// the data payload, with the single trailing newline removed
    Data: string;
    /// the last-event-ID in force at dispatch time ('' when never set)
    Id: string;
    /// the `retry:` value in force at dispatch time, in ms (0 = none seen)
    RetryMs: Integer;
  end;
  PSseEvent = ^TSseEvent;

  /// bridges a response body into a value of T (doc/design/messages.md)
  IResponseReader<T> = interface
    function Read(const AResponse: IHttpResponse): T;
  end;

  // TClearTextPolicy, TNegotiatedProtocol and ICleartextSocketFactory are
  // declared in Http2.Client.Tls.pas (they belong with the transport that acts on
  // them; placing them here would make Http2.Client.Tls need this unit while this
  // unit needs Http2.Client.Tls for IHttp2Socket -- a circular reference).  They are
  // re-exported as aliases so callers that already use Http2.Client.Messages keep
  // compiling.  Note the enum LITERALS (ctReject, npHttp2Tls, ...) are only
  // visible to a unit that also names Http2.Client.Tls in its uses clause; both
  // existing consumers already do.
  TClearTextPolicy = Http2.Client.Tls.TClearTextPolicy;
  TNegotiatedProtocol = Http2.Client.Tls.TNegotiatedProtocol;
  ICleartextSocketFactory = Http2.Client.Tls.ICleartextSocketFactory;

implementation

end.
