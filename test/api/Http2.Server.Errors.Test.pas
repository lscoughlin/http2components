{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, tests
notes:
  - This test set preserves its source project cases for the common API.
---
}
/// Unit tests for Http2.Server.Errors
unit Http2.Server.Errors.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Server.Errors,
  Http2.Client.Errors;

type
  TServerErrorsTest = class(TTestCase)
  published
    procedure TestHierarchyIsComplete;
    procedure TestDefaultErrorCodeIsInternal;
    procedure TestExplicitErrorCodeIsKept;
    procedure TestStreamErrorCarriesStreamId;
    procedure TestExceptionRaiseAndCatchByBase;
    procedure TestErrorCodeNames;
  end;

implementation

procedure TServerErrorsTest.TestHierarchyIsComplete;
begin
  AssertTrue('EHttpConnectionError is EHttpError',
    EHttpConnectionError.InheritsFrom(EHttpError));
  AssertTrue('EHttpProtocolError is EHttpError',
    EHttpProtocolError.InheritsFrom(EHttpError));
  AssertTrue('EHttpStreamError is EHttpError',
    EHttpStreamError.InheritsFrom(EHttpError));
  AssertTrue('EHttpTimeout is EHttpError',
    EHttpTimeout.InheritsFrom(EHttpError));
  AssertTrue('EHttpConnectionClosed is EHttpError',
    EHttpConnectionClosed.InheritsFrom(EHttpError));
  AssertTrue('EHttpTooManyRedirects is EHttpError',
    Http2.Client.Errors.EHttpTooManyRedirects.InheritsFrom(EHttpError));
  AssertTrue('EHttpNotReplayable is EHttpError',
    Http2.Client.Errors.EHttpNotReplayable.InheritsFrom(EHttpError));
  AssertTrue('EServerConfigError is EHttpError',
    EServerConfigError.InheritsFrom(EHttpError));
  AssertTrue('EStreamCancelled is EHttpStreamError',
    EStreamCancelled.InheritsFrom(EHttpStreamError));
  AssertTrue('EStreamReset is EHttpStreamError',
    EStreamReset.InheritsFrom(EHttpStreamError));
  AssertTrue('EServerStopped is EHttpError',
    EServerStopped.InheritsFrom(EHttpError));
  AssertTrue('EHttpError is Exception',
    EHttpError.InheritsFrom(Exception));
end;

procedure TServerErrorsTest.TestDefaultErrorCodeIsInternal;
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

procedure TServerErrorsTest.TestExplicitErrorCodeIsKept;
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

procedure TServerErrorsTest.TestStreamErrorCarriesStreamId;
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

procedure TServerErrorsTest.TestExceptionRaiseAndCatchByBase;
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

procedure TServerErrorsTest.TestErrorCodeNames;
begin
  AssertEquals('NO_ERROR', Http2ErrorCodeName(ecNoError));
  AssertEquals('PROTOCOL_ERROR', Http2ErrorCodeName(ecProtocolError));
  AssertEquals('FLOW_CONTROL_ERROR', Http2ErrorCodeName(ecFlowControlError));
  AssertEquals('FRAME_SIZE_ERROR', Http2ErrorCodeName(ecFrameSizeError));
  AssertEquals('COMPRESSION_ERROR', Http2ErrorCodeName(ecCompressionError));
  AssertEquals('HTTP_1_1_REQUIRED', Http2ErrorCodeName(ecHttp11Required));
end;

initialization
  RegisterTest(TServerErrorsTest);
end.
