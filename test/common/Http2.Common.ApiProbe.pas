{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, api, probe
notes:
  - This program compiles and uses the shared public facade only.
---
}
program Http2.Common.ApiProbe;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}

uses
  SysUtils, Classes, Http2.Common;

var
  Headers: IHttpHeaders;
  Codec: THpackCodec;
  Fields: THeaderBlock;
  Encoded: TBytes;
  Settings: TConnectionSettings;
  Frame: TFrame;
  Window: TWindow;
  CaughtBase: Boolean;
begin
  Headers := NewHttpHeaders;
  Headers.Add(HeaderContentType, 'text/plain');
  if Headers.GetFirst(HeaderContentType) <> 'text/plain' then
    Halt(1);

  Codec := THpackCodec.Create;
  try
    SetLength(Fields, 1);
    Fields[0].Name := HeaderMethod;
    Fields[0].Value := 'GET';
    Encoded := Codec.Encode(Fields);
    Fields := Codec.Decode(Encoded);
    if (Length(Fields) <> 1) or (Fields[0].Value <> 'GET') then
      Halt(2);
  finally
    Codec.Free;
  end;

  Settings := TConnectionSettings.Defaults;
  Frame := BuildSettingsFrame(Settings);
  ValidateFrame(Frame);
  if Frame.Header.FrameType <> ftSettings then
    Halt(3);

  Window := TWindow.Defaults(DefaultWindowSize);
  if Window.Size <> DefaultWindowSize then
    Halt(4);
  if Http2ErrorCodeName(ecNoError) <> 'NO_ERROR' then
    Halt(5);

  CaughtBase := False;
  try
    raise EHttpProtocolError.Create('identity probe', ecProtocolError);
  except
    on E: EHttpError do
      CaughtBase := E.ErrorCode = ecProtocolError;
  end;
  if not CaughtBase then
    Halt(6);
end.
