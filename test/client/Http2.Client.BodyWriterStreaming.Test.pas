{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, body_writer, streaming, flow_control, test
notes:
  - This unit proves that the HTTP/2 client pulls the chunks of a request body
    only as the peer grants flow-control credit.
  - A scripted peer on a mock socket withholds WINDOW_UPDATE until the test
    grants credit.
---
}
/// Pull-rate test of the client request body writer, and the producer upload tests
unit Http2.Client.BodyWriterStreaming.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Common.Body, Http2.Common.Body.Producers,
  Http2.Client.MockSocket.Frames, Http2.Client.Errors,
  Http2.Client.Messages, Http2.Client.Stream, Http2.Client,
  Http2.Client.MockSocket.Support;

type
  /// the error that a test producer raises after its first octets
  EScriptedProducerFailure = class(Exception);

  /// a body writer that yields N chunks of S octets and counts them
  // - the call after the last chunk returns False and writes no octets
  TCountingWriter = class(TInterfacedObject, IBodyWriter)
  private
    FLock: TCriticalSection;
    FData: TBytes;
    FChunks: Integer;
    FSize: Integer;
    FNext: Integer;
  public
    constructor Create(const AChunks, AChunkSize: Integer);
    destructor Destroy; override;
    function NextChunk(const ABuffer: TStream): Boolean;
    /// the number of chunks that the writer has yielded
    function Yielded: Integer;
  end;

  /// a peer that withholds WINDOW_UPDATE and records the request body
  // - the peer answers 200 with END_STREAM after the request END_STREAM
  TStallPeer = class
  private
    FSocket: TMockSocket;
    FStreamId: LongWord;
    FDataOctets: Int64;
    FEnded: Boolean;
    procedure Answer;
  public
    constructor Create(const ASocket: TMockSocket);
    procedure OnClientFrame(const AFrame: TFrame);
    /// the socket of the peer, for the test thread to grant credit
    property Socket: TMockSocket read FSocket;
    property StreamId: LongWord read FStreamId;
    property DataOctets: Int64 read FDataOctets;
    property Ended: Boolean read FEnded;
  end;

  /// sends the request on its own thread, so the test can bound the wait
  TUploadWorker = class(TThread)
  private
    FClient: IHttpClient;
    FWriter: IBodyWriter;
    FStatus: Integer;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AClient: IHttpClient; const AWriter: IBodyWriter);
    property Status: Integer read FStatus;
    property Error: string read FError;
  end;

  TBodyWriterStreamingTest = class(TTestCase)
  private
    FPeers: TObjectList<TObject>;
    FPeer: TStallPeer;
    procedure AttachPeer(const ASocket: TMockSocket);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    /// with a 65535-octet window and no WINDOW_UPDATE, the upload writer
    // yields at most 65535 div 1024 + 3 chunks; the rest follows the credit
    procedure TestH2UploadWriterIsPulledAtTheSpeedOfTheWindow;
  end;

  /// HTTP/2 uploads from a producer: the octets, END_STREAM, the failures and the cancel
  // - the mock socket answers 200 with END_STREAM, so each call returns once the body is sent
  // - the frames that the client wrote are read from the mock after the call
  TProducerUploadTest = class(TTestCase)
  private
    FFactory: IHttp2SocketFactory;
    FClient: IHttpClient;
    FSocket: TMockSocket;
    FToken: ICancellationToken;
    FPayload: TBytes;
    FSizes: TArray<Integer>;
    FErrorClass: string;
    FErrorText: string;
    FErrorCode: THttp2ErrorCode;
    FProducerClass: string;
    FProducerCode: THttp2ErrorCode;
    FProducerSawError: Boolean;
    procedure OnDial(const ASocket: TMockSocket);
    procedure Upload(const AWriter: IBodyWriter; const AToken: ICancellationToken);
    function DataFrames: TArray<TFrame>;
    function FrameOfType(const AType: TFrameType; out AFrame: TFrame): Boolean;
    function WaitForFrame(const AType: TFrameType; const AEndStream: Boolean): Boolean;
    function BodyOfDataFrames: TBytes;
    procedure WriteInPieces(const AOut: TStream);
    procedure WriteNothing(const AOut: TStream);
    procedure WriteThenFail(const AOut: TStream);
    procedure WriteThenCancel(const AOut: TStream);
  protected
    procedure TearDown; override;
  published
    /// odd write sizes arrive complete, and only the last DATA frame has END_STREAM
    procedure TestH2ProducerUploadArrivesComplete;
    /// a body that ends on a chunk boundary sends no empty END_STREAM frame
    procedure TestH2ProducerUploadOnChunkBoundaryEndsOnce;
    /// a producer that writes nothing sends one empty DATA frame with END_STREAM
    procedure TestH2EmptyProducerSendsEmptyEndStreamFrame;
    /// a producer that raises resets the stream with CANCEL and the call raises its exception
    procedure TestH2ProducerRaisingResetsTheStream;
    /// a cancelled call raises EHttpStreamError (ecCancel) in the producer's Write
    procedure TestH2CancelledCallRaisesInProducerWrite;
  end;

implementation

const
  /// the chunks of the upload
  cUploadChunks = 200;
  /// the octets of one chunk
  cUploadChunk = 1024;
  /// the initial flow-control window of the stream and the connection
  cWindow = 65535;
  /// the time that the sender stays stalled, in milliseconds
  cStallMs = 500;
  /// the longest wait for the upload to finish, in milliseconds
  cWaitMs = 20000;
  /// the credit that the test grants after the stall
  cGrant = 1048576;

{ TCountingWriter }

constructor TCountingWriter.Create(const AChunks, AChunkSize: Integer);
var
  I: Integer;
  X: QWord;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FChunks := AChunks;
  FSize := AChunkSize;
  FNext := 0;
  SetLength(FData, AChunks * AChunkSize);
  // a xorshift stream gives every octet a pseudo-random value
  X := QWord($2545F4914F6CDD1D);
  for I := 0 to High(FData) do
  begin
    X := X xor (X shl 13);
    X := X xor (X shr 7);
    X := X xor (X shl 17);
    FData[I] := Byte(X);
  end;
end;

destructor TCountingWriter.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TCountingWriter.NextChunk(const ABuffer: TStream): Boolean;
begin
  if FNext >= FChunks then
    Exit(False);
  ABuffer.WriteBuffer(FData[FNext * FSize], FSize);
  FLock.Acquire;
  try
    Inc(FNext);
  finally
    FLock.Release;
  end;
  Result := True;
end;

function TCountingWriter.Yielded: Integer;
begin
  FLock.Acquire;
  try
    Result := FNext;
  finally
    FLock.Release;
  end;
end;

{ TStallPeer }

constructor TStallPeer.Create(const ASocket: TMockSocket);
begin
  inherited Create;
  FSocket := ASocket;
  FSocket.OnClientFrame := OnClientFrame;
end;

procedure TStallPeer.Answer;
begin
  // the mock already sent the response HEADERS (200, no END_STREAM), so the
  // answer is the empty DATA frame that ends the response
  FSocket.FeedLocked(FrameToBytes(BuildDataFrame(FStreamId, nil, True)));
end;

procedure TStallPeer.OnClientFrame(const AFrame: TFrame);
begin
  case AFrame.Header.FrameType of
    ftHeaders:
      if FStreamId = 0 then
        FStreamId := AFrame.Header.StreamId;
    ftData:
      begin
        // the peer never returns credit here; it only counts the octets
        Inc(FDataOctets, AFrame.DataLength);
        if AFrame.IsEndStream and not FEnded then
        begin
          FEnded := True;
          Answer;
        end;
      end;
  end;
end;

{ TUploadWorker }

constructor TUploadWorker.Create(const AClient: IHttpClient;
  const AWriter: IBodyWriter);
begin
  // the fields are set before the thread starts
  inherited Create(True);
  FClient := AClient;
  FWriter := AWriter;
  FStatus := -1;
  Start;
end;

procedure TUploadWorker.Execute;
var
  R: IHttpResponse;
begin
  try
    R := FClient.Send(THttpRequest.Create(hmPost, 'https://upload.example/x')
      .WithBodyWriter(FWriter));
    FStatus := R.StatusCode;
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

{ TBodyWriterStreamingTest }

procedure TBodyWriterStreamingTest.SetUp;
begin
  FPeers := TObjectList<TObject>.Create(True);
  FPeer := nil;
end;

procedure TBodyWriterStreamingTest.TearDown;
begin
  FPeer := nil;
  FPeers.Free;
end;

procedure TBodyWriterStreamingTest.AttachPeer(const ASocket: TMockSocket);
begin
  FPeer := TStallPeer.Create(ASocket);
  FPeers.Add(FPeer);
end;

procedure TBodyWriterStreamingTest.TestH2UploadWriterIsPulledAtTheSpeedOfTheWindow;
var
  FactoryRef: IHttp2SocketFactory;
  Client: IHttpClient;
  Writer: IBodyWriter;
  Worker: TUploadWorker;
  Yielded: Integer;
  Deadline: QWord;
  Waited: Boolean;
begin
  FactoryRef := TMockSocketFactory.Create;
  // the response HEADERS come at once, without END_STREAM; the body stays open
  (FactoryRef as TMockSocketFactory).SetResponse('200', nil, False);
  (FactoryRef as TMockSocketFactory).OnDial := AttachPeer;
  Client := THttpClientFactory.Create.WithSocketFactory(FactoryRef).Build;
  Writer := TCountingWriter.Create(cUploadChunks, cUploadChunk);
  Worker := TUploadWorker.Create(Client, Writer);
  try
    // wait for the request HEADERS on the peer
    Waited := False;
    Deadline := GetTickCount64 + cWaitMs;
    while (not Waited) and (GetTickCount64 < Deadline) do
    begin
      Waited := (FPeer <> nil) and (FPeer.StreamId <> 0);
      if not Waited then
        Sleep(5);
    end;
    AssertTrue('the request HEADERS arrived', Waited);
    // the sender stalls when the window is spent
    Sleep(cStallMs);
    Yielded := (Writer as TCountingWriter).Yielded;
    AssertTrue('the writer ran', Yielded > 0);
    AssertTrue('the writer waits for credit: at most 65535 div 1024 + 3 chunks',
      Yielded <= cWindow div cUploadChunk + 3);
    // the client sends the window and no more; the last chunk is split (the
    // client grants the octets that the window holds: AcquireSendCredit)
    AssertEquals('the peer got the window and no more', Int64(cWindow),
      FPeer.DataOctets);
    // the peer grants credit, and the rest follows
    FPeer.Socket.FeedFrames([
      BuildWindowUpdateFrame(0, cGrant),
      BuildWindowUpdateFrame(FPeer.StreamId, cGrant)]);
    Deadline := GetTickCount64 + cWaitMs;
    while (not FPeer.Ended) and (GetTickCount64 < Deadline) do
      Sleep(10);
    AssertTrue('the peer saw END_STREAM', FPeer.Ended);
    AssertEquals('the writer yielded every chunk', cUploadChunks,
      (Writer as TCountingWriter).Yielded);
    AssertEquals('the peer got every octet',
      Int64(cUploadChunks) * cUploadChunk, FPeer.DataOctets);
    // the call returns once the response ends and the upload is over
    Deadline := GetTickCount64 + cWaitMs;
    while (not Worker.Finished) and (GetTickCount64 < Deadline) do
      Sleep(10);
    AssertTrue('the call returns', Worker.Finished);
    AssertEquals('no error: ' + Worker.Error, '', Worker.Error);
    AssertEquals('status', 200, Worker.Status);
  finally
    // a stalled worker and its client stay blocked; leaking them is the price
    // of a test that fails in seconds instead of hanging (as in the flow test)
    if Worker.Finished then
      Worker.Free;
    Client.Close;
  end;
end;

/// a pattern of octets that is not periodic in short runs
function MakeOctets(const ACount: Integer): TBytes;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := Byte(I * 31 + (I shr 8));
end;

/// True when both arrays hold the same octets
function SameOctets(const A, B: TBytes): Boolean;
begin
  Result := Length(A) = Length(B);
  if Result and (Length(A) > 0) then
    Result := CompareMem(@A[0], @B[0], Length(A));
end;

{ TProducerUploadTest }

procedure TProducerUploadTest.OnDial(const ASocket: TMockSocket);
begin
  FSocket := ASocket;
end;

procedure TProducerUploadTest.Upload(const AWriter: IBodyWriter;
  const AToken: ICancellationToken);
var
  Req: THttpRequest;
begin
  FErrorClass := '';
  FErrorText := '';
  FFactory := TMockSocketFactory.Create;
  (FFactory as TMockSocketFactory).SetResponse('200', nil, True);
  (FFactory as TMockSocketFactory).OnDial := OnDial;
  FClient := THttpClientFactory.Create.WithSocketFactory(FFactory).Build;
  if AToken = nil then
    Req := THttpRequest.Create(hmPost, 'https://upload.example/x').WithBodyWriter(AWriter)
  else
    Req := THttpRequest.Create(hmPost, 'https://upload.example/x').WithBodyWriter(AWriter)
      .WithCancelToken(AToken);
  try
    FClient.Send(Req);
  except
    on E: EHttpStreamError do
    begin
      FErrorClass := E.ClassName;
      FErrorText := E.Message;
      FErrorCode := E.ErrorCode;
    end;
    on E: Exception do
    begin
      FErrorClass := E.ClassName;
      FErrorText := E.Message;
    end;
  end;
end;

function TProducerUploadTest.DataFrames: TArray<TFrame>;
var
  All: TArray<TFrame>;
  I, N: Integer;
begin
  All := FSocket.OutboundFrames(True);
  SetLength(Result, 0);
  for I := 0 to High(All) do
    if All[I].Header.FrameType = ftData then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := All[I];
    end;
end;

function TProducerUploadTest.FrameOfType(const AType: TFrameType;
  out AFrame: TFrame): Boolean;
var
  All: TArray<TFrame>;
  I: Integer;
begin
  All := FSocket.OutboundFrames(True);
  for I := 0 to High(All) do
    if All[I].Header.FrameType = AType then
    begin
      AFrame := All[I];
      Exit(True);
    end;
  Result := False;
end;

function TProducerUploadTest.WaitForFrame(const AType: TFrameType;
  const AEndStream: Boolean): Boolean;
var
  Deadline: QWord;
  All: TArray<TFrame>;
  I: Integer;
begin
  Deadline := GetTickCount64 + cWaitMs;
  repeat
    All := FSocket.OutboundFrames(True);
    for I := 0 to High(All) do
      if (All[I].Header.FrameType = AType) and
         ((not AEndStream) or All[I].IsEndStream) then
        Exit(True);
    Sleep(5);
  until GetTickCount64 >= Deadline;
  Result := False;
end;

function TProducerUploadTest.BodyOfDataFrames: TBytes;
var
  Frames: TArray<TFrame>;
  I, Pos, Len: Integer;
begin
  Frames := DataFrames;
  Len := 0;
  for I := 0 to High(Frames) do
    Inc(Len, Length(Frames[I].Payload));
  SetLength(Result, Len);
  Pos := 0;
  for I := 0 to High(Frames) do
  begin
    if Length(Frames[I].Payload) > 0 then
      Move(Frames[I].Payload[0], Result[Pos], Length(Frames[I].Payload));
    Inc(Pos, Length(Frames[I].Payload));
  end;
end;

procedure TProducerUploadTest.WriteInPieces(const AOut: TStream);
var
  Sent, Step, Index: Integer;
begin
  // the write sizes cycle through FSizes; the last write takes what is left
  Sent := 0;
  Index := 0;
  while Sent < Length(FPayload) do
  begin
    Step := FSizes[Index mod Length(FSizes)];
    if Step > Length(FPayload) - Sent then
      Step := Length(FPayload) - Sent;
    AOut.WriteBuffer(FPayload[Sent], Step);
    Inc(Sent, Step);
    Inc(Index);
  end;
end;

procedure TProducerUploadTest.WriteNothing(const AOut: TStream);
begin
  // the body is empty
end;

procedure TProducerUploadTest.WriteThenFail(const AOut: TStream);
var
  Piece: array[0..9] of Byte;
begin
  FillChar(Piece, SizeOf(Piece), 7);
  AOut.WriteBuffer(Piece, SizeOf(Piece));
  raise EScriptedProducerFailure.Create('scripted producer failure');
end;

procedure TProducerUploadTest.WriteThenCancel(const AOut: TStream);
var
  First, Second: array[0..3] of Byte;
begin
  // with a chunk of 4 octets, the second write sends the first chunk to the sink
  FillChar(First, SizeOf(First), 1);
  FillChar(Second, SizeOf(Second), 2);
  AOut.WriteBuffer(First, SizeOf(First));
  (FToken as TCancellationToken).Cancel;
  try
    AOut.WriteBuffer(Second, SizeOf(Second));
  except
    on E: EHttpStreamError do
    begin
      FProducerSawError := True;
      FProducerClass := E.ClassName;
      FProducerCode := E.ErrorCode;
      raise;
    end;
  end;
end;

procedure TProducerUploadTest.TearDown;
begin
  if FClient <> nil then
    FClient.Close;
  FClient := nil;
  FSocket := nil;
  FFactory := nil;
  FToken := nil;
  inherited TearDown;
end;

procedure TProducerUploadTest.TestH2ProducerUploadArrivesComplete;
var
  Writer: IBodyWriter;
  Frames: TArray<TFrame>;
  I, Ends: Integer;
  LastIsEnd: Boolean;
begin
  FPayload := MakeOctets(30011);
  SetLength(FSizes, 7);
  FSizes[0] := 1;
  FSizes[1] := 7;
  FSizes[2] := 1000;
  FSizes[3] := 3;
  FSizes[4] := 5000;
  FSizes[5] := 2;
  FSizes[6] := 9000;
  Writer := BodyWriterFromStream(WriteInPieces, 4096);
  Upload(Writer, nil);
  AssertEquals('no error: ' + FErrorText, '', FErrorClass);
  AssertTrue('the peer saw END_STREAM', WaitForFrame(ftData, True));
  Sleep(50);
  Frames := DataFrames;
  Ends := 0;
  LastIsEnd := False;
  for I := 0 to High(Frames) do
  begin
    if Frames[I].IsEndStream then
      Inc(Ends);
    LastIsEnd := Frames[I].IsEndStream;
  end;
  AssertEquals('END_STREAM is on exactly one DATA frame', 1, Ends);
  AssertTrue('the END_STREAM frame is the last DATA frame', LastIsEnd);
  AssertTrue('the peer got every octet, in order',
    SameOctets(FPayload, BodyOfDataFrames));
end;

procedure TProducerUploadTest.TestH2ProducerUploadOnChunkBoundaryEndsOnce;
var
  Writer: IBodyWriter;
  Frames: TArray<TFrame>;
begin
  // 8192 octets in chunks of 4096: the body ends on a chunk boundary
  FPayload := MakeOctets(8192);
  SetLength(FSizes, 1);
  FSizes[0] := 4096;
  Writer := BodyWriterFromStream(WriteInPieces, 4096);
  Upload(Writer, nil);
  AssertEquals('no error: ' + FErrorText, '', FErrorClass);
  AssertTrue('the peer saw END_STREAM', WaitForFrame(ftData, True));
  Sleep(50);
  Frames := DataFrames;
  AssertEquals('two DATA frames and no empty END_STREAM frame', 2, Length(Frames));
  AssertFalse('the first DATA frame does not end the stream', Frames[0].IsEndStream);
  AssertTrue('the second DATA frame ends the stream', Frames[1].IsEndStream);
  AssertTrue('the peer got every octet', SameOctets(FPayload, BodyOfDataFrames));
end;

procedure TProducerUploadTest.TestH2EmptyProducerSendsEmptyEndStreamFrame;
var
  Writer: IBodyWriter;
  Frames: TArray<TFrame>;
begin
  Writer := BodyWriterFromStream(WriteNothing, 4096);
  Upload(Writer, nil);
  AssertEquals('no error: ' + FErrorText, '', FErrorClass);
  AssertTrue('the peer saw END_STREAM', WaitForFrame(ftData, True));
  Sleep(50);
  Frames := DataFrames;
  AssertEquals('one DATA frame', 1, Length(Frames));
  AssertEquals('it is empty', 0, Integer(Frames[0].DataLength));
  AssertTrue('it carries END_STREAM', Frames[0].IsEndStream);
end;

procedure TProducerUploadTest.TestH2ProducerRaisingResetsTheStream;
var
  Writer: IBodyWriter;
  Frames: TArray<TFrame>;
  Headers, Reset: TFrame;
  I: Integer;
begin
  Writer := BodyWriterFromStream(WriteThenFail, 4096);
  Upload(Writer, nil);
  AssertEquals('the producer exception ends the call', 'EScriptedProducerFailure', FErrorClass);
  AssertEquals('with its own message', 'scripted producer failure', FErrorText);
  AssertTrue('the stream is reset', WaitForFrame(ftRstStream, False));
  AssertTrue('the request HEADERS went out', FrameOfType(ftHeaders, Headers));
  AssertTrue('an RST_STREAM went out', FrameOfType(ftRstStream, Reset));
  AssertEquals('the reset is on the request stream',
    Integer(Headers.Header.StreamId), Integer(Reset.Header.StreamId));
  AssertTrue('the reset carries CANCEL',
    SameOctets(BuildRstStreamFrame(Headers.Header.StreamId, ecCancel).Payload,
      Reset.Payload));
  Frames := DataFrames;
  for I := 0 to High(Frames) do
    AssertFalse('no DATA frame ends the body', Frames[I].IsEndStream);
end;

procedure TProducerUploadTest.TestH2CancelledCallRaisesInProducerWrite;
var
  Writer: IBodyWriter;
begin
  FToken := TCancellationToken.Create;
  FProducerSawError := False;
  FProducerClass := '';
  Writer := BodyWriterFromStream(WriteThenCancel, 4);
  Upload(Writer, FToken);
  AssertTrue('the producer Write raised', FProducerSawError);
  AssertEquals('the producer Write raised EHttpStreamError', 'EHttpStreamError', FProducerClass);
  AssertTrue('the producer error is the cancel error', FProducerCode = ecCancel);
  AssertEquals('the call raised EHttpStreamError', 'EHttpStreamError', FErrorClass);
  AssertTrue('the call ends with the cancel error', FErrorCode = ecCancel);
  AssertTrue('the stream is reset with CANCEL', WaitForFrame(ftRstStream, False));
end;

initialization
  RegisterTest(TBodyWriterStreamingTest);
  RegisterTest(TProducerUploadTest);
end.
