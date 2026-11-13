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
/// HTTP/1.1 codec (plan S13 task 13.4; doc/design/fallback.md
/// "HTTP/1.1 codec" and "Errors").
// - this unit is deliberately small.  It is not a general HTTP/1.1 client: it
//   builds one request, writes it over an IHttp2Socket, and parses exactly one
//   response, including its body framing.  One connection carries one request
//   at a time (HTTP/1.1 has no multiplexing) and a response body must be
//   drained before the socket is reused.
// - the public surface mirrors the transport-neutral interfaces: the returned
//   IHttpResponse (Http2.Client.Messages) is the same object the HTTP/2 codec hands
//   back, so redirects/timeouts/observers work unchanged once the pool wires
//   this codec in (task 13.6 does that; this unit only compiles and is tested).
// - request bodies are TStreamRequest bodies: a fixed THttpBody becomes
//   Content-Length, an IBodyWriter is drained and sent chunked because its
//   length is not known in advance.
unit Http2.Client.Http1;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, Generics.Collections,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Http1.Body,
  Http2.Client.Tls.Types;

const
  /// ceiling for the whole response head (status line + all header fields),
  /// in bytes, before the empty line.  doc/design/fallback.md "Open items"
  /// leaves the value open; 64 KiB is generous for a small client that does
  /// not need to accept hostile peers and keeps the buffer bounded.
  cHttp1MaxHeaderBytes = 64 * 1024;
  /// one transport read fills at most this many bytes
  cHttp1ReadBufferSize = 16 * 1024;
  /// most 1xx interim responses (other than 101) read before the final one
  /// (RFC 9110 section 15.2).  A peer that sends more is refused.
  cHttp1MaxInterimResponses = 16;
  bfNone = Http2.Client.Http1.Body.bfNone;
  bfContentLength = Http2.Client.Http1.Body.bfContentLength;
  bfChunked = Http2.Client.Http1.Body.bfChunked;
  bfUntilClose = Http2.Client.Http1.Body.bfUntilClose;

type
  THttp1HeaderField = Http2.Client.Http1.Body.THttp1HeaderField;
  TBufferedReader = Http2.Client.Http1.Body.TBufferedReader;
  TBodyFraming = Http2.Client.Http1.Body.TBodyFraming;
  THttp1BodyStream = Http2.Client.Http1.Body.THttp1BodyStream;

  /// an HTTP/1.1 response (implements the transport-neutral IHttpResponse).
  /// Pseudo-headers do not exist in HTTP/1.1, so Headers carries every regular
  /// field except the connection-specific ones (Connection, Transfer-Encoding,
  /// Keep-Alive, Upgrade, Proxy-Connection), which are transport metadata.
  THttp1Response = class(TInterfacedObject, IHttpResponse, IAttemptProgress)
  private
    FVersion: string;
    FReason: string;
    FStatusCode: LongInt;
    FHeaders: IHttpHeaders;
    FBody: IHttpBodyStream;
    FStream: THttp1BodyStream;   // weak: FBody holds it
    FProgress: IAttemptProgress;
  public
    constructor Create(const AVersion: string; const AStatusCode: LongInt;
      const AReason: string; const AHeaders: IHttpHeaders;
      const ABody: IHttpBodyStream);
    destructor Destroy; override;
    /// let the response report an abandoned body when it is released
    procedure BindStream(const AStream: THttp1BodyStream);
    /// let a reader of the body report its messages to the attempt AExchange
    /// belongs to (nil leaves the null reporter)
    procedure BindProgress(const AExchange: IExchangeObserver);
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
    property Progress: IAttemptProgress read FProgress
      implements IAttemptProgress;
    property Version: string read FVersion;
    property Reason: string read FReason;
  end;

  /// drives exactly one HTTP/1.1 connection.  Send builds a request, writes it
  /// in full, parses the response head, and returns a response whose body is
  /// framed by content-length, chunked coding, or connection close.
  THttp1Connection = class
  private
    FSocket: IHttp2Socket;
    FReader: TBufferedReader;
    FTimeoutMs: Integer;
    FReusable: Boolean;
    FReuse: IReuseFlag;   // shared with the body streams of this connection
    FLastBody: IHttpBodyStream;
    FLastTrailers: IHttpHeaders;
    FRequestCount: Integer;
    // response head, split so an h2c upgrade can inspect the status line
    // before the socket switches protocol
    FBeginDone: Boolean;
    FStatusCode: LongInt;
    FReason: string;
    FVersion: string;
    FFields: TArray<THttp1HeaderField>;
    FHeaders: IHttpHeaders;
    FSendRequest: TStreamRequest;
    FSentBodyBytes: Int64;
    procedure WriteAll(const ABytes: TBytes);
    function GetReaderBuffered: Integer;
  public
    constructor Create(const ASocket: IHttp2Socket;
      const ATimeoutMs: Integer = cDefaultSocketTimeoutMs);
    destructor Destroy; override;
    /// send ARequest and parse one response.  Raises EHttpProtocolError when
    /// the previous response body was not drained first.
    function Send(const ARequest: TStreamRequest): IHttpResponse;
    /// write ARequest, then read ONLY the response status line, byte by byte,
    /// without reading past it.  After True the socket sits exactly at the
    /// start of the header fields; inspect StatusCode to decide whether the
    /// peer accepted an Upgrade.  Used by the h2c upgrade path.
    function BeginResponse(const ARequest: TStreamRequest): Boolean;
    /// parse the header fields and body framing that follow the status line
    /// already read by BeginResponse, and return the response
    function FinishResponse: IHttpResponse;
    /// the request ARequest was already written on this socket by someone else
    /// (the h2c upgrade probe) and AStatusLine is the status line it drew:
    /// take that exchange over and return its response, without writing the
    /// request again
    function ResumeResponse(const ARequest: TStreamRequest;
      const AStatusLine: string): IHttpResponse;
    /// hand the raw socket back to the caller without closing it, so it can
    /// be reused for another protocol.  PendingBytes must be 0 first.
    function Detach: IHttp2Socket;
    /// the status line read by BeginResponse
    property StatusCode: LongInt read FStatusCode;
    property Reason: string read FReason;
    /// bytes already buffered from the socket (>0 only after a read-ahead)
    property PendingBytes: Integer read GetReaderBuffered;
    /// true when the last response permits reusing this socket (HTTP/1.1
    /// default keep-alive and no "Connection: close"; read-to-close framing
    /// always forbids reuse)
    function Reusable: Boolean;
    /// true when input that belongs to no response is already waiting:
    /// buffered bytes, or a socket that reports readable through IPendingInput
    function HasUnreadInput: Boolean;
    procedure Close;
    /// trailers of the last chunked response, filled once its body is drained
    property LastTrailers: IHttpHeaders read FLastTrailers;
    property RequestCount: Integer read FRequestCount;
  end;

/// build the wire bytes of ARequest: request line, exactly one Host header,
/// the regular headers, a body framing header (content-length or chunked), and
/// the body itself.
function BuildHttp1Request(const ARequest: TStreamRequest): TBytes;

/// parse "HTTP/1.1 200 OK" into version, 3-digit status code and reason (the
/// reason may be empty).  A malformed status line raises EHttpProtocolError.
procedure ParseStatusLine(const ALine: string; out AVersion: string;
  out AStatusCode: Integer; out AReason: string);

/// parse "Name: value" field lines.  Repeated names are joined with ", " into
/// a single field, except set-cookie which stays as separate fields (RFC 9110
/// section 5.2).  A malformed field raises EHttpProtocolError.
function ParseHeaders(const ALines: TArray<string>): TArray<THttp1HeaderField>;

/// the first value for AName (case-insensitive), or '' when absent
function HeaderFieldValue(const AFields: TArray<THttp1HeaderField>;
  const AName: string): string;

/// convert parsed fields to the shared header map, dropping connection-specific
/// fields that the map forbids on the HTTP/2 wire
function FieldsToHttpHeaders(
  const AFields: TArray<THttp1HeaderField>): IHttpHeaders;

/// parse one chunk-size line: hexadecimal, with an optional ";extension" that
/// is ignored.  A bad size raises EHttpProtocolError.
function ParseChunkSize(const ALine: string): Int64;

/// decode a whole chunked body from AReader, returning the decoded bytes and
/// any trailer fields.  Used for tests and eager callers; the streaming path
/// uses THttp1BodyStream.
function DecodeChunked(const AReader: TBufferedReader;
  out ATrailers: IHttpHeaders): TBytes;

implementation

uses
  Http2.Client.Http1.Parse;

const
  cCrLf = #13#10;
  cHexDigits = '0123456789abcdefABCDEF';
  cTokenChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' +
                '0123456789!#$%&''*+-.^_`|~';
  /// HTTP/1.1 connection-specific fields the shared header map rejects; they
  /// describe framing, not the application payload
  ForbiddenFields: array[0..4] of string = (
    'connection', 'keep-alive', 'transfer-encoding', 'upgrade',
    'proxy-connection');

function BytesOf(const S: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function ConcatBytes(const A, B: TBytes): TBytes;
var
  N: Integer;
begin
  Result := nil;
  N := Length(A);
  SetLength(Result, N + Length(B));
  if N > 0 then
    Move(A[0], Result[0], N);
  if Length(B) > 0 then
    Move(B[0], Result[N], Length(B));
end;

function IsHexDigit(const ACh: Char): Boolean;
begin
  Result := Pos(ACh, cHexDigits) > 0;
end;

function HexValue(const ACh: Char): Integer;
begin
  if (ACh >= '0') and (ACh <= '9') then
    Result := Ord(ACh) - Ord('0')
  else if (ACh >= 'a') and (ACh <= 'f') then
    Result := Ord(ACh) - Ord('a') + 10
  else
    Result := Ord(ACh) - Ord('A') + 10;
end;

function IsForbiddenField(const ALowerName: string): Boolean;
var
  I: Integer;
begin
  for I := Low(ForbiddenFields) to High(ForbiddenFields) do
    if ALowerName = ForbiddenFields[I] then
      Exit(True);
  Result := False;
end;

{ THttp1Response }

destructor THttp1Response.Destroy;
begin
  if FStream <> nil then
    FStream.ReleaseExchange;
  inherited Destroy;
end;

procedure THttp1Response.BindStream(const AStream: THttp1BodyStream);
begin
  FStream := AStream;
end;

procedure THttp1Response.BindProgress(const AExchange: IExchangeObserver);
begin
  FProgress := ProgressOf(AExchange);
end;

constructor THttp1Response.Create(const AVersion: string;
  const AStatusCode: LongInt; const AReason: string;
  const AHeaders: IHttpHeaders; const ABody: IHttpBodyStream);
begin
  inherited Create;
  FVersion := AVersion;
  FStatusCode := AStatusCode;
  FReason := AReason;
  FHeaders := AHeaders;
  FBody := ABody;
  FProgress := NullAttemptProgress;
end;

function THttp1Response.GetStatusCode: LongInt;
begin
  Result := FStatusCode;
end;

function THttp1Response.GetHeaders: IHttpHeaders;
begin
  Result := FHeaders;
end;

function THttp1Response.GetBody: IHttpBodyStream;
begin
  Result := FBody;
end;

{ request build / response parse }

function BuildHttp1Request(const ARequest: TStreamRequest): TBytes;
var
  Head: string;
  Names, Vals: TArray<string>;
  BodyBytes: TBytes;
  GenerateLength, GenerateChunked: Boolean;
  Host, Value, Chunk: string;
  Writer: IBodyWriter;
  Ch, All: TBytes;
  I, J: Integer;
begin
  if not IsValidTargetPart(ARequest.Path) then
    raise EHttpProtocolError.Create('invalid HTTP/1.1 request target',
      ecProtocolError);
  Head := ARequest.Method;
  if Head = '' then
    Head := 'GET';
  if ARequest.Path = '' then
    Head := Head + ' / HTTP/1.1' + cCrLf
  else
    Head := Head + ' ' + ARequest.Path + ' HTTP/1.1' + cCrLf;

  // exactly one Host header: a caller-supplied value wins, else the authority
  Host := '';
  if ARequest.Headers <> nil then
    Host := ARequest.Headers.GetFirst(HeaderHost);
  if Host = '' then
    Host := ARequest.Authority;
  if Host = '' then
    raise EHttpProtocolError.Create('HTTP/1.1 request has no Host',
      ecProtocolError);
  if not IsValidTargetPart(Host) then
    raise EHttpProtocolError.Create('invalid HTTP/1.1 Host value',
      ecProtocolError);
  Head := Head + 'Host: ' + Host + cCrLf;

  GenerateLength := ARequest.Body.IsSet;
  GenerateChunked := (not GenerateLength) and (ARequest.BodyWriter <> nil);

  if ARequest.Headers <> nil then
  begin
    Names := ARequest.Headers.Names;
    for I := 0 to High(Names) do
    begin
      if SameText(Names[I], HeaderHost) then
        Continue;
      if GenerateLength and SameText(Names[I], HeaderContentLength) then
        Continue;
      Vals := ARequest.Headers.GetValues(Names[I]);
      for J := 0 to High(Vals) do
      begin
        Value := Vals[J];
        Head := Head + Names[I] + ': ' + Value + cCrLf;
      end;
    end;
  end;

  All := nil;
  if GenerateLength then
  begin
    BodyBytes := ARequest.Body.Data;
    Head := Head + 'Content-Length: ' + IntToStr(Length(BodyBytes)) + cCrLf;
    Head := Head + cCrLf;
    All := ConcatBytes(BytesOf(Head), BodyBytes);
  end
  else if GenerateChunked then
  begin
    Head := Head + 'Transfer-Encoding: chunked' + cCrLf;
    Head := Head + cCrLf;
    All := BytesOf(Head);
    Writer := ARequest.BodyWriter;
    while Writer.NextChunk(Ch) do
    begin
      if Length(Ch) = 0 then
        Continue;   // a zero-length chunk would look like the terminator
      Chunk := IntToHex(Integer(Length(Ch)), 1) + cCrLf;
      All := ConcatBytes(All, BytesOf(Chunk));
      All := ConcatBytes(All, Ch);
      All := ConcatBytes(All, BytesOf(cCrLf));
    end;
    All := ConcatBytes(All, BytesOf('0' + cCrLf + cCrLf));
  end
  else
  begin
    Head := Head + cCrLf;
    All := BytesOf(Head);
  end;
  Result := All;
end;

procedure ParseStatusLine(const ALine: string; out AVersion: string;
  out AStatusCode: Integer; out AReason: string);
var
  P1, P2, I: Integer;
  CodeStr: string;
begin
  AVersion := '';
  AStatusCode := 0;
  AReason := '';
  P1 := Pos(' ', ALine);
  if P1 <= 1 then
    raise EHttpProtocolError.Create('malformed status line: ' + ALine,
      ecProtocolError);
  AVersion := Copy(ALine, 1, P1 - 1);
  // must be HTTP/<digit>.<digit>
  if (Copy(AVersion, 1, 5) <> 'HTTP/') or (Length(AVersion) <> 8) or
     ((AVersion[6] < '0') or (AVersion[6] > '9')) or (AVersion[7] <> '.') or
     ((AVersion[8] < '0') or (AVersion[8] > '9')) then
    raise EHttpProtocolError.Create('unsupported HTTP version: ' + AVersion,
      ecProtocolError);
  P2 := Pos(' ', ALine, P1 + 1);
  if P2 = 0 then
    CodeStr := Copy(ALine, P1 + 1, Length(ALine))
  else
  begin
    CodeStr := Copy(ALine, P1 + 1, P2 - P1 - 1);
    AReason := Copy(ALine, P2 + 1, Length(ALine));
  end;
  if Length(CodeStr) <> 3 then
    raise EHttpProtocolError.Create('status code is not 3 digits: ' + CodeStr,
      ecProtocolError);
  for I := 1 to 3 do
    if (CodeStr[I] < '0') or (CodeStr[I] > '9') then
      raise EHttpProtocolError.Create('status code is not numeric: ' + CodeStr,
        ecProtocolError);
  AStatusCode := StrToInt(CodeStr);
end;

function ParseHeaders(const ALines: TArray<string>): TArray<THttp1HeaderField>;
begin
  // one copy of the field rules (obs-fold, colon, repeats) lives in the Body unit
  Result := Http2.Client.Http1.Body.ParseFieldLines(ALines);
end;

function HeaderFieldValue(const AFields: TArray<THttp1HeaderField>;
  const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
    if SameText(AFields[I].Name, AName) then
      Exit(AFields[I].Value);
end;

function FieldsToHttpHeaders(
  const AFields: TArray<THttp1HeaderField>): IHttpHeaders;
var
  I: Integer;
begin
  Result := NewHttpHeaders;
  for I := 0 to High(AFields) do
    if not IsForbiddenField(LowerCase(AFields[I].Name)) then
      Result.Add(AFields[I].Name, AFields[I].Value);
end;

function ParseChunkSize(const ALine: string): Int64;
var
  S: string;
  P, I: Integer;
  Size: Int64;
begin
  S := ALine;
  P := Pos(';', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  S := Trim(S);
  if S = '' then
    raise EHttpProtocolError.Create('empty chunk size', ecProtocolError);
  Size := 0;
  for I := 1 to Length(S) do
  begin
    if not IsHexDigit(S[I]) then
      raise EHttpProtocolError.Create('bad chunk size: ' + ALine,
        ecProtocolError);
    Size := Size * 16 + HexValue(S[I]);
    if Size > MaxInt then
      raise EHttpProtocolError.Create('chunk size too large: ' + ALine,
        ecProtocolError);
  end;
  Result := Size;
end;

function DecodeChunked(const AReader: TBufferedReader;
  out ATrailers: IHttpHeaders): TBytes;
var
  Line, Term: string;
  Size: Int64;
  Chunk: TBytes;
  Got: Integer;
  Lines: TArray<string>;
  N: Integer;
begin
  Result := nil;
  while True do
  begin
    if not AReader.ReadLine(Line, True) then
      raise EHttpProtocolError.Create('truncated chunk-size line',
        ecStreamClosed);
    Size := ParseChunkSize(Line);
    if Size = 0 then
      Break;
    SetLength(Chunk, Integer(Size));
    if Size > 0 then
    begin
      Got := AReader.ReadExact(Chunk[0], Integer(Size));
      if Got <> Integer(Size) then
        raise EHttpProtocolError.Create('truncated chunked body',
          ecStreamClosed);
    end;
    Result := ConcatBytes(Result, Chunk);
    if not AReader.ReadLine(Term, True) then
      raise EHttpProtocolError.Create('truncated chunked body',
        ecStreamClosed);
    if Term <> '' then
      raise EHttpProtocolError.Create('malformed chunk terminator: ' + Term,
        ecProtocolError);
  end;
  SetLength(Lines, 0);
  N := 0;
  while True do
  begin
    if not AReader.ReadLine(Line, True) then
      raise EHttpProtocolError.Create('truncated chunked trailer block',
        ecStreamClosed);
    if Line = '' then
      Break;
    SetLength(Lines, N + 1);
    Lines[N] := Line;
    Inc(N);
  end;
  if N > 0 then
    ATrailers := FieldsToHttpHeaders(ParseHeaders(Lines))
  else
    ATrailers := NewHttpHeaders;
end;

{ THttp1Connection }

constructor THttp1Connection.Create(const ASocket: IHttp2Socket;
  const ATimeoutMs: Integer);
begin
  inherited Create;
  if ASocket = nil then
    raise EHttpError.Create('THttp1Connection requires a socket',
      ecInternalError);
  FSocket := ASocket;
  FSocket.ReadTimeoutMs := ATimeoutMs;
  FSocket.WriteTimeoutMs := ATimeoutMs;
  FReader := TBufferedReader.Create(ASocket);
  FTimeoutMs := ATimeoutMs;
  FReusable := True;
  FReuse := TReuseFlag.Create;
  FLastTrailers := NewHttpHeaders;
end;

destructor THttp1Connection.Destroy;
begin
  FReader.Free;
  Close;
  inherited Destroy;
end;

procedure THttp1Connection.WriteAll(const ABytes: TBytes);
var
  Ofs, N: Integer;
begin
  Ofs := 0;
  while Ofs < Length(ABytes) do
  begin
    N := FSocket.Write(ABytes[Ofs], Length(ABytes) - Ofs);
    if N <= 0 then
      raise EHttpConnectionClosed.Create('HTTP/1.1 request write failed');
    Inc(Ofs, N);
  end;
end;

function THttp1Connection.BeginResponse(const ARequest: TStreamRequest): Boolean;
var
  Line: string;
  Wire: TBytes;
  I: Integer;
begin
  // one request in flight at a time: the previous body must be drained
  if (FLastBody <> nil) and (not FLastBody.Eof) then
    raise EHttpProtocolError.Create(
      'previous HTTP/1.1 response body was not drained', ecProtocolError);
  if not Reusable then
    raise EHttpProtocolError.Create(
      'HTTP/1.1 connection cannot be reused (Connection: close or EOF body)',
      ecProtocolError);

  Wire := BuildHttp1Request(ARequest);
  WriteAll(Wire);
  FSentBodyBytes := 0;
  if ARequest.Exchange <> nil then
  begin
    // the head ends at the first blank line; everything after it is body
    for I := 0 to Length(Wire) - 4 do
      if (Wire[I] = 13) and (Wire[I + 1] = 10) and (Wire[I + 2] = 13) and
         (Wire[I + 3] = 10) then
      begin
        FSentBodyBytes := Length(Wire) - (I + 4);
        Break;
      end;
    ARequest.Exchange.RequestWritten(FSentBodyBytes);
  end;
  Inc(FRequestCount);
  FSendRequest := ARequest;
  FBeginDone := False;

  // one deadline covers the whole head (status line, fields, interim heads)
  if FTimeoutMs > 0 then
    FReader.SetDeadline(GetTickCount64 + QWord(FTimeoutMs));
  // Read ONLY the status line, with no read-ahead: an h2c upgrade must leave
  // the bytes after the 101 in the socket for the HTTP/2 connection.
  if not FReader.ReadLineNoReadAhead(Line, True) then
    Exit(False);
  ParseStatusLine(Line, FVersion, FStatusCode, FReason);
  FBeginDone := True;
  Result := True;
end;

function THttp1Connection.FinishResponse: IHttpResponse;
var
  Head: TArray<string>;
  Line: string;
  Total, I: Integer;
  Fields: TArray<THttp1HeaderField>;
  Headers: IHttpHeaders;
  Framing: TBodyFraming;
  ContentLength: Int64;
  CL, TE, Connection: string;
  Bodyless, ChunkedWithLength, Known: Boolean;
  Interim: Integer;
  Body: THttp1BodyStream;
  Trailers: IHttpHeaders;
  Resp: THttp1Response;
begin
  if not FBeginDone then
    raise EHttpProtocolError.Create(
      'FinishResponse called before BeginResponse', ecInternalError);
  FBeginDone := False;   // consume: one status line per response

  // a head started by BeginResponse keeps its deadline; a resumed head starts one
  if (FTimeoutMs > 0) and not FReader.HasDeadline then
    FReader.SetDeadline(GetTickCount64 + QWord(FTimeoutMs));
  Interim := 0;
  while True do
  begin
    // read the remaining header field lines, bounded
    Total := 0;
    SetLength(Head, 0);
    while True do
    begin
      if not FReader.ReadLine(Line, True) then
        raise EHttpProtocolError.Create('unexpected EOF in response head',
          ecStreamClosed);
      Inc(Total, Length(Line) + 2);
      if Total > cHttp1MaxHeaderBytes then
        raise EHttpProtocolError.Create(
          'HTTP/1.1 response header block exceeds the ' +
          IntToStr(cHttp1MaxHeaderBytes) + '-byte limit', ecProtocolError);
      if Line = '' then
        Break;
      if Length(Head) >= cHttp1MaxHeadLines then
        raise EHttpProtocolError.Create(
          'HTTP/1.1 response has more than ' +
          IntToStr(cHttp1MaxHeadLines) + ' header lines', ecProtocolError);
      SetLength(Head, Length(Head) + 1);
      Head[High(Head)] := Line;
    end;

    SetLength(Fields, 0);
    if Length(Head) > 0 then
      Fields := ParseHeaders(Head);
    FFields := Fields;
    Headers := FieldsToHttpHeaders(Fields);
    FHeaders := Headers;

    // RFC 9110 section 15.2: a 1xx response other than 101 is interim; the
    // final response follows its own status line.  The fields above belong
    // to the interim response and are replaced by the next pass.
    if (FStatusCode < 100) or (FStatusCode > 199) or (FStatusCode = 101) then
      Break;
    Inc(Interim);
    if Interim > cHttp1MaxInterimResponses then
      raise EHttpProtocolError.Create('too many interim HTTP/1.1 responses',
        ecProtocolError);
    if not FReader.ReadLine(Line, True) then
      raise EHttpProtocolError.Create('unexpected EOF before the final response',
        ecStreamClosed);
    ParseStatusLine(Line, FVersion, FStatusCode, FReason);
  end;

  // the head is complete: the body reads have no head deadline
  FReader.ClearDeadline;

  // bodyless responses: HEAD, 204 and 304 never carry a body even when a
  // content-length is present (RFC 9110 section 6.4.1)
  Bodyless := SameText(FSendRequest.Method, 'HEAD') or (FStatusCode = 204) or
    (FStatusCode = 304);

  CL := HeaderFieldValue(Fields, HeaderContentLength);
  TE := HeaderFieldValue(Fields, 'transfer-encoding');
  Connection := HeaderFieldValue(Fields, 'connection');
  ContentLength := 0;
  ChunkedWithLength := False;
  if Bodyless then
    Framing := bfNone
  else if TE <> '' then
  begin
    // RFC 9112 section 6.1: chunked must be the last coding, and the client
    // knows no other transfer coding
    if not (TransferEncodingIsChunked(TE, Known) and Known) then
      raise EHttpProtocolError.Create('unsupported transfer coding: ' + TE,
        ecProtocolError);
    // RFC 9112 section 6.3, item 3: Transfer-Encoding overrides Content-Length
    Framing := bfChunked;
    ChunkedWithLength := CL <> '';
  end
  else if CL <> '' then
  begin
    if not TryParseContentLength(CL, ContentLength) then
      raise EHttpProtocolError.Create('invalid content-length: ' + CL,
        ecProtocolError);
    Framing := bfContentLength;
  end
  else
    Framing := bfUntilClose;

  Trailers := NewHttpHeaders;
  Body := THttp1BodyStream.Create(FReader, Framing, ContentLength, Trailers);
  FLastBody := Body;
  FLastTrailers := Trailers;

  // keep-alive: HTTP/1.1 default unless "Connection: close"; read-to-close
  // framing always forbids reuse (the body ends only at EOF)
  FReusable := (Pos('close', LowerCase(Connection)) = 0) and
    (Framing <> bfUntilClose) and
    ((FVersion = 'HTTP/1.1') or
     (Pos('keep-alive', LowerCase(Connection)) > 0));
  // RFC 9112 section 6.3, item 3: the peer sent a conflicting length, so the
  // connection is not reused after this response
  if ChunkedWithLength then
    FReusable := False;

  Body.BindReuseFlag(FReuse);
  Body.AttachExchange(FSendRequest.Exchange, FSentBodyBytes);
  Resp := THttp1Response.Create(FVersion, FStatusCode, FReason, Headers,
    Body);
  Resp.BindStream(Body);
  Resp.BindProgress(FSendRequest.Exchange);
  Result := Resp;
end;

function THttp1Connection.ResumeResponse(const ARequest: TStreamRequest;
  const AStatusLine: string): IHttpResponse;
begin
  Inc(FRequestCount);
  FSendRequest := ARequest;
  FSentBodyBytes := 0;
  ParseStatusLine(AStatusLine, FVersion, FStatusCode, FReason);
  FBeginDone := True;
  Result := FinishResponse;
end;

function THttp1Connection.Send(const ARequest: TStreamRequest): IHttpResponse;
begin
  if not BeginResponse(ARequest) then
    raise EHttpProtocolError.Create('unexpected EOF in response head',
      ecStreamClosed);
  Result := FinishResponse;
end;

function THttp1Connection.GetReaderBuffered: Integer;
begin
  Result := FReader.Buffered;
end;

function THttp1Connection.Detach: IHttp2Socket;
begin
  if FReader.Buffered <> 0 then
    raise EHttpProtocolError.Create(
      'cannot detach: bytes were read past the status line', ecInternalError);
  Result := FSocket;
  FSocket := nil;        // ownership transfers; Close must not touch it
  FReusable := False;
end;

function THttp1Connection.Reusable: Boolean;
begin
  Result := FReusable and FReuse.Reusable;
end;

function THttp1Connection.HasUnreadInput: Boolean;
var
  Pending: IPendingInput;
begin
  Result := FReader.Buffered > 0;
  if Result or (FSocket = nil) then
    Exit;
  // TLS sockets do not implement IPendingInput: the session cannot report buffered plaintext.
  if Supports(FSocket, IPendingInput, Pending) then
    Result := Pending.HasPendingInput;
end;

procedure THttp1Connection.Close;
begin
  FReusable := False;
  if FSocket <> nil then
    FSocket.Close;
end;

end.
