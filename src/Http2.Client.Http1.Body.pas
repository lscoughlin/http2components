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
    /// drop the entries for bytes already consumed
    procedure TrimStamps;
    /// pull another transport buffer into FBuf; False at end of stream
    function Fill: Boolean;
  public
    constructor Create(const ASocket: IHttp2Socket);
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
    /// only when the stream ends before any byte of the line arrives.
    function ReadLine(out ALine: string): Boolean;
    /// read one CRLF- or LF-terminated line WITHOUT reading past it.  Used at
    /// the HTTP/1.1 -> HTTP/2 upgrade boundary, where a buffered read would
    /// swallow the first HTTP/2 bytes that follow the status line.
    function ReadLineNoReadAhead(out ALine: string): Boolean;
    /// true when no buffered byte remains (may still pull more later)
    function Buffered: Integer;
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
    property Trailers: IHttpHeaders read FTrailers;
  end;


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

function ParseHeaders(const ALines: TArray<string>): TArray<THttp1HeaderField>;
var
  I, J, P: Integer;
  Line, Name, Value: string;
  Ch: Char;
  Found: Boolean;
  Count: Integer;
begin
  Result := nil;
  Count := 0;
  for I := 0 to High(ALines) do
  begin
    Line := ALines[I];
    P := Pos(':', Line);
    if P <= 1 then
      raise EHttpProtocolError.Create('malformed header field: ' + Line,
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
          Break;
        end;
    if not Found then
    begin
      SetLength(Result, Count + 1);
      Result[Count].Name := Name;
      Result[Count].Value := Value;
      Inc(Count);
    end;
  end;
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
  PR: IPartialReader;
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
  // return what is available says so with IPartialReader.
  if Supports(FSocket, IPartialReader, PR) then
    N := PR.ReadSome(Tmp[0], cHttp1ReadBufferSize)
  else
    N := FSocket.Read(Tmp[0], cHttp1ReadBufferSize);
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

function TBufferedReader.ReadLineNoReadAhead(out ALine: string): Boolean;
var
  One: array[0..0] of Byte;
  Bytes: TBytes;
  N: Integer;
begin
  // This variant never reads past the terminating LF: it pulls one byte at a
  // time straight from the socket.  It is used at the h2c upgrade boundary,
  // where the bytes after the status line are HTTP/2 frames that must stay
  // in the socket for the HTTP/2 connection to read.
  ALine := '';
  SetLength(Bytes, 0);
  while True do
  begin
    if FPos < FEnd then
    begin
      SetLength(Bytes, Length(Bytes) + 1);
      Bytes[High(Bytes)] := FBuf[FPos];
      Inc(FPos);
    end
    else
    begin
      N := FSocket.Read(One[0], 1);
      if N <= 0 then
        Break;
      SetLength(Bytes, Length(Bytes) + 1);
      Bytes[High(Bytes)] := One[0];
    end;
    if Bytes[High(Bytes)] = 10 then
      Break;
    if Length(Bytes) > cHttp1MaxHeaderBytes then
      raise EHttpProtocolError.Create(
        'HTTP/1.1 header line exceeds the ' +
        IntToStr(cHttp1MaxHeaderBytes) + '-byte limit', ecProtocolError);
  end;
  if Length(Bytes) = 0 then
    Exit(False);
  if Bytes[High(Bytes)] = 10 then
    SetLength(Bytes, Length(Bytes) - 1);
  if (Length(Bytes) > 0) and (Bytes[High(Bytes)] = 13) then
    SetLength(Bytes, Length(Bytes) - 1);
  SetLength(ALine, Length(Bytes));
  if Length(Bytes) > 0 then
    Move(Bytes[0], ALine[1], Length(Bytes));
  Result := True;
end;

function TBufferedReader.ReadLine(out ALine: string): Boolean;
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
        SetLength(ALine, Len);
        if Len > 0 then
          Move(FBuf[Start], ALine[1], Len);
        FPos := I + 1;
        if (Length(ALine) > 0) and (ALine[Length(ALine)] = #13) then
          SetLength(ALine, Length(ALine) - 1);
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
  N, I: Integer;
  Fields: TArray<THttp1HeaderField>;
begin
  SetLength(Lines, 0);
  N := 0;
  while True do
  begin
    if not FReader.ReadLine(Line) then
      raise EHttpProtocolError.Create('truncated chunked trailer block',
        ecStreamClosed);
    if Line = '' then
      Break;
    SetLength(Lines, N + 1);
    Lines[N] := Line;
    Inc(N);
  end;
  if (N > 0) and (FTrailers <> nil) then
  begin
    Fields := ParseHeaders(Lines);
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
    FDone := True;   // the next Read observes EOF and returns 0
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
      if not FReader.ReadLine(Term) then
        raise EHttpProtocolError.Create('truncated chunked body',
          ecStreamClosed);
      if Term <> '' then
        raise EHttpProtocolError.Create('malformed chunk terminator: ' + Term,
          ecProtocolError);
      FAtChunkEnd := False;
    end;
    if not FReader.ReadLine(Line) then
      raise EHttpProtocolError.Create('truncated chunk-size line',
        ecStreamClosed);
    Size := ParseChunkSize(Line);
    if Size = 0 then
    begin
      ReadTrailers;
      FDone := True;
      FObservedEof := True;   // this Read observes EOF and returns 0
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
  EndExchange(nil, not FDone);
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
