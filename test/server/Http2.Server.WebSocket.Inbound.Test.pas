{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, inbound, pipe, body reader, test, fpcunit
notes:
  - These tests drive TWsMessagePipe and TWsMemoryReader of
    Http2.Server.WebSocket.Inbound with no session. The thread tests use one writer
    thread and one reader thread. Each wait has a deadline, so a hang fails the test.
---
}
/// Tests of the readers that give a WebSocket message to a handler
unit Http2.Server.WebSocket.Inbound.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Common.Body, Http2.Server.Errors, Http2.Server.WebSocket.Inbound;

type
  /// pushes numbered chunks into a pipe and then finishes it
  TPushThread = class(TThread)
  private
    FPipe: TWsMessagePipe;
    FChunks, FSize: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const APipe: TWsMessagePipe; const AChunks, ASize: Integer);
  end;

  /// reads a pipe to its end and keeps the outcome
  TReadThread = class(TThread)
  private
    FReader: IBodyReader;
  protected
    procedure Execute; override;
  public
    Data: TBytes;
    Cancelled: Boolean;
    constructor Create(const AReader: IBodyReader);
  end;

  TWsInboundPipeTest = class(TTestCase)
  private
    FTaken: Integer;
    FStalledCount: Integer;
    procedure Taken(const ACount: Integer);
    procedure Stalled;
    function NewPipe(const ACap: Integer = 1048576; const AStallMs: Integer = 0): TWsMessagePipe;
    function ReadCount(const AReader: IBodyReader; const ACount: Integer): TBytes;
  published
    procedure TestMemoryReaderReadsInPieces;
    procedure TestMemoryReaderChunkAndRepeatedEnd;
    procedure TestEmptyMemoryReaderEnds;
    procedure TestPushThenReadKeepsOrder;
    procedure TestReadGivesLessThanAsked;
    procedure TestTakenCountsTheOctetsRead;
    procedure TestReadChunkGivesPushedChunks;
    procedure TestReadChunkAfterPartialRead;
    procedure TestFinishKeepsTheBufferReadableThenEnds;
    procedure TestEndRepeatsOnReadAndReadChunk;
    procedure TestAbortRaisesOnRead;
    procedure TestAbortDropsAndReportsTheBuffer;
    procedure TestAbortAfterFinishChangesNothing;
    procedure TestPushNeverBlocksAfterAbort;
    procedure TestStallAbortsAndRaises;
    procedure TestStallDoesNotFireWhileOctetsArrive;
    procedure TestOverflowRefusesAndAborts;
    procedure TestOverflowAtTheCapIsAllowed;
    procedure TestReadAllBodyOverPipe;
    procedure TestWriterThreadAndReaderThread;
    procedure TestAbortWakesABlockedReader;
    procedure TestReadChunkOnAThread;
    procedure TestPrepaidOctetsGiveNoCreditOnRead;
    procedure TestPrepaidOctetsAreNotCreditedWhenDropped;
    procedure TestReleaseDropsAFinishedBufferAndCredits;
    procedure TestReleaseCreditsLaterPushesUntilFinish;
  end;

implementation

{ TPushThread }

constructor TPushThread.Create(const APipe: TWsMessagePipe; const AChunks, ASize: Integer);
begin
  FPipe := APipe;
  FChunks := AChunks;
  FSize := ASize;
  inherited Create(False);
end;

procedure TPushThread.Execute;
var
  I, J, Seq: Integer;
  Buf: TBytes;
begin
  SetLength(Buf, FSize);
  Seq := 0;
  for I := 1 to FChunks do
  begin
    for J := 0 to FSize - 1 do
    begin
      Buf[J] := Byte(Seq and $FF);
      Inc(Seq);
    end;
    if not FPipe.Push(Buf[0], FSize) then
      Exit;
    // let the reader catch up now and then, so the pipe is empty at times
    if I mod 7 = 0 then
      Sleep(1);
  end;
  FPipe.Finish;
end;

{ TReadThread }

constructor TReadThread.Create(const AReader: IBodyReader);
begin
  FReader := AReader;
  inherited Create(False);
end;

procedure TReadThread.Execute;
var
  Buf: array[0..999] of Byte;
  N, Len: Integer;
begin
  Len := 0;
  try
    repeat
      N := FReader.Read(Buf[0], 1 + (Len mod 1000));
      if N > 0 then
      begin
        SetLength(Data, Len + N);
        Move(Buf[0], Data[Len], N);
        Inc(Len, N);
      end;
    until N = 0;
  except
    on EStreamCancelled do
      Cancelled := True;
  end;
end;

{ TWsInboundPipeTest }

procedure TWsInboundPipeTest.Taken(const ACount: Integer);
begin
  Inc(FTaken, ACount);
end;

procedure TWsInboundPipeTest.Stalled;
begin
  Inc(FStalledCount);
end;

function TWsInboundPipeTest.NewPipe(const ACap, AStallMs: Integer): TWsMessagePipe;
begin
  Result := TWsMessagePipe.Create(ACap, AStallMs, Taken, Stalled);
end;

function TWsInboundPipeTest.ReadCount(const AReader: IBodyReader; const ACount: Integer): TBytes;
var
  N: Integer;
begin
  SetLength(Result, ACount);
  N := AReader.Read(Result[0], ACount);
  SetLength(Result, N);
end;

procedure TWsInboundPipeTest.TestMemoryReaderReadsInPieces;
var
  R: IBodyReader;
  B: TBytes;
begin
  R := TWsMemoryReader.Create(TBytes.Create(1, 2, 3, 4, 5));
  B := ReadCount(R, 2);
  AssertEquals(2, Length(B));
  AssertEquals(2, B[1]);
  B := ReadCount(R, 10);
  AssertEquals(3, Length(B));
  AssertEquals(5, B[2]);
  AssertEquals(0, Length(ReadCount(R, 10)));
end;

procedure TWsInboundPipeTest.TestMemoryReaderChunkAndRepeatedEnd;
var
  R: IBodyReader;
  S: TMemoryStream;
begin
  R := TWsMemoryReader.Create(TBytes.Create(7, 8, 9));
  S := TMemoryStream.Create;
  try
    AssertTrue(R.ReadChunk(S));
    AssertEquals(3, S.Size);
    AssertFalse(R.ReadChunk(S));
    AssertFalse(R.ReadChunk(S));
    AssertEquals(3, S.Size);
  finally
    S.Free;
  end;
end;

procedure TWsInboundPipeTest.TestEmptyMemoryReaderEnds;
var
  R: IBodyReader;
  S: TMemoryStream;
begin
  R := TWsMemoryReader.Create(nil);
  S := TMemoryStream.Create;
  try
    AssertFalse(R.ReadChunk(S));
    AssertEquals(0, Length(ReadCount(R, 4)));
    AssertEquals(0, Length(ReadAllBody(R)));
  finally
    S.Free;
  end;
end;

procedure TWsInboundPipeTest.TestPushThenReadKeepsOrder;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3);
  AssertTrue(P.Push(B[0], 3));
  B := TBytes.Create(4, 5);
  AssertTrue(P.Push(B[0], 2));
  P.Finish;
  B := ReadAllBody(R);
  AssertEquals(5, Length(B));
  AssertEquals(1, B[0]);
  AssertEquals(5, B[4]);
end;

procedure TWsInboundPipeTest.TestReadGivesLessThanAsked;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3);
  P.Push(B[0], 3);
  AssertEquals(3, Length(ReadCount(R, 100)));
end;

procedure TWsInboundPipeTest.TestTakenCountsTheOctetsRead;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3, 4, 5, 6);
  P.Push(B[0], 6);
  AssertEquals('nothing read yet', 0, FTaken);
  ReadCount(R, 4);
  AssertEquals(4, FTaken);
  AssertEquals(2, P.Buffered);
  ReadCount(R, 4);
  AssertEquals(6, FTaken);
  AssertEquals(0, P.Buffered);
end;

procedure TWsInboundPipeTest.TestReadChunkGivesPushedChunks;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
  S: TChunkBuffer;
begin
  P := NewPipe;
  R := P;
  S := TChunkBuffer.Create;
  try
    B := TBytes.Create(1, 2, 3);
    P.Push(B[0], 3);
    B := TBytes.Create(4, 5);
    P.Push(B[0], 2);
    AssertTrue(R.ReadChunk(S));
    AssertEquals(3, S.Size);
    S.Reset;
    AssertTrue(R.ReadChunk(S));
    AssertEquals(2, S.Size);
    AssertEquals(5, FTaken);
  finally
    S.Free;
  end;
end;

procedure TWsInboundPipeTest.TestReadChunkAfterPartialRead;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
  S: TChunkBuffer;
begin
  P := NewPipe;
  R := P;
  S := TChunkBuffer.Create;
  try
    B := TBytes.Create(1, 2, 3, 4);
    P.Push(B[0], 4);
    ReadCount(R, 1);
    AssertTrue(R.ReadChunk(S));
    AssertEquals(3, S.Size);
    AssertEquals(2, PByte(S.Memory)^);
  finally
    S.Free;
  end;
end;

procedure TWsInboundPipeTest.TestFinishKeepsTheBufferReadableThenEnds;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3);
  P.Push(B[0], 3);
  P.Finish;
  AssertEquals(3, Length(ReadCount(R, 10)));
  AssertEquals(0, Length(ReadCount(R, 10)));
end;

procedure TWsInboundPipeTest.TestEndRepeatsOnReadAndReadChunk;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  S: TChunkBuffer;
  I: Integer;
begin
  P := NewPipe;
  R := P;
  S := TChunkBuffer.Create;
  try
    P.Finish;
    for I := 1 to 3 do
    begin
      AssertEquals(0, Length(ReadCount(R, 8)));
      AssertFalse(R.ReadChunk(S));
    end;
    AssertEquals(0, S.Size);
  finally
    S.Free;
  end;
end;

procedure TWsInboundPipeTest.TestAbortRaisesOnRead;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  Raised: Boolean;
begin
  P := NewPipe;
  R := P;
  P.Abort;
  Raised := False;
  try
    ReadCount(R, 4);
  except
    on EStreamCancelled do
      Raised := True;
  end;
  AssertTrue('Read raised after Abort', Raised);
  Raised := False;
  try
    ReadCount(R, 4);
  except
    on EStreamCancelled do
      Raised := True;
  end;
  AssertTrue('the cancel repeats', Raised);
  AssertTrue(P.Aborted);
end;

procedure TWsInboundPipeTest.TestAbortDropsAndReportsTheBuffer;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3, 4);
  P.Push(B[0], 4);
  ReadCount(R, 1);
  P.Abort;
  AssertEquals('read and dropped octets are all reported', 4, FTaken);
  AssertEquals(0, P.Buffered);
end;

procedure TWsInboundPipeTest.TestAbortAfterFinishChangesNothing;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3);
  P.Push(B[0], 3);
  P.Finish;
  P.Abort;
  AssertFalse(P.Aborted);
  AssertEquals(3, Length(ReadAllBody(R)));
end;

procedure TWsInboundPipeTest.TestPushNeverBlocksAfterAbort;
var
  P: TWsMessagePipe;
  B: TBytes;
  I: Integer;
begin
  P := NewPipe(16);
  B := TBytes.Create(1, 2, 3, 4);
  P.Abort;
  for I := 1 to 100 do
    AssertTrue(P.Push(B[0], 4));
  AssertEquals('the dropped octets are credited', 400, FTaken);
  P.Free;
end;

procedure TWsInboundPipeTest.TestStallAbortsAndRaises;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  Raised: Boolean;
  T0: QWord;
begin
  P := NewPipe(1024, 80);
  R := P;
  Raised := False;
  T0 := GetTickCount64;
  try
    ReadCount(R, 4);
  except
    on EStreamCancelled do
      Raised := True;
  end;
  AssertTrue('Read raised on the stall', Raised);
  AssertTrue('the wait lasted about the stall time', GetTickCount64 - T0 >= 70);
  AssertTrue(P.Stalled);
  AssertTrue(P.Aborted);
  AssertEquals(1, FStalledCount);
end;

procedure TWsInboundPipeTest.TestStallDoesNotFireWhileOctetsArrive;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
  I: Integer;
begin
  P := NewPipe(1024, 200);
  R := P;
  B := TBytes.Create(1);
  // each read finds an octet at once: the stall time never starts
  for I := 1 to 5 do
  begin
    P.Push(B[0], 1);
    AssertEquals(1, Length(ReadCount(R, 1)));
  end;
  AssertFalse(P.Stalled);
  AssertEquals(0, FStalledCount);
end;

procedure TWsInboundPipeTest.TestOverflowRefusesAndAborts;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
  Raised: Boolean;
begin
  P := NewPipe(8);
  R := P;
  B := TBytes.Create(1, 2, 3, 4, 5);
  AssertTrue(P.Push(B[0], 5));
  AssertFalse('the second push passes the cap', P.Push(B[0], 5));
  AssertTrue(P.Overflowed);
  AssertTrue(P.Aborted);
  AssertEquals('the buffer and the refused octets are reported', 10, FTaken);
  Raised := False;
  try
    ReadCount(R, 4);
  except
    on EStreamCancelled do
      Raised := True;
  end;
  AssertTrue(Raised);
end;

procedure TWsInboundPipeTest.TestOverflowAtTheCapIsAllowed;
var
  P: TWsMessagePipe;
  B: TBytes;
begin
  P := NewPipe(8);
  B := TBytes.Create(1, 2, 3, 4);
  AssertTrue(P.Push(B[0], 4));
  AssertTrue('exactly the cap fits', P.Push(B[0], 4));
  AssertFalse(P.Overflowed);
  P.Free;
end;

procedure TWsInboundPipeTest.TestReadAllBodyOverPipe;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(9, 9, 9);
  P.Push(B[0], 3);
  P.Push(B[0], 3);
  P.Finish;
  AssertEquals(6, Length(ReadAllBody(R)));
end;

procedure TWsInboundPipeTest.TestWriterThreadAndReaderThread;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  W: TPushThread;
  Rd: TReadThread;
  I: Integer;
  Same: Boolean;
begin
  P := NewPipe(4 * 1048576, 5000);
  R := P;
  Rd := TReadThread.Create(R);
  W := TPushThread.Create(P, 2000, 173);
  try
    W.WaitFor;
    Rd.WaitFor;
    AssertFalse(Rd.Cancelled);
    AssertEquals(2000 * 173, Length(Rd.Data));
    Same := True;
    for I := 0 to High(Rd.Data) do
      if Rd.Data[I] <> Byte(I and $FF) then
      begin
        Same := False;
        Break;
      end;
    AssertTrue('the octets arrive in order', Same);
    AssertEquals(2000 * 173, FTaken);
  finally
    W.Free;
    Rd.Free;
  end;
end;

procedure TWsInboundPipeTest.TestAbortWakesABlockedReader;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  Rd: TReadThread;
  T0: QWord;
begin
  P := NewPipe(1024, 0);
  R := P;
  Rd := TReadThread.Create(R);
  try
    Sleep(50);
    T0 := GetTickCount64;
    P.Abort;
    Rd.WaitFor;
    AssertTrue('the reader woke at once', GetTickCount64 - T0 < 2000);
    AssertTrue(Rd.Cancelled);
  finally
    Rd.Free;
  end;
end;

procedure TWsInboundPipeTest.TestReadChunkOnAThread;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  W: TPushThread;
  Got: TBytes;
begin
  P := NewPipe(4 * 1048576, 5000);
  R := P;
  W := TPushThread.Create(P, 300, 61);
  try
    Got := ReadAllBody(R);
    W.WaitFor;
    AssertEquals(300 * 61, Length(Got));
    AssertEquals(Byte(61 and $FF), Got[61]);
  finally
    W.Free;
  end;
end;

procedure TWsInboundPipeTest.TestPrepaidOctetsGiveNoCreditOnRead;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3, 4);
  P.PushPrepaid(B[0], 4);
  P.Push(B[0], 2);
  ReadCount(R, 3);
  AssertEquals('three prepaid octets', 0, FTaken);
  ReadCount(R, 3);
  AssertEquals('one prepaid and two new octets: two credits', 2, FTaken);
end;

procedure TWsInboundPipeTest.TestPrepaidOctetsAreNotCreditedWhenDropped;
var
  P: TWsMessagePipe;
  B: TBytes;
begin
  P := NewPipe;
  B := TBytes.Create(1, 2, 3, 4);
  P.PushPrepaid(B[0], 4);
  P.Push(B[0], 3);
  P.Abort;
  AssertEquals(3, FTaken);
  P.Free;
end;

procedure TWsInboundPipeTest.TestReleaseDropsAFinishedBufferAndCredits;
var
  P: TWsMessagePipe;
  R: IBodyReader;
  B: TBytes;
  Raised: Boolean;
begin
  P := NewPipe;
  R := P;
  B := TBytes.Create(1, 2, 3);
  P.Push(B[0], 3);
  P.Finish;
  P.Release;
  AssertEquals(3, FTaken);
  Raised := False;
  try
    ReadCount(R, 4);
  except
    on EStreamCancelled do
      Raised := True;
  end;
  AssertTrue('a read after Release raises', Raised);
end;

procedure TWsInboundPipeTest.TestReleaseCreditsLaterPushesUntilFinish;
var
  P: TWsMessagePipe;
  B: TBytes;
begin
  P := NewPipe;
  B := TBytes.Create(1, 2, 3);
  P.Release;
  AssertTrue(P.Push(B[0], 3));
  AssertEquals('a push after Release is dropped and credited', 3, FTaken);
  P.Finish;
  P.Push(B[0], 3);
  AssertEquals('no call back after Finish', 3, FTaken);
  P.Free;
end;

initialization
  RegisterTest(TWsInboundPipeTest);

end.
