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
/// Pull-rate test of the client request body writer
unit Http2.Client.BodyWriterStreaming.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Common.Frames, Http2.Common.Body, Http2.Client.MockSocket.Frames,
  Http2.Client.Messages, Http2.Client.Stream, Http2.Client,
  Http2.Client.MockSocket.Support;

type
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

initialization
  RegisterTest(TBodyWriterStreamingTest);
end.
