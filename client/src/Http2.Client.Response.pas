{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Response;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  SyncObjs,
  Http2.Common.Headers,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.RequestObserver,
  Http2.Client.Pool.Types;


type
  TGuardedBody = class(TInterfacedObject, IHttpBodyStream, IStampedBodyStream)
  private
    FInner: IHttpBodyStream;
    FLock: TCriticalSection;
    FLease: TStreamLease;    // weak; the response keeps the lease alive
  public
    constructor Create(const AInner: IHttpBodyStream;
      const ALock: TCriticalSection; const ALease: TStreamLease = nil);
    function Read(var ABuffer; const ACount: LongInt): LongInt;
    function Eof: Boolean;
    /// the stamp of the last Read's frame (0 when the inner body is not
    /// stamped)
    function LastReadArrivedUs: Int64;
  end;

  THttpResponse = class(TInterfacedObject, IHttpResponse, IAttemptProgress)
  private
    FLease: TStreamLease;
    FProgress: IAttemptProgress;
    FKeepAlive: IConnectionStream;   // keeps the lease alive after unregister
    FConnRef: IPooledConnection;     // keeps the TConnection alive
    FHeaders: IHttpHeaders;
    FBody: IHttpBodyStream;
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
    function GetStreamId: LongWord;
  public
    constructor Create(const ALease: TStreamLease;
      const AKeepAlive: IConnectionStream; const AConnRef: IPooledConnection);
    destructor Destroy; override;
    /// the reporter a reader of the body uses (Supports(Response,
    /// IAttemptProgress)); it does nothing when the request is not observed
    property Progress: IAttemptProgress read FProgress
      implements IAttemptProgress;
    /// the wire stream id (test seam)
    property StreamId: LongWord read GetStreamId;
  end;

implementation

constructor TGuardedBody.Create(const AInner: IHttpBodyStream;
  const ALock: TCriticalSection; const ALease: TStreamLease);
begin
  inherited Create;
  FInner := AInner;
  FLock := ALock;
  FLease := ALease;
end;

function TGuardedBody.Read(var ABuffer; const ACount: LongInt): LongInt;
begin
  try
    FLock.Acquire;
    try
      Result := FInner.Read(ABuffer, ACount);
    finally
      FLock.Release;
    end;
  finally
    // the lease only records the end of the exchange under the connection
    // lock; the observer is told here, once the lock is released
    if FLease <> nil then
      FLease.DeliverEnd;
  end;
end;

function TGuardedBody.Eof: Boolean;
begin
  Result := FInner.Eof;
end;

function TGuardedBody.LastReadArrivedUs: Int64;
var
  Stamped: IStampedBodyStream;
begin
  if Supports(FInner, IStampedBodyStream, Stamped) then
    Result := Stamped.LastReadArrivedUs
  else
    Result := 0;
end;

{ THttpResponse }

constructor THttpResponse.Create(const ALease: TStreamLease;
  const AKeepAlive: IConnectionStream; const AConnRef: IPooledConnection);
begin
  inherited Create;
  FLease := ALease;
  FKeepAlive := AKeepAlive;
  FConnRef := AConnRef;
  FHeaders := ALease.ResponseHeaders;
  FProgress := ProgressOf(ALease.Exchange);
  ALease.DeferDelivery := True;
  FBody := TGuardedBody.Create(ALease.Body, AConnRef.Lock, ALease);
end;

destructor THttpResponse.Destroy;
begin
  // a response released before its body was read ends the attempt as
  // abandoned; this runs outside the connection lock
  FLease.AbandonExchange;
  FLease.ReleaseLease;
  if FConnRef <> nil then
    FConnRef.ReleaseIfIdle;
  inherited Destroy;
end;

function THttpResponse.GetStatusCode: LongInt;
begin
  Result := FLease.StatusCode;
end;

function THttpResponse.GetStreamId: LongWord;
begin
  Result := FLease.StreamId;
end;

function THttpResponse.GetHeaders: IHttpHeaders;
begin
  Result := FHeaders;
end;

function THttpResponse.GetBody: IHttpBodyStream;
begin
  Result := FBody;
end;

{ THttpConnection }

end.
