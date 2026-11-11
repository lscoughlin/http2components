{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, websocket
notes:
  - This unit owns WebSocket frame and message protocol operations.
---
}
unit Http2.Client.WebSocket.Protocol;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  SysUtils, Http2.Client.Errors;

const
  cWsOpContinuation = $0;
  cWsOpText = $1;
  cWsOpBinary = $2;
  cWsOpClose = $8;
  cWsOpPing = $9;
  cWsOpPong = $A;
  cWsCloseNormal = 1000;
  cWsCloseGoingAway = 1001;
  cWsCloseProtocolError = 1002;
  cWsCloseUnsupported = 1003;
  cWsCloseNoStatus = 1005;
  cWsCloseAbnormal = 1006;
  cWsCloseBadData = 1007;
  cWsCloseTooBig = 1009;
  cWsMaxControlPayload = 125;
  cWsMaxFrameBytes = 64 * 1024 * 1024;
  cWsDefaultMaxMessageBytes = 16 * 1024 * 1024;
  cWsDefaultCloseTimeoutMs = 5000;

type
  TWsMaskKey = array[0..3] of Byte;
  TMaskKeySource = function: Cardinal;
  TWsFrame = record
    Fin: Boolean;
    Opcode: Byte;
    Payload: TBytes;
  end;
  TWsDataKind = (wkText, wkBinary);
  TWebSocketFrameParser = class
  private
    FBuf: TBytes;
    FPos: Integer;
    FEnd: Integer;
    FMaxFrameBytes: Int64;
    FRequireMasked: Boolean;
  public
    constructor Create;
    procedure Feed(const AData; const ACount: Integer);
    function Next(out AFrame: TWsFrame): Boolean;
    function Buffered: Integer;
    property MaxFrameBytes: Int64 read FMaxFrameBytes write FMaxFrameBytes;
    property RequireMasked: Boolean read FRequireMasked write FRequireMasked;
  end;
  TWebSocketMessageAssembler = class
  private
    FInMessage: Boolean;
    FKind: TWsDataKind;
    FTotal: Int64;
    FMax: Int64;
    FCarry: TBytes;
  public
    constructor Create(const AMaxMessageBytes: Int64);
    function Accept(const AFrame: TWsFrame; out AKind: TWsDataKind;
      out AData: TBytes; out ALast: Boolean): Boolean;
  end;

procedure WsApplyMask(const AKey: TWsMaskKey; var ABuffer; const ACount: Integer;
  const APhase: Integer = 0);
function WsMaskKeyFromCardinal(const AValue: Cardinal): TWsMaskKey;
function WsEncodeFrame(const AOpcode: Byte; const AFin: Boolean;
  const APayload: TBytes; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;
function WsUtf8Check(const ABuffer: PByte; const ACount: Integer;
  out ASafeLen: Integer): Boolean;
function WsIsWireCloseCode(const ACode: Integer): Boolean;
procedure WsParseClosePayload(const APayload: TBytes; out ACode: Integer;
  out AReason: string);
function WsBuildClosePayload(const ACode: Integer;
  const AReason: string): TBytes;

implementation

{ masking }

function WsMaskKeyFromCardinal(const AValue: Cardinal): TWsMaskKey;
begin
  Result[0] := Byte(AValue shr 24);
  Result[1] := Byte(AValue shr 16);
  Result[2] := Byte(AValue shr 8);
  Result[3] := Byte(AValue);
end;

procedure WsApplyMask(const AKey: TWsMaskKey; var ABuffer; const ACount: Integer;
  const APhase: Integer);
var
  P: PByte;
  K: TWsMaskKey;
  Word32, Mask32: Cardinal;
  I, Ph: Integer;
begin
  if ACount <= 0 then
    Exit;
  Ph := APhase and 3;
  // rotate the key so that K[0] lines up with the first byte of the buffer
  for I := 0 to 3 do
    K[I] := AKey[(I + Ph) and 3];
  Move(K[0], Mask32, 4);
  P := @ABuffer;
  I := 0;
  while I + 4 <= ACount do
  begin
    Move(P^, Word32, 4);
    Word32 := Word32 xor Mask32;
    Move(Word32, P^, 4);
    Inc(P, 4);
    Inc(I, 4);
  end;
  Ph := 0;
  while I < ACount do
  begin
    P^ := P^ xor K[Ph];
    Inc(P);
    Inc(I);
    Inc(Ph);
  end;
end;

{ frames }

function WsEncodeFrame(const AOpcode: Byte; const AFin: Boolean;
  const APayload: TBytes; const AMasked: Boolean;
  const AKey: TWsMaskKey): TBytes;
var
  Len, HeadLen, P: Integer;
  B1: Byte;
begin
  Len := Length(APayload);
  HeadLen := 2;
  if Len > 65535 then
    Inc(HeadLen, 8)
  else if Len > 125 then
    Inc(HeadLen, 2);
  if AMasked then
    Inc(HeadLen, 4);
  SetLength(Result, HeadLen + Len);
  Result[0] := AOpcode and $0F;
  if AFin then
    Result[0] := Result[0] or $80;
  if AMasked then
    B1 := $80
  else
    B1 := 0;
  P := 2;
  if Len <= 125 then
    Result[1] := B1 or Byte(Len)
  else if Len <= 65535 then
  begin
    Result[1] := B1 or 126;
    Result[2] := Byte(Len shr 8);
    Result[3] := Byte(Len);
    P := 4;
  end
  else
  begin
    Result[1] := B1 or 127;
    Result[2] := 0; Result[3] := 0; Result[4] := 0; Result[5] := 0;
    Result[6] := Byte(Len shr 24);
    Result[7] := Byte(Len shr 16);
    Result[8] := Byte(Len shr 8);
    Result[9] := Byte(Len);
    P := 10;
  end;
  if AMasked then
  begin
    Move(AKey[0], Result[P], 4);
    Inc(P, 4);
  end;
  if Len > 0 then
  begin
    Move(APayload[0], Result[P], Len);
    if AMasked then
      WsApplyMask(AKey, Result[P], Len, 0);
  end;
end;

{ TWebSocketFrameParser }

constructor TWebSocketFrameParser.Create;
begin
  inherited Create;
  FMaxFrameBytes := cWsMaxFrameBytes;
end;

procedure TWebSocketFrameParser.Feed(const AData; const ACount: Integer);
begin
  if ACount <= 0 then
    Exit;
  if FPos > 0 then
  begin
    if FEnd > FPos then
      Move(FBuf[FPos], FBuf[0], FEnd - FPos);
    Dec(FEnd, FPos);
    FPos := 0;
  end;
  if FEnd + ACount > Length(FBuf) then
    SetLength(FBuf, (FEnd + ACount) * 2);
  Move(AData, FBuf[FEnd], ACount);
  Inc(FEnd, ACount);
end;

function TWebSocketFrameParser.Buffered: Integer;
begin
  Result := FEnd - FPos;
end;

function TWebSocketFrameParser.Next(out AFrame: TWsFrame): Boolean;
var
  Avail, HeadLen, Idx: Integer;
  B0, B1: Byte;
  Len7: Integer;
  PayLen: Int64;
  Masked, IsControl: Boolean;
  Key: TWsMaskKey;
  I: Integer;
begin
  Result := False;
  Avail := FEnd - FPos;
  if Avail < 2 then
    Exit;
  B0 := FBuf[FPos];
  B1 := FBuf[FPos + 1];
  if (B0 and $70) <> 0 then
    raise EHttpWebSocketProtocolError.Create(
      'reserved bits set with no extension negotiated', cWsCloseProtocolError);
  IsControl := (B0 and $08) <> 0;
  case B0 and $0F of
    cWsOpContinuation, cWsOpText, cWsOpBinary, cWsOpClose, cWsOpPing, cWsOpPong: ;
  else
    raise EHttpWebSocketProtocolError.CreateFmt(
      'reserved opcode %d', [B0 and $0F], cWsCloseProtocolError);
  end;
  Masked := (B1 and $80) <> 0;
  if Masked and (not FRequireMasked) then
    raise EHttpWebSocketProtocolError.Create(
      'server frame is masked', cWsCloseProtocolError);
  if (not Masked) and FRequireMasked then
    raise EHttpWebSocketProtocolError.Create(
      'client frame is not masked', cWsCloseProtocolError);
  Len7 := B1 and $7F;
  Idx := 2;
  if Len7 <= 125 then
    PayLen := Len7
  else if Len7 = 126 then
  begin
    if Avail < 4 then
      Exit;
    PayLen := (Int64(FBuf[FPos + 2]) shl 8) or FBuf[FPos + 3];
    if PayLen < 126 then
      raise EHttpWebSocketProtocolError.Create(
        'payload length not in its shortest form', cWsCloseProtocolError);
    Idx := 4;
  end
  else
  begin
    if Avail < 10 then
      Exit;
    if (FBuf[FPos + 2] and $80) <> 0 then
      raise EHttpWebSocketProtocolError.Create(
        'payload length has its top bit set', cWsCloseProtocolError);
    PayLen := 0;
    for I := 2 to 9 do
      PayLen := (PayLen shl 8) or FBuf[FPos + I];
    if PayLen < 65536 then
      raise EHttpWebSocketProtocolError.Create(
        'payload length not in its shortest form', cWsCloseProtocolError);
    Idx := 10;
  end;
  if IsControl then
  begin
    if (B0 and $80) = 0 then
      raise EHttpWebSocketProtocolError.Create(
        'fragmented control frame', cWsCloseProtocolError);
    if PayLen > cWsMaxControlPayload then
      raise EHttpWebSocketProtocolError.Create(
        'control frame payload over 125 octets', cWsCloseProtocolError);
  end;
  if PayLen > FMaxFrameBytes then
    raise EHttpWebSocketProtocolError.CreateFmt(
      'frame of %d octets exceeds the limit', [PayLen], cWsCloseTooBig);
  HeadLen := Idx;
  if Masked then
    Inc(HeadLen, 4);
  if Avail < HeadLen + PayLen then
    Exit;
  AFrame.Fin := (B0 and $80) <> 0;
  AFrame.Opcode := B0 and $0F;
  SetLength(AFrame.Payload, Integer(PayLen));
  if PayLen > 0 then
    Move(FBuf[FPos + HeadLen], AFrame.Payload[0], Integer(PayLen));
  if Masked then
  begin
    Move(FBuf[FPos + Idx], Key[0], 4);
    if PayLen > 0 then
      WsApplyMask(Key, AFrame.Payload[0], Integer(PayLen), 0);
  end;
  Inc(FPos, HeadLen + Integer(PayLen));
  Result := True;
end;

{ UTF-8 }

function WsUtf8Check(const ABuffer: PByte; const ACount: Integer;
  out ASafeLen: Integer): Boolean;
var
  I, K, Need: Integer;
  B, Lo, Hi, C: Byte;
begin
  ASafeLen := ACount;
  I := 0;
  while I < ACount do
  begin
    B := ABuffer[I];
    if B < $80 then
    begin
      Inc(I);
      Continue;
    end;
    Lo := $80;
    Hi := $BF;
    if (B >= $C2) and (B <= $DF) then
      Need := 1
    else if (B >= $E0) and (B <= $EF) then
    begin
      Need := 2;
      if B = $E0 then Lo := $A0;
      if B = $ED then Hi := $9F;
    end
    else if (B >= $F0) and (B <= $F4) then
    begin
      Need := 3;
      if B = $F0 then Lo := $90;
      if B = $F4 then Hi := $8F;
    end
    else
      Exit(False);
    for K := 1 to Need do
    begin
      if I + K >= ACount then
      begin
        ASafeLen := I;          // valid so far, the sequence is unfinished
        Exit(True);
      end;
      C := ABuffer[I + K];
      if (C < Lo) or (C > Hi) then
        Exit(False);
      Lo := $80;                // only the first continuation byte is special
      Hi := $BF;
    end;
    Inc(I, Need + 1);
  end;
  Result := True;
end;

function WsIsWireCloseCode(const ACode: Integer): Boolean;
begin
  Result := ((ACode >= 1000) and (ACode <= 1003)) or
    ((ACode >= 1007) and (ACode <= 1011)) or
    ((ACode >= 3000) and (ACode <= 4999));
end;

procedure WsParseClosePayload(const APayload: TBytes; out ACode: Integer;
  out AReason: string);
var
  Safe: Integer;
begin
  AReason := '';
  if Length(APayload) = 0 then
  begin
    ACode := cWsCloseNoStatus;
    Exit;
  end;
  if Length(APayload) = 1 then
    raise EHttpWebSocketProtocolError.Create(
      'close payload of one octet', cWsCloseProtocolError);
  ACode := (Integer(APayload[0]) shl 8) or APayload[1];
  if not WsIsWireCloseCode(ACode) then
    raise EHttpWebSocketProtocolError.CreateFmt(
      'invalid close code %d', [ACode], cWsCloseProtocolError);
  if Length(APayload) > 2 then
  begin
    if (not WsUtf8Check(@APayload[2], Length(APayload) - 2, Safe)) or
       (Safe <> Length(APayload) - 2) then
      raise EHttpWebSocketProtocolError.Create(
        'close reason is not UTF-8', cWsCloseBadData);
    SetLength(AReason, Length(APayload) - 2);
    Move(APayload[2], AReason[1], Length(APayload) - 2);
  end;
end;

function WsBuildClosePayload(const ACode: Integer;
  const AReason: string): TBytes;
begin
  SetLength(Result, 2 + Length(AReason));
  Result[0] := Byte(ACode shr 8);
  Result[1] := Byte(ACode);
  if AReason <> '' then
    Move(AReason[1], Result[2], Length(AReason));
end;

{ TWebSocketMessageAssembler }

constructor TWebSocketMessageAssembler.Create(const AMaxMessageBytes: Int64);
begin
  inherited Create;
  FMax := AMaxMessageBytes;
end;

function TWebSocketMessageAssembler.Accept(const AFrame: TWsFrame;
  out AKind: TWsDataKind; out AData: TBytes; out ALast: Boolean): Boolean;
var
  Buf: TBytes;
  Safe, N: Integer;
begin
  if AFrame.Opcode = cWsOpContinuation then
  begin
    if not FInMessage then
      raise EHttpWebSocketProtocolError.Create(
        'continuation frame with no message open', cWsCloseProtocolError);
  end
  else
  begin
    if FInMessage then
      raise EHttpWebSocketProtocolError.Create(
        'new data frame inside an open message', cWsCloseProtocolError);
    FInMessage := True;
    FTotal := 0;
    SetLength(FCarry, 0);
    if AFrame.Opcode = cWsOpText then
      FKind := wkText
    else
      FKind := wkBinary;
  end;
  AKind := FKind;
  ALast := AFrame.Fin;
  Inc(FTotal, Length(AFrame.Payload));
  if (FMax > 0) and (FTotal > FMax) then
    raise EHttpWebSocketProtocolError.CreateFmt(
      'message exceeds the limit of %d octets', [FMax], cWsCloseTooBig);
  if FKind = wkBinary then
  begin
    AData := AFrame.Payload;
    if AFrame.Fin then
      FInMessage := False;
    Exit(True);
  end;
  // text: validate carry + payload; hold back an unfinished character
  N := Length(FCarry) + Length(AFrame.Payload);
  SetLength(Buf, N);
  if Length(FCarry) > 0 then
    Move(FCarry[0], Buf[0], Length(FCarry));
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], Buf[Length(FCarry)], Length(AFrame.Payload));
  if N = 0 then
    Safe := 0
  else if not WsUtf8Check(@Buf[0], N, Safe) then
    raise EHttpWebSocketProtocolError.Create(
      'text message is not valid UTF-8', cWsCloseBadData);
  if AFrame.Fin then
  begin
    if Safe <> N then
      raise EHttpWebSocketProtocolError.Create(
        'text message ends inside a character', cWsCloseBadData);
    FInMessage := False;
  end;
  SetLength(FCarry, N - Safe);
  if N - Safe > 0 then
    Move(Buf[Safe], FCarry[0], N - Safe);
  SetLength(AData, Safe);
  if Safe > 0 then
    Move(Buf[0], AData[0], Safe);
  Result := (Safe > 0) or AFrame.Fin;
end;

end.
