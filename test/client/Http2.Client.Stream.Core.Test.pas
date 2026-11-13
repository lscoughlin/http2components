{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves a client stream test from the source project
---
}
unit Http2.Client.Stream.Core.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Common.Hpack,
  Http2.Client.Connection, Http2.Client.Stream, Http2.Client.ConnectionThread.Test, Http2.Client.Stream.Support;

type
  TStreamLeaseCoreTest = class(TStreamLeaseTestBase)
  published
    procedure TestAllocatorYieldsOddMonotonicIds;
    procedure TestAllocatorConcurrencyHasNoDuplicates;
    procedure TestHeadersEmitAndDecodeRoundTrip;
    procedure TestLargeHeaderBlockUsesContinuation;
    procedure TestBodyIsStreamedInDataFrames;
    procedure TestEarlyResponseStopsAnUploadParkedOnCredit;
    procedure TestPeerResetStopsAnUploadWithoutAnotherReset;
    procedure TestBodyWriterIsPulledUntilFalse;
    procedure TestResponseAssemblyStatusHeadersBody;
    procedure TestBodylessResponseIsImmediatelyEof;
    procedure TestReadAfterEofRaises;
    procedure TestHeadContentLengthIsNotComparedAgainstBody;
    procedure TestContentLengthMismatchRaises;
    procedure TestResponseTeHeaderMustBeTrailers;
  end;

implementation

procedure TStreamLeaseCoreTest.TestAllocatorYieldsOddMonotonicIds;
var
  A: TStreamIdAllocator;
  I: Integer;
  Prev, Cur: LongWord;
  AllOdd: Boolean;
begin
  A := TStreamIdAllocator.Create;
  try
    AssertEquals('first id is 1', LongWord(1), A.Next);
    AllOdd := True;
    Prev := 1;
    for I := 0 to 9 do
    begin
      Cur := A.Next;
      if (Cur = 0) or (Cur and 1 = 0) or (Cur <= Prev) then
        AllOdd := False;
      Prev := Cur;
    end;
    AssertTrue('every allocated id is odd, non-zero and increasing', AllOdd);
    AssertEquals('Peek matches the next id', A.Next, A.Peek);
  finally
    A.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestAllocatorConcurrencyHasNoDuplicates;
const
  Threads = 8;
  PerThread = 2000;
var
  A: TStreamIdAllocator;
  Workers: array[0..Threads - 1] of TAllocWorker;
  Seen: TDictionary<LongWord, Integer>;
  I, J: Integer;
  Id: LongWord;
  Duplicates, Completed, NonOdd: Integer;
  Dup: Integer;
begin
  A := TStreamIdAllocator.Create;
  Seen := TDictionary<LongWord, Integer>.Create;
  try
    for I := 0 to Threads - 1 do
      Workers[I] := TAllocWorker.Create(A, PerThread);
    for I := 0 to Threads - 1 do
      Workers[I].Start;
    Completed := 0;
    for I := 0 to Threads - 1 do
      if Workers[I].WaitDone(10000) then
        Inc(Completed);
    AssertEquals('every worker thread completed', Threads, Completed);

    Duplicates := 0;
    NonOdd := 0;
    for I := 0 to Threads - 1 do
      for J := 0 to PerThread - 1 do
      begin
        Id := Workers[I].Ids[J];
        if (Id = 0) or (Id and 1 = 0) then
          Inc(NonOdd);
        if Seen.TryGetValue(Id, Dup) then
          Inc(Duplicates)
        else
          Seen.Add(Id, 1);
      end;
    AssertEquals('no even or zero ids', 0, NonOdd);
    AssertEquals('no duplicate ids across threads', 0, Duplicates);
    AssertEquals('every id observed once', Threads * PerThread, Seen.Count);
  finally
    for I := 0 to Threads - 1 do
      Workers[I].Free;
    Seen.Free;
    A.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestHeadersEmitAndDecodeRoundTrip;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Frame, Extra0: TFrame;
  Dec: THpackCodec;
  Fields: THeaderBlock;
  I: Integer;
  SMethod, SScheme, SPath, SAuth, SAccept: string;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443')
      .WithPath('/v1/things?q=1')
      .WithHeader('accept', 'application/json');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      AssertTrue('HEADERS frame emitted', Conn.Outbound.Pop(Frame));
      Extra0 := Frame;
      AssertFalse('only one frame for a bodyless GET',
        Conn.Outbound.TryPop(Extra0));
      AssertEquals('frame is HEADERS', Ord(ftHeaders), Ord(Frame.Header.FrameType));
      AssertEquals('stream id is 1', LongWord(1), Frame.Header.StreamId);
      AssertTrue('HEADERS carries END_HEADERS', Frame.IsEndHeaders);
      AssertTrue('a bodyless GET sets END_STREAM', Frame.IsEndStream);

      Dec := THpackCodec.Create;
      try
        Fields := Dec.Decode(ExtractHeaderBlock(Frame));
      finally
        Dec.Free;
      end;
      SMethod := ''; SScheme := ''; SPath := ''; SAuth := ''; SAccept := '';
      for I := 0 to High(Fields) do
      begin
        if Fields[I].Name = ':method' then SMethod := Fields[I].Value
        else if Fields[I].Name = ':scheme' then SScheme := Fields[I].Value
        else if Fields[I].Name = ':path' then SPath := Fields[I].Value
        else if Fields[I].Name = ':authority' then SAuth := Fields[I].Value
        else if Fields[I].Name = 'accept' then SAccept := Fields[I].Value;
      end;
      AssertEquals('method pseudo-header', 'GET', SMethod);
      AssertEquals('scheme pseudo-header', 'https', SScheme);
      AssertEquals('path pseudo-header', '/v1/things?q=1', SPath);
      AssertEquals('authority pseudo-header', 'api.example:443', SAuth);
      AssertEquals('regular header preserved', 'application/json', SAccept);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestLargeHeaderBlockUsesContinuation;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Peer: TConnectionSettings;
  F1, F2, Fx: TFrame;
  Block: TBytes;
  Dec: THpackCodec;
  Fields: THeaderBlock;
  I: Integer;
  Found: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    // force a tiny peer max frame size so the header block must be split
    Peer := TConnectionSettings.Defaults;
    Peer.MaxFrameSize := 16;
    Conn.ApplyPeerSettingsValue(Peer);
    Req := TStreamRequest.WithMethod(hmGet, 'api.example:443')
      .WithPath('/a/long/path/that/will/not/fit')
      .WithHeader('x-a', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
      .WithHeader('x-b', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      AssertTrue('HEADERS frame emitted', Conn.Outbound.Pop(F1));
      AssertEquals('first frame is HEADERS', Ord(ftHeaders),
        Ord(F1.Header.FrameType));
      Block := ExtractHeaderBlock(F1);
      AssertFalse('HEADERS does not end the header block', F1.IsEndHeaders);
      // pull every CONTINUATION and concatenate the raw block bytes
      while not F1.IsEndHeaders do
      begin
        AssertTrue('a CONTINUATION follows', Conn.Outbound.Pop(F2));
        AssertEquals('next frame is CONTINUATION', Ord(ftContinuation),
          Ord(F2.Header.FrameType));
        Block := JoinBytes(Block, ExtractHeaderBlock(F2));
        F1 := F2;
      end;
      AssertFalse('the whole request is consumed', Conn.Outbound.TryPop(Fx));
      Dec := THpackCodec.Create;
      try
        Fields := Dec.Decode(Block);
      finally
        Dec.Free;
      end;
      Found := False;
      for I := 0 to High(Fields) do
        if (Fields[I].Name = ':path') and
           (Fields[I].Value = '/a/long/path/that/will/not/fit') then
          Found := True;
      AssertTrue('header block reassembles across CONTINUATION', Found);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestEarlyResponseStopsAnUploadParkedOnCredit;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Late: TLateFrame;
  F: TFrame;
  Body: TBytes;
  Started: QWord;
  DataBytes, Resets: Integer;
  ResetCode: THttp2ErrorCode;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    // larger than the default 65535-byte stream window, so the upload parks
    SetLength(Body, 200000);
    FillChar(Body[0], Length(Body), Ord('x'));
    Req := TStreamRequest.WithMethod(hmPost, 'api.example')
      .WithBody(THttpBody.FromBytes(Body));
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Late := TLateFrame.Create(Lease, BuildDataFrame(1, nil, True), 150);
      try
        Late.Start;
        Started := GetTickCount64;
        Lease.Start;
        AssertTrue('Start returned long before the credit timeout',
          GetTickCount64 - Started < 5000);
        Late.WaitFor;
      finally
        Late.Free;
      end;
      DataBytes := 0;
      Resets := 0;
      ResetCode := ecNoError;
      while Conn.Outbound.TryPop(F) or Conn.ControlQueue.TryPop(F) do
        if F.Header.FrameType = ftData then
          Inc(DataBytes, Length(ExtractDataPayload(F)))
        else if F.Header.FrameType = ftRstStream then
        begin
          Inc(Resets);
          ParseRstStream(F, ResetCode);
        end;
      AssertTrue('some DATA went out before the window ran dry', DataBytes > 0);
      AssertTrue('no more than the window was sent', DataBytes <= 65535);
      AssertEquals('the client told the peer to stop', 1, Resets);
      AssertEquals('with CANCEL', Ord(ecCancel), Ord(ResetCode));
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;


procedure TStreamLeaseCoreTest.TestPeerResetStopsAnUploadWithoutAnotherReset;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Late: TLateFrame;
  F: TFrame;
  Body: TBytes;
  Started: QWord;
  Resets: Integer;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    SetLength(Body, 200000);
    FillChar(Body[0], Length(Body), Ord('x'));
    Req := TStreamRequest.WithMethod(hmPost, 'api.example')
      .WithBody(THttpBody.FromBytes(Body));
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Late := TLateFrame.Create(Lease, BuildRstStreamFrame(1, ecNoError), 150);
      try
        Late.Start;
        Started := GetTickCount64;
        Lease.Start;
        AssertTrue('Start returned long before the credit timeout',
          GetTickCount64 - Started < 5000);
        Late.WaitFor;
      finally
        Late.Free;
      end;
      Resets := 0;
      while Conn.Outbound.TryPop(F) or Conn.ControlQueue.TryPop(F) do
        if F.Header.FrameType = ftRstStream then
          Inc(Resets);
      AssertEquals('the peer already reset the stream: no reset from us', 0,
        Resets);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestBodyIsStreamedInDataFrames;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  H, D, Dx: TFrame;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmPost, 'api.example')
      .WithBody(THttpBody.FromString('hello world'));
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      AssertTrue(Conn.Outbound.Pop(H));
      AssertTrue(Conn.Outbound.Pop(D));
      AssertFalse('no third frame for a fixed body', Conn.Outbound.TryPop(Dx));
      AssertFalse('body present so HEADERS has no END_STREAM', H.IsEndStream);
      AssertEquals('DATA frame', Ord(ftData), Ord(D.Header.FrameType));
      AssertTrue('last DATA carries END_STREAM', D.IsEndStream);
      AssertEquals('body bytes transported', 'hello world',
        StrOf(ExtractDataPayload(D)));
      AssertEquals('local side is half-closed',
        Ord(lsLocalHalfClosed), Ord(Lease.LocalState));
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;


procedure TStreamLeaseCoreTest.TestBodyWriterIsPulledUntilFalse;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  H, D1, D2, D3, Dx: TFrame;
  Writer: IBodyWriter;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Writer := TChunkWriter.Create([BytesOf('abc'), BytesOf('de'), BytesOf('f')]);
    Req := TStreamRequest.WithMethod(hmPost, 'api.example')
      .WithBodyWriter(Writer);
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      AssertTrue(Conn.Outbound.Pop(H));
      AssertTrue(Conn.Outbound.Pop(D1));
      AssertTrue(Conn.Outbound.Pop(D2));
      AssertTrue(Conn.Outbound.Pop(D3));
      AssertFalse('no fourth frame', Conn.Outbound.TryPop(Dx));
      AssertFalse('writer body -> HEADERS has no END_STREAM', H.IsEndStream);
      AssertFalse('first chunk not end-stream', D1.IsEndStream);
      AssertFalse('second chunk not end-stream', D2.IsEndStream);
      AssertTrue('final pulled chunk carries END_STREAM', D3.IsEndStream);
      AssertEquals('chunk 1', 'abc', StrOf(ExtractDataPayload(D1)));
      AssertEquals('chunk 2', 'de', StrOf(ExtractDataPayload(D2)));
      AssertEquals('chunk 3', 'f', StrOf(ExtractDataPayload(D3)));
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestResponseAssemblyStatusHeadersBody;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Extra: array[0..0] of THttpHeaderField;
  S1: string;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Extra[0].Name := 'content-type';
        Extra[0].Value := 'text/plain';
        Extra[0].Sensitive := False;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Extra,
          Lease.StreamId, False));
      finally
        Enc.Free;
      end;
      AssertTrue('response header wait succeeded',
        Lease.WaitForResponseHeader(1000));
      AssertEquals('status decoded', 200, Lease.StatusCode);
      AssertEquals('header decoded', 'text/plain',
        Lease.ResponseHeaders.GetFirst('content-type'));
      AssertFalse('body not yet complete', Lease.Body.Eof);

      Conn.DispatchStreamFrame(BuildDataFrame(Lease.StreamId, BytesOf('x'),
        False));
      Conn.DispatchStreamFrame(BuildDataFrame(Lease.StreamId, BytesOf('y'),
        True));
      S1 := ReadAllBody(Lease.Body);
      AssertEquals('assembled body', 'xy', S1);
      AssertTrue('body complete', Lease.Body.Eof);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestBodylessResponseIsImmediatelyEof;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Empty: THeaderBlock;
  Buf: array[0..7] of Byte;
  N: LongInt;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Empty := nil;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '204', Empty,
          Lease.StreamId, False));
      finally
        Enc.Free;
      end;
      AssertTrue('header wait', Lease.WaitForResponseHeader(1000));
      AssertEquals('status 204', 204, Lease.StatusCode);
      AssertTrue('204 is immediately Eof', Lease.Body.Eof);
      N := Lease.ReadBody(Buf, SizeOf(Buf));
      AssertEquals('read on a bodyless response returns 0', LongInt(0), N);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestReadAfterEofRaises;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Extra: array[0..0] of THttpHeaderField;
  Buf: array[0..7] of Byte;
  N: LongInt;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Extra[0].Name := 'content-length';
        Extra[0].Value := '0';
        Extra[0].Sensitive := False;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Extra,
          Lease.StreamId, True));   // END_STREAM on HEADERS
      finally
        Enc.Free;
      end;
      AssertTrue('header wait', Lease.WaitForResponseHeader(1000));
      N := Lease.ReadBody(Buf, SizeOf(Buf));
      AssertEquals('first read after END_STREAM returns 0', LongInt(0), N);
      Raised := False;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpStreamError do Raised := True;
      end;
      AssertTrue('a second read after EOF raises deterministically', Raised);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestHeadContentLengthIsNotComparedAgainstBody;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Extra: array[0..0] of THttpHeaderField;
  Buf: array[0..7] of Byte;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmHead, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Extra[0].Name := 'content-length';
        Extra[0].Value := '10';
        Extra[0].Sensitive := False;
        // a HEAD response: describes 10 bytes but END_STREAM with no DATA
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Extra,
          Lease.StreamId, True));
      finally
        Enc.Free;
      end;
      AssertTrue('HEAD response headers are accepted',
        Lease.WaitForResponseHeader(1000));
      AssertEquals('no body bytes for HEAD', LongInt(0),
        Lease.ReadBody(Buf, SizeOf(Buf)));
      AssertEquals('status preserved', 200, Lease.StatusCode);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestContentLengthMismatchRaises;
var
  Sock: TMockSocket;
  Conn: TConnection;
  Lease: TStreamLease;
  IL: IConnectionStream;
  Alloc: TStreamIdAllocator;
  Req: TStreamRequest;
  Enc: THpackCodec;
  Extra: array[0..0] of THttpHeaderField;
  Buf: array[0..63] of Byte;
  Raised: Boolean;
begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    Req := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, Req, Alloc, Lease, IL);
    try
      Lease.Start;
      Enc := THpackCodec.Create;
      try
        Extra[0].Name := 'content-length';
        Extra[0].Value := '10';
        Extra[0].Sensitive := False;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(Enc, '200', Extra,
          Lease.StreamId, False));
        // only 3 bytes of DATA, but END_STREAM -> malformed response
        Conn.DispatchStreamFrame(
          BuildDataFrame(Lease.StreamId, BytesOf('abc'), True));
      finally
        Enc.Free;
      end;
      AssertTrue('headers accepted', Lease.WaitForResponseHeader(1000));
      Raised := False;
      try
        Lease.ReadBody(Buf, SizeOf(Buf));
      except
        on E: EHttpStreamError do Raised := True;
      end;
      AssertTrue(
        'a content-length that disagrees with the DATA length is a stream error',
        Raised);
    finally
      Lease.ReleaseLease;
      IL := nil;
      Alloc.Free;
    end;
  finally
    Conn.Free;
  end;
end;

procedure TStreamLeaseCoreTest.TestResponseTeHeaderMustBeTrailers;
var
  Sock: TMockSocket;
  Conn: TConnection;

  procedure ExpectTe(const AValue: string; const AShouldRaise: Boolean);
  var
    L: TStreamLease;
    A: TStreamIdAllocator;
    R: IConnectionStream;
    E: THpackCodec;
    X: array[0..0] of THttpHeaderField;
    LReq: TStreamRequest;
    Ok: Boolean;
    Caught: Boolean;
  begin
    LReq := TStreamRequest.WithMethod(hmGet, 'api.example');
    MakeLease(Conn, LReq, A, L, R);
    try
      L.Start;
      E := THpackCodec.Create;
      try
        X[0].Name := 'te';
        X[0].Value := AValue;
        X[0].Sensitive := False;
        Conn.DispatchStreamFrame(ResponseHeadersFrame(E, '200', X,
          L.StreamId, True));
      finally
        E.Free;
      end;
      Caught := False;
      try
        Ok := L.WaitForResponseHeader(1000);
      except
        on E: EHttpStreamError do Caught := True;
      end;
      AssertEquals('te=' + AValue + ' raise', AShouldRaise, Caught);
      if not AShouldRaise then
        AssertTrue('te=trailers accepted', Ok);
    finally
      L.ReleaseLease;
      R := nil;
      A.Free;
    end;
  end;

begin
  Sock := TMockSocket.Create;
  Conn := TConnection.Create(Sock);
  try
    // the one legal value is accepted
    ExpectTe('trailers', False);
    // any other value is a stream PROTOCOL_ERROR
    ExpectTe('trailers, deflate', True);
    ExpectTe('deflate', True);
  finally
    Conn.Free;
  end;
end;

initialization
  RegisterTest(TStreamLeaseCoreTest);
end.
