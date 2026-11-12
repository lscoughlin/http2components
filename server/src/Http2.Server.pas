{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, facade
notes:
  - This unit is the public facade of the HTTP/2 server library.
  - A caller adds only this unit to the uses clause.  Every public type of
    the library is visible through the aliases of this unit.
  - The facade holds no logic.  It re-exports the units that hold the
    server, the settings, the handler contract and the observation events.
---
}
/// Public facade of the HTTP/2 server library
// - this unit is the entry point of the library; a caller adds only this
//   unit to the uses clause
// - THttp2ServerFactory.Build answers a running-capable IHttp2Server
unit Http2.Server;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils,
  Http2.Server.Errors,
  Http2.Server.AccessLog,
  Http2.Common.Frames,
  Http2.Common.Hpack,
  Http2.Server.Duplex,
  Http2.Server.Limits,
  Http2.Server.Http1.Limits,
  Http2.Server.Observer,
  Http2.Server.Seam,
  Http2.Server.Mtls.Types,
  Http2.Server.ClientCert,
  Http2.Server.Config,
  Http2.Server.Config.Limits,
  Http2.Server.Config.Socket,
  Http2.Server.Config.Unix,
  Http2.Server.Encoding,
  Http2.Server.Runtime,
  Http2.Server.Sse.Encoder,
  Http2.Server.Sse,
  Http2.Server.WebSocket.Origin,
  Http2.Server.WebSocket.Options,
  Http2.Server.WebSocket.Types,
  Http2.Server.WebSocket.Frames,
  Http2.Server.WebSocket.Accept;

type
  /// the server lifecycle
  IHttp2Server = Http2.Server.Runtime.IHttp2Server;
  /// the server that runs on the async IO pool
  THttp2Server = Http2.Server.Runtime.THttp2Server;

  /// the server factory and its option records
  THttp2ServerFactory = Http2.Server.Config.THttp2ServerFactory;
  TQueueOptions = Http2.Server.Config.TQueueOptions;
  TQueueRefusalMode = Http2.Server.Config.TQueueRefusalMode;
  TServerLimits = Http2.Server.Config.Limits.TServerLimits;
  TSocketOptions = Http2.Server.Config.Socket.TSocketOptions;
  TUnixSocketOptions = Http2.Server.Config.Unix.TUnixSocketOptions;
  TTokenBucketOptions = Http2.Server.Limits.TTokenBucketOptions;

  /// mutual TLS: the modes, the principal setting and the client identity
  TClientCertPrincipal = Http2.Server.Mtls.Types.TClientCertPrincipal;
  IClientCertificate = Http2.Server.ClientCert.IClientCertificate;

  /// the handler contract
  IHttp2Handler = Http2.Server.Seam.IHttp2Handler;
  IServerRequest = Http2.Server.Seam.IServerRequest;
  IServerResponse = Http2.Server.Seam.IServerResponse;
  IBodyWriter = Http2.Server.Seam.IBodyWriter;
  IStreamWaiter = Http2.Server.Seam.IStreamWaiter;
  TCancelHook = Http2.Server.Seam.TCancelHook;
  TWaitResult = Http2.Server.Seam.TWaitResult;

  /// the access log: the record, the writer contract and the default writer
  TAccessLogRecord = Http2.Server.AccessLog.TAccessLogRecord;
  IAccessLogWriter = Http2.Server.AccessLog.IAccessLogWriter;
  TStdOutAccessLogWriter = Http2.Server.AccessLog.TStdOutAccessLogWriter;

  /// the detached stream: bytes in both directions without a handler thread
  IDuplexChannel = Http2.Server.Duplex.IDuplexChannel;
  IChannelSink = Http2.Server.Duplex.IChannelSink;
  TSendResult = Http2.Server.Duplex.TSendResult;
  TChannelClose = Http2.Server.Duplex.TChannelClose;
  TChannelState = Http2.Server.Duplex.TChannelState;
  EDetachRefused = Http2.Server.Duplex.EDetachRefused;

  /// WebSocket: the settings, the origin policy, the session and the handler
  TWsOptions = Http2.Server.WebSocket.Options.TWsOptions;
  TWsOriginPolicy = Http2.Server.WebSocket.Origin.TWsOriginPolicy;
  IWsSession = Http2.Server.WebSocket.Types.IWsSession;
  IWsHandler = Http2.Server.WebSocket.Types.IWsHandler;
  TWsInitResult = Http2.Server.WebSocket.Types.TWsInitResult;

  /// server-sent events
  ISseStream = Http2.Server.Sse.ISseStream;
  TSseEvent = Http2.Server.Sse.Encoder.TSseEvent;
  ESseError = Http2.Server.Sse.Encoder.ESseError;

  /// the observation contract and the counters
  IHttp2ServerObserver = Http2.Server.Observer.IHttp2ServerObserver;
  TNullServerObserver = Http2.Server.Observer.TNullServerObserver;
  TServerEvent = Http2.Server.Observer.TServerEvent;
  TServerEventKind = Http2.Server.Observer.TServerEventKind;
  TServerStats = Http2.Server.Observer.TServerStats;

  /// the settings of the HTTP/1.1 parser, the clock and the limit kinds
  THttp11Limits = Http2.Server.Http1.Limits.THttp11Limits;
  IMonotonicClock = Http2.Server.Limits.IMonotonicClock;
  TLimitKind = Http2.Server.Limits.TLimitKind;

  /// the error classes and the error codes
  EHttpError = Http2.Server.Errors.EHttpError;
  EHttpTimeout = Http2.Server.Errors.EHttpTimeout;
  EHttpConnectionError = Http2.Server.Errors.EHttpConnectionError;
  EStreamCancelled = Http2.Server.Errors.EStreamCancelled;
  EStreamReset = Http2.Server.Errors.EStreamReset;
  EServerConfigError = Http2.Server.Errors.EServerConfigError;
  EServerStopped = Http2.Server.Errors.EServerStopped;
  THttp2ErrorCode = Http2.Server.Errors.THttp2ErrorCode;

  /// the header list of a request and a response
  THeaderBlock = Http2.Common.Hpack.THeaderBlock;
  THttpHeaderField = Http2.Common.Hpack.THttpHeaderField;
  THpackCodec = Http2.Common.Hpack.THpackCodec;

  /// the content codings a handler can put on a response body
  ///
  /// A handler reads `accept-encoding` from the request, negotiates a coding,
  /// and either writes the coded bytes itself or hands a
  /// TCompressingBodyWriter to IServerResponse.SetBodyWriter.
  TContentEncoding = Http2.Server.Encoding.TContentEncoding;
  TCompressingBodyWriter = Http2.Server.Encoding.TCompressingBodyWriter;

  /// the entry point that turns a factory into a server
  ///
  /// Build validates the settings, then returns a server that the caller
  /// starts.  A problem in the settings raises EServerConfigError, and the
  /// message holds every problem, one per line.
  THttp2ServerFactoryHelper = type helper for THttp2ServerFactory
    function Build: IHttp2Server; overload;
    function Build(const AObserver: IHttp2ServerObserver): IHttp2Server; overload;
    /// the problems of the settings, one per line; '' when none
    function ProblemText: string;
  end;

const
  // the values of TQueueRefusalMode, for the same reason as the event kinds below
  rmRefuseStream = Http2.Server.Config.rmRefuseStream;
  rmHttp503 = Http2.Server.Config.rmHttp503;

  // the values of TLimitKind
  lkReset = Http2.Server.Limits.lkReset;
  lkPing = Http2.Server.Limits.lkPing;
  lkSettings = Http2.Server.Limits.lkSettings;
  lkEmptyData = Http2.Server.Limits.lkEmptyData;
  lkWindowUpdate = Http2.Server.Limits.lkWindowUpdate;
  lkContinuation = Http2.Server.Limits.lkContinuation;

  // the values of THttp2ErrorCode (RFC 9113 section 7)
  ecNoError = Http2.Server.Errors.ecNoError;
  ecProtocolError = Http2.Server.Errors.ecProtocolError;
  ecInternalError = Http2.Server.Errors.ecInternalError;
  ecFlowControlError = Http2.Server.Errors.ecFlowControlError;
  ecSettingsTimeout = Http2.Server.Errors.ecSettingsTimeout;
  ecStreamClosed = Http2.Server.Errors.ecStreamClosed;
  ecFrameSizeError = Http2.Server.Errors.ecFrameSizeError;
  ecRefusedStream = Http2.Server.Errors.ecRefusedStream;
  ecCancel = Http2.Server.Errors.ecCancel;
  ecCompressionError = Http2.Server.Errors.ecCompressionError;
  ecConnectError = Http2.Server.Errors.ecConnectError;
  ecEnhanceYourCalm = Http2.Server.Errors.ecEnhanceYourCalm;
  ecInadequateSecurity = Http2.Server.Errors.ecInadequateSecurity;
  ecHttp11Required = Http2.Server.Errors.ecHttp11Required;

  // the values of TClientCertPrincipal
  ccpNone = Http2.Server.Mtls.Types.ccpNone;
  ccpSubjectDn = Http2.Server.Mtls.Types.ccpSubjectDn;
  ccpCommonName = Http2.Server.Mtls.Types.ccpCommonName;

  // an enum type alias does not carry the enum values, so every value of
  // TServerEventKind appears here as a constant
  seConnectionAccepted = Http2.Server.Observer.seConnectionAccepted;
  seTlsHandshakeFailed = Http2.Server.Observer.seTlsHandshakeFailed;
  seConnectionClosed = Http2.Server.Observer.seConnectionClosed;
  seStreamOpened = Http2.Server.Observer.seStreamOpened;
  seStreamRefused = Http2.Server.Observer.seStreamRefused;
  seStreamReset = Http2.Server.Observer.seStreamReset;
  seStreamCompleted = Http2.Server.Observer.seStreamCompleted;
  seQueueFull = Http2.Server.Observer.seQueueFull;
  seRequestTimedOut = Http2.Server.Observer.seRequestTimedOut;
  seBucketTripped = Http2.Server.Observer.seBucketTripped;
  seGoAwaySent = Http2.Server.Observer.seGoAwaySent;
  seHandlerException = Http2.Server.Observer.seHandlerException;
  seStreamDetached = Http2.Server.Observer.seStreamDetached;
  seStreamDetachRefused = Http2.Server.Observer.seStreamDetachRefused;

  /// the origin policies
  opSameOrAbsent = Http2.Server.WebSocket.Origin.opSameOrAbsent;
  opAllowList = Http2.Server.WebSocket.Origin.opAllowList;
  opAllowListOnly = Http2.Server.WebSocket.Origin.opAllowListOnly;
  opAny = Http2.Server.WebSocket.Origin.opAny;
  opNone = Http2.Server.WebSocket.Origin.opNone;

  /// the observer events of WebSocket
  seWsOpened = Http2.Server.Observer.seWsOpened;
  seWsRejected = Http2.Server.Observer.seWsRejected;
  seWsClosed = Http2.Server.Observer.seWsClosed;
  seWsFailed = Http2.Server.Observer.seWsFailed;
  seWsBucketTripped = Http2.Server.Observer.seWsBucketTripped;

  /// the close codes of RFC 6455 section 7.4.1 that a server sends
  WsCloseNormal = Http2.Server.WebSocket.Frames.WsCloseNormal;
  WsCloseGoingAway = Http2.Server.WebSocket.Frames.WsCloseGoingAway;
  WsCloseProtocolError = Http2.Server.WebSocket.Frames.WsCloseProtocolError;
  WsCloseUnsupported = Http2.Server.WebSocket.Frames.WsCloseUnsupported;
  WsCloseBadData = Http2.Server.WebSocket.Frames.WsCloseBadData;
  WsClosePolicy = Http2.Server.WebSocket.Frames.WsClosePolicy;
  WsCloseTooBig = Http2.Server.WebSocket.Frames.WsCloseTooBig;
  WsCloseInternal = Http2.Server.WebSocket.Frames.WsCloseInternal;

  /// the constants of the channel types
  srQueued = Http2.Server.Duplex.srQueued;
  srFull = Http2.Server.Duplex.srFull;
  srClosed = Http2.Server.Duplex.srClosed;
  ccGraceful = Http2.Server.Duplex.ccGraceful;
  ccAbort = Http2.Server.Duplex.ccAbort;
  csPending = Http2.Server.Duplex.csPending;
  csActive = Http2.Server.Duplex.csActive;
  csClosed = Http2.Server.Duplex.csClosed;

/// accept the WebSocket upgrade of this request and serve it with AHandler
/// - true: the session started and the handler returns; IWsHandler.Init decides
/// - false: an error response was sent; the handler returns
function AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AHandler: IWsHandler): Boolean;

/// answer a request with an event stream and detach it
/// - see Http2.Server.Sse.StartSse
function StartSse(const ARequest: IServerRequest;
  const AResponse: IServerResponse;
  const AExtraHeaders: THeaderBlock = nil): ISseStream;

/// the coding to answer a request with, given its `accept-encoding` value
/// - an absent or empty value yields ceIdentity, so a peer that offered no
///   coding is never sent one
function NegotiateEncoding(const AAcceptEncoding: string): TContentEncoding;

/// the token to put in `content-encoding` for ACoding ('' for identity)
function EncodingToken(const ACoding: TContentEncoding): string;

/// true when the coding codes the body rather than passing it through
function IsEncoded(const ACoding: TContentEncoding): Boolean;

/// compact AData for ACoding, or return AData when the coding is identity
function CompressFor(const ACoding: TContentEncoding;
  const AData: TBytes): TBytes;

/// the Apache Common Log Format line of a record
// - see Http2.Server.AccessLog.FormatCommonLog
function FormatCommonLog(const ARecord: TAccessLogRecord): string;

/// the user name of a Basic `authorization` header, or '' when none
// - see Http2.Server.AccessLog.BasicAuthUser
function BasicAuthUser(const AHeaders: THeaderBlock): string;

/// the first value of AName in AHeaders, or '' when the name is absent
///
/// Header names are compared without case, as RFC 9113 section 8.2 requires.
/// A handler uses this to read `accept-encoding` from a request.
function HeaderValueOf(const AHeaders: THeaderBlock;
  const AName: string): string;

/// compress AData into a gzip container
function GzipCompress(const AData: TBytes): TBytes;
/// compress AData into a zlib container
function DeflateCompress(const AData: TBytes): TBytes;
/// decompress a gzip container
function GzipDecompress(const AData: TBytes): TBytes;
/// decompress a deflate body, zlib-wrapped or bare
function DeflateDecompress(const AData: TBytes): TBytes;

implementation

function AcceptWebSocket(const ARequest: IServerRequest;
  const AResponse: IServerResponse; const AHandler: IWsHandler): Boolean;
begin
  Result := Http2.Server.WebSocket.Accept.AcceptWebSocket(ARequest, AResponse, AHandler);
end;

function StartSse(const ARequest: IServerRequest;
  const AResponse: IServerResponse;
  const AExtraHeaders: THeaderBlock): ISseStream;
begin
  Result := Http2.Server.Sse.StartSse(ARequest, AResponse, AExtraHeaders);
end;

{ THttp2ServerFactoryHelper }

function THttp2ServerFactoryHelper.ProblemText: string;
var
  Problems: TArray<string>;
  I: Integer;
begin
  Result := '';
  if Self.Validate(Problems) then
    Exit;
  for I := 0 to High(Problems) do
  begin
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + Problems[I];
  end;
end;

function THttp2ServerFactoryHelper.Build: IHttp2Server;
begin
  Result := Build(nil);
end;

function THttp2ServerFactoryHelper.Build(
  const AObserver: IHttp2ServerObserver): IHttp2Server;
var
  Text: string;
  Settings: THttp2ServerFactory;
begin
  Text := ProblemText;
  if Text <> '' then
    raise EServerConfigError.Create('the server settings are not valid:' +
      LineEnding + Text);
  Settings := Self;
  Result := THttp2Server.Create(Settings, AObserver);
end;

function NegotiateEncoding(const AAcceptEncoding: string): TContentEncoding;
begin
  Result := Http2.Server.Encoding.NegotiateEncoding(AAcceptEncoding);
end;

function EncodingToken(const ACoding: TContentEncoding): string;
begin
  Result := Http2.Server.Encoding.EncodingToken(ACoding);
end;

function IsEncoded(const ACoding: TContentEncoding): Boolean;
begin
  Result := Http2.Server.Encoding.IsEncoded(ACoding);
end;

function CompressFor(const ACoding: TContentEncoding;
  const AData: TBytes): TBytes;
begin
  Result := Http2.Server.Encoding.CompressFor(ACoding, AData);
end;

function FormatCommonLog(const ARecord: TAccessLogRecord): string;
begin
  Result := Http2.Server.AccessLog.FormatCommonLog(ARecord);
end;

function BasicAuthUser(const AHeaders: THeaderBlock): string;
begin
  Result := Http2.Server.AccessLog.BasicAuthUser(AHeaders);
end;

function HeaderValueOf(const AHeaders: THeaderBlock;
  const AName: string): string;
begin
  Result := Http2.Server.Encoding.HeaderValueOf(AHeaders, AName);
end;

function GzipCompress(const AData: TBytes): TBytes;
begin
  Result := Http2.Server.Encoding.GzipCompress(AData);
end;

function DeflateCompress(const AData: TBytes): TBytes;
begin
  Result := Http2.Server.Encoding.DeflateCompress(AData);
end;

function GzipDecompress(const AData: TBytes): TBytes;
begin
  Result := Http2.Server.Encoding.GzipDecompress(AData);
end;

function DeflateDecompress(const AData: TBytes): TBytes;
begin
  Result := Http2.Server.Encoding.DeflateDecompress(AData);
end;

end.
