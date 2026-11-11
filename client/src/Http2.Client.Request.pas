{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Client.Request;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface


uses
  SysUtils,
  Http2.Client.Errors,
  Http2.Common.Headers,
  Http2.Client.Stream,
  Http2.Client.ClientCert,
  Http2.Client.RequestObserver,
  Http2.Client.Url;


type
  THttpRequest = record
  private
    FMethod: THttpMethod;
    FMethodOverride: string;   // extension verbs, uppercase token
    FUrl: string;
    FHeaders: IHttpHeaders;
    FBody: THttpBody;
    FBodyWriter: IBodyWriter;
    FCancelToken: ICancellationToken;
    FHeaderTimeoutMs: Integer; // per-request override; 0 = factory default
    FBodyReadTimeoutMs: Integer; // per-request body-read deadline
    FBodyReadTimeoutSet: Boolean;
    FContext: IInterface;      // opaque, handed back in THttpAttempt.Context
    FIdentity: IClientIdentity; // per-request origin identity, nil = none
    FAttemptKind: TAttemptKind;
    FStreamId: Int64;          // SSE reconnect loop id, 0 otherwise
    FReconnect: Integer;
    function GetMethodToken: string;
    function GetAuthority: string;
    function GetPath: string;
  public
    class function Create(const AMethod: THttpMethod;
      const AUrl: string): THttpRequest; static;
    function WithMethod(const AMethod: THttpMethod): THttpRequest;
    /// escape hatch for extension verbs; the token is validated and uppercased
    function WithMethodToken(const AToken: string): THttpRequest;
    function WithHeader(const AName, AValue: string): THttpRequest;
    /// offer a content coding for the response body
    /// - the header `accept-encoding` carries AValue (for example
    ///  'gzip, deflate'). A response that answers with one of those codings
    ///  is decoded transparently, so a reader sees plain bytes either way.
    ///  The client offers nothing by default, which keeps a response body
    ///  byte-for-byte what the peer sent.
    function WithAcceptEncoding(const AValue: string): THttpRequest;
    function WithBody(const ABody: THttpBody): THttpRequest;
    function WithBodyWriter(const AWriter: IBodyWriter): THttpRequest;
    /// attach a cancellation token; cancelling it resets the stream in flight
    function WithCancelToken(const AToken: ICancellationToken): THttpRequest;
    /// override the factory HeaderTimeoutMs for this request (0 = default)
    function WithTimeout(const AMs: Integer): THttpRequest;
    /// set the RESPONSE BODY read deadline for this request.
    /// - distinct from WithTimeout, which bounds the wait for response
    ///   headers. 0 here means "wait indefinitely", which a Server-Sent
    ///   Events stream needs because it is idle between events; an unset
    ///   request keeps the header timeout as its body deadline (historic
    ///   behaviour). Use this only for a stream you intend to read lazily.
    function WithSseReadTimeout(const AMs: Integer): THttpRequest;
    /// attach an opaque context object.  The library never inspects it: an
    /// IHttpClientObserver receives it in THttpAttempt.Context for every
    /// attempt (each redirect hop and retry), so an adapter can find its
    /// parent span without a thread-local.  Clone, WithUrl, DropBody and
    /// WithMethodToken keep it.
    function WithContext(const AContext: IInterface): THttpRequest;
    /// present AIdentity to the ORIGIN on the TLS connection this request
    /// uses (doc/design/mtls.md "Per-request identity"): it wins over the
    /// client's selector and fixed identity, works through every route, and
    /// never goes to a proxy.  A redirect to another origin drops it.  Send
    /// raises EHttpTlsConfigError before dialling when it has expired.  nil
    /// clears it.  Clone, WithUrl, DropBody and WithMethodToken keep it.
    function WithClientIdentity(const AIdentity: IClientIdentity): THttpRequest;
    /// mark what an observer sees as THttpAttempt.Kind (akRequest by default).
    /// SseRequest marks its request akSse.  Clone, WithUrl, DropBody and
    /// WithMethodToken keep it.
    function WithAttemptKind(const AKind: TAttemptKind): THttpRequest;
    /// stamp the identity of an SSE reconnect loop: AStreamId is shared by
    /// every connection of the loop and AReconnect counts them from 0.  They
    /// reach THttpAttempt.StreamId and Reconnect.  Kept like the context.
    function WithStream(const AStreamId: Int64;
      const AReconnect: Integer): THttpRequest;
    /// re-target the request at AUrl (used by the redirect loop)
    function WithUrl(const AUrl: string): THttpRequest;
    /// an independent copy, including a deep copy of the headers
    /// - THttpRequest is a value record but FHeaders is an INTERFACE, so a
    ///   plain assignment shares one mutable header map. Mutating a copy
    ///   through WithHeader would therefore also mutate the original. Clone
    ///   breaks that sharing; use it before adding headers to a request you
    ///   did not build yourself (TSseReconnectLoop echoes last-event-id onto
    ///   every reconnect and must not pollute the caller's request).
    function Clone: THttpRequest;
    /// drop any request body (used when a redirect rewrites the method)
    function DropBody: THttpRequest;
    /// bridge to the S08 wire record: pseudo-header mapping at encode time
    function ToStreamRequest: TStreamRequest;

    function Url: string;
    function Method: THttpMethod;
    function Headers: IHttpHeaders;
    function Body: THttpBody;
    function BodyWriter: IBodyWriter;
    /// the uppercase wire method token (:method)
    property MethodToken: string read GetMethodToken;
    /// host[:port] with the default port omitted (:authority)
    property Authority: string read GetAuthority;
    /// path + query, '/' when empty (:path)
    property Path: string read GetPath;
    /// the cancellation token (nil when none was supplied)
    property CancelToken: ICancellationToken read FCancelToken;
    /// the context set with WithContext (nil when none)
    property Context: IInterface read FContext;
    /// the origin identity set with WithClientIdentity (nil when none)
    property ClientIdentity: IClientIdentity read FIdentity;
    /// what an observer sees as THttpAttempt.Kind
    property AttemptKind: TAttemptKind read FAttemptKind;
    /// the SSE loop id and reconnect count (0 for any other request)
    property StreamId: Int64 read FStreamId;
    property Reconnect: Integer read FReconnect;
    /// this request's header timeout in ms; 0 means "use the factory default"
    property HeaderTimeoutMs: Integer read FHeaderTimeoutMs;
  end;

function WithTextBody(const ARequest: THttpRequest;
  const AText: string): THttpRequest;

implementation

const
  cTokenChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' +
                '0123456789!#$%&''*+-.^_`|~';

function HttpMethodTokenOf(const AMethod: THttpMethod): string;
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

function IsValidMethodToken(const AToken: string): Boolean;
var
  I: Integer;
begin
  if AToken = '' then
    Exit(False);
  for I := 1 to Length(AToken) do
    if Pos(AToken[I], cTokenChars) = 0 then
      Exit(False);
  Result := True;
end;

function WithTextBody(const ARequest: THttpRequest;
  const AText: string): THttpRequest;
var
  B: TBytes;
begin
  SetLength(B, Length(AText));
  if Length(B) > 0 then
    Move(AText[1], B[0], Length(B));
  Result := ARequest.WithBody(THttpBody.FromBytes(B));
  if (Result.Headers = nil) or (not Result.Headers.Contains(HeaderContentType)) then
    Result := Result.WithHeader(HeaderContentType, 'text/plain');
end;

class function THttpRequest.Create(const AMethod: THttpMethod;
  const AUrl: string): THttpRequest;
begin
  Result.FMethod := AMethod;
  Result.FMethodOverride := '';
  Result.FUrl := AUrl;
  Result.FHeaders := NewHttpHeaders;
  Result.FBody := Default(THttpBody);
  Result.FBodyWriter := nil;
  Result.FCancelToken := nil;
  Result.FBodyReadTimeoutMs := 0;
  Result.FBodyReadTimeoutSet := False;
  Result.FHeaderTimeoutMs := 0;
  Result.FContext := nil;
  Result.FIdentity := nil;
  Result.FAttemptKind := akRequest;
  Result.FStreamId := 0;
  Result.FReconnect := 0;
end;

function THttpRequest.GetMethodToken: string;
begin
  if FMethodOverride <> '' then
    Result := FMethodOverride
  else
    Result := HttpMethodTokenOf(FMethod);
end;

function THttpRequest.GetAuthority: string;
var
  Host, Path: string;
  Port: Word;
begin
  ParseHttpUrl(FUrl, Host, Port, Path);
  Host := BracketedHost(Host);
  if Port = DefaultPortForScheme(SchemeOfUrl(FUrl)) then
    Result := Host
  else
    Result := Host + ':' + IntToStr(Port);
end;

function THttpRequest.GetPath: string;
var
  Host: string;
  Port: Word;
begin
  ParseHttpUrl(FUrl, Host, Port, Result);
end;

function THttpRequest.WithMethod(const AMethod: THttpMethod): THttpRequest;
begin
  Result := Self;
  Result.FMethod := AMethod;
  Result.FMethodOverride := '';
end;

function THttpRequest.WithMethodToken(const AToken: string): THttpRequest;
begin
  if not IsValidMethodToken(AToken) then
    raise EHttpProtocolError.Create('invalid HTTP method token: ' + AToken,
      ecProtocolError);
  Result := Self;
  Result.FMethodOverride := UpperCase(AToken);
end;

function THttpRequest.WithHeader(const AName, AValue: string): THttpRequest;
begin
  Result := Self;
  if not Assigned(Result.FHeaders) then
    Result.FHeaders := NewHttpHeaders;
  Result.FHeaders.Add(AName, AValue);
end;

function THttpRequest.WithAcceptEncoding(const AValue: string): THttpRequest;
begin
  Result := WithHeader(HeaderAcceptEncoding, AValue);
end;

function THttpRequest.WithBody(const ABody: THttpBody): THttpRequest;
begin
  if FBodyWriter <> nil then
    raise EHttpError.Create(
      'a request body and a body writer are mutually exclusive',
      ecInternalError);
  Result := Self;
  Result.FBody := ABody;
end;

function THttpRequest.WithBodyWriter(const AWriter: IBodyWriter): THttpRequest;
begin
  if FBody.IsSet then
    raise EHttpError.Create(
      'a request body and a body writer are mutually exclusive',
      ecInternalError);
  Result := Self;
  Result.FBodyWriter := AWriter;
  Result.FBody := Default(THttpBody);
end;

function THttpRequest.WithCancelToken(
  const AToken: ICancellationToken): THttpRequest;
begin
  Result := Self;
  Result.FCancelToken := AToken;
end;

function THttpRequest.WithTimeout(const AMs: Integer): THttpRequest;
begin
  Result := Self;
  Result.FHeaderTimeoutMs := AMs;
end;

function THttpRequest.WithSseReadTimeout(const AMs: Integer): THttpRequest;
begin
  Result := Self;
  Result.FBodyReadTimeoutMs := AMs;
  Result.FBodyReadTimeoutSet := True;
end;

function THttpRequest.WithContext(const AContext: IInterface): THttpRequest;
begin
  Result := Self;
  Result.FContext := AContext;
end;

function THttpRequest.WithClientIdentity(
  const AIdentity: IClientIdentity): THttpRequest;
begin
  Result := Self;
  Result.FIdentity := AIdentity;
end;

function THttpRequest.WithAttemptKind(const AKind: TAttemptKind): THttpRequest;
begin
  Result := Self;
  Result.FAttemptKind := AKind;
end;

function THttpRequest.WithStream(const AStreamId: Int64;
  const AReconnect: Integer): THttpRequest;
begin
  Result := Self;
  Result.FStreamId := AStreamId;
  Result.FReconnect := AReconnect;
end;

function THttpRequest.WithUrl(const AUrl: string): THttpRequest;
begin
  Result := Self;
  Result.FUrl := AUrl;
end;

function THttpRequest.Clone: THttpRequest;
var
  Names, Vals: TArray<string>;
  I, J: Integer;
begin
  Result := Self;
  Result.FHeaders := NewHttpHeaders;
  if FHeaders <> nil then
  begin
    Names := FHeaders.Names;
    for I := 0 to High(Names) do
    begin
      Vals := FHeaders.GetValues(Names[I]);
      for J := 0 to High(Vals) do
        Result.FHeaders.Add(Names[I], Vals[J]);
    end;
  end;
end;

function THttpRequest.DropBody: THttpRequest;
begin
  Result := Self;
  Result.FBody := Default(THttpBody);
  Result.FBodyWriter := nil;
end;

function THttpRequest.ToStreamRequest: TStreamRequest;
var
  Names, Vals: TArray<string>;
  I, J: Integer;
begin
  Result := TStreamRequest.Create(GetMethodToken, GetAuthority);
  // the URL scheme drives transport selection and the codec (plan S13):
  // ':scheme' stays 'http'/'https' while a cleartext origin also picks the
  // cleartext policy path in the pool
  Result := Result.WithScheme(SchemeOfUrl(FUrl)).WithPath(GetPath);
  if FHeaders <> nil then
  begin
    Names := FHeaders.Names;
    for I := 0 to High(Names) do
    begin
      Vals := FHeaders.GetValues(Names[I]);
      for J := 0 to High(Vals) do
        Result := Result.WithHeader(Names[I], Vals[J]);
    end;
  end;
  if FBody.IsSet then
    Result := Result.WithBody(FBody);
  if FBodyWriter <> nil then
    Result := Result.WithBodyWriter(FBodyWriter);
  if FCancelToken <> nil then
    Result := Result.WithCancelToken(FCancelToken);
  if FBodyReadTimeoutSet then
    Result := Result.WithBodyReadTimeout(FBodyReadTimeoutMs);
end;

function THttpRequest.Url: string;
begin
  Result := FUrl;
end;

function THttpRequest.Method: THttpMethod;
begin
  Result := FMethod;
end;

function THttpRequest.Headers: IHttpHeaders;
begin
  Result := FHeaders;
end;

function THttpRequest.Body: THttpBody;
begin
  Result := FBody;
end;

function THttpRequest.BodyWriter: IBodyWriter;
begin
  Result := FBodyWriter;
end;

{ THttpClientFactory }

end.
