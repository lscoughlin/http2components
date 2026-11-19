{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, environment, watchdog, stop, latency, test, fpcunit
notes:
  - This unit tests the stop of the watchdog of the WebSocket environment.
  - A session that waits for Init starts the watchdog. The test starts it with
    a deadline far away, so the watchdog only parks, and then times Stop.
---
}
/// Unit tests for the stop of the WebSocket environment
unit Http2.Server.WebSocket.Environment.Test;

{$mode delphi}{$H+}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, fpcunit, testregistry,
  Http2.Server.Limits, Http2.Server.WebSocket.Options, Http2.Server.WebSocket.Types,
  Http2.Server.WebSocket.Environment;

type
  /// a session that waits for Init and never times out in these tests
  TNoopInitWatch = class(TInterfacedObject, IWsInitWatch)
  public
    procedure InitTimedOut;
  end;

  /// tests of the stop of the watchdog
  TWsEnvironmentStopTest = class(TTestCase)
  published
    procedure TestStopWakesTheWatchdogPromptly;
  end;

implementation

{ TNoopInitWatch }

procedure TNoopInitWatch.InitTimedOut;
begin
end;

{ TWsEnvironmentStopTest }

procedure TWsEnvironmentStopTest.TestStopWakesTheWatchdogPromptly;
var
  Env: TWsEnvironment;
  EnvRef: IInterface;
  Watch: IWsInitWatch;
  I: Integer;
  Start: QWord;
  Elapsed: QWord;
begin
  // the watchdog sleeps up to 50 ms between sweeps; a Stop that wakes it returns in
  // about a millisecond, so 100 ms is a wide bound
  for I := 1 to 20 do
  begin
    Env := TWsEnvironment.Create(TWsOptions.Create, TMonotonicClock.Create, nil);
    EnvRef := Env;
    Watch := TNoopInitWatch.Create;
    try
      Env.WatchInit(Watch, GetTickCount64 + 60000);
      Sleep(20);   // the watchdog parks between two sweeps
      Start := GetTickCount64;
      Env.Stop;
      Elapsed := GetTickCount64 - Start;
      AssertTrue('run ' + IntToStr(I) + ': Stop took ' + IntToStr(Elapsed) + ' ms',
        Elapsed < 100);
    finally
      Watch := nil;
      EnvRef := nil;
    end;
  end;
end;

initialization
  RegisterTest(TWsEnvironmentStopTest);

end.
