{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, handshake request, snapshot, test, fpcunit
notes:
  - These tests drive TWsRequestSnapshot of Http2.Server.WebSocket.Snapshot with a
    fake source request. The snapshot has no body, so every read gives no octets.
  - The snapshot is held only in an IServerRequest variable, so the reference count
    keeps it alive while GetStream and GetStreamReader give their streams.
---
}
/// Tests of the read-only copy of the handshake request of a WebSocket session
unit Http2.Server.WebSocket.Snapshot.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, streamex, fpcunit, testregistry,
  Http2.Common.Hpack, Http2.Common.Body, Http2.Server.Seam, Http2.Server.ClientCert,
  Http2.Server.WebSocket.Snapshot;

type
  /// a source request with fixed pseudo-headers and a header list
  TSnapSource = class(TInterfacedObject, IServerRequest)
  public
    MethodText, SchemeText, AuthorityText, PathText: string;
    Header: THeaderBlock;
    function GetPrincipal: string;
    procedure SetPrincipal(const AValue: string);
    function GetClientCertificate: IClientCertificate;
    function Method: string;
    function Scheme: string;
    function Authority: string;
    function Path: string;
    function Headers: THeaderBlock;
    function Read(var ABuffer; const ACount: Integer): Integer;
    function ReadChunk(const ABuffer: TStream): Boolean;
    function GetStream: TStream;
    function GetStreamReader: TStreamReader;
    function BodyIsComplete: Boolean;
    function IsCancelled: Boolean;
    function StreamId: LongWord;
  end;

  /// tests of the stream and reader that the snapshot gives for its body
  TWsSnapshotTest = class(TTestCase)
  private
    FSource: TSnapSource;
    FSourceRef: IServerRequest;
    function NewSnapshot: IServerRequest;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestGetStreamIsEmpty;
    procedure TestGetStreamReaderGivesNoLines;
    procedure TestReadAfterEndRepeatsZero;
    procedure TestHeadersAndPathAreCopied;
  end;

implementation

function TSnapSource.GetPrincipal: string;
begin
  Result := '';
end;

procedure TSnapSource.SetPrincipal(const AValue: string);
begin
end;

function TSnapSource.GetClientCertificate: IClientCertificate;
begin
  Result := nil;
end;

function TSnapSource.Method: string;
begin
  Result := MethodText;
end;

function TSnapSource.Scheme: string;
begin
  Result := SchemeText;
end;

function TSnapSource.Authority: string;
begin
  Result := AuthorityText;
end;

function TSnapSource.Path: string;
begin
  Result := PathText;
end;

function TSnapSource.Headers: THeaderBlock;
begin
  Result := Header;
end;

function TSnapSource.Read(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
end;

function TSnapSource.ReadChunk(const ABuffer: TStream): Boolean;
begin
  Result := False;
end;

function TSnapSource.GetStream: TStream;
begin
  Result := BodyStream(Self as IServerRequest);
end;

function TSnapSource.GetStreamReader: TStreamReader;
begin
  Result := BodyStreamReader(Self as IServerRequest);
end;

function TSnapSource.BodyIsComplete: Boolean;
begin
  Result := True;
end;

function TSnapSource.IsCancelled: Boolean;
begin
  Result := False;
end;

function TSnapSource.StreamId: LongWord;
begin
  Result := 1;
end;

{ TWsSnapshotTest }

procedure TWsSnapshotTest.SetUp;
begin
  inherited SetUp;
  FSource := TSnapSource.Create;
  FSourceRef := FSource;
  FSource.MethodText := 'CONNECT';
  FSource.SchemeText := 'https';
  FSource.AuthorityText := 'example.test';
  FSource.PathText := '/ws/chat';
  SetLength(FSource.Header, 2);
  FSource.Header[0].Name := 'origin';
  FSource.Header[0].Value := 'https://example.test';
  FSource.Header[1].Name := 'sec-websocket-protocol';
  FSource.Header[1].Value := 'chat';
end;

procedure TWsSnapshotTest.TearDown;
begin
  FSourceRef := nil;
  FSource := nil;
  inherited TearDown;
end;

function TWsSnapshotTest.NewSnapshot: IServerRequest;
begin
  Result := TWsRequestSnapshot.Create(FSourceRef);
end;

procedure TWsSnapshotTest.TestGetStreamIsEmpty;
var
  Snap: IServerRequest;
  Stream: TStream;
  Buf: array[0..15] of Byte;
begin
  Snap := NewSnapshot;
  Stream := Snap.GetStream;
  try
    AssertTrue('GetStream gives a stream', Stream <> nil);
    AssertEquals('the stream has no octets', 0, Stream.Read(Buf[0], SizeOf(Buf)));
  finally
    Stream.Free;
  end;
end;

procedure TWsSnapshotTest.TestGetStreamReaderGivesNoLines;
var
  Snap: IServerRequest;
  Reader: TStreamReader;
begin
  Snap := NewSnapshot;
  Reader := Snap.GetStreamReader;
  try
    AssertTrue('the reader is at its end', Reader.EndOfStream);
    AssertEquals('the reader gives no line', '', Reader.ReadLine);
    AssertTrue('the reader is still at its end', Reader.EndOfStream);
  finally
    // the reader owns its stream, so this frees both
    Reader.Free;
  end;
end;

procedure TWsSnapshotTest.TestReadAfterEndRepeatsZero;
var
  Snap: IServerRequest;
  Buf: array[0..15] of Byte;
  Sink: TMemoryStream;
  I: Integer;
begin
  Snap := NewSnapshot;
  for I := 1 to 3 do
    AssertEquals('Read gives 0 on call ' + IntToStr(I), 0,
      Snap.Read(Buf[0], SizeOf(Buf)));
  Sink := TMemoryStream.Create;
  try
    for I := 1 to 3 do
      AssertFalse('ReadChunk gives False on call ' + IntToStr(I),
        Snap.ReadChunk(Sink));
    AssertEquals('ReadChunk writes no octets', Int64(0), Sink.Size);
  finally
    Sink.Free;
  end;
  AssertTrue('the body is complete', Snap.BodyIsComplete);
end;

procedure TWsSnapshotTest.TestHeadersAndPathAreCopied;
var
  Snap: IServerRequest;
begin
  Snap := NewSnapshot;
  AssertEquals('method', 'CONNECT', Snap.Method);
  AssertEquals('scheme', 'https', Snap.Scheme);
  AssertEquals('authority', 'example.test', Snap.Authority);
  AssertEquals('path', '/ws/chat', Snap.Path);
  AssertEquals('header count', 2, Length(Snap.Headers));
  AssertEquals('first header value', 'https://example.test', Snap.Headers[0].Value);

  // the constructor copied the header list: changes to the source do not reach the copy
  FSource.MethodText := 'GET';
  FSource.PathText := '/changed';
  FSource.Header[0].Value := 'https://changed.test';
  SetLength(FSource.Header, 0);
  AssertEquals('method is copied', 'CONNECT', Snap.Method);
  AssertEquals('path is copied', '/ws/chat', Snap.Path);
  AssertEquals('header count is copied', 2, Length(Snap.Headers));
  AssertEquals('header value is copied', 'https://example.test', Snap.Headers[0].Value);
  AssertEquals('header name is copied', 'sec-websocket-protocol', Snap.Headers[1].Name);
end;

initialization
  RegisterTest(TWsSnapshotTest);

end.
