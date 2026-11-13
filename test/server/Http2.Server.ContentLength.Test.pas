{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, content-length, test
notes:
  - Tests for a request head that carries END_STREAM and a declared
    content-length above 0.
  - Such a head declares a body, but no DATA frame follows it. The server
    resets the stream with PROTOCOL_ERROR (RFC 9113 section 8.1.1) and does
    not call the handler.
  - The tests drive the core in memory with the peer of Http2.Server.H2Peer.
---
}
/// Tests of a request head with END_STREAM and a declared content-length
unit Http2.Server.ContentLength.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Server.Errors, Http2.Common.Frames, Http2.Common.Hpack,
  Http2.Server.Stream, Http2.Server.H2Peer;

type
  TContentLengthHeadTest = class(TTestCase)
  private
    FPeer: TH2Peer;
    procedure Start;
    function HeadWithLength(const AValue: string): THeaderBlock;
    function ResetCodeOf(const AStreamId: LongWord): string;
  protected
    procedure TearDown; override;
  published
    procedure TestEndStreamWithLengthAboveZeroIsAProtocolError;
    procedure TestEndStreamWithLengthZeroPasses;
    procedure TestEndStreamWithoutLengthPasses;
    procedure TestHeadWithoutEndStreamIsUnchanged;
  end;

implementation

procedure TContentLengthHeadTest.TearDown;
begin
  FreeAndNil(FPeer);
end;

procedure TContentLengthHeadTest.Start;
begin
  FPeer := TH2Peer.Create(TPeerOptions.Default);
  FPeer.SendPreface;
  FPeer.SendSettings([], []);
  FPeer.Pump;
end;

function TContentLengthHeadTest.HeadWithLength(const AValue: string): THeaderBlock;
begin
  Result := RequestFields('POST', '/');
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)].Name := 'content-length';
  Result[High(Result)].Value := AValue;
end;

function TContentLengthHeadTest.ResetCodeOf(const AStreamId: LongWord): string;
var
  Code: THttp2ErrorCode;
begin
  if FPeer.ResetCode(AStreamId, Code) then
    Result := Http2ErrorCodeName(Code)
  else
    Result := '(none)';
end;

procedure TContentLengthHeadTest.TestEndStreamWithLengthAboveZeroIsAProtocolError;
begin
  Start;
  FPeer.SendHeaders(1, HeadWithLength('100'), True);
  FPeer.Pump;
  AssertEquals('stream 1 is reset', 'PROTOCOL_ERROR', ResetCodeOf(1));
  AssertEquals('the handler is not called', 0, FPeer.Events.Requests);
end;

procedure TContentLengthHeadTest.TestEndStreamWithLengthZeroPasses;
begin
  Start;
  FPeer.SendHeaders(1, HeadWithLength('0'), True);
  FPeer.Pump;
  AssertEquals('no reset', '(none)', ResetCodeOf(1));
  AssertEquals('the handler is called', 1, FPeer.Events.Requests);
end;

procedure TContentLengthHeadTest.TestEndStreamWithoutLengthPasses;
begin
  Start;
  FPeer.SendGet(1);
  FPeer.Pump;
  AssertEquals('no reset', '(none)', ResetCodeOf(1));
  AssertEquals('the handler is called', 1, FPeer.Events.Requests);
end;

procedure TContentLengthHeadTest.TestHeadWithoutEndStreamIsUnchanged;
begin
  Start;
  FPeer.SendHeaders(1, HeadWithLength('100'), False);
  FPeer.Pump;
  AssertEquals('no reset', '(none)', ResetCodeOf(1));
  AssertEquals('the handler is called', 1, FPeer.Events.Requests);
end;

initialization
  RegisterTest(TContentLengthHeadTest);
end.
