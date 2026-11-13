{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, client, header block, continuation
notes:
  - This unit joins a header block that spans HEADERS and CONTINUATION frames.
  - The connection reader owns the assembler. It takes no lock.
---
}
unit Http2.Client.Connection.HeaderBlock;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Http2.Common.Errors, Http2.Common.Hpack, Http2.Common.Headers;

type
  /// joins the fragments of one header block (RFC 9113 section 4.3)
  // - Start opens a block, Append adds a CONTINUATION fragment and Take
  //   returns the joined bytes and closes the block
  THeaderBlockAssembler = class
  private
    FOpen: Boolean;
    FStreamId: LongWord;
    FBytes: TBytes;
    FMaxBytes: Int64;
    procedure CheckLimit(const ASize: Int64);
  public
    /// open a block for AStreamId; replaces any block that is still open
    procedure Start(AStreamId: LongWord; const AFragment: TBytes);
    /// add a CONTINUATION fragment; raises EHttpProtocolError when AStreamId
    // differs from the open block or when no block is open
    procedure Append(AStreamId: LongWord; const AFragment: TBytes);
    /// return the joined bytes and close the block
    function Take: TBytes;
    /// the byte count of the open block (0 when no block is open)
    function Size: Int64;
    /// the stream of the open block (0 when no block is open)
    function OpenStreamId: LongWord;
    /// the limit for the open block; 0 means no limit (not enforced here)
    property MaxBytes: Int64 read FMaxBytes write FMaxBytes;
  end;

/// refuse a decoded header block whose field values hold CR, LF or NUL
// - the HPACK decoder accepts these octets, so the connection checks them
procedure ValidateDecodedFields(const ABlock: THeaderBlock);

implementation

procedure THeaderBlockAssembler.CheckLimit(const ASize: Int64);
begin
  if (FMaxBytes > 0) and (ASize > FMaxBytes) then
    raise EHttpProtocolError.Create(Format(
      'header block exceeds %d bytes', [FMaxBytes]), ecEnhanceYourCalm);
end;

procedure ValidateDecodedFields(const ABlock: THeaderBlock);
var
  I: Integer;
begin
  for I := 0 to High(ABlock) do
    if not IsValidHeaderValue(ABlock[I].Value) then
      raise EHttpProtocolError.Create(
        'header value holds CR, LF or NUL', ecProtocolError);
end;

procedure THeaderBlockAssembler.Start(AStreamId: LongWord;
  const AFragment: TBytes);
begin
  CheckLimit(Length(AFragment));
  FOpen := True;
  FStreamId := AStreamId;
  FBytes := Copy(AFragment, 0, Length(AFragment));
end;

procedure THeaderBlockAssembler.Append(AStreamId: LongWord;
  const AFragment: TBytes);
var
  N: Integer;
begin
  if (not FOpen) or (FStreamId <> AStreamId) then
    raise EHttpProtocolError.Create('unexpected CONTINUATION stream',
      ecProtocolError);
  CheckLimit(Size + Length(AFragment));
  N := Length(FBytes);
  SetLength(FBytes, N + Length(AFragment));
  if Length(AFragment) > 0 then
    Move(AFragment[0], FBytes[N], Length(AFragment));
end;

function THeaderBlockAssembler.Take: TBytes;
begin
  Result := FBytes;
  FBytes := nil;
  FOpen := False;
  FStreamId := 0;
end;

function THeaderBlockAssembler.Size: Int64;
begin
  Result := Length(FBytes);
end;

function THeaderBlockAssembler.OpenStreamId: LongWord;
begin
  if FOpen then
    Result := FStreamId
  else
    Result := 0;
end;

end.
