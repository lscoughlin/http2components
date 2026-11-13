{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, http1, deadline, trailer
notes:
  - This unit tests the limits of the HTTP/1.1 trailer block, the response head and the CONNECT reply (S-27a).
  - The trickle peers serve one byte per read after a pause, as a slow peer does. Their short pauses keep the run fast.
---
}
unit Http2.Client.PhaseDeadline.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Headers, Http2.Client.Stream, Http2.Client.Messages,
  Http2.Client.Http1, Http2.Client.Tls, Http2.Client.Socks, Http2.Client.Tls.Tunnel,
  Http2.Client.ClearText.Support;

type
  /// a socket that serves one byte per Read after a pause, then EOF.  It
  /// ignores ReadTimeoutMs, so only the client's own deadline can cut it.
  TTrickleSocket = class(TInterfacedObject, IHttp2Socket)
  private
    FData: TBytes;
    FPos: Integer;
    FDelayMs: Integer;
    FConnectTimeoutMs: Integer;
    FReadTimeoutMs: Integer;
    FWriteTimeoutMs: Integer;
  public
    constructor Create(const AText: string; const ADelayMs: Integer);
    function Read(var ABuffer; ACount: Integer): Integer;
    function Write(const ABuffer; ACount: Integer): Integer;
    procedure Close;
    function GetConnected: Boolean;
    function GetConnectTimeoutMs: Integer;
    procedure SetConnectTimeoutMs(const AValue: Integer);
    function GetReadTimeoutMs: Integer;
    procedure SetReadTimeoutMs(const AValue: Integer);
    function GetWriteTimeoutMs: Integer;
    procedure SetWriteTimeoutMs(const AValue: Integer);
  end;

  /// an ISocksChannel that serves one byte per ReadSome after a pause, then EOF
  TTrickleChannel = class(TInterfacedObject, ISocksChannel)
  private
    FData: TBytes;
    FPos: Integer;
    FDelayMs: Integer;
  public
    constructor Create(const AText: string; const ADelayMs: Integer);
    procedure WriteAll(const AData: TBytes);
    function ReadSome(var ABuffer; const ACount: Integer): Integer;
  end;

  /// the trailer block limits of a chunked body (RFC 9112 section 7.1.2)
  TTrailerLimitTest = class(TTestCase)
  published
    procedure TestMillionTrailerLinesRaises;
    procedure TestTrailerBytesOverLimitRaises;
    procedure TestTwoHundredFiftySixTrailerLinesAccepted;
  end;

  /// the response head deadline, the head line limit and the CONNECT reply
  /// deadline and interim limit
  TPhaseDeadlineTest = class(TTestCase)
  published
    procedure TestHeadDeadlineCutsTrickle;
    procedure TestHeadWithTooManyLinesRaises;
    procedure TestTwoHundredFiftySixHeadLinesAccepted;
    procedure TestConnectReplyDeadlineCutsTrickle;
    procedure TestSeventeenInterimConnectRepliesRaise;
    procedure TestSixteenInterimConnectRepliesAccepted;
  end;

implementation

const
  cTrickleDelayMs = 500;

function BytesOfText(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

/// a chunked response whose trailer block holds ALines lines of ALineLen bytes
/// each (without the CRLF)
function TrailerScript(const ALines, ALineLen: Integer): TBytes;
var
  Head, Line: TBytes;
  I, Off: Integer;
begin
  Head := BytesOfText('HTTP/1.1 200 OK'#13#10'Transfer-Encoding: chunked'#13#10#13#10 +
    '0'#13#10);
  Line := BytesOfText('x-t: ' + StringOfChar('v', ALineLen - 5) + #13#10);
  SetLength(Result, Length(Head) + ALines * Length(Line) + 2);
  Move(Head[0], Result[0], Length(Head));
  Off := Length(Head);
  for I := 1 to ALines do
  begin
    Move(Line[0], Result[Off], Length(Line));
    Inc(Off, Length(Line));
  end;
  Result[Off] := 13;
  Result[Off + 1] := 10;
end;

/// a response head with ALines field lines
function HeadWithLines(const ALines: Integer): string;
var
  I: Integer;
begin
  Result := 'HTTP/1.1 200 OK'#13#10;
  for I := 1 to ALines do
    Result := Result + 'X-N' + IntToStr(I) + ': v'#13#10;
  Result := Result + #13#10 + 'abc';
end;

function StartRequest: TStreamRequest;
begin
  Result := TStreamRequest.Create('GET', 'example.com').WithPath('/');
end;

/// read a body until its end, raising whatever the body raises
procedure DrainBodyStream(const ABody: IHttpBodyStream);
var
  Buf: array[0..1023] of Byte;
  N: Integer;
begin
  repeat
    N := ABody.Read(Buf[0], SizeOf(Buf));
  until N <= 0;
end;

{ TTrickleSocket }

constructor TTrickleSocket.Create(const AText: string; const ADelayMs: Integer);
begin
  inherited Create;
  FData := BytesOfText(AText);
  FPos := 0;
  FDelayMs := ADelayMs;
  FReadTimeoutMs := 0;
  FConnectTimeoutMs := 0;
  FWriteTimeoutMs := 0;
end;

function TTrickleSocket.Read(var ABuffer; ACount: Integer): Integer;
begin
  if (FPos >= Length(FData)) or (ACount <= 0) then
    Exit(0);
  Sleep(FDelayMs);
  PByte(@ABuffer)^ := FData[FPos];
  Inc(FPos);
  Result := 1;
end;

function TTrickleSocket.Write(const ABuffer; ACount: Integer): Integer;
begin
  Result := ACount;
end;

procedure TTrickleSocket.Close;
begin
end;

function TTrickleSocket.GetConnected: Boolean;
begin
  Result := True;
end;

function TTrickleSocket.GetConnectTimeoutMs: Integer;
begin
  Result := FConnectTimeoutMs;
end;

procedure TTrickleSocket.SetConnectTimeoutMs(const AValue: Integer);
begin
  FConnectTimeoutMs := AValue;
end;

function TTrickleSocket.GetReadTimeoutMs: Integer;
begin
  Result := FReadTimeoutMs;
end;

procedure TTrickleSocket.SetReadTimeoutMs(const AValue: Integer);
begin
  FReadTimeoutMs := AValue;
end;

function TTrickleSocket.GetWriteTimeoutMs: Integer;
begin
  Result := FWriteTimeoutMs;
end;

procedure TTrickleSocket.SetWriteTimeoutMs(const AValue: Integer);
begin
  FWriteTimeoutMs := AValue;
end;

{ TTrickleChannel }

constructor TTrickleChannel.Create(const AText: string; const ADelayMs: Integer);
begin
  inherited Create;
  FData := BytesOfText(AText);
  FPos := 0;
  FDelayMs := ADelayMs;
end;

procedure TTrickleChannel.WriteAll(const AData: TBytes);
begin
end;

function TTrickleChannel.ReadSome(var ABuffer; const ACount: Integer): Integer;
begin
  if (FPos >= Length(FData)) or (ACount <= 0) then
    Exit(0);
  if FDelayMs > 0 then
    Sleep(FDelayMs);
  PByte(@ABuffer)^ := FData[FPos];
  Inc(FPos);
  Result := 1;
end;

{ TTrailerLimitTest }

procedure TTrailerLimitTest.TestMillionTrailerLinesRaises;
var
  Sock: TScriptSocket;
  Conn: THttp1Connection;
  Resp: IHttpResponse;
  Raised: Boolean;
begin
  Sock := TScriptSocket.Create;
  Sock.FeedBytes(TrailerScript(1000000, 6));
  Conn := THttp1Connection.Create(Sock);
  try
    Raised := False;
    try
      AssertTrue('head read', Conn.BeginResponse(StartRequest));
      Resp := Conn.FinishResponse;
      DrainBodyStream(Resp.Body);
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('a trailer block of 1000000 lines raises EHttpProtocolError', Raised);
  finally
    Conn.Free;
  end;
end;

procedure TTrailerLimitTest.TestTrailerBytesOverLimitRaises;
var
  Sock: TScriptSocket;
  Conn: THttp1Connection;
  Resp: IHttpResponse;
  Raised: Boolean;
begin
  // 256 lines of 300 bytes: within the line limit, over the 64 KiB byte limit
  Sock := TScriptSocket.Create;
  Sock.FeedBytes(TrailerScript(256, 300));
  Conn := THttp1Connection.Create(Sock);
  try
    Raised := False;
    try
      AssertTrue('head read', Conn.BeginResponse(StartRequest));
      Resp := Conn.FinishResponse;
      DrainBodyStream(Resp.Body);
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('a trailer block over 65536 bytes raises', Raised);
  finally
    Conn.Free;
  end;
end;

procedure TTrailerLimitTest.TestTwoHundredFiftySixTrailerLinesAccepted;
var
  Sock: TScriptSocket;
  Conn: THttp1Connection;
  Resp: IHttpResponse;
begin
  Sock := TScriptSocket.Create;
  Sock.FeedBytes(TrailerScript(256, 6));
  Conn := THttp1Connection.Create(Sock);
  try
    AssertTrue('head read', Conn.BeginResponse(StartRequest));
    Resp := Conn.FinishResponse;
    DrainBodyStream(Resp.Body);
    AssertTrue('256 trailer lines are within the limit', Resp.Body.Eof);
  finally
    Conn.Free;
  end;
end;

{ TPhaseDeadlineTest }

procedure TPhaseDeadlineTest.TestHeadDeadlineCutsTrickle;
var
  Sock: TTrickleSocket;
  Conn: THttp1Connection;
  Started: QWord;
  Elapsed: QWord;
  Raised: Boolean;
begin
  // the status line starts with "HTTP/1.1 2" and then the peer stalls at EOF;
  // a head that trickles one byte per 500 ms must be cut at the 2 s deadline
  Sock := TTrickleSocket.Create('HTTP/1.1 200 OK'#13#10'X-A: 1'#13#10#13#10, cTrickleDelayMs);
  Conn := THttp1Connection.Create(Sock, 2000);
  try
    Raised := False;
    Started := GetTickCount64;
    try
      Conn.BeginResponse(StartRequest);
    except
      on E: EHttpTimeout do
        Raised := True;
    end;
    Elapsed := GetTickCount64 - Started;
    AssertTrue('the head deadline raises EHttpTimeout', Raised);
    AssertTrue('the head is cut near the 2 s deadline, not at the peer pace',
      (Elapsed >= 1500) and (Elapsed <= 4000));
  finally
    Conn.Free;
  end;
end;

procedure TPhaseDeadlineTest.TestHeadWithTooManyLinesRaises;
var
  Sock: TScriptSocket;
  Conn: THttp1Connection;
  Raised: Boolean;
begin
  Sock := TScriptSocket.Create;
  Sock.Feed(HeadWithLines(300));
  Conn := THttp1Connection.Create(Sock);
  try
    AssertTrue('status line read', Conn.BeginResponse(StartRequest));
    Raised := False;
    try
      Conn.FinishResponse;
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('a response with 300 header lines raises', Raised);
  finally
    Conn.Free;
  end;
end;

procedure TPhaseDeadlineTest.TestTwoHundredFiftySixHeadLinesAccepted;
var
  Sock: TScriptSocket;
  Conn: THttp1Connection;
  Resp: IHttpResponse;
begin
  Sock := TScriptSocket.Create;
  Sock.Feed(HeadWithLines(256));
  Conn := THttp1Connection.Create(Sock);
  try
    AssertTrue('status line read', Conn.BeginResponse(StartRequest));
    Resp := Conn.FinishResponse;
    AssertEquals('status', 200, Resp.StatusCode);
  finally
    Conn.Free;
  end;
end;

procedure TPhaseDeadlineTest.TestConnectReplyDeadlineCutsTrickle;
var
  Ch: ISocksChannel;
  Started, Elapsed: QWord;
  Raised: Boolean;
begin
  // a proxy that answers one byte per 500 ms: the reply must be cut at 2 s
  Ch := TTrickleChannel.Create('HTTP/1.1 200 OK'#13#10#13#10, cTrickleDelayMs);
  Raised := False;
  Started := GetTickCount64;
  try
    EstablishConnectTunnel(Ch, 'example.com', 443, '', '', 2000);
  except
    on E: EHttpTimeout do
      Raised := True;
  end;
  Elapsed := GetTickCount64 - Started;
  AssertTrue('the CONNECT deadline raises EHttpTimeout', Raised);
  AssertTrue('the CONNECT reply is cut near the 2 s deadline',
    (Elapsed >= 1500) and (Elapsed <= 4000));
end;

procedure TPhaseDeadlineTest.TestSeventeenInterimConnectRepliesRaise;
var
  Ch: ISocksChannel;
  Text: string;
  I: Integer;
  Raised: Boolean;
begin
  Text := '';
  for I := 1 to 17 do
    Text := Text + 'HTTP/1.1 100 Continue'#13#10#13#10;
  Ch := TTrickleChannel.Create(Text + 'HTTP/1.1 200 OK'#13#10#13#10, 0);
  Raised := False;
  try
    EstablishConnectTunnel(Ch, 'example.com', 443, '', '');
  except
    on E: EHttpConnectionError do
      Raised := True;
  end;
  AssertTrue('a 17th interim CONNECT reply raises', Raised);
end;

procedure TPhaseDeadlineTest.TestSixteenInterimConnectRepliesAccepted;
var
  Ch: ISocksChannel;
  Text: string;
  I: Integer;
begin
  Text := '';
  for I := 1 to 16 do
    Text := Text + 'HTTP/1.1 100 Continue'#13#10#13#10;
  Ch := TTrickleChannel.Create(Text + 'HTTP/1.1 200 OK'#13#10#13#10, 0);
  EstablishConnectTunnel(Ch, 'example.com', 443, '', '');
end;

initialization
  RegisterTest(TTrailerLimitTest);
  RegisterTest(TPhaseDeadlineTest);
end.
