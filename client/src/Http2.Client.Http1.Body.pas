{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, http1
notes:
  - This unit owns buffered HTTP/1 response body parsing.
---
}
unit Http2.Client.Http1.Body;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs,
  Http2.Client.Errors, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Clock, Http2.Common.Headers;

const
  cHttp1MaxHeaderBytes = 64 * 1024;
  cHttp1ReadBufferSize = 16 * 1024;
  /// the trailer block of a chunked body: at most this many lines and bytes
  cHttp1MaxTrailerLines = 256;
  cHttp1MaxTrailerBytes = 64 * 1024;
  /// the field lines of one response head (interim heads included, one at a time)
  cHttp1MaxHeadLines = 256;

type
  /// one parsed HTTP/1.1 header field.  Name keeps the first-seen spelling;
  /// repeated fields are joined (see ParseHeaders).
  THttp1HeaderField = record
    Name: string;
    Value: string;
  end;

  /// a buffered line/byte reader over an IHttp2Socket.  It is the single owner
  /// of the read position, so a response head and its body can be parsed from
  /// the same stream without losing bytes at the boundary.
  TBufferedReader = class
  private
    FSocket: IHttp2Socket;
    FBuf: TBytes;
    FPos: Integer;
    FEnd: Integer;
    /// which transport read delivered which buffered bytes: entry I covers
    /// the bytes up to (not including) offset FStampEnd[I] since the previous
    /// entry, and arrived at FStampUs[I]
    FStampEnd: array of Integer;
    FStampUs: array of Int64;
    FStampSeq: array of Int64;
    FStampCount: Integer;
    FLastReadUs: Int64;
    FLastReadSeq: Int64;
    FFillCount: Int64;
    /// the GetTickCount64 instant at which the response head must be complete;
    /// 0 when no head is being read
    FDeadlineMs: QWord;
    /// the per-request body-read timeout of the response being read (see
    /// SetBodyReadTimeout); FBodyTimeoutSet False keeps the socket timeout
    FBodyTimeoutSet: Boolean;
    FBodyTimeoutMs: Integer;
    /// drop the entries for bytes already consumed
    procedure TrimStamps;
    /// pull another transport buffer into FBuf; False at end of stream
    function Fill: Boolean;
    /// one transport read.  APartial takes what is available (IPartialReader).
    /// Under a deadline each read waits at most the time that remains, and an
    /// expired deadline raises EHttpTimeout before the read starts.
    function ReadTransport(var ABuffer; const ACount: Integer;
      const APartial: Boolean): Integer;
  public
    constructor Create(const ASocket: IHttp2Socket);
    /// start the deadline of a response head: the head must be complete when
    /// GetTickCount64 reaches ADeadlineMs (one deadline for the whole head)
    procedure SetDeadline(const ADeadlineMs: QWord);
    /// end the deadline of the head; the body reads have no deadline
    procedure ClearDeadline;
    /// the body-read timeout of the response: each body read that waits for
    /// the peer waits at most AMs ms (0 = indefinitely) when ASet is True.
    /// When ASet is False, the body reads use the socket timeout.
    procedure SetBodyReadTimeout(const AMs: Integer; const ASet: Boolean);
    /// true while a head deadline is set
    function HasDeadline: Boolean;
    /// read up to ACount bytes; 0 only at end of stream.  A call returns bytes
    /// of one transport read only, so LastReadUs names its arrival.
    function ReadBytes(var ABuffer; const ACount: Integer): Integer;
    /// the stamp of the transport read that delivered the bytes of the last
    /// ReadBytes
    property LastReadUs: Int64 read FLastReadUs;
    /// which transport read that was, counted from 1; tells two reads with
    /// equal stamps apart
    property LastReadSeq: Int64 read FLastReadSeq;
    /// read exactly ACount bytes; shorter only when the peer closed early
    function ReadExact(var ABuffer; const ACount: Integer): Integer;
    /// read one CRLF- or LF-terminated line, stripping the terminator.  False
    /// only when the stream ends before any byte of the line arrives.  AStrict
    /// refuses a bare LF (no CR before it) and a bare CR inside the line, as
    /// RFC 9112 section 2.2 allows a recipient to refuse them (the client does).
    function ReadLine(out ALine: string; const AStrict: Boolean = False): Boolean;
    /// read one CRLF- or LF-terminated line WITHOUT reading past it.  Used at
    /// the HTTP/1.1 -> HTTP/2 upgrade boundary, where a buffered read would
    /// swallow the first HTTP/2 bytes that follow the status line.
    function ReadLineNoReadAhead(out ALine: string;
      const AStrict: Boolean = False): Boolean;
    /// true when no buffered byte remains (may still pull more later)
    function Buffered: Integer;
  end;

  /// a reuse flag shared by one HTTP/1.1 connection and the body streams it
  /// hands out.  A body that is released before its end marks the flag, so
  /// the connection stops being reusable.  The body holds a counted reference,
  /// so the flag stays valid when the connection is destroyed first.
  IReuseFlag = interface
    ['{C3A1E5B2-6D47-4F9A-8E21-5B7D0A9C1E03}']
    function GetReusable: Boolean;
    procedure MarkNotReusable;
    property Reusable: Boolean read GetReusable;
  end;

  TReuseFlag = class(TInterfacedObject, IReuseFlag)
  private
    FReusable: Boolean;
    function GetReusable: Boolean;
  public
    constructor Create;
    procedure MarkNotReusable;
  end;

  /// how a response body is delimited
  TBodyFraming = (bfNone, bfContentLength, bfChunked, bfUntilClose);

  /// an IHttpBodyStream over a response body.  Chunked decoding is pull-based
  /// (a chunk is decoded as the caller reads it), so a large body is not
  /// buffered whole.
  THttp1BodyStream = class(TInterfacedObject, IHttpBodyStream,
    IStampedBodyStream)
  private
    FReader: TBufferedReader;
    FFraming: TBodyFraming;
    FRemaining: Int64;          // content-length bytes still to read
    FChunkRemaining: Int64;     // bytes left in the current chunk
    FAtChunkEnd: Boolean;       // the CRLF after the current chunk is pending
    FDone: Boolean;
    FReuse: IReuseFlag;         // nil when no connection owns the body
    FObservedEof: Boolean;
    FTrailers: IHttpHeaders;    // filled when the chunked terminator is parsed
    // observed-attempt hook (doc/design/request-observability.md)
    FExchange: IExchangeObserver;
    FBytesIn: Int64;
    FBytesOut: Int64;
    FEnded: LongInt;
    FLastReadUs: Int64;         // arrival stamp of the last Read's bytes
    FLastReadSeq: Int64;        // which transport read that was
    FArrivals: TArrivalStats;
    procedure EndExchange(const AError: Exception; const AAbandoned: Boolean);
    function ReadFramed(var ABuffer; const ACount: LongInt): LongInt;
    procedure ReadTrailers;
    function ReadContentLength(var ABuffer; const ACount: LongInt): LongInt;
    function ReadChunked(var ABuffer; const ACount: LongInt): LongInt;
    function ReadUntilClose(var ABuffer; const ACount: LongInt): LongInt;
  public
    constructor Create(const AReader: TBufferedReader;
      const AFraming: TBodyFraming; const AContentLength: Int64;
      const ATrailers: IHttpHeaders);
    function Read(var ABuffer; const ACount: LongInt): LongInt;
    function Eof: Boolean;
    function LastReadArrivedUs: Int64;
    /// report the end of this body (EOF, a failed read or release) to AExchange
    /// exactly once; ABytesOut is the request body size for the report
    procedure AttachExchange(const AExchange: IExchangeObserver;
      const ABytesOut: Int64);
    /// the response was released: report an abandoned end unless the body was
    /// already finished
    procedure ReleaseExchange;
    /// let a release before the end of the body retire the owning connection
    procedure BindReuseFlag(const AFlag: IReuseFlag);
    property Trailers: IHttpHeaders read FTrailers;
  end;


/// parse the field lines of one head or trailer block (RFC 9112 section 5).
/// A line that starts with SP or HTAB continues the previous field value
/// (obs-fold, section 5.2); a space before the colon raises (section 5.1).
function ParseFieldLines(const ALines: TArray<string>): TArray<THttp1HeaderField>; overload;

/// the same, and AFolded tells whether at least one field line was unfolded.
/// A fold of a framing or hop-by-hop field (Content-Length, Transfer-Encoding,
/// Connection, Upgrade, Keep-Alive, Proxy-Connection, Sec-WebSocket-*) raises.
/// A caller that gets AFolded = True does not reuse the connection.
function ParseFieldLines(const ALines: TArray<string>;
  out AFolded: Boolean): TArray<THttp1HeaderField>; overload;

implementation

const
  cHexDigits = '0123456789abcdefABCDEF';
  cTokenChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' +
                '0123456789!#$%&''*+-.^_`|~';
  ForbiddenFields: array[0..4] of string = (
    'connection', 'keep-alive', 'transfer-encoding', 'upgrade',
    'proxy-connection');

function IsForbiddenField(const ALowerName: string): Boolean;
var I: Integer;
begin
  for I := Low(ForbiddenFields) to High(ForbiddenFields) do
    if ALowerName = ForbiddenFields[I] then Exit(True);
  Result := False;
end;

function IsHexDigit(const ACh: Char): Boolean;
begin Result := Pos(ACh, cHexDigits) > 0; end;

function HexValue(const ACh: Char): Integer;
begin
  if (ACh >= '0') and (ACh <= '9') then Result := Ord(ACh) - Ord('0')
  else if (ACh >= 'a') and (ACh <= 'f') then Result := Ord(ACh) - Ord('a') + 10
  else Result := Ord(ACh) - Ord('A') + 10;
end;

function IsFoldRefusedField(const AName: string): Boolean;
var Lower: string;
begin
  Lower := LowerCase(AName);
  Result := (Lower = 'content-length') or IsForbiddenField(Lower) or
    (Copy(Lower, 1, 14) = 'sec-websocket-');
end;

function ParseFieldLines(const ALines: TArray<string>): TArray<THttp1HeaderField>;
var Folded: Boolean;
begin
  Result := ParseFieldLines(ALines, Folded);
end;

function ParseFieldLines(const ALines: TArray<string>;
  out AFolded: Boolean): TArray<THttp1HeaderField>;
var
  I, J, P: Integer;
  Line, Name, Value: string;
  Ch: Char;
  Found: Boolean;
  Count, Last: Integer;
begin
  Result := nil;
  Count := 0;
  Last := -1;
  AFolded := False;
  for I := 0 to High(ALines) do
  begin
    Line := ALines[I];
    // obs-fold (RFC 9112 section 5.2): the user agent replaces the fold with SP
    if (Line <> '') and ((Line[1] = ' ') or (Line[1] = #9)) then
    begin
      if Last < 0 then
        raise EHttpProtocolError.Create('field line folded before any field',
          ecProtocolError);
      // a fold of a framing field is a desynchronization path: refuse it
      if IsFoldRefusedField(Result[Last].Name) then
        raise EHttpProtocolError.Create(
          'folded line in the field ' + Result[Last].Name, ecProtocolError);
      AFolded := True;
      Value := Trim(Line);
      if Value <> '' then
        if Result[Last].Value = '' then
          Result[Last].Value := Value
        else
          Result[Last].Value := Result[Last].Value + ' ' + Value;
      Continue;
    end;
    P := Pos(':', Line);
    if P <= 1 then
      raise EHttpProtocolError.Create('malformed header field: ' + Line,
        ecProtocolError);
    // RFC 9112 section 5.1: no whitespace between the field name and the colon
    if (Line[P - 1] = ' ') or (Line[P - 1] = #9) then
      raise EHttpProtocolError.Create('whitespace before colon: ' + Line,
        ecProtocolError);
    Name := Trim(Copy(Line, 1, P - 1));
    Value := Trim(Copy(Line, P + 1, Length(Line)));
    if Name = '' then
      raise EHttpProtocolError.Create('empty header field name',
        ecProtocolError);
    for J := 1 to Length(Name) do
    begin
      Ch := Name[J];
      if Pos(Ch, cTokenChars) = 0 then
        raise EHttpProtocolError.Create('invalid header field name: ' + Name,
          ecProtocolError);
    end;
    // join repeats (RFC 9110 section 5.2) except set-cookie
    Found := False;
    if not SameText(Name, HeaderSetCookie) then
      for J := 0 to Count - 1 do
        if SameText(Result[J].Name, Name) then
        begin
          Result[J].Value := Result[J].Value + ', ' + Value;
          Found := True;
          Last := J;
          Break;
        end;
    if not Found then
    begin
      // the array doubles; the final length is set after the loop
      if Count = Length(Result) then
        SetLength(Result, Count * 2 + 4);
      Result[Count].Name := Name;
      Result[Count].Value := Value;
      Last := Count;
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
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

{ TBufferedReader }

constructor TBufferedReader.Create(const ASocket: IHttp2Socket);
begin
  inherited Create;
  FSocket := ASocket;
  FBuf := nil;
  FPos := 0;
  FEnd := 0;
  FStampCount := 0;
  FLastReadUs := 0;
  FLastReadSeq := 0;
  FFillCount := 0;
  FDeadlineMs := 0;
  FBodyTimeoutSet := False;
  FBodyTimeoutMs := 0;
end;

procedure TBufferedReader.SetDeadline(const ADeadlineMs: QWord);
begin
  FDeadlineMs := ADeadlineMs;
end;

procedure TBufferedReader.ClearDeadline;
begin
  FDeadlineMs := 0;
end;

procedure TBufferedReader.SetBodyReadTimeout(const AMs: Integer;
  const ASet: Boolean);
begin
  FBodyTimeoutSet := ASet;
  FBodyTimeoutMs := AMs;
end;

function TBufferedReader.HasDeadline: Boolean;
begin
  Result := FDeadlineMs > 0;
end;

function TBufferedReader.ReadTransport(var ABuffer; const ACount: Integer;
  const APartial: Boolean): Integer;
var
  PR: IPartialReader;
  Now, Remaining: QWord;
  Saved: Integer;
begin
  if FDeadlineMs = 0 then
  begin
    if not FBodyTimeoutSet then
    begin
      if APartial and Supports(FSocket, IPartialReader, PR) then
        Exit(PR.ReadSome(ABuffer, ACount));
      Exit(FSocket.Read(ABuffer, ACount));
    end;
    // the request set a body-read timeout: this read waits at most that long
    // (0 = indefinitely), and the socket timeout comes back after the read
    Saved := FSocket.ReadTimeoutMs;
    FSocket.ReadTimeoutMs := FBodyTimeoutMs;
    try
      if APartial and Supports(FSocket, IPartialReader, PR) then
        Result := PR.ReadSome(ABuffer, ACount)
      else
        Result := FSocket.Read(ABuffer, ACount);
    finally
      FSocket.ReadTimeoutMs := Saved;
    end;
    Exit;
  end;
  // a read may wait only for the time that is left of the head deadline.  A
  // timeout of that read is final: no byte was consumed, and the deadline has
  // passed when it fires.
  Now := GetTickCount64;
  if Now >= FDeadlineMs then
    raise EHttpTimeout.Create('response head deadline passed');
  Remaining := FDeadlineMs - Now;
  Saved := FSocket.ReadTimeoutMs;
  FSocket.ReadTimeoutMs := Integer(Remaining);
  try
    if APartial and Supports(FSocket, IPartialReader, PR) then
      Result := PR.ReadSome(ABuffer, ACount)
    else
      Result := FSocket.Read(ABuffer, ACount);
  finally
    FSocket.ReadTimeoutMs := Saved;
  end;
end;

procedure TBufferedReader.TrimStamps;
var
  Drop, I: Integer;
begin
  // an entry is spent once the read position has passed its end
  Drop := 0;
  while (Drop < FStampCount) and (FStampEnd[Drop] <= FPos) do
    Inc(Drop);
  if Drop = 0 then
    Exit;
  for I := Drop to FStampCount - 1 do
  begin
    FStampEnd[I - Drop] := FStampEnd[I];
    FStampUs[I - Drop] := FStampUs[I];
    FStampSeq[I - Drop] := FStampSeq[I];
  end;
  Dec(FStampCount, Drop);
end;

function TBufferedReader.Fill: Boolean;
var
  N: Integer;
  Tmp: TBytes;
  Stamp: Int64;
begin
  // compact the consumed prefix so the buffer does not grow without bound
  if FPos > 0 then
  begin
    TrimStamps;
    for N := 0 to FStampCount - 1 do
      Dec(FStampEnd[N], FPos);
    if FEnd > FPos then
      Move(FBuf[FPos], FBuf[0], FEnd - FPos);
    Dec(FEnd, FPos);
    FPos := 0;
  end;
  SetLength(Tmp, cHttp1ReadBufferSize);
  // IHttp2Socket.Read insists on the full count (or EOF), which would stall a
  // keep-alive connection until the server closes it.  A socket that can
  // return what is available says so with IPartialReader (see ReadTransport).
  N := ReadTransport(Tmp[0], cHttp1ReadBufferSize, True);
  // the arrival stamp: taken as soon as the transport read returns
  Stamp := NowUs;
  if N <= 0 then
    Exit(False);
  if FEnd + N > Length(FBuf) then
    SetLength(FBuf, FEnd + N);
  Move(Tmp[0], FBuf[FEnd], N);
  Inc(FEnd, N);
  if FStampCount = Length(FStampEnd) then
  begin
    SetLength(FStampEnd, FStampCount + 4);
    SetLength(FStampUs, FStampCount + 4);
    SetLength(FStampSeq, FStampCount + 4);
  end;
  Inc(FFillCount);
  FStampSeq[FStampCount] := FFillCount;
  FStampEnd[FStampCount] := FEnd;
  FStampUs[FStampCount] := Stamp;
  Inc(FStampCount);
  Result := True;
end;

function TBufferedReader.Buffered: Integer;
begin
  Result := FEnd - FPos;
end;

function TBufferedReader.ReadBytes(var ABuffer; const ACount: Integer): Integer;
var
  N: Integer;
  P: PByte;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  if FPos >= FEnd then
    if not Fill then
      Exit;
  N := FEnd - FPos;
  if N > ACount then
    N := ACount;
  // stay inside the transport read that delivered the first byte, so the
  // bytes returned share one arrival stamp
  TrimStamps;
  if FStampCount > 0 then
  begin
    if N > FStampEnd[0] - FPos then
      N := FStampEnd[0] - FPos;
    FLastReadUs := FStampUs[0];
    FLastReadSeq := FStampSeq[0];
  end;
  P := @ABuffer;
  Move(FBuf[FPos], P^, N);
  Inc(FPos, N);
  Result := N;
end;

function TBufferedReader.ReadExact(var ABuffer; const ACount: Integer): Integer;
var
  P: PByte;
  N: Integer;
begin
  Result := 0;
  P := @ABuffer;
  while Result < ACount do
  begin
    N := ReadBytes(P[Result], ACount - Result);
    if N = 0 then
      Break;
    Inc(Result, N);
  end;
end;

function TBufferedReader.ReadLineNoReadAhead(out ALine: string;
  const AStrict: Boolean): Boolean;
var
  One: array[0..0] of Byte;
  Bytes: TBytes;
  N, Len: Integer;
  Last: Byte;
begin
  // This variant never reads past the terminating LF: it pulls one byte at a
  // time straight from the socket.  It is used at the h2c upgrade boundary,
  // where the bytes after the status line are HTTP/2 frames that must stay
  // in the socket for the HTTP/2 connection to read.
  ALine := '';
  Len := 0;
  SetLength(Bytes, 128);
  while True do
  begin
    if FPos < FEnd then
    begin
      Last := FBuf[FPos];
      Inc(FPos);
    end
    else
    begin
      N := ReadTransport(One[0], 1, False);
      if N <= 0 then
        Break;
      Last := One[0];
    end;
    // the buffer doubles, so a long line costs O(n) copies, not O(n^2)
    if Len = Length(Bytes) then
      SetLength(Bytes, Len * 2);
    Bytes[Len] := Last;
    Inc(Len);
    if Last = 10 then
      Break;
    if Len > cHttp1MaxHeaderBytes then
      raise EHttpProtocolError.Create(
        'HTTP/1.1 header line exceeds the ' +
        IntToStr(cHttp1MaxHeaderBytes) + '-byte limit', ecProtocolError);
  end;
  if Len = 0 then
    Exit(False);
  if Bytes[Len - 1] = 10 then
  begin
    Dec(Len);
    // strict: the LF must follow a CR (a bare LF is refused)
    if AStrict and ((Len = 0) or (Bytes[Len - 1] <> 13)) then
      raise EHttpProtocolError.Create('bare LF in HTTP/1.1 line',
        ecProtocolError);
  end;
  if (Len > 0) and (Bytes[Len - 1] = 13) then
    Dec(Len);
  SetLength(ALine, Len);
  if Len > 0 then
    Move(Bytes[0], ALine[1], Len);
  if AStrict and (Pos(#13, ALine) > 0) then
    raise EHttpProtocolError.Create('bare CR in HTTP/1.1 line',
      ecProtocolError);
  Result := True;
end;

function TBufferedReader.ReadLine(out ALine: string;
  const AStrict: Boolean): Boolean;
var
  I, Start, Len: Integer;
begin
  ALine := '';
  while True do
  begin
    for I := FPos to FEnd - 1 do
      if FBuf[I] = 10 then
      begin
        Start := FPos;
        Len := I - FPos;
        // strict: the LF must follow a CR, so a bare LF is refused
        if AStrict and ((Len = 0) or (FBuf[I - 1] <> 13)) then
          raise EHttpProtocolError.Create('bare LF in HTTP/1.1 line',
            ecProtocolError);
        SetLength(ALine, Len);
        if Len > 0 then
          Move(FBuf[Start], ALine[1], Len);
        FPos := I + 1;
        if (Length(ALine) > 0) and (ALine[Length(ALine)] = #13) then
          SetLength(ALine, Length(ALine) - 1);
        // strict: a CR inside the line is a bare CR
        if AStrict and (Pos(#13, ALine) > 0) then
          raise EHttpProtocolError.Create('bare CR in HTTP/1.1 line',
            ecProtocolError);
        Exit(True);
      end;
    // a single unterminated line is bounded by the header ceiling as well
    if (FEnd - FPos) > cHttp1MaxHeaderBytes then
      raise EHttpProtocolError.Create(
        'HTTP/1.1 header line exceeds the ' +
        IntToStr(cHttp1MaxHeaderBytes) + '-byte limit',
        ecProtocolError);
    if not Fill then
    begin
      if FEnd > FPos then
      begin
        Len := FEnd - FPos;
        SetLength(ALine, Len);
        Move(FBuf[FPos], ALine[1], Len);
        FPos := FEnd;
        Exit(True);
      end;
      Exit(False);
    end;
  end;
end;

{ THttp1BodyStream }

constructor THttp1BodyStream.Create(const AReader: TBufferedReader;
  const AFraming: TBodyFraming; const AContentLength: Int64;
  const ATrailers: IHttpHeaders);
begin
  inherited Create;
  FReader := AReader;
  FFraming := AFraming;
  FRemaining := AContentLength;
  FTrailers := ATrailers;
  FChunkRemaining := 0;
  // a bodyless response and an empty content-length body are complete already
  FDone := (AFraming = bfNone) or
           ((AFraming = bfContentLength) and (AContentLength = 0));
end;

procedure THttp1BodyStream.ReadTrailers;
var
  Line: string;
  Lines: TArray<string>;
  N, I, Bytes: Integer;
  Fields: TArray<THttp1HeaderField>;
  Folded: Boolean;
begin
  SetLength(Lines, 0);
  N := 0;
  Bytes := 0;
  while True do
  begin
    if not FReader.ReadLine(Line, True) then
      raise EHttpProtocolError.Create('truncated chunked trailer block',
        ecStreamClosed);
    if Line = '' then
      Break;
    // RFC 9112 section 7.1.2 leaves the size open; the client bounds it
    Inc(N);
    Inc(Bytes, Length(Line) + 2);
    if (N > cHttp1MaxTrailerLines) or (Bytes > cHttp1MaxTrailerBytes) then
      raise EHttpProtocolError.Create('chunked trailer block exceeds the ' +
        IntToStr(cHttp1MaxTrailerLines) + '-line or ' +
        IntToStr(cHttp1MaxTrailerBytes) + '-byte limit', ecProtocolError);
    // the array doubles as lines arrive
    if N > Length(Lines) then
      SetLength(Lines, Length(Lines) * 2 + 8);
    Lines[N - 1] := Line;
  end;
  SetLength(Lines, N);
  if (N > 0) and (FTrailers <> nil) then
  begin
    Fields := ParseFieldLines(Lines, Folded);
    // a trailer block that needed an unfold: the connection is not reused
    if Folded and (FReuse <> nil) then
      FReuse.MarkNotReusable;
    for I := 0 to High(Fields) do
      if not IsForbiddenField(LowerCase(Fields[I].Name)) then
        FTrailers.Add(Fields[I].Name, Fields[I].Value);
  end;
end;

function THttp1BodyStream.ReadContentLength(var ABuffer;
  const ACount: LongInt): LongInt;
var
  N: Integer;
begin
  N := ACount;
  if Int64(N) > FRemaining then
    N := Integer(FRemaining);
  Result := FReader.ReadBytes(PByte(@ABuffer)^, N);
  if Result <= 0 then
    raise EHttpProtocolError.Create('truncated response body',
      ecStreamClosed);
  Dec(FRemaining, Result);
  if FRemaining = 0 then
  begin
    FDone := True;   // the next Read observes EOF and returns 0
    // bytes read past the body belong to no response of this connection
    if (FReader.Buffered > 0) and (FReuse <> nil) then
      FReuse.MarkNotReusable;
  end;
end;

function THttp1BodyStream.ReadChunked(var ABuffer;
  const ACount: LongInt): LongInt;
var
  Line, Term: string;
  Size: Int64;
  N: Integer;
begin
  while True do
  begin
    if FChunkRemaining > 0 then
    begin
      N := ACount;
      if Int64(N) > FChunkRemaining then
        N := Integer(FChunkRemaining);
      Result := FReader.ReadBytes(PByte(@ABuffer)^, N);
      if Result <= 0 then
        raise EHttpProtocolError.Create('truncated chunked body',
          ecStreamClosed);
      Dec(FChunkRemaining, Result);
      if FChunkRemaining = 0 then
        FAtChunkEnd := True;
      Exit;
    end;
    if FAtChunkEnd then
    begin
      if not FReader.ReadLine(Term, True) then
        raise EHttpProtocolError.Create('truncated chunked body',
          ecStreamClosed);
      if Term <> '' then
        raise EHttpProtocolError.Create('malformed chunk terminator: ' + Term,
          ecProtocolError);
      FAtChunkEnd := False;
    end;
    if not FReader.ReadLine(Line, True) then
      raise EHttpProtocolError.Create('truncated chunk-size line',
        ecStreamClosed);
    Size := ParseChunkSize(Line);
    if Size = 0 then
    begin
      ReadTrailers;
      FDone := True;
      FObservedEof := True;   // this Read observes EOF and returns 0
      // bytes read past the body belong to no response of this connection
      if (FReader.Buffered > 0) and (FReuse <> nil) then
        FReuse.MarkNotReusable;
      Exit(0);
    end;
    FChunkRemaining := Size;
  end;
end;

function THttp1BodyStream.ReadUntilClose(var ABuffer;
  const ACount: LongInt): LongInt;
begin
  Result := FReader.ReadBytes(PByte(@ABuffer)^, ACount);
  if Result = 0 then
  begin
    FDone := True;
    FObservedEof := True;   // this Read observes EOF and returns 0
  end;
end;

procedure THttp1BodyStream.AttachExchange(const AExchange: IExchangeObserver;
  const ABytesOut: Int64);
begin
  FExchange := AExchange;
  FBytesOut := ABytesOut;
end;

procedure THttp1BodyStream.EndExchange(const AError: Exception;
  const AAbandoned: Boolean);
var
  Info: TExchangeEnd;
begin
  if FExchange = nil then
    Exit;
  if InterlockedCompareExchange(FEnded, 1, 0) <> 0 then
    Exit;
  Info.Error := AError;
  Info.Abandoned := AAbandoned;
  Info.BytesIn := FBytesIn;
  Info.BytesOut := FBytesOut;
  Info.Arrivals := FArrivals;
  try
    FExchange.ExchangeEnded(Info);
  except
    // the hook is the attempt tracker, which already guards its observers
  end;
end;

procedure THttp1BodyStream.ReleaseExchange;
begin
  if (not FDone) and (FReuse <> nil) then
    FReuse.MarkNotReusable;
  EndExchange(nil, not FDone);
end;

procedure THttp1BodyStream.BindReuseFlag(const AFlag: IReuseFlag);
begin
  FReuse := AFlag;
end;

{ TReuseFlag }

constructor TReuseFlag.Create;
begin
  inherited Create;
  FReusable := True;
end;

function TReuseFlag.GetReusable: Boolean;
begin
  Result := FReusable;
end;

procedure TReuseFlag.MarkNotReusable;
begin
  FReusable := False;
end;

function THttp1BodyStream.Read(var ABuffer; const ACount: LongInt): LongInt;
begin
  try
    Result := ReadFramed(ABuffer, ACount);
  except
    on E: Exception do
    begin
      EndExchange(E, False);
      raise;
    end;
  end;
  if Result > 0 then
  begin
    Inc(FBytesIn, Result);
    // each transport read is one chunk: a Read continuing the same read is
    // not another arrival
    if FReader.LastReadSeq <> FLastReadSeq then
      FArrivals.Note(FReader.LastReadUs);
    FLastReadSeq := FReader.LastReadSeq;
    FLastReadUs := FReader.LastReadUs;
  end;
  if FDone then
    EndExchange(nil, False);
end;

function THttp1BodyStream.ReadFramed(var ABuffer;
  const ACount: LongInt): LongInt;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  if FDone then
  begin
    if FObservedEof then
      raise EHttpStreamError.Create('read after end of stream', 0,
        ecStreamClosed);
    FObservedEof := True;
    Exit(0);
  end;
  case FFraming of
    bfContentLength: Result := ReadContentLength(ABuffer, ACount);
    bfChunked:       Result := ReadChunked(ABuffer, ACount);
    bfUntilClose:    Result := ReadUntilClose(ABuffer, ACount);
  else
    // bfNone is FDone at construction; unreachable here
    FDone := True;
    FObservedEof := True;
    Result := 0;
  end;
end;

function THttp1BodyStream.LastReadArrivedUs: Int64;
begin
  Result := FLastReadUs;
end;

function THttp1BodyStream.Eof: Boolean;
begin
  // the body is complete once FDone is set; bytes still buffered in the
  // reader belong to the NEXT response, not to this body
  Result := FDone;
end;


end.
