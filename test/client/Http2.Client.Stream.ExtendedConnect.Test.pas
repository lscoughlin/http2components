{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this tests the :protocol pseudo-header and the KeepOpen flag of a stream request (RFC 8441)
---
}
unit Http2.Client.Stream.ExtendedConnect.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Client.Connection, Http2.Client.Stream.Types,
  Http2.Client.Stream.Send, Http2.Common.Frames, Http2.Common.Headers,
  Http2.Common.Hpack;

type
  TStreamExtendedConnectTest = class(TTestCase)
  private
    procedure SendHeaders(const ARequest: TStreamRequest; out AFrame: TFrame;
      out AState: TLeaseLocalState);
  published
    procedure TestProtocolNameIsTheConstant;
    procedure TestHeaderBlockHasProtocolAndRegularFields;
    procedure TestKeepOpenLeavesStreamOpen;
    procedure TestWithoutKeepOpenEndsStream;
    procedure TestConnectWithoutProtocolIsUnchanged;
    procedure TestProtocolRequestChecksItsFields;
  end;

implementation

/// a CONNECT request for the WebSocket protocol, with two regular fields
function ConnectRequest: TStreamRequest;
begin
  Result := TStreamRequest.Create('CONNECT', 'example.test:443')
    .WithScheme('https')
    .WithPath('/chat')
    .WithProtocol('websocket')
    .WithHeader('sec-websocket-version', '13')
    .WithHeader('origin', 'https://example.test');
end;

/// send the HEADERS of ARequest on stream 1; AFrame is the HEADERS frame
procedure TStreamExtendedConnectTest.SendHeaders(const ARequest: TStreamRequest;
  out AFrame: TFrame; out AState: TLeaseLocalState);
var
  Queue: IBlockingQueue<TFrame>;
  Encoder: THpackCodec;
begin
  Queue := TBlockingQueue<TFrame>.Create(0);
  Encoder := THpackCodec.Create;
  try
    AState := lsIdle;
    LeaseSendHeaders(ARequest, Encoder, Queue, 1, 16384, AState);
    AssertTrue('one HEADERS frame is sent', Queue.TryPop(AFrame));
    AssertEquals('frame is HEADERS', Ord(ftHeaders), Ord(AFrame.Header.FrameType));
    AssertEquals('stream id is 1', LongWord(1), AFrame.Header.StreamId);
  finally
    Encoder.Free;
  end;
end;

/// decode the header block of AFrame
function DecodeBlock(const AFrame: TFrame): THeaderBlock;
var
  Decoder: THpackCodec;
begin
  Decoder := THpackCodec.Create;
  try
    Result := Decoder.Decode(ExtractHeaderBlock(AFrame));
  finally
    Decoder.Free;
  end;
end;

/// the value of the first field named AName, or '' when absent
function FieldValue(const AFields: THeaderBlock; const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AFields) do
    if AFields[I].Name = AName then
    begin
      Result := AFields[I].Value;
      Exit;
    end;
end;

/// True when LeaseSendHeaders of ARequest raises EHttpError
function HeadersRaise(const ARequest: TStreamRequest): Boolean;
var
  Queue: IBlockingQueue<TFrame>;
  Encoder: THpackCodec;
  State: TLeaseLocalState;
begin
  Result := False;
  Queue := TBlockingQueue<TFrame>.Create(0);
  Encoder := THpackCodec.Create;
  try
    State := lsIdle;
    try
      LeaseSendHeaders(ARequest, Encoder, Queue, 1, 16384, State);
    except
      on E: EHttpError do
        Result := True;
    end;
  finally
    Encoder.Free;
  end;
end;

procedure TStreamExtendedConnectTest.TestProtocolNameIsTheConstant;
begin
  AssertEquals('protocol pseudo-header name', ':protocol', HeaderProtocol);
end;

procedure TStreamExtendedConnectTest.TestHeaderBlockHasProtocolAndRegularFields;
var
  Frame: TFrame;
  State: TLeaseLocalState;
  Fields: THeaderBlock;
begin
  SendHeaders(ConnectRequest, Frame, State);
  Fields := DecodeBlock(Frame);
  AssertEquals('five pseudo-headers and two regular fields', 7, Length(Fields));
  AssertEquals('method', 'CONNECT', FieldValue(Fields, ':method'));
  AssertEquals('scheme', 'https', FieldValue(Fields, ':scheme'));
  AssertEquals('path', '/chat', FieldValue(Fields, ':path'));
  AssertEquals('authority', 'example.test:443', FieldValue(Fields, ':authority'));
  AssertEquals('protocol', 'websocket', FieldValue(Fields, ':protocol'));
  AssertEquals('version field', '13', FieldValue(Fields, 'sec-websocket-version'));
  AssertEquals('origin field', 'https://example.test', FieldValue(Fields, 'origin'));
end;

procedure TStreamExtendedConnectTest.TestKeepOpenLeavesStreamOpen;
var
  Frame: TFrame;
  State: TLeaseLocalState;
begin
  SendHeaders(ConnectRequest.WithKeepOpen, Frame, State);
  AssertFalse('HEADERS has no END_STREAM with KeepOpen', Frame.IsEndStream);
  AssertEquals('local state is headers sent', Ord(lsHeadersSent), Ord(State));
end;

procedure TStreamExtendedConnectTest.TestWithoutKeepOpenEndsStream;
var
  Frame: TFrame;
  State: TLeaseLocalState;
begin
  SendHeaders(ConnectRequest, Frame, State);
  AssertTrue('HEADERS has END_STREAM without a body or KeepOpen', Frame.IsEndStream);
  AssertEquals('local state is half-closed', Ord(lsLocalHalfClosed), Ord(State));
end;

procedure TStreamExtendedConnectTest.TestConnectWithoutProtocolIsUnchanged;
var
  Request: TStreamRequest;
  Frame: TFrame;
  State: TLeaseLocalState;
  Fields: THeaderBlock;
begin
  Request := TStreamRequest.Create('CONNECT', 'example.test:443')
    .WithScheme('https')
    .WithPath('/x');
  SendHeaders(Request, Frame, State);
  Fields := DecodeBlock(Frame);
  AssertEquals('four pseudo-headers and no protocol', 4, Length(Fields));
  AssertEquals('no protocol field', '', FieldValue(Fields, ':protocol'));
  AssertTrue('bodyless CONNECT sets END_STREAM', Frame.IsEndStream);
end;

procedure TStreamExtendedConnectTest.TestProtocolRequestChecksItsFields;
var
  Request: TStreamRequest;
begin
  Request := ConnectRequest;
  Request.Path := '';
  AssertTrue('empty path raises', HeadersRaise(Request));

  Request := ConnectRequest;
  Request.Method := 'GET';
  AssertTrue('a method other than CONNECT raises', HeadersRaise(Request));

  Request := ConnectRequest;
  Request.Scheme := '';
  AssertTrue('empty scheme raises', HeadersRaise(Request));

  AssertFalse('a valid protocol request does not raise', HeadersRaise(ConnectRequest));
end;

initialization
  RegisterTest(TStreamExtendedConnectTest);
end.
