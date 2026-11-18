{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, facade
notes:
  - This unit exposes shared protocol types and helpers.
---
}
unit Http2.Common;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes,
  Http2.Common.Errors, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Common.Frames, Http2.Common.FlowControl,
  Http2.Common.Tls.Types, Http2.Common.Tls.Identity,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session,
  Http2.Common.Tls.Context;

const
  ecNoError = Http2.Common.Errors.ecNoError;
  ecProtocolError = Http2.Common.Errors.ecProtocolError;
  ecInternalError = Http2.Common.Errors.ecInternalError;
  ecFlowControlError = Http2.Common.Errors.ecFlowControlError;
  ecSettingsTimeout = Http2.Common.Errors.ecSettingsTimeout;
  ecStreamClosed = Http2.Common.Errors.ecStreamClosed;
  ecFrameSizeError = Http2.Common.Errors.ecFrameSizeError;
  ecRefusedStream = Http2.Common.Errors.ecRefusedStream;
  ecCancel = Http2.Common.Errors.ecCancel;
  ecCompressionError = Http2.Common.Errors.ecCompressionError;
  ecConnectError = Http2.Common.Errors.ecConnectError;
  ecEnhanceYourCalm = Http2.Common.Errors.ecEnhanceYourCalm;
  ecInadequateSecurity = Http2.Common.Errors.ecInadequateSecurity;
  ecHttp11Required = Http2.Common.Errors.ecHttp11Required;
  HeaderMethod = Http2.Common.Headers.HeaderMethod;
  HeaderPath = Http2.Common.Headers.HeaderPath;
  HeaderScheme = Http2.Common.Headers.HeaderScheme;
  HeaderAuthority = Http2.Common.Headers.HeaderAuthority;
  HeaderStatus = Http2.Common.Headers.HeaderStatus;
  HeaderContentType = Http2.Common.Headers.HeaderContentType;
  HeaderContentLength = Http2.Common.Headers.HeaderContentLength;
  HeaderContentEncoding = Http2.Common.Headers.HeaderContentEncoding;
  HeaderAccept = Http2.Common.Headers.HeaderAccept;
  HeaderAcceptEncoding = Http2.Common.Headers.HeaderAcceptEncoding;
  HeaderUserAgent = Http2.Common.Headers.HeaderUserAgent;
  HeaderAuthorization = Http2.Common.Headers.HeaderAuthorization;
  HeaderCookie = Http2.Common.Headers.HeaderCookie;
  HeaderSetCookie = Http2.Common.Headers.HeaderSetCookie;
  HeaderCacheControl = Http2.Common.Headers.HeaderCacheControl;
  HeaderLocation = Http2.Common.Headers.HeaderLocation;
  HeaderHost = Http2.Common.Headers.HeaderHost;
  HeaderTe = Http2.Common.Headers.HeaderTe;
  HeaderLastEventId = Http2.Common.Headers.HeaderLastEventId;
  HeaderAcceptLanguage = Http2.Common.Headers.HeaderAcceptLanguage;
  HeaderAcceptRanges = Http2.Common.Headers.HeaderAcceptRanges;
  HeaderAllow = Http2.Common.Headers.HeaderAllow;
  HeaderConnection = Http2.Common.Headers.HeaderConnection;
  HeaderContentDisposition = Http2.Common.Headers.HeaderContentDisposition;
  HeaderContentLanguage = Http2.Common.Headers.HeaderContentLanguage;
  HeaderContentRange = Http2.Common.Headers.HeaderContentRange;
  HeaderDate = Http2.Common.Headers.HeaderDate;
  HeaderEtag = Http2.Common.Headers.HeaderEtag;
  HeaderExpect = Http2.Common.Headers.HeaderExpect;
  HeaderIfMatch = Http2.Common.Headers.HeaderIfMatch;
  HeaderIfModifiedSince = Http2.Common.Headers.HeaderIfModifiedSince;
  HeaderIfNoneMatch = Http2.Common.Headers.HeaderIfNoneMatch;
  HeaderIfRange = Http2.Common.Headers.HeaderIfRange;
  HeaderIfUnmodifiedSince = Http2.Common.Headers.HeaderIfUnmodifiedSince;
  HeaderLastModified = Http2.Common.Headers.HeaderLastModified;
  HeaderOrigin = Http2.Common.Headers.HeaderOrigin;
  HeaderRange = Http2.Common.Headers.HeaderRange;
  HeaderReferer = Http2.Common.Headers.HeaderReferer;
  HeaderRetryAfter = Http2.Common.Headers.HeaderRetryAfter;
  HeaderServer = Http2.Common.Headers.HeaderServer;
  HeaderTransferEncoding = Http2.Common.Headers.HeaderTransferEncoding;
  HeaderUpgrade = Http2.Common.Headers.HeaderUpgrade;
  HeaderVary = Http2.Common.Headers.HeaderVary;
  HeaderSecWebSocketAccept = Http2.Common.Headers.HeaderSecWebSocketAccept;
  HeaderSecWebSocketExtensions = Http2.Common.Headers.HeaderSecWebSocketExtensions;
  HeaderSecWebSocketKey = Http2.Common.Headers.HeaderSecWebSocketKey;
  HeaderSecWebSocketProtocol = Http2.Common.Headers.HeaderSecWebSocketProtocol;
  HeaderSecWebSocketVersion = Http2.Common.Headers.HeaderSecWebSocketVersion;
  FrameHeaderSize = Http2.Common.Frames.FrameHeaderSize;
  ClientPrefaceSize = Http2.Common.Frames.ClientPrefaceSize;
  ClientPreface: array[0..ClientPrefaceSize - 1] of Byte = (
    $50, $52, $49, $20, $2A, $20, $48, $54, $54, $50, $2F, $32,
    $2E, $30, $0D, $0A, $0D, $0A, $53, $4D, $0D, $0A, $0D, $0A);
  SettingsEntrySize = Http2.Common.Frames.SettingsEntrySize;
  DefaultMaxFrameSize = Http2.Common.Frames.DefaultMaxFrameSize;
  MinAllowedFrameSize = Http2.Common.Frames.MinAllowedFrameSize;
  MaxAllowedFrameSize = Http2.Common.Frames.MaxAllowedFrameSize;
  MaxStreamId = Http2.Common.Frames.MaxStreamId;
  SettingHeaderTableSize = Http2.Common.Frames.SettingHeaderTableSize;
  SettingEnablePush = Http2.Common.Frames.SettingEnablePush;
  SettingMaxConcurrentStreams = Http2.Common.Frames.SettingMaxConcurrentStreams;
  SettingInitialWindowSize = Http2.Common.Frames.SettingInitialWindowSize;
  SettingMaxFrameSize = Http2.Common.Frames.SettingMaxFrameSize;
  SettingMaxHeaderListSize = Http2.Common.Frames.SettingMaxHeaderListSize;
  SettingEnableConnectProtocol = Http2.Common.Frames.SettingEnableConnectProtocol;
  ftData = Http2.Common.Frames.ftData;
  ftHeaders = Http2.Common.Frames.ftHeaders;
  ftPriority = Http2.Common.Frames.ftPriority;
  ftRstStream = Http2.Common.Frames.ftRstStream;
  ftSettings = Http2.Common.Frames.ftSettings;
  ftPushPromise = Http2.Common.Frames.ftPushPromise;
  ftPing = Http2.Common.Frames.ftPing;
  ftGoAway = Http2.Common.Frames.ftGoAway;
  ftWindowUpdate = Http2.Common.Frames.ftWindowUpdate;
  ftContinuation = Http2.Common.Frames.ftContinuation;
  ffEndStream = Http2.Common.Frames.ffEndStream;
  ffEndHeaders = Http2.Common.Frames.ffEndHeaders;
  ffAck = Http2.Common.Frames.ffAck;
  ffPadded = Http2.Common.Frames.ffPadded;
  ffPriority = Http2.Common.Frames.ffPriority;
  MaxWindowSize = Http2.Common.FlowControl.MaxWindowSize;
  DefaultWindowSize = Http2.Common.FlowControl.DefaultWindowSize;
  tls12 = Http2.Common.Tls.Types.tls12;
  tls13 = Http2.Common.Tls.Types.tls13;
  trClient = Http2.Common.Tls.Types.trClient;
  trServer = Http2.Common.Tls.Types.trServer;
  tlsAuthNone = Http2.Common.Tls.Types.tlsAuthNone;
  tlsAuthRequest = Http2.Common.Tls.Types.tlsAuthRequest;
  tlsAuthRequire = Http2.Common.Tls.Types.tlsAuthRequire;
  tssNew = Http2.Common.Tls.Types.tssNew;
  tssHandshaking = Http2.Common.Tls.Types.tssHandshaking;
  tssOpen = Http2.Common.Tls.Types.tssOpen;
  tssClosing = Http2.Common.Tls.Types.tssClosing;
  tssClosed = Http2.Common.Tls.Types.tssClosed;
  tssFailed = Http2.Common.Tls.Types.tssFailed;
  tecConfiguration = Http2.Common.Tls.Types.tecConfiguration;
  tecVerification = Http2.Common.Tls.Types.tecVerification;
  tecProtocol = Http2.Common.Tls.Types.tecProtocol;
  tecTransportEof = Http2.Common.Tls.Types.tecTransportEof;
  tecTimeout = Http2.Common.Tls.Types.tecTimeout;
  tecAlert = Http2.Common.Tls.Types.tecAlert;
  tecInternal = Http2.Common.Tls.Types.tecInternal;
  tisUseDefault = Http2.Common.Tls.Policy.tisUseDefault;
  tisExplicit = Http2.Common.Tls.Policy.tisExplicit;
  TlsMaxEncryptedInput = Http2.Common.Tls.Types.TlsMaxEncryptedInput;
  TlsMaxEncryptedOutput = Http2.Common.Tls.Types.TlsMaxEncryptedOutput;
  TlsMaxPlaintextBuffer = Http2.Common.Tls.Types.TlsMaxPlaintextBuffer;

type
  THttp2ErrorCode = Http2.Common.Errors.THttp2ErrorCode;
  EHttpError = Http2.Common.Errors.EHttpError;
  EHttpConnectionError = Http2.Common.Errors.EHttpConnectionError;
  EHttpProtocolError = Http2.Common.Errors.EHttpProtocolError;
  EHttpStreamError = Http2.Common.Errors.EHttpStreamError;
  EHttpTimeout = Http2.Common.Errors.EHttpTimeout;
  EHttpConnectionClosed = Http2.Common.Errors.EHttpConnectionClosed;
  IHttpHeaders = Http2.Common.Headers.IHttpHeaders;
  THttpHeaderField = Http2.Common.Hpack.THttpHeaderField;
  THeaderBlock = Http2.Common.Hpack.THeaderBlock;
  THpackTableState = Http2.Common.Hpack.THpackTableState;
  THpackCodec = Http2.Common.Hpack.THpackCodec;
  TFrameType = Http2.Common.Frames.TFrameType;
  TFrameFlag = Http2.Common.Frames.TFrameFlag;
  TFrameFlags = Http2.Common.Frames.TFrameFlags;
  TFrameHeader = Http2.Common.Frames.TFrameHeader;
  TFrame = Http2.Common.Frames.TFrame;
  TConnectionSettings = Http2.Common.Frames.TConnectionSettings;
  TWindow = Http2.Common.FlowControl.TWindow;
  TFlowControl = Http2.Common.FlowControl.TFlowControl;
  TTlsVersion = Http2.Common.Tls.Types.TTlsVersion;
  TTlsRole = Http2.Common.Tls.Types.TTlsRole;
  TTlsRoles = Http2.Common.Tls.Types.TTlsRoles;
  TTlsClientAuthMode = Http2.Common.Tls.Types.TTlsClientAuthMode;
  TTlsCapabilities = Http2.Common.Tls.Types.TTlsCapabilities;
  TTlsClientPolicy = Http2.Common.Tls.Policy.TTlsClientPolicy;
  TTlsServerPolicy = Http2.Common.Tls.Policy.TTlsServerPolicy;
  TTlsContextInfo = Http2.Common.Tls.Types.TTlsContextInfo;
  TTlsCertificateSummary = Http2.Common.Tls.Identity.TTlsCertificateSummary;
  TTlsClientSessionOptions = Http2.Common.Tls.Policy.TTlsClientSessionOptions;
  TTlsServerSessionOptions = Http2.Common.Tls.Policy.TTlsServerSessionOptions;
  TTlsIdentitySelection = Http2.Common.Tls.Policy.TTlsIdentitySelection;
  TTlsProgress = Http2.Common.Tls.Session.TTlsProgress;
  TTlsSessionState = Http2.Common.Tls.Types.TTlsSessionState;
  TTlsNegotiatedInfo = Http2.Common.Tls.Session.TTlsNegotiatedInfo;
  ITLSIdentity = Http2.Common.Tls.Identity.ITLSIdentity;
  ITLSPeerCertificate = Http2.Common.Tls.Identity.ITLSPeerCertificate;
  ITLSSession = Http2.Common.Tls.Session.ITLSSession;
  ITLSContext = Http2.Common.Tls.Context.ITLSContext;
  ETlsContextError = Http2.Common.Tls.Types.ETlsContextError;
  ETlsSessionError = Http2.Common.Tls.Types.ETlsSessionError;

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;
function NewHttpHeaders: IHttpHeaders;
function NewTlsPeerCertificate(const AVerified: Boolean;
  const ALeaf: TTlsCertificateSummary; const AChain: array of TTlsCertificateSummary;
  const ADns, AIp, AUri, AEmail: array of string): ITLSPeerCertificate;
function FrameFlagsToByte(const AFlags: TFrameFlags): Byte;
function FrameTypeName(const AFrameType: TFrameType): string;
function IsKnownFrameType(const AFrameType: TFrameType): Boolean;
function BuildDataFrame(const AStreamId: LongWord; const AData: TBytes;
  const AEndStream: Boolean): TFrame;
function BuildHeadersFrame(const AStreamId: LongWord; const AHeaderBlock: TBytes;
  const AEndHeaders, AEndStream: Boolean): TFrame;
function BuildContinuationFrame(const AStreamId: LongWord;
  const AHeaderBlock: TBytes; const AEndHeaders: Boolean): TFrame;
function BuildPriorityFrame(const AStreamId, ADependsOn, AWeight: LongWord;
  const AExclusive: Boolean): TFrame;
function BuildRstStreamFrame(const AStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode): TFrame;
function BuildSettingsFrame(const ASettings: TConnectionSettings): TFrame;
function BuildServerSettings(const ASettings: TConnectionSettings): TFrame;
function BuildSettingsAck: TFrame;
function CheckClientPreface(const ABuffer: TBytes): Boolean;
procedure ReadClientPreface(const AStream: TStream);
function BuildPingFrame(const AData: TBytes; const AAck: Boolean): TFrame;
function BuildGoAwayFrame(const ALastStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode; const ADebug: TBytes): TFrame;
function BuildWindowUpdateFrame(const AStreamId, AIncrement: LongWord): TFrame;
procedure ParseRstStream(const AFrame: TFrame; out AErrorCode: THttp2ErrorCode);
procedure ParseGoAway(const AFrame: TFrame; out ALastStreamId: LongWord;
  out AErrorCode: THttp2ErrorCode; out ADebug: TBytes);
function ParseWindowUpdate(const AFrame: TFrame): LongWord;
function ParsePing(const AFrame: TFrame): TBytes;
procedure ParsePriority(const AFrame: TFrame; out ADependsOn, AWeight: LongWord;
  out AExclusive: Boolean);
function HeaderPriorityDependsOn(const AFrame: TFrame): LongWord;
function HeaderBlockOffset(const AFrame: TFrame): Integer;
function ExtractHeaderBlock(const AFrame: TFrame): TBytes;
function ExtractDataPayload(const AFrame: TFrame): TBytes;
function ReadFrame(const AStream: TStream;
  const AMaxFrameSize: LongWord = DefaultMaxFrameSize): TFrame;
procedure WriteFrame(const AStream: TStream; const AFrame: TFrame);
procedure ValidateFrame(const AFrame: TFrame;
  const AMaxFrameSize: LongWord = DefaultMaxFrameSize);
function ShouldEmitWindowUpdate(const AConsumed, AWindowSize: LongWord;
  const AStreamEnded: Boolean): Boolean;

implementation

function Http2ErrorCodeName(const ACode: THttp2ErrorCode): string;
begin Result := Http2.Common.Errors.Http2ErrorCodeName(ACode); end;
function NewHttpHeaders: IHttpHeaders;
begin Result := Http2.Common.Headers.NewHttpHeaders; end;
function NewTlsPeerCertificate(const AVerified: Boolean;
  const ALeaf: TTlsCertificateSummary; const AChain: array of TTlsCertificateSummary;
  const ADns, AIp, AUri, AEmail: array of string): ITLSPeerCertificate;
begin
  Result := Http2.Common.Tls.Identity.NewTlsPeerCertificate(
    AVerified, ALeaf, AChain, ADns, AIp, AUri, AEmail);
end;
function FrameFlagsToByte(const AFlags: TFrameFlags): Byte;
begin Result := Http2.Common.Frames.FrameFlagsToByte(AFlags); end;
function FrameTypeName(const AFrameType: TFrameType): string;
begin Result := Http2.Common.Frames.FrameTypeName(AFrameType); end;
function IsKnownFrameType(const AFrameType: TFrameType): Boolean;
begin Result := Http2.Common.Frames.IsKnownFrameType(AFrameType); end;
function BuildDataFrame(const AStreamId: LongWord; const AData: TBytes;
  const AEndStream: Boolean): TFrame;
begin Result := Http2.Common.Frames.BuildDataFrame(AStreamId, AData, AEndStream); end;
function BuildHeadersFrame(const AStreamId: LongWord; const AHeaderBlock: TBytes;
  const AEndHeaders, AEndStream: Boolean): TFrame;
begin Result := Http2.Common.Frames.BuildHeadersFrame(AStreamId, AHeaderBlock, AEndHeaders, AEndStream); end;
function BuildContinuationFrame(const AStreamId: LongWord;
  const AHeaderBlock: TBytes; const AEndHeaders: Boolean): TFrame;
begin Result := Http2.Common.Frames.BuildContinuationFrame(AStreamId, AHeaderBlock, AEndHeaders); end;
function BuildPriorityFrame(const AStreamId, ADependsOn, AWeight: LongWord;
  const AExclusive: Boolean): TFrame;
begin Result := Http2.Common.Frames.BuildPriorityFrame(AStreamId, ADependsOn, AWeight, AExclusive); end;
function BuildRstStreamFrame(const AStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode): TFrame;
begin Result := Http2.Common.Frames.BuildRstStreamFrame(AStreamId, AErrorCode); end;
function BuildSettingsFrame(const ASettings: TConnectionSettings): TFrame;
begin Result := Http2.Common.Frames.BuildSettingsFrame(ASettings); end;
function BuildServerSettings(const ASettings: TConnectionSettings): TFrame;
begin Result := Http2.Common.Frames.BuildServerSettings(ASettings); end;
function BuildSettingsAck: TFrame;
begin Result := Http2.Common.Frames.BuildSettingsAck; end;
function CheckClientPreface(const ABuffer: TBytes): Boolean;
begin Result := Http2.Common.Frames.CheckClientPreface(ABuffer); end;
procedure ReadClientPreface(const AStream: TStream);
begin Http2.Common.Frames.ReadClientPreface(AStream); end;
function BuildPingFrame(const AData: TBytes; const AAck: Boolean): TFrame;
begin Result := Http2.Common.Frames.BuildPingFrame(AData, AAck); end;
function BuildGoAwayFrame(const ALastStreamId: LongWord;
  const AErrorCode: THttp2ErrorCode; const ADebug: TBytes): TFrame;
begin Result := Http2.Common.Frames.BuildGoAwayFrame(ALastStreamId, AErrorCode, ADebug); end;
function BuildWindowUpdateFrame(const AStreamId, AIncrement: LongWord): TFrame;
begin Result := Http2.Common.Frames.BuildWindowUpdateFrame(AStreamId, AIncrement); end;
procedure ParseRstStream(const AFrame: TFrame; out AErrorCode: THttp2ErrorCode);
begin Http2.Common.Frames.ParseRstStream(AFrame, AErrorCode); end;
procedure ParseGoAway(const AFrame: TFrame; out ALastStreamId: LongWord;
  out AErrorCode: THttp2ErrorCode; out ADebug: TBytes);
begin Http2.Common.Frames.ParseGoAway(AFrame, ALastStreamId, AErrorCode, ADebug); end;
function ParseWindowUpdate(const AFrame: TFrame): LongWord;
begin Result := Http2.Common.Frames.ParseWindowUpdate(AFrame); end;
function ParsePing(const AFrame: TFrame): TBytes;
begin Result := Http2.Common.Frames.ParsePing(AFrame); end;
procedure ParsePriority(const AFrame: TFrame; out ADependsOn, AWeight: LongWord;
  out AExclusive: Boolean);
begin Http2.Common.Frames.ParsePriority(AFrame, ADependsOn, AWeight, AExclusive); end;
function HeaderPriorityDependsOn(const AFrame: TFrame): LongWord;
begin Result := Http2.Common.Frames.HeaderPriorityDependsOn(AFrame); end;
function HeaderBlockOffset(const AFrame: TFrame): Integer;
begin Result := Http2.Common.Frames.HeaderBlockOffset(AFrame); end;
function ExtractHeaderBlock(const AFrame: TFrame): TBytes;
begin Result := Http2.Common.Frames.ExtractHeaderBlock(AFrame); end;
function ExtractDataPayload(const AFrame: TFrame): TBytes;
begin Result := Http2.Common.Frames.ExtractDataPayload(AFrame); end;
function ReadFrame(const AStream: TStream; const AMaxFrameSize: LongWord): TFrame;
begin Result := Http2.Common.Frames.ReadFrame(AStream, AMaxFrameSize); end;
procedure WriteFrame(const AStream: TStream; const AFrame: TFrame);
begin Http2.Common.Frames.WriteFrame(AStream, AFrame); end;
procedure ValidateFrame(const AFrame: TFrame; const AMaxFrameSize: LongWord);
begin Http2.Common.Frames.ValidateFrame(AFrame, AMaxFrameSize); end;
function ShouldEmitWindowUpdate(const AConsumed, AWindowSize: LongWord;
  const AStreamEnded: Boolean): Boolean;
begin Result := Http2.Common.FlowControl.ShouldEmitWindowUpdate(AConsumed, AWindowSize, AStreamEnded); end;

end.
