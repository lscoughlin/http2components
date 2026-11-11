{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.Clock.Hook.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Redirects.Test,
  Http2.Client.ClearText.Support, Http2.Client.Http1, Http2.Client.Http1.Test, Http2.Client.Sse, Http2.Client.RequestObserver.Support;

type
  TClockHookTest = class(TTestCase)
  published
    procedure TestHookReplacesTheClockUntilReset;
  end;

implementation

procedure TClockHookTest.TestHookReplacesTheClockUntilReset;
begin
  GScriptedUs := 123456;
  SetNowUsHook(ScriptedClock);
  AssertEquals('the hook answers', 123456, NowUs);
  GScriptedUs := 7;
  AssertEquals('and follows the script', 7, NowUs);
  ResetNowUsHook;
  AssertTrue('the system clock is back', NowUs <> 7);
  GScriptedUs := 8;
  SetNowUsHook(ScriptedClock);
  AssertEquals(8, NowUs);
  SetNowUsHook(nil);
  AssertTrue('nil restores it too', NowUs <> 8);
end;


initialization
  RegisterTest(TClockHookTest);
end.
