{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, common, errors, type-identity
notes:
  - This test checks shared exception identity across both role units.
---
}
unit Http2.Api.ErrorsIdentity.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  fpcunit, testregistry, Http2.Common.Errors, Http2.Client.Errors,
  Http2.Server.Errors;

type
  TApiErrorIdentityTest = class(TTestCase)
  published
    procedure TestRoleUnitsAliasTheCommonBaseTypes;
    procedure TestClientRoleErrorUsesTheCommonBase;
    procedure TestServerRoleErrorUsesTheCommonBase;
  end;

implementation

procedure TApiErrorIdentityTest.TestRoleUnitsAliasTheCommonBaseTypes;
var
  ClientCode: Http2.Client.Errors.THttp2ErrorCode;
  ServerCode: Http2.Server.Errors.THttp2ErrorCode;
begin
  AssertTrue('client error class is common',
    Http2.Client.Errors.EHttpError = Http2.Common.Errors.EHttpError);
  AssertTrue('server error class is common',
    Http2.Server.Errors.EHttpError = Http2.Common.Errors.EHttpError);
  AssertTrue('client connection error class is common',
    Http2.Client.Errors.EHttpConnectionError =
      Http2.Common.Errors.EHttpConnectionError);
  AssertTrue('server connection error class is common',
    Http2.Server.Errors.EHttpConnectionError =
      Http2.Common.Errors.EHttpConnectionError);
  AssertTrue('client protocol error class is common',
    Http2.Client.Errors.EHttpProtocolError =
      Http2.Common.Errors.EHttpProtocolError);
  AssertTrue('server protocol error class is common',
    Http2.Server.Errors.EHttpProtocolError =
      Http2.Common.Errors.EHttpProtocolError);
  AssertTrue('client stream error class is common',
    Http2.Client.Errors.EHttpStreamError =
      Http2.Common.Errors.EHttpStreamError);
  AssertTrue('server stream error class is common',
    Http2.Server.Errors.EHttpStreamError =
      Http2.Common.Errors.EHttpStreamError);
  AssertTrue('client timeout class is common',
    Http2.Client.Errors.EHttpTimeout = Http2.Common.Errors.EHttpTimeout);
  AssertTrue('server timeout class is common',
    Http2.Server.Errors.EHttpTimeout = Http2.Common.Errors.EHttpTimeout);
  AssertTrue('client closed class is common',
    Http2.Client.Errors.EHttpConnectionClosed =
      Http2.Common.Errors.EHttpConnectionClosed);
  AssertTrue('server closed class is common',
    Http2.Server.Errors.EHttpConnectionClosed =
      Http2.Common.Errors.EHttpConnectionClosed);
  ClientCode := Http2.Common.Errors.ecCancel;
  ServerCode := ClientCode;
  AssertEquals('client enum value is common',
    Ord(Http2.Common.Errors.ecCancel), Ord(ClientCode));
  AssertEquals('server enum value is common',
    Ord(Http2.Common.Errors.ecCancel), Ord(ServerCode));
end;

procedure TApiErrorIdentityTest.TestClientRoleErrorUsesTheCommonBase;
var
  Caught: Boolean;
begin
  Caught := False;
  try
    raise Http2.Client.Errors.EHttpProxyConfigError.Create('bad proxy');
  except
    on E: Http2.Common.Errors.EHttpError do
      Caught := E.Message = 'bad proxy';
  end;
  AssertTrue('client error is caught by common base', Caught);
end;

procedure TApiErrorIdentityTest.TestServerRoleErrorUsesTheCommonBase;
var
  Caught: Boolean;
begin
  Caught := False;
  try
    raise Http2.Server.Errors.EServerStopped.Create('stopped');
  except
    on E: Http2.Common.Errors.EHttpError do
      Caught := E.Message = 'stopped';
  end;
  AssertTrue('server error is caught by common base', Caught);
end;

initialization
  RegisterTest(TApiErrorIdentityTest);
end.
