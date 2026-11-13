{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  TypInfo,
  BaseUnix,
  Sockets,
  DateUtils,
  Http2.Client.Errors,
  Http2.Client.ClientCert,
  Http2.Common.Frames,
  Http2.Common.Headers,
  Http2.Common.Hpack,
  Http2.Client.Tls,
  Http2.Client.Connection,
  Http2.Client.Stream,
  Http2.Client.Observer,
  Http2.Client.Messages,
  Http2.Client.Http1,
  Http2.Client.Encoding,
  Http2.Client.Proxy,
  Http2.Client.WebSocket,
  Http2.Client.Clock,
  Http2.Client.RequestObserver,
  Http2.Client.SocketFactory.Types,
  Http2.Client.SocketFactory,
  Http2.Client.Request,
  Http2.Client.Api,
  Http2.Client.Factory,
  Http2.Client.Pool.Types,
  Http2.Client.Response,
  Http2.Client.Pool.Http2,
  Http2.Client.Pool.Http1,
  Http2.Client.Pool,
  Http2.Client.Core,
  Http2.Client.BodyReader,
  Http2.Client.Url,
  Http2.Client.Upgrade,
  Http2.Client.Defaults;

const
  hmGet = Http2.Client.Stream.hmGet;
  hmHead = Http2.Client.Stream.hmHead;
  hmPost = Http2.Client.Stream.hmPost;
  hmPut = Http2.Client.Stream.hmPut;
  hmDelete = Http2.Client.Stream.hmDelete;
  hmConnect = Http2.Client.Stream.hmConnect;
  hmOptions = Http2.Client.Stream.hmOptions;
  hmTrace = Http2.Client.Stream.hmTrace;
  hmPatch = Http2.Client.Stream.hmPatch;
  ctReject = Http2.Client.Tls.ctReject;
  ctPriorKnowledge = Http2.Client.Tls.ctPriorKnowledge;
  ctUpgrade = Http2.Client.Tls.ctUpgrade;
  ctHttp1 = Http2.Client.Tls.ctHttp1;
  pkHttp = Http2.Client.Proxy.pkHttp;
  pkHttps = Http2.Client.Proxy.pkHttps;
  pkSocks5 = Http2.Client.Proxy.pkSocks5;
  cDefaultMaxConnectionsPerHost = Http2.Client.Defaults.cDefaultMaxConnectionsPerHost;
  cDefaultMaxTotalConnections = Http2.Client.Defaults.cDefaultMaxTotalConnections;
  cDefaultMaxStreamsPerConnection = Http2.Client.Defaults.cDefaultMaxStreamsPerConnection;
  cDefaultFollowRedirects = Http2.Client.Defaults.cDefaultFollowRedirects;
  cDefaultMaxRedirects = Http2.Client.Defaults.cDefaultMaxRedirects;
  cDefaultConnectTimeoutMs = Http2.Client.Defaults.cDefaultConnectTimeoutMs;
  cDefaultHeaderTimeoutMs = Http2.Client.Defaults.cDefaultHeaderTimeoutMs;
  cDefaultIdleTimeoutMs = Http2.Client.Defaults.cDefaultIdleTimeoutMs;
  cDefaultHttpsPort = Http2.Client.Defaults.cDefaultHttpsPort;
  cDefaultHttpPort = Http2.Client.Defaults.cDefaultHttpPort;
  cMaxTransparentRetries = Http2.Client.Defaults.cMaxTransparentRetries;
  cCancelPollSliceMs = Http2.Client.Defaults.cCancelPollSliceMs;
  cDefaultHttp1Fallback = Http2.Client.Defaults.cDefaultHttp1Fallback;
  cHttp1StreamLimit = Http2.Client.Defaults.cHttp1StreamLimit;

type
  // TClearTextPolicy and TNegotiatedProtocol come from Http2.Client.Messages.pas

  // Proxy types and kind values are also available through this facade.
  IProxy = Http2.Client.Proxy.IProxy;
  IProxySelector = Http2.Client.Proxy.IProxySelector;
  TProxy = Http2.Client.Proxy.TProxy;
  TProxyKind = Http2.Client.Proxy.TProxyKind;
  TEnvLookup = Http2.Client.Proxy.TEnvLookup;

  // the WebSocket types live in Http2.Client.WebSocket; re-exported so a caller that
  // only uses Http2.Client can name them and descend from TWebSocketListener
  IWebSocket = Http2.Client.WebSocket.IWebSocket;
  IWebSocketListener = Http2.Client.WebSocket.IWebSocketListener;
  IWebSocketRequest = Http2.Client.WebSocket.IWebSocketRequest;
  TWebSocketListener = Http2.Client.WebSocket.TWebSocketListener;
  TWebSocketRequest = Http2.Client.WebSocket.TWebSocketRequest;

  IHttp2SocketFactory = Http2.Client.SocketFactory.Types.IHttp2SocketFactory;
  TDefaultSocketFactory = Http2.Client.SocketFactory.TDefaultSocketFactory;
  THttpRequest = Http2.Client.Request.THttpRequest;
  IHttpClient = Http2.Client.Api.IHttpClient;
  THttpClientFactory = Http2.Client.Factory.THttpClientFactory;
  IPooledConnection = Http2.Client.Pool.Types.IPooledConnection;
  TGuardedBody = Http2.Client.Response.TGuardedBody;
  THttpResponse = Http2.Client.Response.THttpResponse;
  THttpConnection = Http2.Client.Pool.Http2.THttpConnection;
  TSingleReadSocket = Http2.Client.Pool.Http1.TSingleReadSocket;
  THttp1PooledConnection = Http2.Client.Pool.Http1.THttp1PooledConnection;
  TConnectionStats = Http2.Client.Pool.Types.TConnectionStats;
  TOriginStats = Http2.Client.Pool.Types.TOriginStats;
  TPoolStats = Http2.Client.Pool.Types.TPoolStats;
  TConnectionPool = Http2.Client.Pool.TConnectionPool;
  THttpClient = Http2.Client.Core.THttpClient;
  IHttpResponse = Http2.Client.Messages.IHttpResponse;
  IBodyWriter = Http2.Client.Stream.IBodyWriter;
  THttpBody = Http2.Client.Stream.THttpBody;
  THttpMethod = Http2.Client.Stream.THttpMethod;
  IHttpHeaders = Http2.Common.Headers.IHttpHeaders;
  THeaderBlock = Http2.Common.Hpack.THeaderBlock;
  ICancellationToken = Http2.Client.Stream.ICancellationToken;
  TCancellationToken = Http2.Client.Stream.TCancellationToken;
  TClearTextPolicy = Http2.Client.Tls.TClearTextPolicy;

  TResponseReader<T> = class(TInterfacedObject, IResponseReader<T>)
  public
    function Read(const AResponse: IHttpResponse): T; overload;
    /// read with a cap on the body bytes (see ReadAllBodyBytes); AMaxBytes
    /// <= 0 means no cap
    function Read(const AResponse: IHttpResponse;
      const AMaxBytes: Int64): T; overload;
    class procedure Read(const AResponse: IHttpResponse;
      out AValue: T); overload; static;
    class procedure Read(const AResponse: IHttpResponse;
      const AMaxBytes: Int64; out AValue: T); overload; static;
  end;

  PBytesValue = ^TBytes;

function WithTextBody(const ARequest: THttpRequest;
  const AText: string): THttpRequest;

/// read a whole response body as text (the body bytes copied verbatim; UTF-8
/// when the peer sends UTF-8, which is the HTTP/2 default for text)
function ReadText(const AResponse: IHttpResponse): string; overload;

/// read a response body as text with a cap on the body bytes: raises
/// EHttpResponseTooLarge past AMaxBytes (AMaxBytes <= 0 means no cap)
function ReadText(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): string; overload;

/// split a URL into host, port and path+query; default port is 443 (TLS)
procedure ParseHttpUrl(const AUrl: string; out AHost: string; out APort: Word;
  out APath: string);

/// the host as written in a host[:port] string: an IPv6 literal (ParseHttpUrl
/// returns it without brackets) gets its brackets back
function BracketedHost(const AHost: string): string;

/// origin key = host[:port] with the default port omitted (doc/design). A
/// non-https URL is prefixed with its scheme so an http redirect target cannot
/// share a pooled https connection (plan S10 task 10.4).
function OriginOfUrl(const AUrl: string): string;

/// lowercased scheme of AUrl ('https' when the URL carries none)
function SchemeOfUrl(const AUrl: string): string;

/// the default port for a scheme: 80 for http, 443 for anything else
function DefaultPortForScheme(const AScheme: string): Word;

/// resolve a redirect Location against the URL that produced it: absolute,
/// protocol-relative, root-relative or path-relative (plan S10 task 10.1)
function ResolveLocation(const ABaseUrl, ALocation: string): string;

/// read a response body to EOF into a byte array (used by TResponseReader<T>).
/// It has no cap: a caller that reads a body from a peer it does not trust
/// passes a cap to the overload below
function ReadAllBodyBytes(const ABody: IHttpBodyStream): TBytes; overload;

/// read a response body to EOF with a cap: raises EHttpResponseTooLarge as
/// soon as the total would pass AMaxBytes (AMaxBytes <= 0 means no cap)
function ReadAllBodyBytes(const ABody: IHttpBodyStream;
  const AMaxBytes: Int64): TBytes; overload;

/// base64url (RFC 4648 section 5) of AData: standard base64 with '+'->'-',
/// '/'->'_' and NO '=' padding
function Base64UrlEncode(const AData: TBytes): string;

/// the value of the h2c `HTTP2-Settings` header: the base64url (unpadded)
/// encoding of the client's initial SETTINGS wire payload
// (RFC 7540 section 3.2.1).  It is exactly the payload the connection preface
// sends, so the client never later emits a conflicting SETTINGS frame.
function Http2SettingsBase64Url: string;

/// build the raw bytes of the h2c Upgrade request: request line, Host, the
/// caller's headers, then Upgrade/Connection/HTTP2-Settings
// (doc/design/fallback.md "h2c upgrade procedure").  The Upgrade and
// Connection headers cannot travel through TStreamRequest.Headers (the shared
// header map forbids connection-specific fields), so they are written here.
function BuildH2cUpgradeRequest(const ARequest: TStreamRequest): TBytes;

/// read one CRLF/LF-terminated line byte by byte from AScope, never reading
/// past the terminator, so an h2c upgrade leaves any following HTTP/2 bytes in
/// the socket.  False when the stream ends before any byte arrives.
function ReadHeadLineBytewise(const ASock: IHttp2Socket;
  out ALine: string): Boolean;

{ ---- implementation ---- }

implementation

function WithTextBody(const ARequest: THttpRequest;
  const AText: string): THttpRequest;
begin
  Result := Http2.Client.Request.WithTextBody(ARequest, AText);
end;

procedure ParseHttpUrl(const AUrl: string; out AHost: string; out APort: Word;
  out APath: string);
begin
  Http2.Client.Url.ParseHttpUrl(AUrl, AHost, APort, APath);
end;

function SchemeOfUrl(const AUrl: string): string;
begin
  Result := Http2.Client.Url.SchemeOfUrl(AUrl);
end;

function DefaultPortForScheme(const AScheme: string): Word;
begin
  Result := Http2.Client.Url.DefaultPortForScheme(AScheme);
end;

function BracketedHost(const AHost: string): string;
begin
  Result := Http2.Client.Url.BracketedHost(AHost);
end;

function OriginOfUrl(const AUrl: string): string;
begin
  Result := Http2.Client.Url.OriginOfUrl(AUrl);
end;

function ResolveLocation(const ABaseUrl, ALocation: string): string;
begin
  Result := Http2.Client.Url.ResolveLocation(ABaseUrl, ALocation);
end;

function ReadAllBodyBytes(const ABody: IHttpBodyStream): TBytes;
begin
  Result := Http2.Client.BodyReader.ReadAllBodyBytes(ABody);
end;

function ReadAllBodyBytes(const ABody: IHttpBodyStream;
  const AMaxBytes: Int64): TBytes;
begin
  Result := Http2.Client.BodyReader.ReadAllBodyBytes(ABody, AMaxBytes);
end;

function ReadText(const AResponse: IHttpResponse): string;
begin
  Result := Http2.Client.BodyReader.ReadText(AResponse);
end;

function ReadText(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): string;
begin
  Result := Http2.Client.BodyReader.ReadText(AResponse, AMaxBytes);
end;

function Base64UrlEncode(const AData: TBytes): string;
begin
  Result := Http2.Client.Upgrade.Base64UrlEncode(AData);
end;

function Http2SettingsBase64Url: string;
begin
  Result := Http2.Client.Upgrade.Http2SettingsBase64Url;
end;

function BuildH2cUpgradeRequest(const ARequest: TStreamRequest): TBytes;
begin
  Result := Http2.Client.Upgrade.BuildH2cUpgradeRequest(ARequest);
end;

function ReadHeadLineBytewise(const ASock: IHttp2Socket;
  out ALine: string): Boolean;
begin
  Result := Http2.Client.Upgrade.ReadHeadLineBytewise(ASock, ALine);
end;

function TResponseReader<T>.Read(const AResponse: IHttpResponse): T;
begin
  Read(AResponse, 0, Result);
end;

function TResponseReader<T>.Read(const AResponse: IHttpResponse;
  const AMaxBytes: Int64): T;
begin
  Read(AResponse, AMaxBytes, Result);
end;

class procedure TResponseReader<T>.Read(const AResponse: IHttpResponse;
  out AValue: T);
begin
  Read(AResponse, 0, AValue);
end;

class procedure TResponseReader<T>.Read(const AResponse: IHttpResponse;
  const AMaxBytes: Int64; out AValue: T);
var
  Raw: TBytes;
  PI: PTypeInfo;
  S: AnsiString;
begin
  if AResponse = nil then
    raise EHttpProtocolError.Create('response is nil', ecInternalError);
  Raw := ReadAllBodyBytes(AResponse.Body, AMaxBytes);
  PI := TypeInfo(T);
  case PI^.Kind of
    tkAString:
      begin
        // string, AnsiString and UTF8String all report tkAString on FPC
        // 3.2.4, so this branch is the text reader for every string type.
        // The bytes are copied verbatim; no code-page conversion is applied.
        SetLength(S, Length(Raw));
        if Length(Raw) > 0 then
          Move(Raw[0], S[1], Length(Raw));
        PAnsiString(@AValue)^ := S;
      end;
    tkDynArray:
      PBytesValue(@AValue)^ := Raw;
  else
    if Length(Raw) < SizeOf(T) then
      raise EHttpProtocolError.Create(
        'response body is too short to decode the requested value',
        ecProtocolError);
    Move(Raw[0], AValue, SizeOf(T));
  end;
end;

end.
