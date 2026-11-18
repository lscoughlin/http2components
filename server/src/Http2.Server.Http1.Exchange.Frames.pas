{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, exchange, frame, chunked, content-length, refusal, upgrade
notes:
  - This unit builds the octets that an HTTP/1.1 exchange writes around its head:
    one frame of a response body, the headers of a whole response with a body, the
    head of a refused upgrade, and the headers of a refusal. It holds no state, so
    a test calls it directly.
  - A body frame follows the framing that Http2.Server.Http1.ResponseHead chose. A
    chunked body gets a chunk size and a CRLF. A body with a Content-Length counts
    its octets against the length that remains.
  - The pull loop of a body writer and the sink of a producer body give each chunk to
    one write method of the exchange, so a producer body and a pulled body share the
    framing path of the exchange.
---
}
/// The octets that an HTTP/1.1 exchange writes around its head
unit Http2.Server.Http1.Exchange.Frames;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Http2.Server.Errors, Http2.Common.Hpack, Http2.Common.Body,
  Http2.Server.HandlerJob, Http2.Server.Http1.ResponseHead;

type
  /// the method of an exchange that writes one chunk of a body
  // - the exchange frames the octets and sends them; it copies them before it returns
  TH1ChunkWrite = procedure(const ABuffer; const ACount: Integer) of object;

  /// the sink that a producer body gives its chunks to
  // - a chunk with octets goes to the write method; the last call with no octets
  //   writes nothing, and the exchange then ends the body
  TH1BodySink = class(TInterfacedObject, IBodyChunkSink)
  private
    FWrite: TH1ChunkWrite;
  public
    constructor Create(const AWrite: TH1ChunkWrite);
    procedure Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
  end;

/// pull every chunk of AWriter and give its octets to AWrite, until the body ends
// - the octets of the call that returns False are written too (D22)
procedure H1PullBody(const AWriter: IBodyWriter; const AWrite: TH1ChunkWrite);

/// one frame of a response body, with the octets that the handler wrote
// - ARemaining is the count of octets that the Content-Length still allows; it is
//   counted down unless the end of the connection delimits the body
// - raises EHttpError when the handler writes more than its Content-Length
function H1BodyFrame(const ABuffer; const ACount: Integer;
  const AFraming: TH1ResponseFraming; var ARemaining: Int64): TBytes;

/// a copy of the headers, with a content-length header at the end
function H1WithContentLength(const AHeaders: THeaderBlock;
  const ALength: Integer): THeaderBlock;

/// the status line and the headers of an upgrade response, as text
// - the text ends with the empty line that closes the head
function H1UpgradeHeadText(const AStatus: Integer;
  const AHeaders: THeaderBlock): string;

/// the headers of a refused request; a stopped job has none
function H1RefusalHeaders(const AReason: THandlerJobRefusal): THeaderBlock;

implementation

uses
  Http2.Server.Http1.Status;

function H1BodyFrame(const ABuffer; const ACount: Integer;
  const AFraming: TH1ResponseFraming; var ARemaining: Int64): TBytes;
var
  Hex: string;
  Off: Integer;
begin
  Result := nil;
  if AFraming.Chunked then
  begin
    Hex := IntToHex(ACount, 1) + #13#10;
    SetLength(Result, Length(Hex) + ACount + 2);
    Move(Hex[1], Result[0], Length(Hex));
    Off := Length(Hex);
    Move(ABuffer, Result[Off], ACount);
    Result[Off + ACount] := 13;
    Result[Off + ACount + 1] := 10;
  end
  else
  begin
    if (not AFraming.CloseDelimited) and (ACount > ARemaining) then
      raise EHttpError.Create('the handler wrote more than its Content-Length');
    SetLength(Result, ACount);
    Move(ABuffer, Result[0], ACount);
    if not AFraming.CloseDelimited then
      Dec(ARemaining, ACount);
  end;
end;

function H1WithContentLength(const AHeaders: THeaderBlock;
  const ALength: Integer): THeaderBlock;
var
  N: Integer;
begin
  Result := Copy(AHeaders);
  N := Length(Result);
  SetLength(Result, N + 1);
  Result[N].Name := 'content-length';
  Result[N].Value := IntToStr(ALength);
  Result[N].Sensitive := False;
end;

function H1UpgradeHeadText(const AStatus: Integer;
  const AHeaders: THeaderBlock): string;
var
  I: Integer;
begin
  Result := Http1StatusLine(AStatus, 1);
  for I := 0 to High(AHeaders) do
    Result := Result + AHeaders[I].Name + ': ' + AHeaders[I].Value + #13#10;
  Result := Result + #13#10;
end;

function H1RefusalHeaders(const AReason: THandlerJobRefusal): THeaderBlock;
begin
  Result := nil;
  if AReason <> jrStopped then
  begin
    SetLength(Result, 1);
    Result[0].Name := 'retry-after';
    Result[0].Value := '1';
  end;
end;

constructor TH1BodySink.Create(const AWrite: TH1ChunkWrite);
begin
  inherited Create;
  FWrite := AWrite;
end;

procedure TH1BodySink.Chunk(const ABuffer; const ACount: Integer; const ALast: Boolean);
begin
  if ACount > 0 then
    FWrite(ABuffer, ACount);
end;

procedure H1PullBody(const AWriter: IBodyWriter; const AWrite: TH1ChunkWrite);
var
  Buf: TChunkBuffer;
  More: Boolean;
begin
  Buf := TChunkBuffer.Create;
  try
    repeat
      Buf.Reset;
      // the octets of the call that returns False are the last chunk (D22)
      More := AWriter.NextChunk(Buf);
      // AWrite copies the octets into the frame before it returns, so the
      // buffer is free for the next chunk after the call
      if Buf.Size > 0 then
        AWrite(Buf.Memory^, Buf.Size);
    until not More;
  finally
    Buf.Free;
  end;
end;

end.
