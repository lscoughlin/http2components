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
/// Stream lease and request/response state machine (plan S08)
// - this unit is part of the http2client project (see doc/design/messages.md
//   "Request and response streaming" and doc/design/client-api.md
//   "Lease acquisition").
// - a TStreamLease owns exactly ONE request/response exchange: stream-id
//   allocation, request frame emission (HEADERS + DATA), response assembly
//   (status + headers + body) and the RFC 7540 section 5.1 half-closed
//   transitions. It pushes outbound frames onto the connection's queue (the
//   connection thread is the sole socket writer) and receives inbound frames
//   through the IConnectionStream callback.
// - frame assembly is driven by the CALLER thread (WaitForResponseHeader /
//   Body.Read pop an internal inbound queue); the connection thread only
//   enqueues. This keeps HPACK decode single-threaded.
unit Http2.Client.Stream;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack, Http2.Common.Status,
  Http2.Client.Tls,
  Http2.Client.Connection, Http2.Client.Stream.Types, Http2.Client.Stream.Receive, Http2.Common.Body;

const
  /// polls as often as this many milliseconds while waiting for a cancel
  /// (mirrors cCancelPollSliceMs in Http2.Client.pas: the lease cannot see
  /// that constant, and a body read needs the same cadence)
  cReadCancelPollSliceMs = 20;
  hmGet = Http2.Client.Stream.Types.hmGet;
  hmHead = Http2.Client.Stream.Types.hmHead;
  hmPost = Http2.Client.Stream.Types.hmPost;
  hmPut = Http2.Client.Stream.Types.hmPut;
  hmDelete = Http2.Client.Stream.Types.hmDelete;
  hmConnect = Http2.Client.Stream.Types.hmConnect;
  hmOptions = Http2.Client.Stream.Types.hmOptions;
  hmTrace = Http2.Client.Stream.Types.hmTrace;
  hmPatch = Http2.Client.Stream.Types.hmPatch;
  lsIdle = Http2.Client.Stream.Types.lsIdle;
  lsHeadersSent = Http2.Client.Stream.Types.lsHeadersSent;
  lsLocalHalfClosed = Http2.Client.Stream.Types.lsLocalHalfClosed;
  lsClosed = Http2.Client.Stream.Types.lsClosed;
  edNone = Http2.Client.Stream.Types.edNone;
  edEof = Http2.Client.Stream.Types.edEof;
  edFailed = Http2.Client.Stream.Types.edFailed;
  edCancelled = Http2.Client.Stream.Types.edCancelled;

type
  THttpMethod = Http2.Client.Stream.Types.THttpMethod;
  ICancellationToken = Http2.Client.Stream.Types.ICancellationToken;
  TCancellationToken = Http2.Client.Stream.Types.TCancellationToken;
  IBodyWriter = Http2.Client.Stream.Types.IBodyWriter;
  THttpBody = Http2.Client.Stream.Types.THttpBody;
  TArrivalStats = Http2.Client.Stream.Types.TArrivalStats;
  IStampedBodyStream = Http2.Client.Stream.Types.IStampedBodyStream;
  TExchangeEnd = Http2.Client.Stream.Types.TExchangeEnd;
  IExchangeObserver = Http2.Client.Stream.Types.IExchangeObserver;
  TStreamRequest = Http2.Client.Stream.Types.TStreamRequest;
  IHttpBodyStream = Http2.Client.Stream.Types.IHttpBodyStream;
  TStreamIdAllocator = Http2.Client.Stream.Types.TStreamIdAllocator;

  TLeaseLocalState = Http2.Client.Stream.Types.TLeaseLocalState;
  TLeaseEndDue = Http2.Client.Stream.Types.TLeaseEndDue;

  /// the response (receive) side assembly state
  TResponseState = (rsIdle, rsBodyOpen, rsBodyComplete, rsFailed);

  TStreamLease = class;

  /// one request/response exchange. Implements IConnectionStream so the
  /// connection can route stream-scoped frames to it and fan out failures.
  TStreamLease = class(TInterfacedObject, IConnectionStream)
  private
    FConnection: TConnection;
    FAllocator: TStreamIdAllocator;
    FRequest: TStreamRequest;
    FStreamId: LongWord;
    FOutbound: IBlockingQueue<TFrame>;
    FInbound: TByteBoundedFrameQueue;
    FEncoder: THpackCodec;
    FDecoder: THpackCodec;
    FOwnsEncoder: Boolean;
    FOwnsDecoder: Boolean;
    FWaitLock: TCriticalSection; // weak; the pooled connection outlives the lease
    FBodyStream: IHttpBodyStream;

    FStarted: Boolean;
    FRegistered: Boolean;
    FUnregistered: Boolean;
    /// set by the connection's reader thread when the peer has ended the
    /// response or reset the stream: an upload parked on credit stops, because
    /// a peer that answered early is not going to read the rest (RFC 9113
    /// section 8.1)
    FPeerDone: LongInt;
    FPeerReset: LongInt;
    FUploadStopped: Boolean;
    FLocalState: TLeaseLocalState;
    FResponseState: TResponseState;

    FStatusCode: LongInt;
    FResponseHeaders: IHttpHeaders;
    FHeadersDecoded: Boolean;

    // in-progress header block (HEADERS + CONTINUATION reassembly)
    FInHeaderBlock: Boolean;
    FPendingBlock: TBytes;
    FPendingEndStream: Boolean;

    // body assembly
    FBodyPending: TBytes;
    FBodyPendingOfs: Integer;
    /// the wire stamp of the frame in FBodyPending, taken from the frame
    FBodyArrivedUs: Int64;
    /// the stamp of the frame that supplied the last ReadBody
    FLastReadArrivedUs: Int64;
    FArrivals: TArrivalStats;
    FBodyEof: Boolean;
    FBodyReading: LongInt; // 1 while ReadBody runs; one reader at a time
    /// total DATA bytes received on this stream, compared against a declared
    /// `content-length` at END_STREAM (RFC 7540 section 8.1.2.6)
    FBodyReceived: Int64;
    /// declared content-length, or -1 when the response did not send one
    FExpectedLength: Int64;

    // failure / teardown
    FFailed: Boolean;
    FErrorMessage: string;
    FErrorCode: THttp2ErrorCode;
    /// True when the failure came from the CONNECTION (FailWith / a
    /// connection-level protocol violation), False when the stream alone
    /// failed (RST_STREAM, GOAWAY above the stream id). Callers rely on the
    /// distinction: a stream error leaves the connection usable, a
    /// connection error does not, and the conformance harness scores them as
    /// different outcomes.
    FConnectionError: Boolean;
    FRstReceived: Boolean;
    FRstCode: THttp2ErrorCode;
    FFailCount: Integer;
    FReleaseCount: Integer;
    FUnregisterCount: Integer;
    FGoAwayLastStreamId: LongWord;
    FRetryable: Boolean;

    FTimeoutMs: Integer;

    // observed-attempt hook (doc/design/request-observability.md)
    FExchange: IExchangeObserver;
    FBytesSent: Int64;
    FEndDue: TLeaseEndDue;
    FEndFired: LongInt;
    FDeferDelivery: Boolean;
    /// record that the exchange ended for AReason; the first reason wins.  It
    /// only records, so it is safe under the pooled connection's lock
    procedure NoteEnd(const AReason: TLeaseEndDue);
    /// tell the hook, once, outside any lock the caller controls
    procedure FireExchange(const AReason: TLeaseEndDue;
      const AAbandoned: Boolean);

    /// reserve up to AWant bytes of the peer's SEND window for this stream,
    /// blocking until credit arrives or the lease deadline expires. Raises
    /// EHttpTimeout on expiry so a stalled send fails instead of hanging.
    function MakeStreamError: EHttpError;
    function PopInbound(out AFrame: TFrame; const ATimeoutMs: Integer): Boolean;
    function WaitForInbound(const ATimeoutMs: Integer): Boolean;
    /// wait for an inbound frame on the body read path, honouring the
    /// request's own body-read deadline and polling its cancel token. Returns
    /// False on shutdown, on the deadline, or when the token is cancelled;
    /// the caller distinguishes the three.
    function WaitForBodyFrame(out AFrame: TFrame): Boolean;
    procedure HandleInboundFrame(const AFrame: TFrame);
    procedure HandleHeaderFrame(const AFrame: TFrame);
    procedure HandleDataFrame(const AFrame: TFrame);
    procedure DecodeBlock(const ABlock: TBytes; const AEndStream: Boolean);
    procedure ApplyDecodedBlock(const Fields: THeaderBlock;
      const AEndStream: Boolean);
    procedure MarkResponseComplete;
  public
    /// Production callers hold this lock while processing lease frames.
    /// Inbound queue waits release it and reacquire it before processing.
    property WaitLock: TCriticalSection read FWaitLock write FWaitLock;
    constructor Create(const AConnection: TConnection;
      const AAllocator: TStreamIdAllocator; const ARequest: TStreamRequest);
      overload;
    /// inject connection-scoped HPACK codecs (production); when omitted the
    /// lease creates its own (unit-test only: a wire codec table is shared
    /// per connection, not per stream)
    constructor Create(const AConnection: TConnection;
      const AAllocator: TStreamIdAllocator; const ARequest: TStreamRequest;
      const AEncoder, ADecoder: THpackCodec); overload;
    destructor Destroy; override;

    /// allocate the stream id, register with the connection, emit the request
    procedure Start;
    /// RFC 7540 section 3.2 (h2c upgrade): the peer already received this
    /// request as stream 1 during the HTTP/1.1 Upgrade, so adopt stream 1 and
    /// wait for its response WITHOUT emitting any request frame.  The request
    /// body (if any) was carried by the HTTP/1.1 message, never by DATA.
    procedure AdoptUpgradedStream;
    /// emit the request HEADERS block (END_STREAM when there is no body)
    procedure SendHeaders;
    /// emit one DATA frame; AEndStream half-closes the local side
    procedure SendData(const AData: TBytes; const AEndStream: Boolean);
    /// emit the request body (THttpBody or IBodyWriter pull), half-closing
    procedure SendBody;
    /// half-close the local side with an empty END_STREAM DATA frame
    procedure EndSend;

    /// block until response HEADERS are decoded. Returns False on timeout;
    /// raises EHttpProtocolError on framing/HPACK errors and EHttpStreamError
    /// when the peer RESETs the stream before the headers arrived.
    function WaitForResponseHeader(const ATimeoutMs: Integer): Boolean;
    /// release the lease (idempotent; unregisters from the connection once)
    procedure ReleaseLease;
    /// true once the response body is complete and no bytes are buffered
    function BodyEof: Boolean;
    /// blocking body read; a read after EOF gives 0. One reader at a time: a
    /// second call that overlaps this one raises EInvalidOperation
    function ReadBody(var ABuffer; const ACount: LongInt): LongInt;
    /// report a recorded end to the attempt hook (idempotent).  ReadBody only
    /// records; the caller delivers once it holds no lock
    procedure DeliverEnd;
    /// the response was released: report the recorded end, or an abandoned
    /// one when the body was never finished
    procedure AbandonExchange;

    // IConnectionStream
    procedure OnConnectionFailed(const AMessage: string;
      const ACode: THttp2ErrorCode);
    procedure OnConnectionGoAway(const ALastStreamId: LongWord);
    procedure OnStreamFrame(const AFrame: TFrame);

    property StreamId: LongWord read FStreamId;
    property LocalState: TLeaseLocalState read FLocalState;
    property ResponseState: TResponseState read FResponseState;
    property StatusCode: LongInt read FStatusCode;
    property ResponseHeaders: IHttpHeaders read FResponseHeaders;
    property Body: IHttpBodyStream read FBodyStream;
    /// the per-attempt hook the request carried (nil when unobserved)
    property Exchange: IExchangeObserver read FExchange;
    property RequestMethod: string read FRequest.Method;
    /// response/body read deadline (ms); default 30000
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    // test seams
    property ReleaseCount: Integer read FReleaseCount;
    property UnregisterCount: Integer read FUnregisterCount;
    property FailCount: Integer read FFailCount;
    property RstReceived: Boolean read FRstReceived;
    property RstCode: THttp2ErrorCode read FRstCode;
    property GoAwayLastStreamId: LongWord read FGoAwayLastStreamId;
    property Retryable: Boolean read FRetryable;
    /// True when the owner calls DeliverEnd itself, after releasing its lock
    property DeferDelivery: Boolean read FDeferDelivery write FDeferDelivery;
    /// the wire stamp of the frame that supplied the last ReadBody
    property LastReadArrivedUs: Int64 read FLastReadArrivedUs;
    /// request body bytes emitted as DATA so far
    property BytesSent: Int64 read FBytesSent;
  end;

implementation

uses
  Http2.Client.Stream.Send, Http2.Client.Stream.Exchange, Http2.Client.Stream.Inbound,
  Http2.Client.Stream.BodyView;

{ TStreamLease }

constructor TStreamLease.Create(const AConnection: TConnection;
  const AAllocator: TStreamIdAllocator; const ARequest: TStreamRequest);
begin
  Create(AConnection, AAllocator, ARequest, nil, nil);
end;

constructor TStreamLease.Create(const AConnection: TConnection;
  const AAllocator: TStreamIdAllocator; const ARequest: TStreamRequest;
  const AEncoder, ADecoder: THpackCodec);
begin
  inherited Create;
  if AConnection = nil then
    raise EHttpError.Create('TStreamLease requires a connection',
      ecInternalError);
  if AAllocator = nil then
    raise EHttpError.Create('TStreamLease requires a stream-id allocator',
      ecInternalError);
  FConnection := AConnection;
  FAllocator := AAllocator;
  FRequest := ARequest;
  FOutbound := FConnection.Outbound;
  FInbound := TByteBoundedFrameQueue.Create(FConnection.Security.MaxReceiveQueueBytes);
  FOwnsEncoder := AEncoder = nil;
  FOwnsDecoder := ADecoder = nil;
  if AEncoder <> nil then FEncoder := AEncoder else FEncoder := THpackCodec.Create;
  if ADecoder <> nil then FDecoder := ADecoder else FDecoder := THpackCodec.Create;
  FResponseHeaders := NewHttpHeaders;
  FBodyStream := TIStreamBody.Create(Self);
  FLocalState := lsIdle;
  FResponseState := rsIdle;
  FStatusCode := -1;
  FBodyReceived := 0;
  FExpectedLength := -1;
  FTimeoutMs := 30000;
  FGoAwayLastStreamId := MaxStreamId;
  FExchange := ARequest.Exchange;
end;

destructor TStreamLease.Destroy;
begin
  ReleaseLease;
  if FOwnsEncoder then FEncoder.Free;
  if FOwnsDecoder then FDecoder.Free;
  FInbound.Free;
  inherited Destroy;
end;

function TStreamLease.MakeStreamError: EHttpError;
begin
  Result := CreateStreamError(FConnection, FErrorMessage, FConnectionError,
    FErrorCode, FStreamId);
end;

procedure TStreamLease.Start;
var
  Err: EHttpError;
begin
  if FStarted then
    raise EHttpProtocolError.Create('stream lease already started',
      ecProtocolError);
  FStarted := True;
  FStreamId := FAllocator.Next;
  if FStreamId = 0 then
    raise EHttpError.Create('client stream-id space is exhausted',
      ecInternalError);
  FRegistered := True;     // before registering: the connection may fail us at once
  FConnection.RegisterStream(FStreamId, Self);
  if FFailed then
  begin
    // the connection was already dead: the stream must not stay in its map
    // (ReleaseLease is idempotent, and the failure callback usually ran it)
    Err := MakeStreamError;
    ReleaseLease;
    raise Err;
  end;
  try
    SendHeaders;
    if FLocalState = lsHeadersSent then
      SendBody;
  except
    ReleaseLease;
    raise;
  end;
end;

procedure TStreamLease.AdoptUpgradedStream;
begin
  if FStarted then
    raise EHttpProtocolError.Create('stream lease already started',
      ecProtocolError);
  FStarted := True;
  // RFC 7540 section 3.2: "requests that contain a payload body MUST be sent
  // in their entirety before the client can send HTTP/2 frames", and the
  // upgrade request becomes stream 1
  FStreamId := FAllocator.Next;
  if FStreamId <> 1 then
    raise EHttpProtocolError.Create('an h2c upgrade must use stream 1',
      ecProtocolError);
  if not FConnection.AdoptStreamOne(Self) then
    raise EHttpProtocolError.Create('stream 1 is already in use',
      ecProtocolError);
  FRegistered := True;
  // the request was already sent as the HTTP/1.1 upgrade request, so nothing
  // more is emitted: the local side is half-closed (and the response's
  // END_STREAM drives it to closed via MarkResponseComplete)
  FLocalState := lsLocalHalfClosed;
end;

procedure TStreamLease.SendHeaders;
begin
  LeaseSendHeaders(FRequest, FEncoder, FOutbound, FStreamId,
    LeaseMaxFrameSize(FConnection), FLocalState);
end;

procedure TStreamLease.SendData(const AData: TBytes;
  const AEndStream: Boolean);
begin
  LeaseSendData(FConnection, FOutbound, FWaitLock, FStreamId, FTimeoutMs,
    @FPeerDone, @FPeerReset, FUploadStopped, FBytesSent, FLocalState, AData,
    AEndStream);
end;

procedure TStreamLease.SendBody;
begin
  LeaseSendBody(FConnection, FRequest, FOutbound, FWaitLock, FStreamId,
    FTimeoutMs, @FPeerDone, @FPeerReset, FUploadStopped, FBytesSent,
    FLocalState);
end;

procedure TStreamLease.EndSend;
begin
  LeaseEndSend(FConnection, FOutbound, FWaitLock, FStreamId, FTimeoutMs,
    @FPeerDone, @FPeerReset, FUploadStopped, FBytesSent, FLocalState);
end;

function TStreamLease.WaitForInbound(const ATimeoutMs: Integer): Boolean;
begin
  if FWaitLock <> nil then FWaitLock.Release;
  try
    Result := FInbound.WaitForItem(ATimeoutMs);
  finally
    if FWaitLock <> nil then FWaitLock.Acquire;
  end;
end;

function TStreamLease.PopInbound(out AFrame: TFrame;
  const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  if FInbound.TryPop(AFrame) then
    Exit(True);
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if FInbound.IsShutdown then
      Exit(False);
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    WaitForInbound(Remaining);
    if FInbound.TryPop(AFrame) then
      Exit(True);
  end;
end;

function TStreamLease.WaitForBodyFrame(out AFrame: TFrame): Boolean;
var
  Deadline: QWord;
  EffectiveMs: Integer;
  HasDeadline: Boolean;
  Slice: Integer;
  Token: ICancellationToken;
  Waiting: Boolean;
begin
  if FInbound.TryPop(AFrame) then
    Exit(True);
  Token := FRequest.CancelToken;
  // an explicit body-read deadline (0 = wait indefinitely) overrides the
  // historic header-timeout default; an unset request keeps FTimeoutMs so
  // every existing caller behaves byte-for-byte as before
  if FRequest.BodyReadTimeoutSet then
    EffectiveMs := FRequest.BodyReadTimeoutMs
  else
    EffectiveMs := FTimeoutMs;
  HasDeadline := EffectiveMs > 0;
  if HasDeadline then
    Deadline := GetTickCount64 + QWord(EffectiveMs);
  while True do
  begin
    if FInbound.IsShutdown then
      Exit(False);
    if HasDeadline and (GetTickCount64 >= Deadline) then
      Exit(False);
    // poll the token every slice so a Cancel unblocks the read promptly;
    // without a token this is one blocking wait (remaining deadline or,
    // for an SSE stream, indefinitely)
    if Token <> nil then
      Slice := cReadCancelPollSliceMs
    else if HasDeadline then
      Slice := Integer(Deadline - GetTickCount64)
    else
      Slice := MaxInt;
    if (Token <> nil) and Token.IsCancelled then
      Exit(False);
    Waiting := WaitForInbound(Slice);
    if FInbound.TryPop(AFrame) then
      Exit(True);
    if not Waiting then
    begin
      // no item within the slice: either the queue shut down, the deadline
      // expired, or a poll slice elapsed and the token may have flipped
      if FInbound.IsShutdown then
        Exit(False);
      if (Token <> nil) and Token.IsCancelled then
        Exit(False);
      if HasDeadline and (GetTickCount64 >= Deadline) then
        Exit(False);
      Continue;
    end;
  end;
end;

procedure TStreamLease.HandleInboundFrame(const AFrame: TFrame);
var
  Code: THttp2ErrorCode;
begin
  case AFrame.Header.FrameType of
    ftHeaders, ftContinuation:
      HandleHeaderFrame(AFrame);
    ftData:
      HandleDataFrame(AFrame);
    ftRstStream:
      begin
        ParseRstStream(AFrame, Code);
        FRstReceived := True;
        FRstCode := Code;
        if not FFailed then
        begin
          FFailed := True;
          FErrorCode := Code;
          FErrorMessage := 'peer reset stream ' + IntToStr(FStreamId) + ': ' +
            Http2ErrorCodeName(Code);
        end;
        FBodyEof := True;
        FResponseState := rsFailed;
        FLocalState := lsClosed;
        ReleaseLease;
      end;
    ftWindowUpdate:
      ; // flow-control replenishment is integrated by the connection layer
  else
    ; // frames not addressed to a single stream are ignored here
  end;
end;

procedure TStreamLease.HandleHeaderFrame(const AFrame: TFrame);
begin
  if not FInHeaderBlock then
  begin
    if AFrame.Header.FrameType <> ftHeaders then
      raise EHttpProtocolError.Create('CONTINUATION without HEADERS',
        ecProtocolError);
    FInHeaderBlock := True;
    FPendingBlock := ExtractHeaderBlock(AFrame);
    FPendingEndStream := AFrame.IsEndStream;
  end
  else
  begin
    if AFrame.Header.FrameType <> ftContinuation then
      raise EHttpProtocolError.Create('expected CONTINUATION',
        ecProtocolError);
    // append the continuation block
    if Length(ExtractHeaderBlock(AFrame)) > 0 then
    begin
      FPendingBlock := ConcatStreamBytes(FPendingBlock,
        ExtractHeaderBlock(AFrame));
    end;
    if AFrame.IsEndStream then
      FPendingEndStream := True;
  end;
  if AFrame.IsEndHeaders then
  begin
    FInHeaderBlock := False;
    if AFrame.HeadersDecoded then
      ApplyDecodedBlock(AFrame.DecodedHeaders, FPendingEndStream)
    else
      DecodeBlock(FPendingBlock, FPendingEndStream);
  end;
end;

procedure TStreamLease.DecodeBlock(const ABlock: TBytes;
  const AEndStream: Boolean);
begin
  ApplyDecodedBlock(FDecoder.Decode(ABlock), AEndStream);
end;

procedure TStreamLease.ApplyDecodedBlock(const Fields: THeaderBlock;
  const AEndStream: Boolean);
var
  F: THttpHeaderField;
  I, St: Integer;
  SawRegular: Boolean;
begin
  if not FHeadersDecoded then
  begin
    FStatusCode := -1;
    FExpectedLength := -1;
    SawRegular := False;
    for I := 0 to High(Fields) do
    begin
      F := Fields[I];
      if F.Name = HeaderStatus then
      begin
        // RFC 7540 section 8.1.2.1: pseudo-header fields MUST appear before
        // regular fields; a :status arriving after a regular field is a
        // malformed response -> STREAM PROTOCOL_ERROR (harness 8.1.2.1/4).
        if SawRegular then
          raise EHttpStreamError.Create(
            ':status pseudo-header after a regular header field', FStreamId,
            ecProtocolError);
        St := StrToIntDef(F.Value, -1);
        if (St < 100) or (St > 599) then
          // RFC 7540 section 8.1.2.6: a malformed response is a STREAM error
          // (the connection survives); the peer is told with RST_STREAM.
          raise EHttpStreamError.Create('invalid :status value ' + F.Value,
            FStreamId, ecProtocolError);
        FStatusCode := St;
      end
      else if (F.Name <> '') and (F.Name[1] = ':') then
        raise EHttpStreamError.Create(
          'unexpected pseudo-header in response: ' + F.Name, FStreamId,
          ecProtocolError)
      else
      begin
        SawRegular := True;
        // RFC 7540 section 8.1.2: header field names MUST be lowercase; a
        // response with an uppercase name is malformed -> STREAM
        // PROTOCOL_ERROR (harness 8.1.2/1).
        if F.Name <> LowerCase(F.Name) then
          raise EHttpStreamError.Create(
            'header field name is not lowercase: ' + F.Name, FStreamId,
            ecProtocolError);
        if SameText(F.Name, HeaderContentLength) then
          FExpectedLength := StrToInt64Def(F.Value, -1);
        // RFC 9113 section 8.2.2: 'te' is the one connection-specific field
        // allowed in HTTP/2, and a *response* may carry it only with the
        // value 'trailers'. Any other value is malformed -> STREAM
        // PROTOCOL_ERROR (harness 8.1.2.2/2).
        if SameText(F.Name, HeaderTe) and (not SameText(Trim(F.Value), 'trailers')) then
          raise EHttpStreamError.Create(
            'response te header must be "trailers": ' + F.Value, FStreamId,
            ecProtocolError);
        FResponseHeaders.Add(F.Name, F.Value);
      end;
    end;
    if FStatusCode < 0 then
      raise EHttpStreamError.Create('response has no :status', FStreamId,
        ecProtocolError);
    FHeadersDecoded := True;
    // bodyless responses: 1xx, 204, 304 and every HEAD request.
    //  * HEAD and 1xx: a declared content-length describes the entity a GET
    //    *would* return (RFC 9110 section 8.6), so exempt it from the length
    //    check entirely.
    //  * 204/304: no body is sent, but a non-zero declared content-length is
    //    still malformed (RFC 7540 section 8.1.2.6); keep the value so
    //    MarkResponseComplete can compare it against the zero bytes received.
    if RequestIsBodyless(FRequest.Method) or
       ((FStatusCode >= 100) and (FStatusCode < 200)) then
    begin
      FExpectedLength := -1;
      MarkResponseComplete;
    end
    else if (FStatusCode = HttpStatusNoContent) or (FStatusCode = HttpStatusNotModified) then
      MarkResponseComplete
    else
      FResponseState := rsBodyOpen;
  end  else
  begin
    // trailers: regular headers only, never a second :status, and the frame
    // must END the stream. RFC 7540 section 8.1.2.6: a HEADERS frame (and its
    // CONTINUATIONs) can only appear at the end of a stream, so one arriving
    // without END_STREAM is a malformed response -> STREAM PROTOCOL_ERROR
    // (the connection survives; harness case 8.1/1).
    if not AEndStream then
      raise EHttpStreamError.Create(
        'trailing HEADERS without END_STREAM', FStreamId, ecProtocolError);
    for I := 0 to High(Fields) do
    begin
      F := Fields[I];
      if F.Name = HeaderStatus then
        raise EHttpStreamError.Create(
          'trailing HEADERS must not carry :status', FStreamId,
          ecProtocolError);
      FResponseHeaders.Add(F.Name, F.Value);
    end;
  end;

  if AEndStream then
    MarkResponseComplete;
  if FBodyEof then
    ReleaseLease;
end;

procedure TStreamLease.MarkResponseComplete;
begin
  FBodyEof := True;
  FResponseState := rsBodyComplete;
  // RFC 7540 section 8.1.2.6: if the response declared a content-length, the
  // DATA it actually sent must match. A mismatch is a malformed response ->
  // STREAM PROTOCOL_ERROR (the connection survives; harness 8.1.2.6/1,2).
  if (FExpectedLength >= 0) and (FBodyReceived <> FExpectedLength) then
    raise EHttpStreamError.Create(
      Format('content-length %d does not match %d received DATA bytes',
        [FExpectedLength, FBodyReceived]), FStreamId, ecProtocolError);
  // RFC 7540 section 5.1: local half-closed + remote END_STREAM = closed
  if FLocalState = lsLocalHalfClosed then
    FLocalState := lsClosed;
end;

procedure TStreamLease.HandleDataFrame(const AFrame: TFrame);
begin
  if FResponseState = rsIdle then
    raise EHttpProtocolError.Create('DATA before response HEADERS',
      ecProtocolError);
  // DATA on a stream that already saw END_STREAM is a STREAM error, not a
  // connection error: only this stream is broken (RFC 7540 section 5.1,
  // "closed (remote)" / "half-closed (remote)"), and the peer is told with
  // RST_STREAM. Raising a connection error here aborted the whole connection
  // and the harness scored it as a level mismatch (8.1.2.6/2).
  if (FResponseState = rsBodyComplete) or FBodyEof then
    raise EHttpStreamError.Create('DATA after END_STREAM', FStreamId,
      ecStreamClosed);
  FBodyPending := ExtractDataPayload(AFrame);
  FBodyPendingOfs := 0;
  // the stamp belongs to the frame: this runs on the consumer's thread, long
  // after the reader thread saw the frame, so the clock is never read here
  FBodyArrivedUs := AFrame.ArrivedUs;
  Inc(FBodyReceived, Length(FBodyPending));
  FConnection.DataConsumed(FStreamId, AFrame.DataLength); // credit follows the read
  FResponseState := rsBodyOpen;
  if AFrame.IsEndStream then
  begin
    MarkResponseComplete;
    ReleaseLease;
  end;
end;

function TStreamLease.WaitForResponseHeader(
  const ATimeoutMs: Integer): Boolean;
var
  Frame: TFrame;
  Deadline: QWord;
  Remaining: Integer;
begin
  Result := False;
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while True do
  begin
    if FFailed then
      raise MakeStreamError;
    if FHeadersDecoded then
      Break;
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    if not PopInbound(Frame, Remaining) then
    begin
      // the queue can shut down because the stream failed (RST_STREAM,
      // GOAWAY, connection loss) rather than because the deadline expired;
      // surface that cause instead of masking it as a timeout, else the
      // caller's transparent-retry path never sees the stream error
      if FFailed then
        raise MakeStreamError;
      Exit(False);
    end;
    HandleInboundFrame(Frame);
  end;
  if FFailed then
    raise MakeStreamError;
  Result := True;
end;

function TStreamLease.BodyEof: Boolean;
begin
  Result := FBodyEof and (FBodyPendingOfs >= Length(FBodyPending));
end;

function TStreamLease.ReadBody(var ABuffer; const ACount: LongInt): LongInt;
var
  P: PByte;
  Avail, N: Integer;
  Frame: TFrame;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  if InterlockedExchange(FBodyReading, 1) <> 0 then
    raise EInvalidOperation.Create('the response body has a second reader at the same time');
  try
    P := @ABuffer;
    while True do
    begin
      Avail := Length(FBodyPending) - FBodyPendingOfs;
      if Avail > 0 then
      begin
        N := ACount;
        if N > Avail then
          N := Avail;
        // one Read spans one frame, so it has one stamp; the first Read of a
        // frame is one more arrival
        if FBodyPendingOfs = 0 then
          FArrivals.Note(FBodyArrivedUs);
        FLastReadArrivedUs := FBodyArrivedUs;
        Move(FBodyPending[FBodyPendingOfs], P^, N);
        Inc(FBodyPendingOfs, N);
        if FBodyEof and (FBodyPendingOfs >= Length(FBodyPending)) and
           (not FFailed) then
          NoteEnd(edEof);
        Exit(N);
      end;
      if FFailed then
      begin
        NoteEnd(edFailed);
        raise MakeStreamError;
      end;
      // every Read after the end gives 0 (D2); NoteEnd keeps the first end
      if FBodyEof then
      begin
        NoteEnd(edEof);
        Exit(0);
      end;
      // a body read waits with the request's own deadline when it is set (0
      // waits indefinitely, as an SSE stream needs); otherwise FTimeoutMs applies
      if not WaitForBodyFrame(Frame) then
      begin
        // the queue shuts down when the stream fails (RST_STREAM, GOAWAY,
        // connection loss): surface that cause, not a timeout (mirrors
        // WaitForResponseHeader), so a dead connection is told from a slow peer
        if FFailed then
        begin
          NoteEnd(edFailed);
          raise MakeStreamError;
        end;
        if (FRequest.CancelToken <> nil) and
           FRequest.CancelToken.IsCancelled then
        begin
          NoteEnd(edCancelled);
          // abandon the stream the same way a cancelled Send does: reset it,
          // never orphan it (doc/design/errors-redirects.md "Cancellation")
          FConnection.PostFrame(BuildRstStreamFrame(FStreamId, ecCancel));
          ReleaseLease;
          raise EHttpStreamError.Create('body read cancelled', FStreamId,
            ecCancel);
        end;
        raise EHttpTimeout.Create('timed out reading response body');
      end;
      HandleInboundFrame(Frame);
    end;
  finally
    InterlockedExchange(FBodyReading, 0);
  end;
end;

procedure TStreamLease.ReleaseLease;
begin
  if FUnregistered then
    Exit;
  FUnregistered := True;
  Inc(FReleaseCount);
  if FRegistered then
  begin
    Inc(FUnregisterCount);
    FConnection.UnregisterStream(FStreamId);
  end;
end;

procedure TStreamLease.OnConnectionFailed(const AMessage: string;
  const ACode: THttp2ErrorCode);
begin
  Inc(FFailCount);
  if not FFailed then
  begin
    FFailed := True;
    FConnectionError := True;   // connection-scoped: the connection is gone
    FErrorMessage := AMessage;
    FErrorCode := ACode;
    FBodyEof := True;
    if FResponseState = rsIdle then
      FResponseState := rsFailed;
    FLocalState := lsClosed;
  end;
  FInbound.Shutdown;
  ReleaseLease;
  // the connection thread holds no lock here (TConnection.FailWith fans out
  // after releasing its own), so the hook may run now
  if FFailed then
    FireExchange(edFailed, False);
end;

procedure TStreamLease.OnConnectionGoAway(const ALastStreamId: LongWord);
begin
  FGoAwayLastStreamId := ALastStreamId;
  FRetryable := FStreamId > ALastStreamId;
  // RFC 7540 section 6.8: a stream whose id is above last-stream-id was never
  // processed and is safe to retry; a stream at or below it still completes
  // and must NOT be failed by the GOAWAY itself.
  if FRetryable and (not FBodyEof) then
  begin
    FFailed := True;
    FErrorMessage := 'peer sent GOAWAY before this stream was processed';
    FErrorCode := ecRefusedStream;
    FBodyEof := True;
    FResponseState := rsFailed;
    FInbound.Shutdown;
    ReleaseLease;
    FireExchange(edFailed, False);
  end;
end;

procedure TStreamLease.NoteEnd(const AReason: TLeaseEndDue);
begin
  RecordExchangeEnd(FExchange, FEndDue, AReason);
end;

procedure TStreamLease.FireExchange(const AReason: TLeaseEndDue;
  const AAbandoned: Boolean);
var
  E: Exception;
begin
  if FExchange = nil then
    Exit;
  if InterlockedCompareExchange(FEndFired, 1, 0) <> 0 then Exit;
  E := nil;
  case AReason of
    edFailed:    E := MakeStreamError;
    edCancelled: E := EHttpStreamError.Create('body read cancelled',
                   FStreamId, ecCancel);
  end;
  FireExchangeEnd(FExchange, AAbandoned,
    FBodyReceived, FBytesSent, FArrivals, E);
end;

procedure TStreamLease.DeliverEnd;
begin
  if (FExchange <> nil) and (FEndDue <> edNone) then
    FireExchange(FEndDue, False);
end;

procedure TStreamLease.AbandonExchange;
begin
  if FExchange = nil then
    Exit;
  if FEndDue <> edNone then
    FireExchange(FEndDue, False)
  else
    FireExchange(edNone, True);
end;

procedure TStreamLease.OnStreamFrame(const AFrame: TFrame);
begin
  if FUnregistered then Exit;
  if LeasePushInbound(FConnection, FInbound, FStreamId, AFrame, @FPeerDone,
    @FPeerReset) then
    Exit;
  // the queue overflowed: a stream error, the connection goes on
  FFailed := True;
  FErrorMessage := 'receive queue of stream ' + IntToStr(FStreamId) + ' is full';
  FErrorCode := ecFlowControlError;
  FBodyEof := True;
  FResponseState := rsFailed;
  FLocalState := lsClosed;
  FInbound.Shutdown;
  ReleaseLease;
  FireExchange(edFailed, False);
end;

end.
