{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, errors
notes:
  - This test checks the common HTTP/2 error model without role dependencies.
---
}
unit Http2.Common.Errors.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Common.Errors;

type
  TCommonErrorsTest = class(TTestCase)
  published
    procedure TestErrorCodeOrdinals;
    procedure TestDefaultErrorCodeIsInternal;
    procedure TestExplicitErrorCodeIsKept;
    procedure TestStreamErrorCarriesStreamId;
    procedure TestExceptionRaiseAndCatchByBase;
    procedure TestErrorCodeNames;
  end;

implementation

procedure TCommonErrorsTest.TestErrorCodeOrdinals;
begin
  AssertEquals('NO_ERROR', 0, Ord(ecNoError));
  AssertEquals('PROTOCOL_ERROR', 1, Ord(ecProtocolError));
  AssertEquals('INTERNAL_ERROR', 2, Ord(ecInternalError));
  AssertEquals('FLOW_CONTROL_ERROR', 3, Ord(ecFlowControlError));
  AssertEquals('SETTINGS_TIMEOUT', 4, Ord(ecSettingsTimeout));
  AssertEquals('STREAM_CLOSED', 5, Ord(ecStreamClosed));
  AssertEquals('FRAME_SIZE_ERROR', 6, Ord(ecFrameSizeError));
  AssertEquals('REFUSED_STREAM', 7, Ord(ecRefusedStream));
  AssertEquals('CANCEL', 8, Ord(ecCancel));
  AssertEquals('COMPRESSION_ERROR', 9, Ord(ecCompressionError));
  AssertEquals('CONNECT_ERROR', 10, Ord(ecConnectError));
  AssertEquals('ENHANCE_YOUR_CALM', 11, Ord(ecEnhanceYourCalm));
  AssertEquals('INADEQUATE_SECURITY', 12, Ord(ecInadequateSecurity));
  AssertEquals('HTTP_1_1_REQUIRED', 13, Ord(ecHttp11Required));
end;

procedure TCommonErrorsTest.TestDefaultErrorCodeIsInternal;
var
  E: EHttpError;
begin
  E := EHttpError.Create('boom');
  try
    AssertEquals('default code', Ord(ecInternalError), Ord(E.ErrorCode));
    AssertEquals('message', 'boom', E.Message);
  finally
    E.Free;
  end;
end;

procedure TCommonErrorsTest.TestExplicitErrorCodeIsKept;
var
  E: EHttpProtocolError;
begin
  E := EHttpProtocolError.Create('bad frame', ecFrameSizeError);
  try
    AssertEquals('code', Ord(ecFrameSizeError), Ord(E.ErrorCode));
  finally
    E.Free;
  end;
end;

procedure TCommonErrorsTest.TestStreamErrorCarriesStreamId;
var
  E: EHttpStreamError;
begin
  E := EHttpStreamError.Create('reset', 7, ecRefusedStream);
  try
    AssertEquals('stream id', 7, E.StreamId);
    AssertEquals('code', Ord(ecRefusedStream), Ord(E.ErrorCode));
  finally
    E.Free;
  end;
end;

procedure TCommonErrorsTest.TestExceptionRaiseAndCatchByBase;
var
  Caught: Boolean;
  Code: THttp2ErrorCode;
begin
  Caught := False;
  try
    raise EHttpStreamError.Create('nope', 3, ecCancel);
  except
    on E: EHttpError do
    begin
      Caught := True;
      Code := E.ErrorCode;
      AssertEquals('stream id survived polymorphic catch', 3,
        (E as EHttpStreamError).StreamId);
    end;
  end;
  AssertTrue('caught via base class', Caught);
  AssertEquals('code survived', Ord(ecCancel), Ord(Code));
end;

procedure TCommonErrorsTest.TestErrorCodeNames;
begin
  AssertEquals('NO_ERROR', Http2ErrorCodeName(ecNoError));
  AssertEquals('PROTOCOL_ERROR', Http2ErrorCodeName(ecProtocolError));
  AssertEquals('FLOW_CONTROL_ERROR', Http2ErrorCodeName(ecFlowControlError));
  AssertEquals('FRAME_SIZE_ERROR', Http2ErrorCodeName(ecFrameSizeError));
  AssertEquals('COMPRESSION_ERROR', Http2ErrorCodeName(ecCompressionError));
  AssertEquals('HTTP_1_1_REQUIRED', Http2ErrorCodeName(ecHttp11Required));
end;

initialization
  RegisterTest(TCommonErrorsTest);
end.
