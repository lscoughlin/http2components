{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test_support
notes:
  - this contains helper types for client mock socket tests
---
}
unit Http2.Client.MockSocket.TestSupport;

{$mode delphi}{$H+}
interface

uses SysUtils, Classes, SyncObjs, fpcunit, Http2.Common.Frames,
  Http2.Client.Errors, Http2.Client.Connection, Http2.Client.Observer,
  Http2.Client, Http2.Client.Tls.Types, Http2.Client.Stream, Http2.Client.MockSocket.Support;

type
/// a worker that performs exactly one Read on a socket
TReadProbe = class(TThread)
private
  FSocket: IHttp2Socket;
  FDone: PRTLEvent;
  FDoneFlag: Boolean;
  FCount: Integer;
  FRaised: Boolean;
  FError: string;
protected
  procedure Execute; override;
public
  constructor Create(const ASocket: IHttp2Socket);
  destructor Destroy; override;
  function WaitDone(const ATimeoutMs: Integer): Boolean;
  property Count: Integer read FCount;
  property Raised: Boolean read FRaised;
  property Error: string read FError;
end;

/// a do-nothing IConnectionStream, so the observer tests can register and
/// unregister a stream without pulling in another test unit's fake lease
  TObserverTestLease = class(TInterfacedObject, IConnectionStream)
  public
    procedure OnConnectionFailed(const AMessage: string;
      const ACode: THttp2ErrorCode);
    procedure OnConnectionGoAway(const ALastStreamId: LongWord);
    procedure OnStreamFrame(const AFrame: TFrame);
  end;

/// bounded wait until at least ACount events of AKind are recorded
function WaitForObserverEvent(const AObs: TRecordingObserver;
  const AKind: TObserverEventKind; const ACount, ATimeoutMs: Integer): Boolean;
function BytesOfString(const A: string): TBytes;
function ReadAllBodyText(const ABody: IHttpBodyStream): string;
function StartLease(const AConn: TConnection; const AAlloc: TStreamIdAllocator;
  const AReq: TStreamRequest; out ALease: TStreamLease;
  out AIL: IConnectionStream): Boolean;


implementation
procedure TObserverTestLease.OnConnectionFailed(const AMessage: string;
  const ACode: THttp2ErrorCode);
begin
end;

procedure TObserverTestLease.OnConnectionGoAway(
  const ALastStreamId: LongWord);
begin
end;

procedure TObserverTestLease.OnStreamFrame(const AFrame: TFrame);
begin
end;

{ TReadProbe }

constructor TReadProbe.Create(const ASocket: IHttp2Socket);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FSocket := ASocket;
  FDone := RTLEventCreate;
end;

destructor TReadProbe.Destroy;
begin
  RTLEventDestroy(FDone);
  inherited Destroy;
end;

procedure TReadProbe.Execute;
var
  Buf: array[0..31] of Byte;
begin
  try
    try
      FCount := FSocket.Read(Buf, SizeOf(Buf));
    except
      on E: Exception do
      begin
        FRaised := True;
        FError := E.ClassName + ': ' + E.Message;
      end;
    end;
  finally
    FDoneFlag := True;
    RTLEventSetEvent(FDone);
  end;
end;

function TReadProbe.WaitDone(const ATimeoutMs: Integer): Boolean;
var
  Deadline: QWord;
  Remaining: Integer;
begin
  Deadline := GetTickCount64 + QWord(ATimeoutMs);
  while not FDoneFlag do
  begin
    if GetTickCount64 >= Deadline then
      Exit(False);
    Remaining := Integer(Deadline - GetTickCount64);
    RTLEventWaitFor(FDone, Remaining);
  end;
  Result := True;
end;

{ WaitForObserverEvent }

function WaitForObserverEvent(const AObs: TRecordingObserver;
  const AKind: TObserverEventKind; const ACount, ATimeoutMs: Integer): Boolean;
begin
  Result := AObs.WaitForCount(AKind, ACount, ATimeoutMs);
end;

{ shared test helpers }

function BytesOfString(const A: string): TBytes;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(A));
  for I := 1 to Length(A) do
    Result[I - 1] := Ord(A[I]);
end;

function ReadAllBodyText(const ABody: IHttpBodyStream): string;
var
  Buf: array[0..63] of Byte;
  N, I: LongInt;
begin
  Result := '';
  while True do
  begin
    N := ABody.Read(Buf, SizeOf(Buf));
    if N = 0 then
      Break;
    for I := 0 to N - 1 do
      Result := Result + Chr(Buf[I]);
  end;
end;

{ TObserverEmissionTest }


function StartLease(const AConn: TConnection; const AAlloc: TStreamIdAllocator;
  const AReq: TStreamRequest; out ALease: TStreamLease;
  out AIL: IConnectionStream): Boolean;
begin
  ALease := TStreamLease.Create(AConn, AAlloc, AReq);
  AIL := ALease;
  ALease.Start;
  Result := True;
end;

end.
