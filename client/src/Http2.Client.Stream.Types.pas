{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, stream
notes:
  - This unit owns client request, body, cancellation and stream-id contracts.
---
}
unit Http2.Client.Stream.Types;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, SyncObjs, Http2.Client.Tls, Http2.Common.Headers,
  Http2.Common.Frames;

type
  /// the HTTP methods this client sends. The token is uppercased on the
  /// wire; THttpMethodToken exposes the token for a pseudo-header.
  THttpMethod = (hmGet, hmHead, hmPost, hmPut, hmDelete, hmConnect,
    hmOptions, hmTrace, hmPatch);

  /// cooperative cancellation for an in-flight request or body read
  // - declared here (not in Http2.Client.pas, which uses this unit) so a
  //   TStreamLease can poll it on a blocked body read: a request carries one
  //   through TStreamRequest.CancelToken and the lease resets the stream with
  //   RST_STREAM(CANCEL) when it flips.
  ICancellationToken = interface
    ['{6B1C2D3E-4F50-4A61-9C72-0000000000C1}']
    function IsCancelled: Boolean;
  end;

  /// the default thread-safe token: Cancel() may be called from any thread
  TCancellationToken = class(TInterfacedObject, ICancellationToken)
  private
    FLock: TCriticalSection;
    FCancelled: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel;
    function IsCancelled: Boolean;
  end;

  /// a pulled request body: NextChunk is called until it returns False, at
  /// which point the last emitted DATA frame carries END_STREAM
  /// (doc/design/messages.md "Request and response streaming").
  IBodyWriter = interface
    function NextChunk(out ABuffer: TBytes): Boolean;
  end;

  /// an in-memory request body; IsSet distinguishes an empty body from none
  THttpBody = record
  private
    FData: TBytes;
    FIsSet: Boolean;
  public
    class function FromBytes(const AData: TBytes): THttpBody; static;
    class function FromString(const AData: string): THttpBody; static;
    function IsSet: Boolean;
    function Data: TBytes;
  end;

  /// the arrival aggregates of the body chunks one exchange delivered.  A
  /// chunk is the bytes of one frame (HTTP/2) or one transport read
  /// (HTTP/1.1); stamps are absolute Http2.Client.Clock microseconds.
  TArrivalStats = record
    /// stamps of the first and the last chunk; 0 when none arrived
    FirstUs, LastUs: Int64;
    Count: Int64;
    /// the largest and the summed gap between consecutive chunk stamps
    MaxGapUs, SumGapUs: Int64;
    /// record the arrival of one more chunk stamped AArrivedUs
    procedure Note(const AArrivedUs: Int64);
  end;

  /// a body stream that can say when the bytes of its last Read arrived
  // - each Read returns bytes of exactly one chunk (one DATA frame, or one
  //   transport read on HTTP/1.1), so one Read maps to one stamp.  Consumers
  //   test Supports(Body, IStampedBodyStream) after a Read.
  IStampedBodyStream = interface
    ['{7D1E5A02-3B94-4C6F-8E21-5A0C9B3D6F11}']
    /// the arrival stamp, in microseconds on the Http2.Client.Clock clock, of the
    /// chunk that supplied the bytes returned by the last Read; 0 before any
    /// Read returned bytes
    function LastReadArrivedUs: Int64;
  end;

  /// how one exchange ended, as the codec saw it
  TExchangeEnd = record
    /// borrowed for the duration of the call; nil on a clean end
    Error: Exception;
    /// the response was released before its body was read to the end
    Abandoned: Boolean;
    /// body payload bytes sent and received on the wire
    BytesOut, BytesIn: Int64;
    /// when the body chunks arrived on the wire
    Arrivals: TArrivalStats;
  end;

  /// the per-attempt hook a codec reports to (doc/design/
  /// request-observability.md "Attempt end").  A request carries it in
  /// TStreamRequest.Exchange; nil costs nothing.  The codec never calls it
  /// while it holds a lock of its own on the consumer's thread, but the
  /// connection thread may (a connection failure), so an implementation must
  /// be thread-safe and fast.
  IExchangeObserver = interface
    ['{7D1E5A02-3B94-4C6F-8E21-5A0C9B3D6F10}']
    /// the pool picked the transport for this exchange
    procedure RouteChosen(const AProtocol: TNegotiatedProtocol;
      const AReused: Boolean);
    /// the request (head and body) has been handed to the transport
    procedure RequestWritten(const ABytesOut: Int64);
    /// the body reached its end, the exchange failed or it was released;
    /// reported at most once per codec exchange
    procedure ExchangeEnded(const AEnd: TExchangeEnd);
  end;

  /// the wire method token plus the parsed request fields one lease emits.
  /// Pseudo-header mapping happens at encode time; Method is stored uppercase.
  TStreamRequest = record
    Method: string;         // ':method' (uppercase token)
    Scheme: string;         // ':scheme'
    Authority: string;      // ':authority' (host[:port])
    Path: string;           // ':path' (defaults to '/')
    Headers: IHttpHeaders;  // regular headers
    Body: THttpBody;        // fixed body; IsSet=False when absent
    BodyWriter: IBodyWriter;
    /// the request's cancellation token (nil when none was supplied). The
    /// lease polls it in WaitForResponseHeader and in ReadBody.
    CancelToken: ICancellationToken;
    /// response-body read deadline in ms. BodyReadTimeoutSet distinguishes
    /// "use the header timeout" (False, the historic behaviour) from an
    /// explicit value (True); when set, 0 means "wait indefinitely", which
    /// a Server-Sent Events source relies on.
    BodyReadTimeoutMs: Integer;
    BodyReadTimeoutSet: Boolean;
    /// response-body limit in bytes (0 = no limit). MaxResponseBytesSet says
    /// whether the request set it; when False the client option applies.
    MaxResponseBytes: Int64;
    MaxResponseBytesSet: Boolean;
    /// the observed attempt this request belongs to (nil when unobserved)
    Exchange: IExchangeObserver;
    /// build a request with default scheme 'https', path '/', empty headers
    class function Create(const AMethod, AAuthority: string): TStreamRequest; static;
    class function WithMethod(const AMethod: THttpMethod;
      const AAuthority: string): TStreamRequest; static;
    function WithScheme(const AScheme: string): TStreamRequest;
    function WithPath(const APath: string): TStreamRequest;
    function WithHeader(const AName, AValue: string): TStreamRequest;
    function WithBody(const ABody: THttpBody): TStreamRequest;
    function WithBodyWriter(const AWriter: IBodyWriter): TStreamRequest;
    function WithCancelToken(const AToken: ICancellationToken): TStreamRequest;
    /// set the body read deadline explicitly (0 = wait indefinitely)
    function WithBodyReadTimeout(const AMs: Integer): TStreamRequest;
    /// attach the per-attempt end hook
    function WithExchange(const AExchange: IExchangeObserver): TStreamRequest;
  end;

  /// a response body stream (matches doc/design/messages.md IHttpBodyStream)
  IHttpBodyStream = interface
    /// block until bytes are available or END_STREAM is seen. The first Read
    /// that observes EOF returns 0; a Read after EOF raises EHttpStreamError.
    function Read(var ABuffer; const ACount: LongInt): LongInt;
    /// true once END_STREAM (or a bodyless response) is observed and buffered
    /// bytes are exhausted
    function Eof: Boolean;
  end;

  /// monotonic allocation of client-initiated (odd) stream ids for ONE
  /// connection. Guarded by its own TCriticalSection so many caller threads
  /// can allocate concurrently without duplicates.
  TStreamIdAllocator = class
  private
    FLock: TCriticalSection;
    FNext: LongWord;
  public
    constructor Create;
    destructor Destroy; override;
    /// the next odd id (1, 3, 5 ...); 0 once the id space is exhausted
    function Next: LongWord;
    /// the id that Next would return, without consuming it (test seam)
    function Peek: LongWord;
  end;


  /// local side of the RFC 7540 section 5.1 state machine
  TLeaseLocalState = (lsIdle, lsHeadersSent, lsLocalHalfClosed, lsClosed);
  TLeaseEndDue = (edNone, edEof, edFailed, edCancelled);

implementation

function HttpMethodToken(const AMethod: THttpMethod): string;
begin
  case AMethod of
    hmGet:     Result := 'GET';
    hmHead:    Result := 'HEAD';
    hmPost:    Result := 'POST';
    hmPut:     Result := 'PUT';
    hmDelete:  Result := 'DELETE';
    hmConnect: Result := 'CONNECT';
    hmOptions: Result := 'OPTIONS';
    hmTrace:   Result := 'TRACE';
    hmPatch:   Result := 'PATCH';
  else
    Result := 'GET';
  end;
end;

{ THttpBody }

class function THttpBody.FromBytes(const AData: TBytes): THttpBody;
begin
  Result.FData := AData;
  Result.FIsSet := True;
end;

class function THttpBody.FromString(const AData: string): THttpBody;
var
  B: TBytes;
begin
  B := nil;
  SetLength(B, Length(AData));
  if Length(B) > 0 then
    Move(AData[1], B[0], Length(B));
  Result.FData := B;
  Result.FIsSet := True;
end;

function THttpBody.IsSet: Boolean;
begin
  Result := FIsSet;
end;

function THttpBody.Data: TBytes;
begin
  Result := FData;
end;

{ TStreamRequest }

class function TStreamRequest.WithMethod(const AMethod: THttpMethod;
  const AAuthority: string): TStreamRequest;
begin
  Result := TStreamRequest.Create(HttpMethodToken(AMethod), AAuthority);
end;

class function TStreamRequest.Create(const AMethod,
  AAuthority: string): TStreamRequest;
begin
  Result.Method := UpperCase(AMethod);
  Result.Scheme := 'https';
  Result.Authority := AAuthority;
  Result.Path := '/';
  Result.Headers := NewHttpHeaders;
  Result.Body.FIsSet := False;
  Result.Body.FData := nil;
  Result.BodyWriter := nil;
  Result.CancelToken := nil;
  Result.BodyReadTimeoutMs := 0;
  Result.BodyReadTimeoutSet := False;
  Result.MaxResponseBytes := 0;
  Result.MaxResponseBytesSet := False;
  Result.Exchange := nil;
end;

function TStreamRequest.WithScheme(const AScheme: string): TStreamRequest;
begin
  Result := Self;
  Result.Scheme := AScheme;
end;

function TStreamRequest.WithPath(const APath: string): TStreamRequest;
begin
  Result := Self;
  if APath = '' then
    Result.Path := '/'
  else
    Result.Path := APath;
end;

function TStreamRequest.WithHeader(const AName, AValue: string): TStreamRequest;
begin
  Result := Self;
  if not Assigned(Result.Headers) then
    Result.Headers := NewHttpHeaders;
  Result.Headers.Add(AName, AValue);
end;

function TStreamRequest.WithBody(const ABody: THttpBody): TStreamRequest;
begin
  Result := Self;
  Result.Body := ABody;
  Result.BodyWriter := nil;
end;

function TStreamRequest.WithBodyWriter(
  const AWriter: IBodyWriter): TStreamRequest;
begin
  Result := Self;
  Result.BodyWriter := AWriter;
  Result.Body.FIsSet := False;
  Result.Body.FData := nil;
end;

function TStreamRequest.WithCancelToken(
  const AToken: ICancellationToken): TStreamRequest;
begin
  Result := Self;
  Result.CancelToken := AToken;
end;

function TStreamRequest.WithBodyReadTimeout(const AMs: Integer): TStreamRequest;
begin
  Result := Self;
  Result.BodyReadTimeoutMs := AMs;
  Result.BodyReadTimeoutSet := True;
end;

function TStreamRequest.WithExchange(
  const AExchange: IExchangeObserver): TStreamRequest;
begin
  Result := Self;
  Result.Exchange := AExchange;
end;

{ TArrivalStats }

procedure TArrivalStats.Note(const AArrivedUs: Int64);
var
  Gap: Int64;
begin
  if Count = 0 then
    FirstUs := AArrivedUs
  else
  begin
    Gap := AArrivedUs - LastUs;
    if Gap < 0 then
      Gap := 0;
    if Gap > MaxGapUs then
      MaxGapUs := Gap;
    Inc(SumGapUs, Gap);
  end;
  LastUs := AArrivedUs;
  Inc(Count);
end;

{ TCancellationToken }

constructor TCancellationToken.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FCancelled := False;
end;

destructor TCancellationToken.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TCancellationToken.Cancel;
begin
  FLock.Acquire;
  try
    FCancelled := True;
  finally
    FLock.Release;
  end;
end;

function TCancellationToken.IsCancelled: Boolean;
begin
  FLock.Acquire;
  try
    Result := FCancelled;
  finally
    FLock.Release;
  end;
end;

{ TStreamIdAllocator }

constructor TStreamIdAllocator.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FNext := 1;
end;

destructor TStreamIdAllocator.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TStreamIdAllocator.Next: LongWord;
begin
  FLock.Acquire;
  try
    Result := FNext;
    if FNext = 0 then
      Exit;                          // exhausted
    if FNext >= MaxStreamId then
      FNext := 0                     // this was the last odd id
    else
      FNext := FNext + 2;
  finally
    FLock.Release;
  end;
end;

function TStreamIdAllocator.Peek: LongWord;
begin
  FLock.Acquire;
  try
    Result := FNext;
  finally
    FLock.Release;
  end;
end;


end.
