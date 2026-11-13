{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: async, trace, connection start, diagnostics
notes:
  - This unit writes the start trace of the async server connections.
  - The trace is off unless the environment variable HTTP2_TEST_TRACE has a
    value. When it is off, each call costs one test of a Boolean.
  - A line has the form
    "HTTP2_TEST_TRACE CONN <event> conn=<id> tid=<thread> t_us=<monotonic>".
    The events are accept, first_read, first_write and settings_write.
---
}
/// The start trace of the async server connections
unit Http2.Server.Async.Trace;

{$mode delphi}{$H+}

interface

type
  /// the event of the connection start that the trace reports
  TAsyncTraceEvent = (teAccept, teFirstRead, teFirstWrite, teSettingsWrite);

  /// the trace state of one connection: its id and the events already reported
  TConnTrace = record
    Id: Cardinal;
    Seen: set of TAsyncTraceEvent;
  end;

  /// the receiver of one trace line; the default receiver writes to StdErr
  TAsyncTraceSink = procedure(const ALine: string) of object;

/// switch the trace on or off, and set the receiver of the lines
// - a nil receiver restores the StdErr receiver
procedure SetAsyncTrace(const AOn: Boolean; const ASink: TAsyncTraceSink = nil);
/// true when the trace is on
function AsyncTraceOn: Boolean;
/// start the trace of a connection and report its accept
procedure TraceAccept(var ATrace: TConnTrace; const AId: Cardinal);
/// report the first read event of the connection, once
procedure TraceFirstRead(var ATrace: TConnTrace);
/// report the first write of the connection, and the write of the server
/// SETTINGS frame, once each
procedure TraceWrite(var ATrace: TConnTrace; const AData: Pointer;
  const ALength: SizeInt);

implementation

uses
  SysUtils, SyncObjs,
  mormot.core.os;

const
  cEventNames: array[TAsyncTraceEvent] of string =
    ('accept', 'first_read', 'first_write', 'settings_write');
  cFrameHeaderBytes = 9;
  cFrameTypeSettings = 4;
  cFlagAck = 1;

type
  /// the default receiver: one line on StdErr
  TStdErrSink = class
    procedure Write(const ALine: string);
  end;

var
  GOn: Boolean;
  GSink: TAsyncTraceSink;
  GLock: TCriticalSection;
  GStdErrSink: TStdErrSink;

procedure TStdErrSink.Write(const ALine: string);
begin
  WriteLn(StdErr, ALine);
  Flush(StdErr);
end;

procedure SetAsyncTrace(const AOn: Boolean; const ASink: TAsyncTraceSink);
begin
  GLock.Enter;
  try
    if Assigned(ASink) then
      GSink := ASink
    else
      GSink := GStdErrSink.Write;
    GOn := AOn;
  finally
    GLock.Leave;
  end;
end;

function AsyncTraceOn: Boolean;
begin
  Result := GOn;
end;

procedure Emit(var ATrace: TConnTrace; const AEvent: TAsyncTraceEvent);
var
  Micros: Int64;
  Line: string;
begin
  if AEvent in ATrace.Seen then
    Exit;
  Include(ATrace.Seen, AEvent);
  QueryPerformanceMicroSeconds(Micros);
  Line := 'HTTP2_TEST_TRACE CONN ' + cEventNames[AEvent] +
    ' conn=' + IntToStr(ATrace.Id) +
    ' tid=' + IntToStr(PtrUInt(GetCurrentThreadId)) +
    ' t_us=' + IntToStr(Micros);
  GLock.Enter;
  try
    try
      GSink(Line);
    except
      // a failed trace line must never end an IO thread
    end;
  finally
    GLock.Leave;
  end;
end;

procedure TraceAccept(var ATrace: TConnTrace; const AId: Cardinal);
begin
  ATrace.Id := AId;
  ATrace.Seen := [];
  if GOn then
    Emit(ATrace, teAccept);
end;

procedure TraceFirstRead(var ATrace: TConnTrace);
begin
  if GOn then
    Emit(ATrace, teFirstRead);
end;

procedure TraceWrite(var ATrace: TConnTrace; const AData: Pointer;
  const ALength: SizeInt);
var
  P: PByte;
begin
  if not GOn then
    Exit;
  Emit(ATrace, teFirstWrite);
  if (teSettingsWrite in ATrace.Seen) or (ALength < cFrameHeaderBytes) then
    Exit;
  // the first frame of the chunk is a SETTINGS frame that is not an ACK
  P := PByte(AData);
  if (P[3] = cFrameTypeSettings) and ((P[4] and cFlagAck) = 0) then
    Emit(ATrace, teSettingsWrite);
end;

initialization
  GLock := TCriticalSection.Create;
  GStdErrSink := TStdErrSink.Create;
  GSink := GStdErrSink.Write;
  GOn := GetEnvironmentVariable('HTTP2_TEST_TRACE') <> '';

finalization
  GStdErrSink.Free;
  GLock.Free;

end.
