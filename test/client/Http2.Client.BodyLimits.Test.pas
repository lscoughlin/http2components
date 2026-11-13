{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, test
notes:
  - Tests the response size limits and the decode ratio cap.
---
}
unit Http2.Client.BodyLimits.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Messages,
  Http2.Client.Stream, Http2.Client.Body.Limits, Http2.Client.Encoding,
  Http2.Client.BodyReader, Http2.Client.Pool.Types, Http2.Client.Pool.Http1,
  Http2.Client.Http1, Http2.Client.Http1.Test, Http2.Client,
  Http2.Client.Redirects.Test;

type
  /// a body of ASize bytes, each one $41 (no allocation of the whole body)
  TFillBody = class(TInterfacedObject, IHttpBodyStream)
  private
    FSize: Int64;
    FPos: Int64;
  public
    constructor Create(const ASize: Int64);
    function Read(var ABuffer; const ACount: LongInt): LongInt;
    function Eof: Boolean;
  end;

  /// a body that serves a byte array
  TBytesBody = class(TInterfacedObject, IHttpBodyStream)
  private
    FData: TBytes;
    FPos: Integer;
  public
    constructor Create(const AData: TBytes);
    function Read(var ABuffer; const ACount: LongInt): LongInt;
    function Eof: Boolean;
  end;

  /// a body that reports a scripted count on each Read: the first Read reports
  /// AFirst and the later Reads report ASecond. The buffer is filled only up
  /// to the smaller of the count and ACount, so a huge count costs no memory.
  TReportedCountBody = class(TInterfacedObject, IHttpBodyStream)
  private
    FFirst: LongInt;
    FSecond: LongInt;
    FCalls: Integer;
  public
    constructor Create(const AFirst, ASecond: LongInt);
    function Read(var ABuffer; const ACount: LongInt): LongInt;
    function Eof: Boolean;
    function CallCount: Integer;
  end;

  /// a response with a body and headers
  TBodyResponse = class(TInterfacedObject, IHttpResponse)
  private
    FHeaders: IHttpHeaders;
    FBody: IHttpBodyStream;
  public
    constructor Create(const ABody: IHttpBodyStream);
    function GetStatusCode: LongInt;
    function GetHeaders: IHttpHeaders;
    function GetBody: IHttpBodyStream;
  end;

  TBodyLimitsTest = class(TTestCase)
  private
    function BytesOf(const AText: string): TBytes;
    function Zeros(const ASize: Integer): TBytes;
    function Noise(const ASize: Integer): TBytes;
    /// read ABody to its end in 1 KiB reads; ARejected is True when a read
    // raised EHttpResponseTooLarge
    function ReadCount(const ABody: IHttpBodyStream;
      out ARejected: Boolean): Int64;
    /// the HTTP/1.1 pooled connection reads AWire; the result is the byte count
    function Http1Read(const AWire: string; const AOption: Int64;
      const ARequestSet: Boolean; const ARequestValue: Int64;
      out ARejected: Boolean): Int64;
  published
    procedure TestLimitedBodyRaisesPastTheLimit;
    procedure TestLimitedBodyAllowsTheExactLimit;
    procedure TestLimitedBodyZeroMeansNoLimit;
    procedure TestResponseTooLargeIsAnHttpError;
    procedure TestDecodedLimitRaisesPastTheLimit;
    procedure TestRatioCapRaisesOnAHighRatio;
    procedure TestRatioCapPassesAnIncompressibleBody;
    procedure TestRatioCapFloorKeepsASmallBodyWhole;
    procedure TestRatioZeroTurnsTheCapOff;
    procedure TestUnsolicitedCodingIsLeftAlone;
    procedure TestSolicitedCodingIsDecoded;
    procedure TestReadAllBodyBytesGrowsPastTheInitialBuffer;
    procedure TestReadAllBodyBytesRaisesPastTwoGiB;
    procedure TestTypedReaderPassesTheTwoGiBRaise;
    procedure TestHttp1ResponseOverTheOptionRaises;
    procedure TestHttp1RequestOverrideRaises;
    procedure TestHttp1RequestOverrideZeroIsUnlimited;
    procedure TestHttp2ResponseOverTheOptionRaises;
    procedure TestHttp2RequestOverrideRaises;
  end;

procedure RegisterTests;

implementation

{ TFillBody }

constructor TFillBody.Create(const ASize: Int64);
begin
  inherited Create;
  FSize := ASize;
  FPos := 0;
end;

function TFillBody.Read(var ABuffer; const ACount: LongInt): LongInt;
var
  Take: Int64;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  Take := FSize - FPos;
  if Take <= 0 then
    Exit;
  if Take > ACount then
    Take := ACount;
  FillChar(ABuffer, Take, $41);
  Inc(FPos, Take);
  Result := LongInt(Take);
end;

function TFillBody.Eof: Boolean;
begin
  Result := FPos >= FSize;
end;

{ TBytesBody }

constructor TBytesBody.Create(const AData: TBytes);
begin
  inherited Create;
  FData := Copy(AData, 0, Length(AData));
  FPos := 0;
end;

function TBytesBody.Read(var ABuffer; const ACount: LongInt): LongInt;
var
  Left, Take: Integer;
begin
  Result := 0;
  if ACount <= 0 then
    Exit;
  Left := Length(FData) - FPos;
  if Left <= 0 then
    Exit;
  Take := ACount;
  if Take > Left then
    Take := Left;
  Move(FData[FPos], ABuffer, Take);
  Inc(FPos, Take);
  Result := Take;
end;

function TBytesBody.Eof: Boolean;
begin
  Result := FPos >= Length(FData);
end;

{ TReportedCountBody }

constructor TReportedCountBody.Create(const AFirst, ASecond: LongInt);
begin
  inherited Create;
  FFirst := AFirst;
  FSecond := ASecond;
  FCalls := 0;
end;

function TReportedCountBody.Read(var ABuffer; const ACount: LongInt): LongInt;
var
  Take: LongInt;
begin
  Inc(FCalls);
  if FCalls = 1 then
    Result := FFirst
  else
    Result := FSecond;
  Take := Result;
  if Take > ACount then
    Take := ACount;
  if Take > 0 then
    FillChar(ABuffer, Take, $41);
end;

function TReportedCountBody.Eof: Boolean;
begin
  Result := FCalls >= 2;
end;

function TReportedCountBody.CallCount: Integer;
begin
  Result := FCalls;
end;

{ TBodyResponse }

constructor TBodyResponse.Create(const ABody: IHttpBodyStream);
begin
  inherited Create;
  FHeaders := NewHttpHeaders;
  FBody := ABody;
end;

function TBodyResponse.GetStatusCode: LongInt;
begin
  Result := 200;
end;

function TBodyResponse.GetHeaders: IHttpHeaders;
begin
  Result := FHeaders;
end;

function TBodyResponse.GetBody: IHttpBodyStream;
begin
  Result := FBody;
end;

{ TBodyLimitsTest }

function TBodyLimitsTest.BytesOf(const AText: string): TBytes;
begin
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function TBodyLimitsTest.Zeros(const ASize: Integer): TBytes;
begin
  SetLength(Result, ASize);
  if ASize > 0 then
    FillChar(Result[0], ASize, 0);
end;

function TBodyLimitsTest.Noise(const ASize: Integer): TBytes;
var
  I: Integer;
  X: Int64;
begin
  // a linear congruential generator: the bytes do not compress
  SetLength(Result, ASize);
  X := 12345;
  for I := 0 to ASize - 1 do
  begin
    X := (X * 1103515245 + 12345) and $7FFFFFFF;
    Result[I] := Byte(X shr 16);
  end;
end;

function TBodyLimitsTest.ReadCount(const ABody: IHttpBodyStream;
  out ARejected: Boolean): Int64;
var
  Buf: array[0..1023] of Byte;
  N: LongInt;
begin
  Result := 0;
  ARejected := False;
  try
    repeat
      N := ABody.Read(Buf, SizeOf(Buf));
      if N > 0 then
        Inc(Result, N);
    until N <= 0;
  except
    on E: EHttpResponseTooLarge do
      ARejected := True;
  end;
end;

function TBodyLimitsTest.Http1Read(const AWire: string;
  const AOption: Int64; const ARequestSet: Boolean;
  const ARequestValue: Int64; out ARejected: Boolean): Int64;
var
  Sock: TSocketScript;
  H1: THttp1Connection;
  Pooled: THttp1PooledConnection;
  Conn: IPooledConnection;
  Req: TStreamRequest;
  Acquired: Boolean;
  Resp: IHttpResponse;
begin
  Sock := TSocketScript.Create;
  Sock.Feed(AWire);
  H1 := THttp1Connection.Create(Sock);
  Pooled := THttp1PooledConnection.Create(H1, 'http://h1.example');
  // the pooled connection owns H1 from here on
  Conn := Pooled;
  Pooled.MaxResponseBytes := AOption;
  Req := TStreamRequest.Create('GET', 'h1.example').WithPath('/a');
  if ARequestSet then
  begin
    Req.MaxResponseBytes := ARequestValue;
    Req.MaxResponseBytesSet := True;
  end;
  Resp := Conn.Acquire(Req, 1000, Acquired);
  AssertTrue('the request was acquired', Acquired);
  Result := ReadCount(Resp.Body, ARejected);
  Resp := nil;
  Conn := nil;
end;

procedure TBodyLimitsTest.TestLimitedBodyRaisesPastTheLimit;
var
  Body: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  Body := TLimitedBodyStream.Create(TBytesBody.Create(Zeros(100)), 50);
  Count := ReadCount(Body, Rejected);
  AssertTrue('a 100 byte body with a limit of 50 raises', Rejected);
  AssertTrue('no more than the limit was returned', Count <= 50);
end;

procedure TBodyLimitsTest.TestLimitedBodyAllowsTheExactLimit;
var
  Body: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  Body := TLimitedBodyStream.Create(TBytesBody.Create(Zeros(100)), 100);
  Count := ReadCount(Body, Rejected);
  AssertFalse('a body of exactly the limit passes', Rejected);
  AssertEquals('all bytes read', Int64(100), Count);
end;

procedure TBodyLimitsTest.TestLimitedBodyZeroMeansNoLimit;
var
  Body: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  // a 64 MiB body streams through with no limit; nothing is held in memory
  Body := TLimitedBodyStream.Create(TFillBody.Create(64 * 1024 * 1024), 0);
  Count := ReadCount(Body, Rejected);
  AssertFalse('limit 0 never raises', Rejected);
  AssertEquals('the whole 64 MiB body is read', Int64(64 * 1024 * 1024), Count);
end;

procedure TBodyLimitsTest.TestResponseTooLargeIsAnHttpError;
var
  E: EHttpResponseTooLarge;
begin
  E := EHttpResponseTooLarge.Create('too large');
  try
    AssertTrue('the class derives from EHttpError', E is EHttpError);
  finally
    E.Free;
  end;
end;

procedure TBodyLimitsTest.TestDecodedLimitRaisesPastTheLimit;
var
  Inner: IHttpResponse;
  Wrapped: IHttpResponse;
  Rejected: Boolean;
begin
  // 4 KiB of zeros gzips to a few dozen bytes; the decoded limit is 1 KiB
  Inner := TBodyResponse.Create(TBytesBody.Create(GzipCompress(Zeros(4096))));
  Inner.Headers.Add(HeaderContentEncoding, 'gzip');
  Wrapped := WrapDecodingResponse(Inner, True, 1024, 0);
  ReadCount(Wrapped.Body, Rejected);
  AssertTrue('the decoded body past 1 KiB raises', Rejected);
end;

procedure TBodyLimitsTest.TestRatioCapRaisesOnAHighRatio;
var
  Stream: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  // 64 KiB of zeros gzips to about 70 bytes: a ratio of about 900:1, above 10:1
  Stream := TDecodingBodyStream.Create(
    TBytesBody.Create(GzipCompress(Zeros(65536))), ceGzip, 10, 4096);
  Count := ReadCount(Stream, Rejected);
  AssertTrue('a body over the ratio raises past the floor', Rejected);
  AssertTrue('no more than the floor was returned', Count <= 4096);
end;

procedure TBodyLimitsTest.TestRatioCapPassesAnIncompressibleBody;
var
  Stream: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  // 16 KiB of noise gzips to about its own size: the ratio is near 1:1
  Stream := TDecodingBodyStream.Create(
    TBytesBody.Create(GzipCompress(Noise(16384))), ceGzip, 10, 4096);
  Count := ReadCount(Stream, Rejected);
  AssertFalse('a body under the ratio passes', Rejected);
  AssertEquals('all decoded bytes read', Int64(16384), Count);
end;

procedure TBodyLimitsTest.TestRatioCapFloorKeepsASmallBodyWhole;
var
  Stream: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  // the default floor is 1 MiB: 64 KiB of zeros never reaches the check
  Stream := TDecodingBodyStream.Create(
    TBytesBody.Create(GzipCompress(Zeros(65536))), ceGzip, 10);
  Count := ReadCount(Stream, Rejected);
  AssertFalse('a small body passes the default floor', Rejected);
  AssertEquals('the whole body decodes', Int64(65536), Count);
end;

procedure TBodyLimitsTest.TestRatioZeroTurnsTheCapOff;
var
  Stream: IHttpBodyStream;
  Rejected: Boolean;
  Count: Int64;
begin
  Stream := TDecodingBodyStream.Create(
    TBytesBody.Create(GzipCompress(Zeros(65536))), ceGzip, 0, 4096);
  Count := ReadCount(Stream, Rejected);
  AssertFalse('ratio 0 never raises', Rejected);
  AssertEquals('the whole body decodes', Int64(65536), Count);
end;

procedure TBodyLimitsTest.TestUnsolicitedCodingIsLeftAlone;
var
  Gz: TBytes;
  Inner: IHttpResponse;
  Wrapped: IHttpResponse;
  Rejected: Boolean;
begin
  Gz := GzipCompress(BytesOf('not asked for'));
  Inner := TBodyResponse.Create(TBytesBody.Create(Gz));
  Inner.Headers.Add(HeaderContentEncoding, 'gzip');
  Wrapped := WrapDecodingResponse(Inner, False);
  AssertTrue('the response is returned unchanged', Wrapped = Inner);
  AssertEquals('the coding header stays', 'gzip',
    Wrapped.Headers.GetFirst(HeaderContentEncoding));
  AssertEquals('the body stays coded', Int64(Length(Gz)),
    ReadCount(Wrapped.Body, Rejected));
end;

procedure TBodyLimitsTest.TestSolicitedCodingIsDecoded;
var
  Inner: IHttpResponse;
  Wrapped: IHttpResponse;
  Got, Expected: TBytes;
begin
  Inner := TBodyResponse.Create(
    TBytesBody.Create(GzipCompress(BytesOf('asked for'))));
  Inner.Headers.Add(HeaderContentEncoding, 'gzip');
  Wrapped := WrapDecodingResponse(Inner, True);
  AssertEquals('the coding header is removed', '',
    Wrapped.Headers.GetFirst(HeaderContentEncoding));
  Got := ReadAllBodyBytes(Wrapped.Body);
  Expected := BytesOf('asked for');
  AssertEquals('the body decodes', Length(Expected), Length(Got));
  AssertTrue('the body decodes to the text',
    CompareMem(@Got[0], @Expected[0], Length(Expected)));
end;

procedure TBodyLimitsTest.TestReadAllBodyBytesGrowsPastTheInitialBuffer;
var
  Got: TBytes;
begin
  // 300 KiB needs several doublings of the result buffer
  Got := ReadAllBodyBytes(TFillBody.Create(300 * 1024));
  AssertEquals('every byte is kept', 300 * 1024, Length(Got));
  AssertEquals('the first byte', $41, Integer(Got[0]));
  AssertEquals('the last byte', $41, Integer(Got[High(Got)]));
end;

procedure TBodyLimitsTest.TestReadAllBodyBytesRaisesPastTwoGiB;
var
  Body: IHttpBodyStream;
  Counted: TReportedCountBody;
  Raised: Boolean;
begin
  // the first read reports 4 KiB; the second reports the largest LongInt, so
  // the total passes High(Integer) before the result buffer grows, and no
  // 2 GiB buffer is allocated
  Counted := TReportedCountBody.Create(4096, High(LongInt));
  Body := Counted;
  Raised := False;
  try
    ReadAllBodyBytes(Body);
  except
    on E: EHttpResponseTooLarge do
      Raised := True;
  end;
  AssertTrue('a total past 2 GiB raises', Raised);
  AssertEquals('the read stops at the overflowing read', 2,
    Counted.CallCount);
end;

procedure TBodyLimitsTest.TestTypedReaderPassesTheTwoGiBRaise;
var
  Resp: IHttpResponse;
  Text: string;
  Raised: Boolean;
begin
  // TResponseReader<T> does not catch the error: it reaches the caller
  Resp := TBodyResponse.Create(
    TReportedCountBody.Create(4096, High(LongInt)));
  Raised := False;
  try
    TResponseReader<string>.Read(Resp, Text);
  except
    on E: EHttpResponseTooLarge do
      Raised := True;
  end;
  AssertTrue('the typed reader raises past 2 GiB', Raised);
end;

procedure TBodyLimitsTest.TestHttp1ResponseOverTheOptionRaises;
var
  Rejected: Boolean;
begin
  // the client option is 50 bytes; the response body is 100 bytes
  Http1Read('HTTP/1.1 200 OK'#13#10'Content-Length: 100'#13#10#13#10 +
    StringOfChar('x', 100), 50, False, 0, Rejected);
  AssertTrue('an HTTP/1 body over the option raises', Rejected);
end;

procedure TBodyLimitsTest.TestHttp1RequestOverrideRaises;
var
  Rejected: Boolean;
begin
  // the client option is unlimited; the request sets 50 bytes
  Http1Read('HTTP/1.1 200 OK'#13#10'Content-Length: 100'#13#10#13#10 +
    StringOfChar('x', 100), 0, True, 50, Rejected);
  AssertTrue('the request override applies', Rejected);
end;

procedure TBodyLimitsTest.TestHttp1RequestOverrideZeroIsUnlimited;
var
  Rejected: Boolean;
  Count: Int64;
begin
  // the client option is 50 bytes; the request sets 0, which means no limit
  Count := Http1Read('HTTP/1.1 200 OK'#13#10'Content-Length: 100'#13#10#13#10 +
    StringOfChar('x', 100), 50, True, 0, Rejected);
  AssertFalse('a request value of 0 overrides the option', Rejected);
  AssertEquals('all 100 bytes read', Int64(100), Count);
end;

procedure TBodyLimitsTest.TestHttp2ResponseOverTheOptionRaises;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Rejected: Boolean;
begin
  // the client option is 50 bytes; the HTTP/2 body is 100 bytes
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '',
    BytesOf(StringOfChar('x', 100)), True)]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory)
    .WithMaxResponseBytes(50).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://h2.example/x'));
  ReadCount(R.Body, Rejected);
  AssertTrue('an HTTP/2 body over the option raises', Rejected);
  Client.Close;
end;

procedure TBodyLimitsTest.TestHttp2RequestOverrideRaises;
var
  Factory: TFakeFrameFactory;
  Client: IHttpClient;
  R: IHttpResponse;
  Rejected: Boolean;
begin
  // the client option is unlimited; the request sets 50 bytes
  Factory := TFakeFrameFactory.Create;
  Factory.SetDialScript(0, SpecArray([HdrSpec('200', '',
    BytesOf(StringOfChar('x', 100)), True)]));
  Client := THttpClientFactory.Create.WithSocketFactory(Factory).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://h2.example/x')
    .WithMaxResponseBytes(50));
  ReadCount(R.Body, Rejected);
  AssertTrue('the request override applies on HTTP/2', Rejected);
  Client.Close;
end;

procedure RegisterTests;
begin
  RegisterTest(TBodyLimitsTest);
end;

initialization
  RegisterTests;

end.
