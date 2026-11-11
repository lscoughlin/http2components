{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, tests
notes:
  - This test set preserves its source project cases for the common API.
---
}
/// Unit tests for Http2.Client.Errors (plan story S01, task 01.1)
// - run with `make test`
unit Http2.Client.Errors.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, fpcunit, testregistry, Http2.Client.Errors;

type
  TClientErrorsTest = class(TTestCase)
  published
    procedure TestHierarchyIsComplete;
    procedure TestDefaultErrorCodeIsInternal;
    procedure TestExplicitErrorCodeIsKept;
    procedure TestStreamErrorCarriesStreamId;
    procedure TestExceptionRaiseAndCatchByBase;
    procedure TestErrorCodeNames;
    procedure TestClientCertificateErrorsAreCatchableByTheirBases;
  end;

implementation

procedure TClientErrorsTest.TestHierarchyIsComplete;
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
    EHttpTooManyRedirects.InheritsFrom(EHttpError));
  AssertTrue('EHttpNotReplayable is EHttpError',
    EHttpNotReplayable.InheritsFrom(EHttpError));
  AssertTrue('EHttpError is Exception',
    EHttpError.InheritsFrom(Exception));
end;

procedure TClientErrorsTest.TestDefaultErrorCodeIsInternal;
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

procedure TClientErrorsTest.TestExplicitErrorCodeIsKept;
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

procedure TClientErrorsTest.TestStreamErrorCarriesStreamId;
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

procedure TClientErrorsTest.TestExceptionRaiseAndCatchByBase;
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

procedure TClientErrorsTest.TestErrorCodeNames;
begin
  AssertEquals('NO_ERROR', Http2ErrorCodeName(ecNoError));
  AssertEquals('PROTOCOL_ERROR', Http2ErrorCodeName(ecProtocolError));
  AssertEquals('FLOW_CONTROL_ERROR', Http2ErrorCodeName(ecFlowControlError));
  AssertEquals('FRAME_SIZE_ERROR', Http2ErrorCodeName(ecFrameSizeError));
  AssertEquals('COMPRESSION_ERROR', Http2ErrorCodeName(ecCompressionError));
  AssertEquals('HTTP_1_1_REQUIRED', Http2ErrorCodeName(ecHttp11Required));
end;

procedure TClientErrorsTest.TestClientCertificateErrorsAreCatchableByTheirBases;
var
  BaseSeen, ConnSeen: Boolean;
  Alert: string;
begin
  AssertTrue('config error is an EHttpError',
    EHttpTlsConfigError.InheritsFrom(EHttpError));
  AssertFalse('config error is not a connection error',
    EHttpTlsConfigError.InheritsFrom(EHttpConnectionError));
  AssertTrue('client auth error is an EHttpConnectionError',
    EHttpTlsClientAuthError.InheritsFrom(EHttpConnectionError));
  BaseSeen := False;
  try
    raise EHttpTlsConfigError.Create('bad identity');
  except
    on E: EHttpError do
      BaseSeen := E.Message = 'bad identity';
  end;
  AssertTrue('config error caught by EHttpError', BaseSeen);
  ConnSeen := False;
  Alert := '';
  try
    raise EHttpTlsClientAuthError.Create('rejected', 'unknown ca');
  except
    on E: EHttpConnectionError do
    begin
      ConnSeen := True;
      Alert := (E as EHttpTlsClientAuthError).Alert;
    end;
  end;
  AssertTrue('client auth error caught by EHttpConnectionError', ConnSeen);
  AssertEquals('alert survived', 'unknown ca', Alert);
end;

initialization
  RegisterTest(TClientErrorsTest);
end.
