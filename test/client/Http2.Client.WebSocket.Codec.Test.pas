{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client test from the source project
---
}
unit Http2.Client.WebSocket.Codec.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Client.Errors, Http2.Client.WebSocket;

type
  TWsFrameTest = class(TTestCase)
  private
    function Bytes(const A: array of Byte): TBytes;
    procedure AssertBytes(const AMsg: string; const AExpected: array of Byte;
      const AActual: TBytes);
    function ParseCode(const A: array of Byte; const AClient: Boolean = False): Integer;
  published
    procedure TestRfcMaskedHello;
    procedure TestRfcUnmaskedHello;
    procedure TestRfcPingAndFragments;
    procedure TestLengthForms;
    procedure TestMaskPhaseAcrossChunks;
    procedure TestChunkSplitInvariance;
    procedure TestServerFrameMaskedIs1002;
    procedure TestClientFrameUnmaskedIs1002OnServerSide;
    procedure TestReservedBitsAre1002;
    procedure TestReservedOpcodesAre1002;
    procedure TestFragmentedControlIs1002;
    procedure TestLongControlIs1002;
    procedure TestNonMinimalLengthIs1002;
    procedure TestLength64TopBitIs1002;
    procedure TestOversizeFrameIs1009;
    procedure TestPartialHeaderWaits;
  end;

  TWsMessageTest = class(TTestCase)
  private
    function Frame(const AOp: Byte; const AFin: Boolean; const A: array of Byte): TWsFrame;
    function AcceptCode(const AAsm: TWebSocketMessageAssembler; const AF: TWsFrame): Integer;
  published
    procedure TestUtf8Table;
    procedure TestUtf8UnfinishedTailIsReported;
    procedure TestCloseCodeTable;
    procedure TestClosePayload;
    procedure TestClosePayloadOneOctetIs1002;
    procedure TestClosePayloadBadReasonIs1007;
    procedure TestFragmentedBinary;
    procedure TestContinuationWithoutStartIs1002;
    procedure TestDataInsideOpenMessageIs1002;
    procedure TestTextSplitInsideCharacterIsHeldBack;
    procedure TestTextBadPrefixFailsEarly;
    procedure TestTextEndingInsideCharacterIs1007;
    procedure TestMessageLimitIs1009;
  end;

implementation

function FixedKey: TWsMaskKey;
begin
  Result[0] := $37; Result[1] := $fa; Result[2] := $21; Result[3] := $3d;
end;

{ TWsFrameTest }

function TWsFrameTest.Bytes(const A: array of Byte): TBytes;
begin
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[0], Result[0], Length(A));
end;

procedure TWsFrameTest.AssertBytes(const AMsg: string;
  const AExpected: array of Byte; const AActual: TBytes);
var
  I: Integer;
begin
  AssertEquals(AMsg + ' length', Length(AExpected), Length(AActual));
  for I := 0 to High(AExpected) do
    AssertEquals(AMsg + ' byte ' + IntToStr(I), AExpected[I], AActual[I]);
end;

function TWsFrameTest.ParseCode(const A: array of Byte;
  const AClient: Boolean): Integer;
var
  P: TWebSocketFrameParser;
  F: TWsFrame;
begin
  Result := 0;
  P := TWebSocketFrameParser.Create;
  try
    P.RequireMasked := AClient;
    P.MaxFrameBytes := 1000000;
    P.Feed(A[0], Length(A));
    try
      P.Next(F);
    except
      on E: EHttpWebSocketProtocolError do
        Result := E.CloseCode;
    end;
  finally
    P.Free;
  end;
end;

procedure TWsFrameTest.TestRfcMaskedHello;
var
  Hello: TBytes;
begin
  Hello := Bytes([$48, $65, $6c, $6c, $6f]);
  AssertBytes('masked Hello', [$81, $85, $37, $fa, $21, $3d, $7f, $9f, $4d,
    $51, $58], WsEncodeFrame(cWsOpText, True, Hello, True, FixedKey));
end;

procedure TWsFrameTest.TestRfcUnmaskedHello;
var
  P: TWebSocketFrameParser;
  F: TWsFrame;
  Wire: TBytes;
begin
  Wire := Bytes([$81, $05, $48, $65, $6c, $6c, $6f]);
  AssertBytes('unmasked Hello', [$81, $05, $48, $65, $6c, $6c, $6f],
    WsEncodeFrame(cWsOpText, True, Bytes([$48, $65, $6c, $6c, $6f]), False,
      FixedKey));
  P := TWebSocketFrameParser.Create;
  try
    P.Feed(Wire[0], Length(Wire));
    AssertTrue('frame', P.Next(F));
    AssertTrue('fin', F.Fin);
    AssertEquals('op', cWsOpText, F.Opcode);
    AssertBytes('payload', [$48, $65, $6c, $6c, $6f], F.Payload);
  finally
    P.Free;
  end;
  // a masked client frame parses on the server side
  P := TWebSocketFrameParser.Create;
  try
    P.RequireMasked := True;
    Wire := Bytes([$81, $85, $37, $fa, $21, $3d, $7f, $9f, $4d, $51, $58]);
    P.Feed(Wire[0], Length(Wire));
    AssertTrue('frame', P.Next(F));
    AssertBytes('unmasked payload', [$48, $65, $6c, $6c, $6f], F.Payload);
  finally
    P.Free;
  end;
end;

procedure TWsFrameTest.TestRfcPingAndFragments;
begin
  AssertBytes('ping', [$89, $05, $48, $65, $6c, $6c, $6f],
    WsEncodeFrame(cWsOpPing, True, Bytes([$48, $65, $6c, $6c, $6f]), False,
      FixedKey));
  AssertBytes('first fragment', [$01, $03, $48, $65, $6c],
    WsEncodeFrame(cWsOpText, False, Bytes([$48, $65, $6c]), False, FixedKey));
  AssertBytes('last fragment', [$80, $02, $6c, $6f],
    WsEncodeFrame(cWsOpContinuation, True, Bytes([$6c, $6f]), False, FixedKey));
end;

procedure TWsFrameTest.TestLengthForms;
var
  Sizes: array[0..6] of Integer;
  I: Integer;
  Pl, Wire: TBytes;
  P: TWebSocketFrameParser;
  F: TWsFrame;
begin
  Sizes[0] := 0; Sizes[1] := 125; Sizes[2] := 126; Sizes[3] := 127;
  Sizes[4] := 65535; Sizes[5] := 65536; Sizes[6] := 100000;
  for I := 0 to High(Sizes) do
  begin
    SetLength(Pl, Sizes[I]);
    if Sizes[I] > 0 then
      FillChar(Pl[0], Sizes[I], $5A);
    Wire := WsEncodeFrame(cWsOpBinary, True, Pl, True, FixedKey);
    P := TWebSocketFrameParser.Create;
    try
      P.RequireMasked := True;
      P.Feed(Wire[0], Length(Wire));
      AssertTrue('frame ' + IntToStr(Sizes[I]), P.Next(F));
      AssertEquals('len ' + IntToStr(Sizes[I]), Sizes[I], Length(F.Payload));
      if Sizes[I] > 0 then
        AssertEquals('content', $5A, F.Payload[Sizes[I] - 1]);
    finally
      P.Free;
    end;
  end;
  SetLength(Pl, 256);
  Wire := WsEncodeFrame(cWsOpBinary, True, Pl, False, FixedKey);
  AssertEquals('256 header 0', $82, Wire[0]);
  AssertEquals('256 header 1', $7E, Wire[1]);
  AssertEquals('256 header 2', $01, Wire[2]);
  AssertEquals('256 header 3', $00, Wire[3]);
  SetLength(Pl, 65536);
  Wire := WsEncodeFrame(cWsOpBinary, True, Pl, False, FixedKey);
  AssertEquals('64k header 1', $7F, Wire[1]);
  AssertEquals('64k header 7', $01, Wire[7]);
  AssertEquals('64k header 8', $00, Wire[8]);
end;

procedure TWsFrameTest.TestMaskPhaseAcrossChunks;
var
  A, B: TBytes;
  I: Integer;
begin
  SetLength(A, 23);
  SetLength(B, 23);
  for I := 0 to 22 do
  begin
    A[I] := I * 7;
    B[I] := I * 7;
  end;
  WsApplyMask(FixedKey, A[0], 23, 0);
  WsApplyMask(FixedKey, B[0], 5, 0);
  WsApplyMask(FixedKey, B[5], 18, 5);
  for I := 0 to 22 do
    AssertEquals('byte ' + IntToStr(I), A[I], B[I]);
  // masking twice restores the data
  WsApplyMask(FixedKey, A[0], 23, 0);
  for I := 0 to 22 do
    AssertEquals('restored ' + IntToStr(I), Byte(I * 7), A[I]);
end;

procedure TWsFrameTest.TestChunkSplitInvariance;
var
  Wire, Pl: TBytes;
  Sizes: array[0..5] of Integer;
  I, J, N, Pos, Count: Integer;
  P: TWebSocketFrameParser;
  F: TWsFrame;
  Seen: array of Integer;
  Mode: Integer;
begin
  Sizes[0] := 0; Sizes[1] := 3; Sizes[2] := 125; Sizes[3] := 126;
  Sizes[4] := 300; Sizes[5] := 70000;
  SetLength(Wire, 0);
  for I := 0 to High(Sizes) do
  begin
    SetLength(Pl, Sizes[I]);
    for J := 0 to Sizes[I] - 1 do
      Pl[J] := Byte(J + I);
    Pl := WsEncodeFrame(cWsOpBinary, True, Pl, False, FixedKey);
    N := Length(Wire);
    SetLength(Wire, N + Length(Pl));
    Move(Pl[0], Wire[N], Length(Pl));
  end;
  RandSeed := 1234;
  for Mode := 0 to 2 do
  begin
    P := TWebSocketFrameParser.Create;
    try
      SetLength(Seen, 0);
      Pos := 0;
      while Pos < Length(Wire) do
      begin
        case Mode of
          0: Count := 1;
          1: Count := 1 + Random(97);
        else
          Count := Length(Wire);
        end;
        if Pos + Count > Length(Wire) then
          Count := Length(Wire) - Pos;
        P.Feed(Wire[Pos], Count);
        Inc(Pos, Count);
        while P.Next(F) do
        begin
          SetLength(Seen, Length(Seen) + 1);
          Seen[High(Seen)] := Length(F.Payload);
          if Length(F.Payload) > 0 then
            AssertEquals('content', Byte(Length(F.Payload) - 1 + High(Seen)),
              F.Payload[Length(F.Payload) - 1]);
        end;
      end;
      AssertEquals('count mode ' + IntToStr(Mode), 6, Length(Seen));
      for I := 0 to High(Sizes) do
        AssertEquals('size', Sizes[I], Seen[I]);
    finally
      P.Free;
    end;
  end;
end;

procedure TWsFrameTest.TestServerFrameMaskedIs1002;
begin
  AssertEquals(1002, ParseCode([$81, $81, 1, 2, 3, 4, 5]));
end;

procedure TWsFrameTest.TestClientFrameUnmaskedIs1002OnServerSide;
begin
  AssertEquals(1002, ParseCode([$81, $01, $41], True));
end;

procedure TWsFrameTest.TestReservedBitsAre1002;
begin
  AssertEquals('rsv1', 1002, ParseCode([$C1, $00]));
  AssertEquals('rsv2', 1002, ParseCode([$A1, $00]));
  AssertEquals('rsv3', 1002, ParseCode([$91, $00]));
end;

procedure TWsFrameTest.TestReservedOpcodesAre1002;
var
  Op: Integer;
begin
  for Op := 3 to 7 do
    AssertEquals('data op ' + IntToStr(Op), 1002, ParseCode([$80 or Op, $00]));
  for Op := $B to $F do
    AssertEquals('control op ' + IntToStr(Op), 1002, ParseCode([$80 or Op, $00]));
end;

procedure TWsFrameTest.TestFragmentedControlIs1002;
begin
  AssertEquals(1002, ParseCode([$09, $00]));
  AssertEquals(1002, ParseCode([$08, $00]));
end;

procedure TWsFrameTest.TestLongControlIs1002;
begin
  AssertEquals(1002, ParseCode([$89, 126, 0, 126]));
end;

procedure TWsFrameTest.TestNonMinimalLengthIs1002;
begin
  AssertEquals('126 form for 5', 1002, ParseCode([$82, 126, 0, 5]));
  AssertEquals('127 form for 5', 1002,
    ParseCode([$82, 127, 0, 0, 0, 0, 0, 0, 0, 5]));
  AssertEquals('127 form for 65535', 1002,
    ParseCode([$82, 127, 0, 0, 0, 0, 0, 0, $FF, $FF]));
end;

procedure TWsFrameTest.TestLength64TopBitIs1002;
begin
  AssertEquals(1002, ParseCode([$82, 127, $80, 0, 0, 0, 0, 0, 0, 0]));
end;

procedure TWsFrameTest.TestOversizeFrameIs1009;
begin
  AssertEquals(1009, ParseCode([$82, 127, 0, 0, 0, 0, 0, $20, 0, 0]));
end;

procedure TWsFrameTest.TestPartialHeaderWaits;
var
  P: TWebSocketFrameParser;
  F: TWsFrame;
  B: Byte;
begin
  P := TWebSocketFrameParser.Create;
  try
    B := $81;
    P.Feed(B, 1);
    AssertFalse('one byte', P.Next(F));
    B := 126;
    P.Feed(B, 1);
    AssertFalse('length incomplete', P.Next(F));
  finally
    P.Free;
  end;
end;

{ TWsMessageTest }

function TWsMessageTest.Frame(const AOp: Byte; const AFin: Boolean;
  const A: array of Byte): TWsFrame;
begin
  Result.Fin := AFin;
  Result.Opcode := AOp;
  SetLength(Result.Payload, Length(A));
  if Length(A) > 0 then
    Move(A[0], Result.Payload[0], Length(A));
end;

function TWsMessageTest.AcceptCode(const AAsm: TWebSocketMessageAssembler;
  const AF: TWsFrame): Integer;
var
  K: TWsDataKind;
  D: TBytes;
  L: Boolean;
begin
  Result := 0;
  try
    AAsm.Accept(AF, K, D, L);
  except
    on E: EHttpWebSocketProtocolError do
      Result := E.CloseCode;
  end;
end;

procedure TWsMessageTest.TestUtf8Table;
  procedure Check(const AName: string; const A: array of Byte;
    const AValid: Boolean);
  var
    Safe: Integer;
    R: Boolean;
  begin
    R := WsUtf8Check(@A[0], Length(A), Safe) and (Safe = Length(A));
    AssertEquals(AName, AValid, R);
  end;
begin
  Check('ascii', [$41, $7F], True);
  Check('2 octets', [$C2, $80], True);
  Check('C3 A9', [$C3, $A9], True);
  Check('overlong C0 80', [$C0, $80], False);
  Check('overlong C1 BF', [$C1, $BF], False);
  Check('3 octets U+0800', [$E0, $A0, $80], True);
  Check('overlong E0 9F BF', [$E0, $9F, $BF], False);
  Check('U+D7FF', [$ED, $9F, $BF], True);
  Check('surrogate ED A0 80', [$ED, $A0, $80], False);
  Check('surrogate ED BF BF', [$ED, $BF, $BF], False);
  Check('U+E000', [$EE, $80, $80], True);
  Check('U+FFFF', [$EF, $BF, $BF], True);
  Check('4 octets U+10000', [$F0, $90, $80, $80], True);
  Check('overlong F0 8F BF BF', [$F0, $8F, $BF, $BF], False);
  Check('U+10FFFF', [$F4, $8F, $BF, $BF], True);
  Check('above 10FFFF F4 90', [$F4, $90, $80, $80], False);
  Check('F5', [$F5, $80, $80, $80], False);
  Check('FF', [$FF], False);
  Check('lone continuation', [$80], False);
  Check('bad continuation', [$C3, $41], False);
end;

procedure TWsMessageTest.TestUtf8UnfinishedTailIsReported;
var
  A: array[0..3] of Byte;
  Safe: Integer;
begin
  A[0] := $41; A[1] := $E2; A[2] := $82;
  AssertTrue('valid so far', WsUtf8Check(@A[0], 3, Safe));
  AssertEquals('safe prefix', 1, Safe);
  A[3] := $41;
  A[0] := $E2; A[1] := $41;
  AssertFalse('bad second byte', WsUtf8Check(@A[0], 2, Safe));
end;

procedure TWsMessageTest.TestCloseCodeTable;
const
  Valid: array[0..12] of Integer = (1000, 1001, 1002, 1003, 1007, 1008, 1009,
    1010, 1011, 3000, 3999, 4000, 4999);
  Invalid: array[0..13] of Integer = (0, 999, 1004, 1005, 1006, 1012, 1013,
    1014, 1015, 1016, 1100, 2000, 2999, 5000);
var
  I: Integer;
begin
  for I := 0 to High(Valid) do
    AssertTrue('valid ' + IntToStr(Valid[I]), WsIsWireCloseCode(Valid[I]));
  for I := 0 to High(Invalid) do
    AssertFalse('invalid ' + IntToStr(Invalid[I]), WsIsWireCloseCode(Invalid[I]));
end;

procedure TWsMessageTest.TestClosePayload;
var
  Code: Integer;
  Reason: string;
  P: TBytes;
begin
  SetLength(P, 0);
  WsParseClosePayload(P, Code, Reason);
  AssertEquals(1005, Code);
  P := WsBuildClosePayload(1000, 'bye');
  WsParseClosePayload(P, Code, Reason);
  AssertEquals(1000, Code);
  AssertEquals('bye', Reason);
  AssertEquals(5, Length(P));
  AssertEquals($03, P[0]);
  AssertEquals($E8, P[1]);
end;

procedure TWsMessageTest.TestClosePayloadOneOctetIs1002;
var
  P: TBytes;
  Code: Integer;
  Reason: string;
  Got: Integer;
begin
  SetLength(P, 1);
  Got := 0;
  try
    WsParseClosePayload(P, Code, Reason);
  except
    on E: EHttpWebSocketProtocolError do
      Got := E.CloseCode;
  end;
  AssertEquals(1002, Got);
  P := WsBuildClosePayload(1004, '');
  try
    WsParseClosePayload(P, Code, Reason);
  except
    on E: EHttpWebSocketProtocolError do
      Got := E.CloseCode;
  end;
  AssertEquals('bad code', 1002, Got);
end;

procedure TWsMessageTest.TestClosePayloadBadReasonIs1007;
var
  P: TBytes;
  Code, Got: Integer;
  Reason: string;
begin
  P := WsBuildClosePayload(1000, 'ab');
  P[2] := $FF;
  Got := 0;
  try
    WsParseClosePayload(P, Code, Reason);
  except
    on E: EHttpWebSocketProtocolError do
      Got := E.CloseCode;
  end;
  AssertEquals(1007, Got);
end;

procedure TWsMessageTest.TestFragmentedBinary;
var
  A: TWebSocketMessageAssembler;
  K: TWsDataKind;
  D: TBytes;
  L: Boolean;
begin
  A := TWebSocketMessageAssembler.Create(0);
  try
    AssertTrue(A.Accept(Frame(cWsOpBinary, False, [1, 2]), K, D, L));
    AssertTrue(K = wkBinary);
    AssertFalse(L);
    AssertTrue(A.Accept(Frame(cWsOpContinuation, True, [3]), K, D, L));
    AssertTrue(L);
    AssertEquals(1, Length(D));
    // a new message may start again
    AssertTrue(A.Accept(Frame(cWsOpText, True, [$41]), K, D, L));
    AssertTrue(K = wkText);
  finally
    A.Free;
  end;
end;

procedure TWsMessageTest.TestContinuationWithoutStartIs1002;
var
  A: TWebSocketMessageAssembler;
begin
  A := TWebSocketMessageAssembler.Create(0);
  try
    AssertEquals(1002, AcceptCode(A, Frame(cWsOpContinuation, True, [1])));
  finally
    A.Free;
  end;
end;

procedure TWsMessageTest.TestDataInsideOpenMessageIs1002;
var
  A: TWebSocketMessageAssembler;
  K: TWsDataKind;
  D: TBytes;
  L: Boolean;
begin
  A := TWebSocketMessageAssembler.Create(0);
  try
    A.Accept(Frame(cWsOpBinary, False, [1]), K, D, L);
    AssertEquals(1002, AcceptCode(A, Frame(cWsOpText, True, [$41])));
  finally
    A.Free;
  end;
end;

procedure TWsMessageTest.TestTextSplitInsideCharacterIsHeldBack;
var
  A: TWebSocketMessageAssembler;
  K: TWsDataKind;
  D: TBytes;
  L: Boolean;
begin
  A := TWebSocketMessageAssembler.Create(0);
  try
    // U+20AC is E2 82 AC; split after the first two octets
    AssertTrue(A.Accept(Frame(cWsOpText, False, [$41, $E2, $82]), K, D, L));
    AssertEquals('only the complete prefix', 1, Length(D));
    AssertTrue(A.Accept(Frame(cWsOpContinuation, True, [$AC, $42]), K, D, L));
    AssertEquals('character completed', 4, Length(D));
    AssertEquals($E2, D[0]);
    AssertEquals($AC, D[2]);
    AssertTrue(L);
    // a fragment holding only part of a character delivers nothing yet
    AssertFalse(A.Accept(Frame(cWsOpText, False, [$E2]), K, D, L));
    AssertFalse(A.Accept(Frame(cWsOpContinuation, False, [$82]), K, D, L));
    AssertTrue(A.Accept(Frame(cWsOpContinuation, True, [$AC]), K, D, L));
    AssertEquals(3, Length(D));
  finally
    A.Free;
  end;
end;

procedure TWsMessageTest.TestTextBadPrefixFailsEarly;
var
  A: TWebSocketMessageAssembler;
begin
  A := TWebSocketMessageAssembler.Create(0);
  try
    AssertEquals(1007, AcceptCode(A, Frame(cWsOpText, False, [$41, $FF])));
  finally
    A.Free;
  end;
end;

procedure TWsMessageTest.TestTextEndingInsideCharacterIs1007;
var
  A: TWebSocketMessageAssembler;
begin
  A := TWebSocketMessageAssembler.Create(0);
  try
    AssertEquals(1007, AcceptCode(A, Frame(cWsOpText, True, [$41, $E2, $82])));
  finally
    A.Free;
  end;
end;

procedure TWsMessageTest.TestMessageLimitIs1009;
var
  A: TWebSocketMessageAssembler;
  K: TWsDataKind;
  D: TBytes;
  L: Boolean;
begin
  A := TWebSocketMessageAssembler.Create(4);
  try
    A.Accept(Frame(cWsOpBinary, False, [1, 2, 3]), K, D, L);
    AssertEquals(1009, AcceptCode(A, Frame(cWsOpContinuation, True, [4, 5])));
  finally
    A.Free;
  end;
end;

{ TWsHandshakeTest }

function FixedRandom: Cardinal;
begin
  Result := $01020304;
end;

initialization
  RegisterTest(TWsFrameTest);
  RegisterTest(TWsMessageTest);
end.
