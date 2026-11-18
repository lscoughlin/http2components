{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: body_reader, body_writer, text
notes:
  - This unit reads a body as text and writes a text as a body.
  - The octets pass unchanged. The unit does not convert a charset.
---
}
unit Http2.Common.Body.Text;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, Http2.Common.Body, Http2.Common.Body.Streams;

type
  /// the writer of a text body; the octets of the text are the octets of the body
  TTextBodyWriter = class(TSerializedBodyWriter)
  private
    FText: string;
  protected
    procedure Serialize(const ATarget: TStream); override;
  public
    constructor Create(const AText: string);
  end;

/// read the body to its end and give its octets as a string
// - the octets are kept as they arrive; the unit does not convert a charset
// - AMax > 0 limits the length of the body; a longer body raises EBodyTooLarge
// - an exception of the reader passes to the caller
function ReadText(AReader: IBodyReader; AMax: Int64 = 0): string;

/// a body writer for AText; the octets of AText are the octets of the body
// - the writer keeps the text until the body ends; the text is not copied when the writer is made
function TextBodyWriter(const AText: string): IBodyWriter;

implementation

{ TTextBodyWriter }

constructor TTextBodyWriter.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
end;

procedure TTextBodyWriter.Serialize(const ATarget: TStream);
begin
  if Length(FText) > 0 then
    ATarget.WriteBuffer(FText[1], Length(FText));
end;

{ module routines }

function ReadText(AReader: IBodyReader; AMax: Int64): string;
var
  LBytes: TBytes;
begin
  LBytes := ReadAllBody(AReader, AMax);
  SetLength(Result, Length(LBytes));
  if Length(LBytes) > 0 then
    Move(LBytes[0], Result[1], Length(LBytes));
end;

function TextBodyWriter(const AText: string): IBodyWriter;
begin
  Result := TTextBodyWriter.Create(AText);
end;

end.
