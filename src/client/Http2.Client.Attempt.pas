{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Attempt;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  SyncObjs,
  Http2.Client.Errors,
  Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client.Tls,
  Http2.Client.WebSocket,
  Http2.Client.WebSocket.Connection,
  Http2.Client.Clock,
  Http2.Client.RequestObserver,
  Http2.Client.Request,
  Http2.Client.Url;


type
  TWsHandshakeSink = class(TInterfacedObject, IHeaderSink)
  private
    FFields: TArray<TWsHeaderField>;
  public
    constructor Create(const AFields: TArray<TWsHeaderField>);
    procedure SetValue(const AName, AValue: string);
    function GetFirst(const AName: string): string;
    function Fields: TArray<TWsHeaderField>;
  end;

  TAttemptTracker = class(TInterfacedObject, IExchangeObserver,
    IAttemptProgress, IWebSocketAttempt)
  private
    FObserver: IHttpClientObserver;
    FToken: IInterface;
    FStartUs: Int64;
    FCancelToken: ICancellationToken;
    FStatus: LongInt;
    FProtocol: TNegotiatedProtocol;
    FReused: Boolean;
    FBytesOut: Int64;
    FRequestSentUs: Int64;
    FRequestWritten: Boolean;
    FHeadersUs: Int64;
    // an end reported before Send armed the tracker
    FEndAbandoned: Boolean;
    // the body chunk arrivals the codec reported with the end
    FArrivals: TArrivalStats;
    FEndBytesIn: Int64;
    FEndBytesOut: Int64;
    FEndHasError: Boolean;
    FEndErrorText: string;
    FArmed: LongInt;
    FEnded: LongInt;
    FFired: LongInt;
    // the per-message path: asked once per attempt in Start
    FMessages: IHttpMessageObserver;
    FWanted: TMessageKinds;
    // what a reader reported; guarded by FProgressLock
    FProgressLock: TCriticalSection;
    FReaderIn: TArrivalStats;
    FReaderOut: Int64;
    FInIndex, FOutIndex: Int64;
    FInLastUs, FOutLastUs: Int64;
    // a clean end held back while a reader is inside a Read
    FInRead: LongInt;
    FHeld: LongInt;            // 0 none, 1 held, 2 claimed
    FHeldEnd: TExchangeEnd;
    // WebSocket: written by the thread that wins the end latch, or before
    // the reader thread exists
    FSink: TWsHandshakeSink;   // weak: FSinkRef holds it
    FSinkRef: IHeaderSink;
    FSubprotocol: string;
    FWsClosedBy: TCloseInitiator;
    FWsCloseCode: Integer;
    FWsCloseReason: string;
    procedure TryFireHeld;
    procedure Dispatch(const AError: Exception; const AAbandoned: Boolean;
      const ABytesIn, ABytesOut: Int64);
    procedure TryFireEarly;
    procedure BeginAttempt(const A: THttpAttempt);
  public
    constructor Create(const AObserver: IHttpClientObserver);
    destructor Destroy; override;
    /// build the attempt for ARequest (whose headers are a private clone) and
    /// run OnAttemptStart
    procedure Start(const ARequest: THttpRequest; const AHop,
      ARetry: Integer);
    /// the same for a WebSocket request, before it dials
    procedure StartSocket(const ARequest: IWebSocketRequest; const AHost: string;
      const APort: Word; const ASecure: Boolean);
    /// a WebSocket attempt failed before the session opened: end it with
    /// AError and, for a refused handshake, the status the server answered
    procedure FailHandshake(const AError: Exception);
    procedure GotResponse(const AResponse: IHttpResponse);
    procedure NotifyRedirect(const AFromUrl, AToUrl: string;
      const AStatus: LongInt);
    procedure NotifyRetry(const AReason: string);
    /// the attempt failed in Send: end it with AError (a no-op once ended)
    procedure Fail(const AError: Exception);
    /// Send is done reporting headers (and redirect): an end may now fire
    procedure Arm(const AResponse: IHttpResponse);
    /// Send dropped the response itself (a redirect hop): end now if the
    /// response's release did not
    procedure Drop;
    // IExchangeObserver
    procedure RouteChosen(const AProtocol: TNegotiatedProtocol;
      const AReused: Boolean);
    procedure RequestWritten(const ABytesOut: Int64);
    procedure ExchangeEnded(const AEnd: TExchangeEnd);
    // IAttemptProgress
    function WantedKinds: TMessageKinds;
    procedure ReportMessage(const AKind: TMessageKind;
      const ADirection: TDirection; const AArrivedUs: Int64;
      const ASize: Integer; const ASse: PSseEvent);
    procedure ReadBegin;
    procedure ReadEnd;
    procedure Finish(const ABytesIn: Int64);
    // IWebSocketAttempt
    function HandshakeHeaders: TArray<TWsHeaderField>;
    procedure HandshakeWritten;
    procedure HandshakeAccepted(const AStatus: Integer;
      const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
    procedure SessionEnded(const AEnd: TWsSessionEnd);
  end;

implementation

uses
  Http2.Common.Headers, Http2.Client.Http1;

constructor TWsHandshakeSink.Create(const AFields: TArray<TWsHeaderField>);
begin
  inherited Create;
  FFields := Copy(AFields);
end;

procedure TWsHandshakeSink.SetValue(const AName, AValue: string);
var
  I, N: Integer;
begin
  if not WsIsHttpToken(AName) then
    raise EHttpWebSocketError.CreateFmt('"%s" is not a header name', [AName]);
  if WsIsRestrictedHeader(AName) then
    raise EHttpWebSocketError.CreateFmt(
      'header "%s" is set by the handshake and cannot be supplied', [AName]);
  if (Pos(#13, AValue) > 0) or (Pos(#10, AValue) > 0) then
    raise EHttpWebSocketError.Create('a header value cannot contain a line break');
  // replace every value: drop the old ones, then append the new one
  N := 0;
  for I := 0 to High(FFields) do
    if not SameText(FFields[I].Name, AName) then
    begin
      FFields[N] := FFields[I];
      Inc(N);
    end;
  SetLength(FFields, N + 1);
  FFields[N].Name := AName;
  FFields[N].Value := AValue;
end;

function TWsHandshakeSink.GetFirst(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(FFields) do
    if SameText(FFields[I].Name, AName) then
      Exit(FFields[I].Value);
  Result := '';
end;

function TWsHandshakeSink.Fields: TArray<TWsHeaderField>;
begin
  Result := Copy(FFields);
end;

constructor TAttemptTracker.Create(const AObserver: IHttpClientObserver);
begin
  inherited Create;
  FObserver := AObserver;
  FProgressLock := TCriticalSection.Create;
  FStartUs := NowUs;
end;

destructor TAttemptTracker.Destroy;
begin
  FProgressLock.Free;
  inherited Destroy;
end;

procedure TAttemptTracker.Start(const ARequest: THttpRequest; const AHop,
  ARetry: Integer);
var
  A: THttpAttempt;
  Path: string;
begin
  FCancelToken := ARequest.CancelToken;
  A.Kind := ARequest.AttemptKind;
  A.Method := ARequest.MethodToken;
  A.Url := ARequest.Url;
  A.Host := '';
  A.Port := 0;
  try
    ParseHttpUrl(ARequest.Url, A.Host, A.Port, Path);
  except
    // SendOnce raises the same error and the attempt then ends with it
  end;
  A.Hop := AHop;
  A.Retry := ARetry;
  A.StreamId := ARequest.StreamId;
  A.Reconnect := ARequest.Reconnect;
  A.Context := ARequest.Context;
  A.Headers := THeaderSink.Create(ARequest.Headers);
  BeginAttempt(A);
end;

procedure TAttemptTracker.StartSocket(const ARequest: IWebSocketRequest;
  const AHost: string; const APort: Word; const ASecure: Boolean);
var
  A: THttpAttempt;
begin
  FSink := TWsHandshakeSink.Create(ARequest.Headers);
  FSinkRef := FSink;
  // a WebSocket is on its own HTTP/1.1 connection, never a pooled one
  if ASecure then
    FProtocol := npHttp1Tls
  else
    FProtocol := npHttp1Cleartext;
  FReused := False;
  FCancelToken := nil;
  A.Kind := akWebSocket;
  A.Method := 'GET';
  A.Url := ARequest.Url;
  A.Host := AHost;
  A.Port := APort;
  A.Hop := 0;
  A.Retry := 0;
  A.StreamId := 0;
  A.Reconnect := 0;
  A.Context := ARequest.Context;
  A.Headers := FSinkRef;
  BeginAttempt(A);
end;

procedure TAttemptTracker.BeginAttempt(const A: THttpAttempt);
var
  Gate: IHttpMessageGate;
begin
  try
    FToken := FObserver.OnAttemptStart(A);
  except
    FToken := nil;
  end;
  // the message observer is asked once per attempt.  A composite already
  // collected its members' answers in OnAttemptStart; any other observer is
  // asked here.  An empty answer leaves the per-message path switched off.
  FWanted := [];
  FMessages := nil;
  try
    if Supports(FObserver, IHttpMessageObserver, FMessages) then
      if Supports(FObserver, IHttpMessageGate, Gate) then
        FWanted := Gate.WantedFor(FToken)
      else
        FWanted := FMessages.WantsMessages(A);
  except
    FWanted := [];
  end;
  if FWanted = [] then
    FMessages := nil;
end;

procedure TAttemptTracker.GotResponse(const AResponse: IHttpResponse);
begin
  FStatus := AResponse.StatusCode;
  FHeadersUs := NowUs - FStartUs;
  try
    FObserver.OnResponseHeaders(FToken, AResponse);
  except
    // the composite guards its members; this is the last line of defence
  end;
end;

procedure TAttemptTracker.NotifyRedirect(const AFromUrl, AToUrl: string;
  const AStatus: LongInt);
begin
  try
    FObserver.OnRedirect(FToken, AFromUrl, AToUrl, AStatus);
  except
  end;
end;

procedure TAttemptTracker.NotifyRetry(const AReason: string);
begin
  try
    FObserver.OnRetry(FToken, AReason);
  except
  end;
end;

procedure TAttemptTracker.Dispatch(const AError: Exception;
  const AAbandoned: Boolean; const ABytesIn, ABytesOut: Int64);
var
  O: THttpOutcome;
  Arrivals: TArrivalStats;
begin
  FillChar(O, SizeOf(O), 0);
  O.Subprotocol := FSubprotocol;
  O.ClosedBy := FWsClosedBy;
  O.CloseCode := FWsCloseCode;
  O.CloseReason := FWsCloseReason;
  O.StatusCode := FStatus;
  O.Protocol := FProtocol;
  O.ConnectionReused := FReused;
  O.Error := AError;
  O.Abandoned := AAbandoned;
  O.Cancelled := (AError <> nil) and (
    ((AError is EHttpStreamError) and
     (EHttpStreamError(AError).ErrorCode = ecCancel)) or
    ((FCancelToken <> nil) and FCancelToken.IsCancelled));
  O.BytesIn := ABytesIn;
  O.BytesOut := ABytesOut;
  if O.BytesOut < FBytesOut then
    O.BytesOut := FBytesOut;
  O.RequestSentUs := FRequestSentUs;
  O.HeadersUs := FHeadersUs;
  FProgressLock.Acquire;
  try
    // a reader that reported messages (an SSE event is a message, a DATA
    // frame is not) wins over the codec's per-frame arrivals
    if FReaderIn.Count > 0 then
      Arrivals := FReaderIn
    else
      Arrivals := FArrivals;
    O.MessagesOut := FReaderOut;
  finally
    FProgressLock.Release;
  end;
  if Arrivals.Count > 0 then
  begin
    // stamps are absolute clock values; the outcome is relative to the start
    O.FirstMessageUs := Arrivals.FirstUs - FStartUs;
    O.LastMessageUs := Arrivals.LastUs - FStartUs;
    O.MessagesIn := Arrivals.Count;
    O.MaxGapUs := Arrivals.MaxGapUs;
    O.SumGapUs := Arrivals.SumGapUs;
  end;
  O.EndUs := NowUs - FStartUs;
  try
    FObserver.OnAttemptEnd(FToken, O);
  except
  end;
end;

procedure TAttemptTracker.Fail(const AError: Exception);
begin
  if InterlockedCompareExchange(FFired, 1, 0) = 0 then
    Dispatch(AError, False, 0, 0);
end;

procedure TAttemptTracker.TryFireEarly;
var
  E: Exception;
begin
  if InterlockedCompareExchange(FFired, 1, 0) <> 0 then
    Exit;
  E := nil;
  if FEndHasError then
    // the original exception is gone; a connection failure that raced the
    // arming is reported by its text
    E := EHttpError.Create(FEndErrorText, ecInternalError);
  try
    Dispatch(E, FEndAbandoned, FEndBytesIn, FEndBytesOut);
  finally
    E.Free;
  end;
end;

procedure TAttemptTracker.Arm(const AResponse: IHttpResponse);
var
  Done: Boolean;
begin
  // a response that is already complete (HEAD, 204, END_STREAM on the
  // headers) has nothing left to read: end it now rather than at release
  Done := False;
  if (AResponse <> nil) and (AResponse.Body <> nil) then
    Done := AResponse.Body.Eof;
  if Done and (InterlockedCompareExchange(FEnded, 0, 0) = 0) then
  begin
    FEndAbandoned := False;
    FEndBytesIn := 0;
    FEndBytesOut := 0;
    FEndHasError := False;
    InterlockedExchange(FEnded, 1);
  end;
  InterlockedExchange(FArmed, 1);
  if InterlockedCompareExchange(FEnded, 0, 0) = 1 then
    TryFireEarly;
end;

procedure TAttemptTracker.Drop;
begin
  // the response was dropped; if nothing reported its end, it ends abandoned
  if InterlockedCompareExchange(FFired, 1, 0) = 0 then
    Dispatch(nil, True, 0, 0);
end;

procedure TAttemptTracker.RouteChosen(const AProtocol: TNegotiatedProtocol;
  const AReused: Boolean);
begin
  FProtocol := AProtocol;
  FReused := AReused;
end;

procedure TAttemptTracker.RequestWritten(const ABytesOut: Int64);
begin
  // the h2c paths report again after the response head was read (the probe
  // carried the request); the first report is the real write, so a later one
  // may only raise the byte count, never move the stamp
  if ABytesOut > FBytesOut then
    FBytesOut := ABytesOut;
  if FRequestWritten then
    Exit;
  FRequestWritten := True;
  FRequestSentUs := NowUs - FStartUs;
end;

procedure TAttemptTracker.ExchangeEnded(const AEnd: TExchangeEnd);
begin
  FArrivals := AEnd.Arrivals;
  if (AEnd.Error = nil) and (not AEnd.Abandoned) and
     (InterlockedCompareExchange(FArmed, 0, 0) = 1) and
     (InterlockedCompareExchange(FInRead, 0, 0) = 1) then
  begin
    // a reader is inside the Read that ended the body: let it report what
    // that Read returned first
    FHeldEnd := AEnd;
    InterlockedExchange(FHeld, 1);
    if InterlockedCompareExchange(FInRead, 0, 0) = 0 then
      TryFireHeld;
    Exit;
  end;
  if InterlockedCompareExchange(FArmed, 0, 0) = 1 then
  begin
    // armed: report with the live exception
    if InterlockedCompareExchange(FFired, 1, 0) = 0 then
      Dispatch(AEnd.Error, AEnd.Abandoned, AEnd.BytesIn, AEnd.BytesOut);
    Exit;
  end;
  FEndAbandoned := AEnd.Abandoned;
  FEndBytesIn := AEnd.BytesIn;
  FEndBytesOut := AEnd.BytesOut;
  FEndHasError := AEnd.Error <> nil;
  if FEndHasError then
    FEndErrorText := AEnd.Error.ClassName + ': ' + AEnd.Error.Message;
  InterlockedExchange(FEnded, 1);
  // Arm may have run between the check above and the store: look again
  if InterlockedCompareExchange(FArmed, 0, 0) = 1 then
    TryFireEarly;
end;

procedure TAttemptTracker.TryFireHeld;
begin
  if InterlockedCompareExchange(FHeld, 2, 1) <> 1 then
    Exit;
  if InterlockedCompareExchange(FFired, 1, 0) = 0 then
    Dispatch(nil, False, FHeldEnd.BytesIn, FHeldEnd.BytesOut);
end;

function TAttemptTracker.WantedKinds: TMessageKinds;
begin
  Result := FWanted;
end;

procedure TAttemptTracker.ReportMessage(const AKind: TMessageKind;
  const ADirection: TDirection; const AArrivedUs: Int64;
  const ASize: Integer; const ASse: PSseEvent);
var
  M: TMessageInfo;
  Deliver: Boolean;
begin
  // a message that a reader on another thread reports as the attempt ends is
  // not delivered: OnMessage never follows OnAttemptEnd
  if InterlockedCompareExchange(FFired, 0, 0) <> 0 then
    Exit;
  Deliver := AKind in FWanted;
  if Deliver then
    FillChar(M, SizeOf(M), 0);
  FProgressLock.Acquire;
  try
    if ADirection = mdIn then
    begin
      if Deliver then
      begin
        M.Index := FInIndex;
        if FInIndex > 0 then
          M.SinceLastUs := AArrivedUs - FInLastUs;
      end;
      Inc(FInIndex);
      FInLastUs := AArrivedUs;
      if AKind in [mkSseEvent, mkWsText, mkWsBinary] then
        FReaderIn.Note(AArrivedUs);
    end
    else
    begin
      if Deliver then
      begin
        M.Index := FOutIndex;
        if FOutIndex > 0 then
          M.SinceLastUs := AArrivedUs - FOutLastUs;
      end;
      Inc(FOutIndex);
      // senders on several threads may report slightly out of order
      if (Deliver) and (M.SinceLastUs < 0) then
        M.SinceLastUs := 0;
      if AArrivedUs > FOutLastUs then
        FOutLastUs := AArrivedUs;
      if AKind in [mkSseEvent, mkWsText, mkWsBinary] then
        Inc(FReaderOut);
    end;
  finally
    FProgressLock.Release;
  end;
  if not Deliver then
    Exit;
  M.Kind := AKind;
  M.Direction := ADirection;
  M.Size := ASize;
  M.ArrivedUs := AArrivedUs - FStartUs;
  if (AKind = mkSseEvent) and (ASse <> nil) then
  begin
    M.EventType := ASse^.EventType;
    M.EventId := ASse^.Id;
    M.Sse := ASse;
  end;
  // outside every lock; the composite guards its members
  try
    FMessages.OnMessage(FToken, M);
  except
  end;
end;

procedure TAttemptTracker.ReadBegin;
begin
  InterlockedExchange(FInRead, 1);
end;

procedure TAttemptTracker.ReadEnd;
begin
  InterlockedExchange(FInRead, 0);
  TryFireHeld;
end;

procedure TAttemptTracker.Finish(const ABytesIn: Int64);
begin
  if InterlockedCompareExchange(FFired, 1, 0) = 0 then
    Dispatch(nil, False, ABytesIn, 0);
end;

procedure TAttemptTracker.FailHandshake(const AError: Exception);
begin
  if InterlockedCompareExchange(FFired, 1, 0) <> 0 then
    Exit;
  // a refusal carries the status the server answered; no response headers
  // are reported for it
  if AError is EHttpWebSocketHandshakeError then
    FStatus := EHttpWebSocketHandshakeError(AError).StatusCode;
  FWsClosedBy := ciError;
  Dispatch(AError, False, 0, 0);
end;

function TAttemptTracker.HandshakeHeaders: TArray<TWsHeaderField>;
begin
  if FSink <> nil then
    Result := FSink.Fields
  else
    Result := nil;
end;

procedure TAttemptTracker.HandshakeWritten;
begin
  RequestWritten(0);
end;

procedure TAttemptTracker.HandshakeAccepted(const AStatus: Integer;
  const AFields: TArray<TWsHeaderField>; const ASubprotocol: string);
var
  Headers: IHttpHeaders;
  I: Integer;
begin
  FSubprotocol := ASubprotocol;
  Headers := NewHttpHeaders;
  for I := 0 to High(AFields) do
    try
      Headers.Add(AFields[I].Name, AFields[I].Value);
    except
      // a connection-specific name the header map refuses stays off it
    end;
  GotResponse(THttp1Response.Create('HTTP/1.1', AStatus, 'Switching Protocols',
    Headers, nil));
end;

procedure TAttemptTracker.SessionEnded(const AEnd: TWsSessionEnd);
begin
  if InterlockedCompareExchange(FFired, 1, 0) <> 0 then
    Exit;
  FWsClosedBy := AEnd.ClosedBy;
  FWsCloseCode := AEnd.CloseCode;
  FWsCloseReason := AEnd.CloseReason;
  Dispatch(AEnd.Error, AEnd.Abandoned, AEnd.BytesIn, AEnd.BytesOut);
end;

end.
