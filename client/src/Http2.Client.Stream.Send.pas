{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, stream
notes:
  - This unit owns HTTP/2 request frame emission for a client stream.
---
}
unit Http2.Client.Stream.Send;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, Generics.Collections, SyncObjs,
  Http2.Client.Errors, Http2.Client.Connection, Http2.Client.Stream.Types,
  Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Common.Body;

function LeaseMaxFrameSize(const AConnection: TConnection): LongWord;
function RequestIsBodyless(const AMethod: string): Boolean;
procedure LeaseSendHeaders(const ARequest: TStreamRequest;
  const AEncoder: THpackCodec; const AOutbound: IBlockingQueue<TFrame>;
  const AStreamId: LongWord; const AMaxFrameSize: LongWord;
  var ALocalState: TLeaseLocalState);
procedure LeaseSendData(const AConnection: TConnection;
  const AOutbound: IBlockingQueue<TFrame>; const AWaitLock: TCriticalSection;
  const AStreamId: LongWord; const ATimeoutMs: Integer;
  const APeerDone, APeerReset: PLongInt; var AUploadStopped: Boolean;
  var ABytesSent: Int64; var ALocalState: TLeaseLocalState;
  const AData: TBytes; const AEndStream: Boolean);
procedure LeaseSendBody(const AConnection: TConnection;
  const ARequest: TStreamRequest; const AOutbound: IBlockingQueue<TFrame>;
  const AWaitLock: TCriticalSection; const AStreamId: LongWord;
  const ATimeoutMs: Integer; const APeerDone, APeerReset: PLongInt;
  var AUploadStopped: Boolean; var ABytesSent: Int64;
  var ALocalState: TLeaseLocalState);
procedure LeaseEndSend(const AConnection: TConnection;
  const AOutbound: IBlockingQueue<TFrame>; const AWaitLock: TCriticalSection;
  const AStreamId: LongWord; const ATimeoutMs: Integer;
  const APeerDone, APeerReset: PLongInt; var AUploadStopped: Boolean;
  var ABytesSent: Int64; var ALocalState: TLeaseLocalState);

implementation

function FrameSize(const AConnection: TConnection): LongWord;
begin
  Result := AConnection.PeerSettings.MaxFrameSize;
  if Result = 0 then
    Result := DefaultMaxFrameSize;
end;

function LeaseMaxFrameSize(const AConnection: TConnection): LongWord;
begin
  // the caller holds the encoder lock and encodes the header block next
  AConnection.TableHandoff.Apply(AConnection.HeaderEncoder);
  Result := FrameSize(AConnection);
end;

function RequestIsBodyless(const AMethod: string): Boolean;
begin
  Result := SameText(AMethod, 'HEAD');
end;

function AcquireCredit(const AConnection: TConnection;
  const AStreamId: LongWord; const AWant: LongWord;
  const ATimeoutMs: Integer; const AWaitLock: TCriticalSection;
  const APeerDone: PLongInt): LongWord;
begin
  if AWaitLock <> nil then AWaitLock.Release;
  try
    Result := AConnection.AcquireSendCredit(AStreamId, AWant, ATimeoutMs, APeerDone);
  finally
    if AWaitLock <> nil then AWaitLock.Acquire;
  end;
  if (Result = 0) and (InterlockedExchangeAdd(APeerDone^, 0) <> 0) then
    Exit(0);
  if Result = 0 then
    raise EHttpTimeout.CreateFmt(
      'timed out after %d ms waiting for flow-control credit on stream %d',
      [ATimeoutMs, AStreamId]);
end;

function BuildRequestHeaderBlock(const ARequest: TStreamRequest): THeaderBlock;
var
  Fields: TList<THttpHeaderField>;
  Names, Values: TArray<string>;
  Name, Value: string;
  I, J: Integer;
  Field: THttpHeaderField;
begin
  Result := nil;
  Fields := TList<THttpHeaderField>.Create;
  try
    Field.Name := HeaderMethod;
    Field.Value := ARequest.Method;
    Field.Sensitive := False;
    Fields.Add(Field);
    Field.Name := HeaderScheme;
    Field.Value := ARequest.Scheme;
    Fields.Add(Field);
    Field.Name := HeaderPath;
    if ARequest.Path = '' then Field.Value := '/' else Field.Value := ARequest.Path;
    Fields.Add(Field);
    Field.Name := HeaderAuthority;
    Field.Value := ARequest.Authority;
    Fields.Add(Field);
    if ARequest.Headers <> nil then
    begin
      Names := ARequest.Headers.Names;
      for I := 0 to High(Names) do
      begin
        Name := Names[I];
        Values := ARequest.Headers.GetValues(Name);
        for J := 0 to High(Values) do
        begin
          Value := Values[J];
          Field.Name := Name;
          Field.Value := Value;
          Field.Sensitive := (Name = 'authorization') or (Name = 'cookie');
          Fields.Add(Field);
        end;
      end;
    end;
    SetLength(Result, Fields.Count);
    for I := 0 to Fields.Count - 1 do
      Result[I] := Fields[I];
  finally
    Fields.Free;
  end;
end;

procedure EmitHeaderBlock(const AOutbound: IBlockingQueue<TFrame>;
  const AStreamId: LongWord; const AMaxFrameSize: LongWord;
  const ABlock: TBytes; const AEndStream: Boolean);
var
  Max, Offset, Count: Integer;
  Chunk: TBytes;
begin
  Max := Integer(AMaxFrameSize);
  if Length(ABlock) <= Max then
  begin
    AOutbound.Push(BuildHeadersFrame(AStreamId, ABlock, True, AEndStream));
    Exit;
  end;
  Chunk := Copy(ABlock, 0, Max);
  AOutbound.Push(BuildHeadersFrame(AStreamId, Chunk, False, AEndStream));
  Offset := Max;
  while Offset < Length(ABlock) do
  begin
    Count := Length(ABlock) - Offset;
    if Count > Max then Count := Max;
    Chunk := Copy(ABlock, Offset, Count);
    Inc(Offset, Count);
    AOutbound.Push(BuildContinuationFrame(AStreamId, Chunk,
      Offset >= Length(ABlock)));
  end;
end;

procedure EmitData(const AConnection: TConnection;
  const AOutbound: IBlockingQueue<TFrame>; const AWaitLock: TCriticalSection;
  const AStreamId: LongWord; const ATimeoutMs: Integer;
  const APeerDone, APeerReset: PLongInt; var AUploadStopped: Boolean;
  var ABytesSent: Int64; const AData; const ACount: Integer;
  const AEndStream: Boolean);
var
  Offset, Count: Integer;
  Want: LongWord;
  Chunk: TBytes;
  Src: PByte;
begin
  if ACount = 0 then
  begin
    AOutbound.Push(BuildDataFrame(AStreamId, nil, AEndStream));
    Exit;
  end;
  if AUploadStopped then Exit;
  Inc(ABytesSent, ACount);
  Src := PByte(@AData);
  Offset := 0;
  while Offset < ACount do
  begin
    Want := FrameSize(AConnection);
    Count := ACount - Offset;
    if LongWord(Count) < Want then Want := LongWord(Count);
    Count := Integer(AcquireCredit(AConnection, AStreamId, Want, ATimeoutMs,
      AWaitLock, APeerDone));
    if Count = 0 then
    begin
      AUploadStopped := True;
      if InterlockedExchangeAdd(APeerReset^, 0) = 0 then
        AConnection.PostFrame(BuildRstStreamFrame(AStreamId, ecCancel));
      Exit;
    end;
    // the frame owns its payload, so the octets are copied once (D25)
    SetLength(Chunk, Count);
    Move(Src^, Chunk[0], Count);
    Inc(Src, Count);
    Inc(Offset, Count);
    AOutbound.Push(BuildDataFrame(AStreamId, Chunk,
      AEndStream and (Offset >= ACount)));
  end;
end;

procedure LeaseSendHeaders(const ARequest: TStreamRequest;
  const AEncoder: THpackCodec; const AOutbound: IBlockingQueue<TFrame>;
  const AStreamId: LongWord; const AMaxFrameSize: LongWord;
  var ALocalState: TLeaseLocalState);
var
  Block: TBytes;
  Bodyless: Boolean;
begin
  if ALocalState <> lsIdle then
    raise EHttpProtocolError.Create('HEADERS already sent or stream closed',
      ecProtocolError);
  Block := AEncoder.Encode(BuildRequestHeaderBlock(ARequest));
  Bodyless := (not ARequest.Body.IsSet) and (ARequest.BodyWriter = nil);
  EmitHeaderBlock(AOutbound, AStreamId, AMaxFrameSize, Block, Bodyless);
  if Bodyless then ALocalState := lsLocalHalfClosed
  else ALocalState := lsHeadersSent;
end;

procedure LeaseSendData(const AConnection: TConnection;
  const AOutbound: IBlockingQueue<TFrame>; const AWaitLock: TCriticalSection;
  const AStreamId: LongWord; const ATimeoutMs: Integer;
  const APeerDone, APeerReset: PLongInt; var AUploadStopped: Boolean;
  var ABytesSent: Int64; var ALocalState: TLeaseLocalState;
  const AData: TBytes; const AEndStream: Boolean);
var
  NoData: Byte;
begin
  if ALocalState = lsIdle then
    raise EHttpProtocolError.Create('cannot send DATA before HEADERS',
      ecProtocolError);
  if ALocalState <> lsHeadersSent then
    raise EHttpProtocolError.Create(
      'cannot send DATA on a half-closed or closed stream', ecStreamClosed);
  NoData := 0;
  if Length(AData) > 0 then
    EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
      APeerDone, APeerReset, AUploadStopped, ABytesSent, AData[0],
      Length(AData), AEndStream)
  else
    EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
      APeerDone, APeerReset, AUploadStopped, ABytesSent, NoData, 0,
      AEndStream);
  if AEndStream then ALocalState := lsLocalHalfClosed;
end;

procedure LeaseSendBody(const AConnection: TConnection;
  const ARequest: TStreamRequest; const AOutbound: IBlockingQueue<TFrame>;
  const AWaitLock: TCriticalSection; const AStreamId: LongWord;
  const ATimeoutMs: Integer; const APeerDone, APeerReset: PLongInt;
  var AUploadStopped: Boolean; var ABytesSent: Int64;
  var ALocalState: TLeaseLocalState);
var
  Cur, Ahead, Swap: TChunkBuffer;
  PendingSet: Boolean;
  NoData: Byte;
  Body: TBytes;
begin
  if ALocalState = lsIdle then
    raise EHttpProtocolError.Create('cannot send a body before HEADERS',
      ecProtocolError);
  if ALocalState <> lsHeadersSent then
    raise EHttpProtocolError.Create(
      'cannot send a body on a half-closed or closed stream', ecStreamClosed);
  NoData := 0;
  if ARequest.Body.IsSet then
  begin
    Body := ARequest.Body.Data;
    if Length(Body) > 0 then
      EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
        APeerDone, APeerReset, AUploadStopped, ABytesSent, Body[0],
        Length(Body), True)
    else
      EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
        APeerDone, APeerReset, AUploadStopped, ABytesSent, NoData, 0, True);
  end
  else if ARequest.BodyWriter <> nil then
  begin
    // Ahead holds the chunk that waits for the next one, so that the last
    // DATA frame carries END_STREAM (D16). Cur receives the next chunk.
    Cur := TChunkBuffer.Create;
    Ahead := TChunkBuffer.Create;
    try
      PendingSet := False;
      Cur.Reset;
      while (not AUploadStopped) and ARequest.BodyWriter.NextChunk(Cur) do
      begin
        if PendingSet then
          EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
            APeerDone, APeerReset, AUploadStopped, ABytesSent,
            Ahead.Memory^, Ahead.Size, False);
        Swap := Cur;
        Cur := Ahead;
        Ahead := Swap;
        PendingSet := True;
        Cur.Reset;
      end;
      if PendingSet then
        EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
          APeerDone, APeerReset, AUploadStopped, ABytesSent,
          Ahead.Memory^, Ahead.Size, True)
      else
        EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
          APeerDone, APeerReset, AUploadStopped, ABytesSent, NoData, 0, True);
    finally
      Ahead.Free;
      Cur.Free;
    end;
  end
  else
    raise EHttpProtocolError.Create('SendBody called with no body',
      ecInternalError);
  ALocalState := lsLocalHalfClosed;
end;

procedure LeaseEndSend(const AConnection: TConnection;
  const AOutbound: IBlockingQueue<TFrame>; const AWaitLock: TCriticalSection;
  const AStreamId: LongWord; const ATimeoutMs: Integer;
  const APeerDone, APeerReset: PLongInt; var AUploadStopped: Boolean;
  var ABytesSent: Int64; var ALocalState: TLeaseLocalState);
var
  NoData: Byte;
begin
  if ALocalState = lsIdle then
    raise EHttpProtocolError.Create('cannot end before HEADERS', ecProtocolError);
  if ALocalState = lsLocalHalfClosed then
    raise EHttpProtocolError.Create('local side already half-closed',
      ecStreamClosed);
  NoData := 0;
  EmitData(AConnection, AOutbound, AWaitLock, AStreamId, ATimeoutMs,
    APeerDone, APeerReset, AUploadStopped, ABytesSent, NoData, 0, True);
  ALocalState := lsLocalHalfClosed;
end;

end.
