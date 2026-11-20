{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, stream, body
notes:
  - This unit holds the body view of a stream lease: an IHttpBodyStream over the response body of one lease.
  - The unit uses the lease type of Http2.Client.Stream. That unit uses this unit in its implementation only.
---
}
unit Http2.Client.Stream.BodyView;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Classes, Http2.Client.Stream.Types, Http2.Client.Stream, Http2.Common.Body;

type
  /// IHttpBodyStream view of a lease's response body
  TIStreamBody = class(TBodyReaderBase, IHttpBodyStream, IStampedBodyStream)
  private
    FLease: TStreamLease;   // weak reference: the lease owns this object
  public
    constructor Create(const ALease: TStreamLease);
    function Read(var ABuffer; const ACount: LongInt): LongInt; override;
    function Eof: Boolean;
    function LastReadArrivedUs: Int64;
  end;

implementation

{ TIStreamBody }

constructor TIStreamBody.Create(const ALease: TStreamLease);
begin
  inherited Create;
  FLease := ALease;
end;

function TIStreamBody.Read(var ABuffer; const ACount: LongInt): LongInt;
begin
  try
    Result := FLease.ReadBody(ABuffer, ACount);
  finally
    // a pooled response defers this until its connection lock is released
    if not FLease.DeferDelivery then
      FLease.DeliverEnd;
  end;
end;

function TIStreamBody.Eof: Boolean;
begin
  Result := FLease.BodyEof;
end;

function TIStreamBody.LastReadArrivedUs: Int64;
begin
  Result := FLease.LastReadArrivedUs;
end;

end.
