{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, websocket, h2_socket, tunnel
notes:
  - this checks the adapter TH2StreamSocket over a fake tunnel, with no HTTP/2 connection
  - the fake records the calls, so the test checks the order and the count of each call
---
}
unit Http2.Client.WebSocket.H2Socket.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client.Errors, Http2.Client.Tls.Types,
  Http2.Client.Tunnel.Types, Http2.Client.WebSocket.H2Socket;

type
  /// a tunnel without HTTP/2: the test feeds octets in and reads the calls out
  TFakeTunnel = class(TInterfacedObject, IH2Tunnel)
  private
    FPending: TBytes;
    FEnded: Boolean;
    FSent: TBytes;
    FSendCalls: Integer;
    FEndSends: Integer;
    FResets: Integer;
    FReleases: Integer;
    FLastTimeoutMs: Integer;
  public
    /// octets that the next reads return
    procedure Feed(const AText: RawByteString);
    /// the peer ended the stream: a read with no octet left returns 0
    procedure SetEnded;
    procedure SendData(const AData: TBytes);
    procedure EndSend;
    function ReadSome(var ABuffer; ACount: Integer; ATimeoutMs: Integer): Integer;
    procedure Reset;
    function IsEnded: Boolean;
    function EndedAbnormally: Boolean;
    procedure Release;
    property Sent: TBytes read FSent;
    property SendCalls: Integer read FSendCalls;
    property EndSends: Integer read FEndSends;
    property Resets: Integer read FResets;
    property Releases: Integer read FReleases;
    property LastTimeoutMs: Integer read FLastTimeoutMs;
  end;

  TH2StreamSocketTest = class(TTestCase)
  private
    FFake: TFakeTunnel;
    FSock: IHttp2Socket;
    /// read ACount octets with Read; the caller checks the result
    function ReadBuffer(ACount: Integer; out ABuffer: TBytes): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestOctetsPassInOrder;
    procedure TestReadWithNoOctetRaisesTimeout;
    procedure TestReadSomeWithNoOctetRaisesTimeout;
    procedure TestPartialReadReturnsWhatArrived;
    procedure TestReadSomeReturnsAtMostTheCount;
    procedure TestPollUsesTheReadTimeout;
    procedure TestEndOfStreamGivesZero;
    procedure TestWriteSendsTheWholeBuffer;
    procedure TestWriteAfterCloseRaises;
    procedure TestCloseEndsTheStreamOnce;
    procedure TestAbortResetsTheStream;
    procedure TestAbortAfterCloseStillResets;
    procedure TestConnectedFollowsTheState;
    procedure TestSocketIsAbortable;
  end;

implementation

function BytesToRaw(const AData: TBytes): RawByteString;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

{ TFakeTunnel }

procedure TFakeTunnel.Feed(const AText: RawByteString);
var
  Start: Integer;
begin
  Start := Length(FPending);
  SetLength(FPending, Start + Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], FPending[Start], Length(AText));
end;

procedure TFakeTunnel.SetEnded;
begin
  FEnded := True;
end;

procedure TFakeTunnel.SendData(const AData: TBytes);
var
  Start: Integer;
begin
  Inc(FSendCalls);
  Start := Length(FSent);
  SetLength(FSent, Start + Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], FSent[Start], Length(AData));
end;

procedure TFakeTunnel.EndSend;
begin
  Inc(FEndSends);
end;

function TFakeTunnel.ReadSome(var ABuffer; ACount: Integer; ATimeoutMs: Integer): Integer;
var
  N: Integer;
begin
  FLastTimeoutMs := ATimeoutMs;
  if Length(FPending) > 0 then
  begin
    N := Length(FPending);
    if N > ACount then
      N := ACount;
    Move(FPending[0], ABuffer, N);
    Delete(FPending, 0, N);
    Exit(N);
  end;
  if FEnded then
    Exit(0);
  Result := -1;
end;

procedure TFakeTunnel.Reset;
begin
  Inc(FResets);
  FEnded := True;
end;

function TFakeTunnel.IsEnded: Boolean;
begin
  Result := FEnded;
end;

function TFakeTunnel.EndedAbnormally: Boolean;
begin
  Result := FResets > 0;
end;

procedure TFakeTunnel.Release;
begin
  Inc(FReleases);
end;

{ TH2StreamSocketTest }

procedure TH2StreamSocketTest.SetUp;
begin
  FFake := TFakeTunnel.Create;
  FSock := TH2StreamSocket.Create(FFake);
end;

procedure TH2StreamSocketTest.TearDown;
begin
  FSock := nil;
  FFake := nil;
end;

function TH2StreamSocketTest.ReadBuffer(ACount: Integer; out ABuffer: TBytes): Integer;
begin
  SetLength(ABuffer, ACount);
  Result := FSock.Read(ABuffer[0], ACount);
end;

procedure TH2StreamSocketTest.TestOctetsPassInOrder;
var
  Buf: TBytes;
begin
  FFake.Feed('ab');
  FFake.Feed('cde');
  AssertEquals('count', 5, ReadBuffer(5, Buf));
  AssertEquals('octets', 'abcde', BytesToRaw(Buf));
end;

procedure TH2StreamSocketTest.TestReadWithNoOctetRaisesTimeout;
var
  Buf: TBytes;
begin
  try
    ReadBuffer(5, Buf);
    Fail('a read with no octet must raise EHttpTimeout');
  except
    on E: EHttpTimeout do
      ; // expected: the poll found no octet
  end;
end;

procedure TH2StreamSocketTest.TestReadSomeWithNoOctetRaisesTimeout;
var
  PR: IPartialReader;
  Buf: TBytes;
begin
  AssertTrue('the adapter implements IPartialReader', Supports(FSock, IPartialReader, PR));
  SetLength(Buf, 8);
  try
    PR.ReadSome(Buf[0], 8);
    Fail('ReadSome with no octet must raise EHttpTimeout');
  except
    on E: EHttpTimeout do
      ; // expected
  end;
end;

procedure TH2StreamSocketTest.TestPartialReadReturnsWhatArrived;
var
  Buf: TBytes;
begin
  FFake.Feed('ab');
  // two octets arrived, then the poll found none: Read returns the two octets
  AssertEquals('count', 2, ReadBuffer(5, Buf));
  AssertEquals('octets', 'ab', BytesToRaw(Copy(Buf, 0, 2)));
end;

procedure TH2StreamSocketTest.TestReadSomeReturnsAtMostTheCount;
var
  PR: IPartialReader;
  Buf: TBytes;
begin
  AssertTrue(Supports(FSock, IPartialReader, PR));
  FFake.Feed('abcdef');
  SetLength(Buf, 4);
  AssertEquals('first count', 4, PR.ReadSome(Buf[0], 4));
  AssertEquals('first octets', 'abcd', BytesToRaw(Buf));
  AssertEquals('second count', 2, PR.ReadSome(Buf[0], 4));
  AssertEquals('second octets', 'ef', Copy(BytesToRaw(Buf), 1, 2));
end;

procedure TH2StreamSocketTest.TestPollUsesTheReadTimeout;
var
  Buf: TBytes;
begin
  FSock.ReadTimeoutMs := 100;
  FFake.Feed('x');
  ReadBuffer(1, Buf);
  AssertEquals('the poll time of the tunnel', 100, FFake.LastTimeoutMs);
end;

procedure TH2StreamSocketTest.TestEndOfStreamGivesZero;
var
  PR: IPartialReader;
  Buf: TBytes;
begin
  FFake.SetEnded;
  AssertEquals('Read at END_STREAM', 0, ReadBuffer(5, Buf));
  AssertTrue(Supports(FSock, IPartialReader, PR));
  SetLength(Buf, 5);
  AssertEquals('ReadSome at END_STREAM', 0, PR.ReadSome(Buf[0], 5));
end;

procedure TH2StreamSocketTest.TestWriteSendsTheWholeBuffer;
var
  Data, Sent: TBytes;
  I: Integer;
begin
  SetLength(Data, 102400);
  for I := 0 to High(Data) do
    Data[I] := Byte(I * 7);
  AssertEquals('count', 102400, FSock.Write(Data[0], Length(Data)));
  AssertEquals('one tunnel send', 1, FFake.SendCalls);
  Sent := FFake.Sent;
  AssertEquals('length', 102400, Length(Sent));
  AssertTrue('octets as given', CompareMem(@Data[0], @Sent[0], Length(Data)));
end;

procedure TH2StreamSocketTest.TestWriteAfterCloseRaises;
var
  Data: TBytes;
begin
  FSock.Close;
  SetLength(Data, 4);
  try
    FSock.Write(Data[0], 4);
    Fail('a write after Close must raise EHttpConnectionError');
  except
    on E: EHttpConnectionError do
      ; // expected
  end;
  AssertEquals('no tunnel send after Close', 0, FFake.SendCalls);
end;

procedure TH2StreamSocketTest.TestCloseEndsTheStreamOnce;
begin
  FSock.Close;
  FSock.Close;
  AssertEquals('END_STREAM once', 1, FFake.EndSends);
  AssertEquals('released once', 1, FFake.Releases);
  AssertEquals('no reset on a close', 0, FFake.Resets);
end;

procedure TH2StreamSocketTest.TestAbortResetsTheStream;
var
  Ab: IH2Abortable;
begin
  AssertTrue(Supports(FSock, IH2Abortable, Ab));
  Ab.Abort;
  AssertEquals('one reset', 1, FFake.Resets);
  AssertEquals('released', 1, FFake.Releases);
  AssertEquals('no END_STREAM', 0, FFake.EndSends);
  AssertFalse('not connected', FSock.Connected);
end;

procedure TH2StreamSocketTest.TestAbortAfterCloseStillResets;
var
  Ab: IH2Abortable;
begin
  FSock.Close;
  AssertTrue(Supports(FSock, IH2Abortable, Ab));
  Ab.Abort;
  AssertEquals('one reset', 1, FFake.Resets);
end;

procedure TH2StreamSocketTest.TestConnectedFollowsTheState;
begin
  AssertTrue('open at the start', FSock.Connected);
  FFake.SetEnded;
  AssertFalse('not connected when the tunnel ended', FSock.Connected);
end;

procedure TH2StreamSocketTest.TestSocketIsAbortable;
var
  Ab: IH2Abortable;
begin
  AssertTrue('the adapter implements IH2Abortable', Supports(FSock, IH2Abortable, Ab));
end;

initialization
  RegisterTest(TH2StreamSocketTest);
end.
