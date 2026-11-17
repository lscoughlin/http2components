{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, http1, server, body writer, streaming, test, fpcunit
notes:
  - This unit proves that the server body writers pull a chunk only when the
    consumer takes the octets of the earlier chunks.
  - The HTTP/2 response uses a TServerStream with an outbound limit. A handler
    thread waits in Write, and the test thread takes the octets.
  - The HTTP/1.1 response uses a TH1Exchange over a host fake that counts the
    backlog of queued octets.
  - The compressing writer pulls one inner chunk at a time.
---
}
/// Pull-rate tests of the server body writers
unit Http2.Server.BodyWriterStreaming.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  SysUtils, Classes, SyncObjs, fpcunit, testregistry,
  Http2.Common.Body, Http2.Common.Hpack, Http2.Server.Errors, Http2.Server.Seam,
  Http2.Server.Duplex, Http2.Server.Stream, Http2.Server.StreamAdapters,
  Http2.Server.Http1.Guard, Http2.Server.Http1.Host,
  Http2.Server.Http1.Exchange, Http2.Server.Encoding;

type
  /// a body writer that yields N chunks of S octets and counts them
  // - the call after the last chunk returns False and writes no octets
  // - the chunks differ, so a coder cannot shrink them to nothing
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

  /// runs SetBodyWriter and then Finish on its own thread, as a handler does
  TWriterThread = class(TThread)
  private
    FResponse: IServerResponse;
    FWriter: IBodyWriter;
    FFailed: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AResponse: IServerResponse;
      const AWriter: IBodyWriter);
    /// true when SetBodyWriter or Finish raised an exception
    property Failed: Boolean read FFailed;
  end;

  /// a connection host for the HTTP/1.1 exchange that counts its backlog
  // - the test takes octets with Take; the backlog is the queued minus the taken
  TCapHost = class(TH1Host)
  private
    FLock: TCriticalSection;
    FQueued: Int64;
    FTaken: Int64;
  public
    constructor Create;
    destructor Destroy; override;
    procedure EnqueueOutput(const AData: TBytes); override;
    function OutputBacklog: Int64; override;
    procedure RequestContinue; override;
    procedure ExchangeFinished(const AKeepAlive, AFailed: Boolean); override;
    procedure AbortConnection; override;
    procedure WatchDrain(const ALowWater: Int64;
      const ASink: IChannelSink); override;
    function BufferedAfterHead: Int64; override;
    procedure UpgradeBegin(const ATarget: IH1Inbound); override;
    procedure UpgradeDone; override;
    procedure UpgradeCancel; override;
    procedure CloseAfterOutput; override;
    /// the octets that were queued in total
    function Queued: Int64;
    /// take ACount octets from the backlog
    procedure Take(const ACount: Int64);
  end;

  /// tests of the pull rate of the server body writers
  TBodyWriterStreamingTest = class(TTestCase)
  private
    /// take every octet that the stream holds; return the count
    function TakeAll(const AStream: TServerStream): Int64;
  published
    /// with the outbound limit L and chunk size S, the HTTP/2 writer waits
    // at the limit: at most L div S + 2 chunks are pulled while nothing is taken
    procedure TestH2ResponseWriterIsPulledAtTheSpeedOfTheConsumer;
    /// the same bound for the HTTP/1.1 writer
    procedure TestH1ResponseWriterIsPulledAtTheSpeedOfTheConsumer;
    /// the compressing writer pulls one inner chunk per call of its own
    procedure TestCompressingWriterPullsOneInnerChunkAtATime;
  end;

implementation

const
  /// the outbound limit of the two response writers, in octets
  cOutboundLimit = 16384;
  /// the chunk size of the response writers, in octets
  cResponseChunk = 4096;
  /// the chunks of the response writers
  cResponseChunks = 20;
  /// the time that the consumer stays idle, in milliseconds
  cStallMs = 300;
  /// the longest wait for the writer thread to finish, in milliseconds
  cWaitMs = 10000;

/// append the octets of ABuffer to ATarget
procedure AppendChunk(var ATarget: TBytes; const ABuffer: TChunkBuffer);
var
  Count, At: Integer;
begin
  Count := ABuffer.Size;
  if Count <= 0 then
    Exit;
  At := Length(ATarget);
  SetLength(ATarget, At + Count);
  Move(ABuffer.Memory^, ATarget[At], Count);
end;

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

{ TWriterThread }

constructor TWriterThread.Create(const AResponse: IServerResponse;
  const AWriter: IBodyWriter);
begin
  // the fields are set before the thread starts
  inherited Create(True);
  FreeOnTerminate := False;
  FResponse := AResponse;
  FWriter := AWriter;
  Start;
end;

procedure TWriterThread.Execute;
begin
  try
    FResponse.SetBodyWriter(FWriter);
    FResponse.Finish;
  except
    on E: Exception do
      FFailed := True;
  end;
end;

{ TCapHost }

constructor TCapHost.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TCapHost.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TCapHost.EnqueueOutput(const AData: TBytes);
begin
  FLock.Acquire;
  try
    Inc(FQueued, Length(AData));
  finally
    FLock.Release;
  end;
end;

function TCapHost.OutputBacklog: Int64;
begin
  FLock.Acquire;
  try
    Result := FQueued - FTaken;
  finally
    FLock.Release;
  end;
end;

function TCapHost.Queued: Int64;
begin
  FLock.Acquire;
  try
    Result := FQueued;
  finally
    FLock.Release;
  end;
end;

procedure TCapHost.Take(const ACount: Int64);
begin
  FLock.Acquire;
  try
    Inc(FTaken, ACount);
  finally
    FLock.Release;
  end;
end;

procedure TCapHost.RequestContinue;
begin
  // the test sends no body that waits for 100 Continue
end;

procedure TCapHost.ExchangeFinished(const AKeepAlive, AFailed: Boolean);
begin
  // the test reads the octets only; the exchange end is not checked here
end;

procedure TCapHost.AbortConnection;
begin
  // the stall limit is 0 in these tests, so no abort happens
end;

procedure TCapHost.WatchDrain(const ALowWater: Int64; const ASink: IChannelSink);
begin
  // the exchange polls the backlog, so no drain callback is needed
end;

function TCapHost.BufferedAfterHead: Int64;
begin
  Result := 0;
end;

procedure TCapHost.UpgradeBegin(const ATarget: IH1Inbound);
begin
  // no upgrade happens in these tests
end;

procedure TCapHost.UpgradeDone;
begin
  // no upgrade happens in these tests
end;

procedure TCapHost.UpgradeCancel;
begin
  // no upgrade happens in these tests
end;

procedure TCapHost.CloseAfterOutput;
begin
  // the connection stays open in these tests
end;

{ TBodyWriterStreamingTest }

function TBodyWriterStreamingTest.TakeAll(const AStream: TServerStream): Int64;
var
  Data: TBytes;
begin
  Result := 0;
  while AStream.TakeOutbound(Data, 0) do
    Inc(Result, Length(Data));
end;

procedure TBodyWriterStreamingTest.TestH2ResponseWriterIsPulledAtTheSpeedOfTheConsumer;
var
  Stream: TServerStream;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Runner: TWriterThread;
  Yielded: Integer;
  Got: Int64;
  Deadline: QWord;
begin
  Stream := TServerStream.Create(1, nil, nil, 65536, cOutboundLimit);
  Response := TServerStreamResponse.Create(Stream, nil);
  Writer := TCountingWriter.Create(cResponseChunks, cResponseChunk);
  Runner := TWriterThread.Create(Response, Writer);
  try
    // the consumer takes nothing while the writer runs
    Sleep(cStallMs);
    Yielded := (Writer as TCountingWriter).Yielded;
    AssertTrue('the writer fills the outbound limit',
      Yielded >= cOutboundLimit div cResponseChunk);
    AssertTrue('the writer waits at the limit: at most L div S + 2 chunks',
      Yielded <= cOutboundLimit div cResponseChunk + 2);
    AssertFalse('the handler thread waits in Write', Runner.Finished);
    // the consumer takes the octets, and the rest follows
    Got := 0;
    Deadline := GetTickCount64 + cWaitMs;
    while (not Runner.Finished) and (GetTickCount64 < Deadline) do
    begin
      Got := Got + TakeAll(Stream);
      Sleep(1);
    end;
    AssertTrue('the writer finishes', Runner.Finished);
    AssertFalse('the writer raised nothing', Runner.Failed);
    Got := Got + TakeAll(Stream);
    AssertEquals('every chunk was yielded', cResponseChunks,
      (Writer as TCountingWriter).Yielded);
    AssertEquals('every octet reached the consumer',
      Int64(cResponseChunks) * cResponseChunk, Got);
  finally
    if not Runner.Finished then
    begin
      // release a writer that waits in Write, so the test does not hang
      Stream.Cancel(ecCancel);
      Runner.WaitFor;
    end;
    Runner.Free;
    Response := nil;
    Stream.Free;
  end;
end;

procedure TBodyWriterStreamingTest.TestH1ResponseWriterIsPulledAtTheSpeedOfTheConsumer;
var
  Host: TCapHost;
  Link: THostLink;
  LinkRef: IInterface;
  Options: TH1ExchangeOptions;
  Head: TH1Head;
  Headers: THeaderBlock;
  Response: IServerResponse;
  Writer: IBodyWriter;
  Runner: TWriterThread;
  Queued0: Int64;
  Yielded: Integer;
  Deadline: QWord;
begin
  Host := TCapHost.Create;
  Link := THostLink.Create(Host);
  LinkRef := Link;
  Options.Scheme := 'http';
  Options.OutboundLimit := cOutboundLimit;
  Options.BodyDeadlineMs := 0;
  Options.BodyTotalMs := 0;
  Options.WriteStallMs := 0;
  Options.BodyBudget := nil;
  // the head holds no field that the test does not set, so zero it first
  FillChar(Head, SizeOf(Head), 0);
  Head.Line.Method := 'GET';
  Head.Line.Minor := 1;
  Head.KeepAlive := True;
  Head.Expect100 := False;
  // the content length makes the body frames the same size as the chunks
  SetLength(Headers, 1);
  Headers[0].Name := 'content-length';
  Headers[0].Value := IntToStr(Int64(cResponseChunks) * cResponseChunk);
  Headers[0].Sensitive := False;
  Response := TH1Exchange.Create(Link, Head, Options, 1);
  Writer := TCountingWriter.Create(cResponseChunks, cResponseChunk);
  Runner := nil;
  try
    Response.SendHeaders(200, Headers, False);
    Queued0 := Host.Queued;
    Runner := TWriterThread.Create(Response, Writer);
    // the consumer takes nothing while the writer runs
    Sleep(cStallMs);
    Yielded := (Writer as TCountingWriter).Yielded;
    AssertTrue('the writer fills the outbound limit',
      Yielded >= cOutboundLimit div cResponseChunk);
    AssertTrue('the writer waits at the limit: at most L div S + 2 chunks',
      Yielded <= cOutboundLimit div cResponseChunk + 2);
    AssertFalse('the handler thread waits in WaitForRoom', Runner.Finished);
    // the consumer takes the octets, and the rest follows
    Deadline := GetTickCount64 + cWaitMs;
    while (not Runner.Finished) and (GetTickCount64 < Deadline) do
    begin
      Host.Take(Host.OutputBacklog);
      Sleep(1);
    end;
    AssertTrue('the writer finishes', Runner.Finished);
    AssertFalse('the writer raised nothing', Runner.Failed);
    Host.Take(Host.OutputBacklog);
    AssertEquals('every chunk was yielded', cResponseChunks,
      (Writer as TCountingWriter).Yielded);
    AssertEquals('every body octet reached the consumer',
      Int64(cResponseChunks) * cResponseChunk, Host.Queued - Queued0);
  finally
    if Runner <> nil then
    begin
      if not Runner.Finished then
      begin
        // release a writer that waits for room, so the test does not hang
        Link.Orphan;
        Runner.WaitFor;
      end;
      Runner.Free;
    end;
    Response := nil;
    LinkRef := nil;
    Host.Free;
  end;
end;

procedure TBodyWriterStreamingTest.TestCompressingWriterPullsOneInnerChunkAtATime;
const
  // the coder holds its output until its own buffer fills, so the chunks are
  // big enough that one inner call gives the coder enough input to emit
  cCodedChunk = 65536;
  cCodedChunks = 4;
var
  Inner: IBodyWriter;
  Writer: IBodyWriter;
  Buf: TChunkBuffer;
  More: Boolean;
  Coded: TBytes;
  Yielded: Integer;
begin
  Inner := TCountingWriter.Create(cCodedChunks, cCodedChunk);
  Writer := TCompressingBodyWriter.Create(Inner, ceGzip);
  Buf := TChunkBuffer.Create;
  try
    Buf.Reset;
    More := Writer.NextChunk(Buf);
    AppendChunk(Coded, Buf);
    Yielded := (Inner as TCountingWriter).Yielded;
    AssertTrue('the first call returns coded octets', More);
    AssertTrue('the first call pulls at most 2 inner chunks', Yielded <= 2);
    // the rest of the body
    while More do
    begin
      Buf.Reset;
      More := Writer.NextChunk(Buf);
      AppendChunk(Coded, Buf);
    end;
  finally
    Buf.Free;
  end;
  AssertEquals('the inner writer yielded every chunk', cCodedChunks,
    (Inner as TCountingWriter).Yielded);
  AssertEquals('the coded body decodes to every octet',
    cCodedChunks * cCodedChunk, Length(GzipDecompress(Coded)));
end;

initialization
  RegisterTest(TBodyWriterStreamingTest);
end.
