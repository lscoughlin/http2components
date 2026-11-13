{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_connection_test, header_block, receive_credit
notes:
  - this checks the header block assembler and the receive credit tracker
---
}
unit Http2.Client.Connection.Receive.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry,
  Http2.Common.Errors, Http2.Client.Connection.HeaderBlock,
  Http2.Client.Connection.Credit;

type
  THeaderBlockAssemblerTest = class(TTestCase)
  published
    procedure TestStartAppendTakeReturnsJoinedBytes;
    procedure TestAppendForOtherStreamRaises;
    procedure TestAppendWithoutOpenBlockRaises;
    procedure TestTakeClosesTheBlock;
  end;

  TReceiveCreditTrackerTest = class(TTestCase)
  published
    procedure TestBatchEmitsOneIncrementOnThirdFrame;
    procedure TestUntrackedStreamKeepsNoStreamCredit;
    procedure TestTakeStreamReturnsAndClearsPending;
    procedure TestForgetClearsStream;
  end;

implementation

procedure THeaderBlockAssemblerTest.TestStartAppendTakeReturnsJoinedBytes;
var
  Asm1: THeaderBlockAssembler;
  Block: TBytes;
begin
  Asm1 := THeaderBlockAssembler.Create;
  try
    Asm1.Start(1, TBytes.Create($01, $02));
    Asm1.Append(1, TBytes.Create($03));
    AssertEquals(3, Asm1.Size);
    Block := Asm1.Take;
    AssertEquals(3, Length(Block));
    AssertEquals($01, Integer(Block[0]));
    AssertEquals($02, Integer(Block[1]));
    AssertEquals($03, Integer(Block[2]));
  finally
    Asm1.Free;
  end;
end;

procedure THeaderBlockAssemblerTest.TestAppendForOtherStreamRaises;
var
  Asm1: THeaderBlockAssembler;
  Raised: Boolean;
begin
  Asm1 := THeaderBlockAssembler.Create;
  try
    Asm1.Start(1, TBytes.Create($01));
    Raised := False;
    try
      Asm1.Append(3, TBytes.Create($02));
    except
      on E: EHttpProtocolError do
        Raised := E.ErrorCode = ecProtocolError;
    end;
    AssertTrue('CONTINUATION for another stream must raise', Raised);
  finally
    Asm1.Free;
  end;
end;

procedure THeaderBlockAssemblerTest.TestAppendWithoutOpenBlockRaises;
var
  Asm1: THeaderBlockAssembler;
  Raised: Boolean;
begin
  Asm1 := THeaderBlockAssembler.Create;
  try
    Raised := False;
    try
      Asm1.Append(1, TBytes.Create($02));
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('CONTINUATION without a block must raise', Raised);
  finally
    Asm1.Free;
  end;
end;

procedure THeaderBlockAssemblerTest.TestTakeClosesTheBlock;
var
  Asm1: THeaderBlockAssembler;
  Raised: Boolean;
begin
  Asm1 := THeaderBlockAssembler.Create;
  try
    Asm1.Start(1, TBytes.Create($01));
    Asm1.Take;
    AssertEquals(0, Asm1.Size);
    Raised := False;
    try
      Asm1.Append(1, TBytes.Create($02));
    except
      on E: EHttpProtocolError do
        Raised := True;
    end;
    AssertTrue('Take must close the block', Raised);
  finally
    Asm1.Free;
  end;
end;

procedure TReceiveCreditTrackerTest.TestBatchEmitsOneIncrementOnThirdFrame;
var
  Tracker: TReceiveCreditTracker;
  ConnInc, StreamInc: LongWord;
  Emitted: Boolean;
begin
  Tracker := TReceiveCreditTracker.Create;
  try
    Emitted := Tracker.OnData(1, 6000, True, 16384, ConnInc, StreamInc);
    AssertFalse(Emitted);
    AssertEquals(0, Integer(ConnInc));
    AssertEquals(0, Integer(StreamInc));
    Emitted := Tracker.OnData(1, 6000, True, 16384, ConnInc, StreamInc);
    AssertFalse(Emitted);
    Emitted := Tracker.OnData(1, 6000, True, 16384, ConnInc, StreamInc);
    AssertTrue(Emitted);
    AssertEquals(16384, Integer(ConnInc));
    AssertEquals(18000, Integer(StreamInc));
    AssertEquals(0, Integer(Tracker.TakeStream(1)));
  finally
    Tracker.Free;
  end;
end;

procedure TReceiveCreditTrackerTest.TestUntrackedStreamKeepsNoStreamCredit;
var
  Tracker: TReceiveCreditTracker;
  ConnInc, StreamInc: LongWord;
begin
  Tracker := TReceiveCreditTracker.Create;
  try
    Tracker.OnData(5, 6000, False, 16384, ConnInc, StreamInc);
    AssertEquals(0, Integer(Tracker.TakeStream(5)));
  finally
    Tracker.Free;
  end;
end;

procedure TReceiveCreditTrackerTest.TestTakeStreamReturnsAndClearsPending;
var
  Tracker: TReceiveCreditTracker;
  ConnInc, StreamInc: LongWord;
begin
  Tracker := TReceiveCreditTracker.Create;
  try
    Tracker.OnData(1, 1000, True, 16384, ConnInc, StreamInc);
    AssertEquals(1000, Integer(Tracker.TakeStream(1)));
    AssertEquals(0, Integer(Tracker.TakeStream(1)));
  finally
    Tracker.Free;
  end;
end;

procedure TReceiveCreditTrackerTest.TestForgetClearsStream;
var
  Tracker: TReceiveCreditTracker;
  ConnInc, StreamInc: LongWord;
begin
  Tracker := TReceiveCreditTracker.Create;
  try
    Tracker.OnData(1, 1000, True, 16384, ConnInc, StreamInc);
    Tracker.Forget(1);
    AssertEquals(0, Integer(Tracker.TakeStream(1)));
  finally
    Tracker.Free;
  end;
end;

initialization
  RegisterTest(THeaderBlockAssemblerTest);
  RegisterTest(TReceiveCreditTrackerTest);
end.
