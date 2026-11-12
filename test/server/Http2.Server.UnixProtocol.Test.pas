{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: unix socket, test, http2, http1.1, tls, fpcunit
notes:
  - This unit tests the protocols over a Unix socket: HTTP/2 with prior knowledge,
    many HTTP/1.1 connections in sequence and in parallel, and TLS with ALPN.
  - The HTTP/2 test writes raw octets with the frame and HPACK units, because the
    in-memory peer of the connection core cannot write to a socket.
  - Each test uses a path under /tmp that TearDown removes.
---
}
unit Http2.Server.UnixProtocol.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$interfaces com}

interface

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, process, fpcunit, testregistry,
  Http2.Server, Http2.Server.Unix.TestKit,
  Http2.Common.Frames, Http2.Common.Hpack, Http2.Common.Tls.Context,
  Http2.Common.Tls.Policy;

type
  /// the tests of the protocols over a Unix socket listener
  TUnixProtocolTest = class(TTestCase)
  private
    FPath: string;
    FHandler: IHttp2Handler;
    FServer: IHttp2Server;
    procedure StartServer;
    procedure AssertHttp2Answer(const AWire: RawByteString);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure TestH2cPriorKnowledgeOverUnix;
    procedure TestManyConnectionsOverUnix;
  end;

implementation

type
  /// a handler that answers every request with the body hi
  TUnixHiHandler = class(TInterfacedObject, IHttp2Handler)
  public
    procedure Handle(const ARequest: IServerRequest;
      const AResponse: IServerResponse);
  end;

  /// one HTTP/1.1 request over a Unix socket, run on its own thread
  TUnixGetThread = class(TThread)
  private
    FPath: string;
    FOk: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const APath: string);
    /// true when the answer is a 200 with the body hi
    property Ok: Boolean read FOk;
  end;

const
  CRLF = #13#10;
  CRLF2 = #13#10#13#10;
  /// the certificate pair of the loopback TLS fixtures, relative to the repository
  cTlsCertFile = 'test/fixtures/client/certs/localhost.crt';
  cTlsKeyFile = 'test/fixtures/client/certs/localhost.key';

procedure TUnixHiHandler.Handle(const ARequest: IServerRequest;
  const AResponse: IServerResponse);
var
  H: THeaderBlock;
  Body: TBytes;
begin
  SetLength(H, 1);
  H[0].Name := 'content-length';
  H[0].Value := '2';
  SetLength(Body, 2);
  Body[0] := Ord('h');
  Body[1] := Ord('i');
  AResponse.SendHeaders(200, H, False);
  AResponse.Write(Body);
  AResponse.Finish;
end;

/// the octets of a byte array as a raw string
function BytesToRaw(const AData: TBytes): RawByteString;
begin
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

/// one frame as wire octets: the 9-byte header, then the payload
function FrameToWire(const AFrame: TFrame): RawByteString;
var
  B: TBytes;
begin
  SetLength(B, FrameHeaderSize + Length(AFrame.Payload));
  AFrame.Header.WriteTo(B);
  if Length(AFrame.Payload) > 0 then
    Move(AFrame.Payload[0], B[FrameHeaderSize], Length(AFrame.Payload));
  Result := BytesToRaw(B);
end;

/// the frames in the octets that a server wrote; an incomplete tail is left out
function ParseFrames(const AWire: RawByteString): TArray<TFrame>;
var
  Pos, Len: Integer;
  Hdr: TBytes;
  F: TFrame;
begin
  SetLength(Result, 0);
  Pos := 1;
  while Length(AWire) - Pos + 1 >= FrameHeaderSize do
  begin
    SetLength(Hdr, FrameHeaderSize);
    Move(AWire[Pos], Hdr[0], FrameHeaderSize);
    F := Default(TFrame);
    F.Header := TFrameHeader.ReadFrom(Hdr);
    Len := Integer(F.Header.Length);
    if Length(AWire) - Pos + 1 - FrameHeaderSize < Len then
      Break;
    SetLength(F.Payload, Len);
    if Len > 0 then
      Move(AWire[Pos + FrameHeaderSize], F.Payload[0], Len);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := F;
    Inc(Pos, FrameHeaderSize + Len);
  end;
end;

/// the status of the first HEADERS frame on a stream; false when none has one
function StatusOnStream(const AFrames: TArray<TFrame>; const AStreamId: LongWord;
  out AStatus: string): Boolean;
var
  I, J: Integer;
  Dec: THpackCodec;
  Block: THeaderBlock;
begin
  Result := False;
  AStatus := '';
  Dec := THpackCodec.Create;
  try
    for I := 0 to High(AFrames) do
      if (AFrames[I].Header.FrameType = ftHeaders) and
        (AFrames[I].Header.StreamId = AStreamId) then
      begin
        Block := Dec.Decode(ExtractHeaderBlock(AFrames[I]));
        for J := 0 to High(Block) do
          if Block[J].Name = ':status' then
          begin
            AStatus := Block[J].Value;
            Result := True;
            Exit;
          end;
        Exit;
      end;
  finally
    Dec.Free;
  end;
end;

/// the HTTP/1.1 answer of a GET / with Connection: close over a Unix socket
// - answers the empty string when the connect fails
function OverUnixAnswer(const APath: string): string;
var
  Fd: Integer;
begin
  Result := '';
  Fd := UnixConnect(APath, 2000);
  if Fd < 0 then
    Exit;
  try
    UnixSend(Fd, 'GET / HTTP/1.1' + CRLF + 'Host: localhost' + CRLF +
      'Connection: close' + CRLF + CRLF);
    Result := string(UnixReadAll(Fd, 3000));
  finally
    UnixClose(Fd);
  end;
end;

/// true when the answer is a 200 status line with the body hi
function IsHiAnswer(const AAnswer: string): Boolean;
begin
  Result := (Pos('HTTP/1.1 200', AAnswer) = 1) and
    (Pos(CRLF2 + 'hi', AAnswer) > 0);
end;

/// copies what the process wrote so far to AMem; true while it runs
function DrainProcess(const AProcess: TProcess; const AMem: TMemoryStream): Boolean;
var
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  while AProcess.Output.NumBytesAvailable > 0 do
  begin
    N := AProcess.Output.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    AMem.Write(Buf, N);
  end;
  Result := AProcess.Running;
end;

/// runs a command with the input text and answers its output, stderr included
function RunCommand(const AExe: string; const AArgs: array of string;
  const AInput: string; out AOutput: string): Boolean;
var
  P: TProcess;
  Mem: TMemoryStream;
  I: Integer;
  Deadline: QWord;
  Text: RawByteString;
begin
  AOutput := '';
  Result := False;
  P := TProcess.Create(nil);
  Mem := TMemoryStream.Create;
  try
    P.Executable := AExe;
    for I := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[I]);
    P.Options := [poUsePipes, poStderrToOutput];
    P.Execute;
    if AInput <> '' then
    begin
      Text := RawByteString(AInput);
      P.Input.Write(Text[1], Length(Text));
    end;
    P.CloseInput;
    Deadline := GetTickCount64 + 15000;
    while DrainProcess(P, Mem) and (GetTickCount64 < Deadline) do
      Sleep(10);
    if P.Running then
    begin
      P.Terminate(1);
      Exit;
    end;
    DrainProcess(P, Mem);
    SetLength(AOutput, Mem.Size);
    if Mem.Size > 0 then
      Move(Mem.Memory^, AOutput[1], Mem.Size);
    Result := True;
  finally
    Mem.Free;
    P.Free;
  end;
end;

constructor TUnixGetThread.Create(const APath: string);
begin
  FPath := APath;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TUnixGetThread.Execute;
begin
  FOk := IsHiAnswer(OverUnixAnswer(FPath));
end;

procedure TUnixProtocolTest.SetUp;
begin
  FPath := NewUnixTestPath;
  FHandler := TUnixHiHandler.Create;
end;

procedure TUnixProtocolTest.TearDown;
begin
  if FServer <> nil then
    FServer.Stop;
  FServer := nil;
  FHandler := nil;
  if FPath <> '' then
    DeleteFile(FPath);
end;

procedure TUnixProtocolTest.StartServer;
var
  LFactory: THttp2ServerFactory;
begin
  LFactory := THttp2ServerFactory.Create
    .WithUnixSocket(FPath)
    .WithClearTextAllowed(True)
    .WithHttp11Fallback(True)
    .WithHandler(FHandler)
    .WithHandlerThreads(2)
    .WithIOThreads(2)
    .WithGracefulStopTimeout(500);
  FServer := LFactory.Build;
  FServer.Start;
end;

procedure TUnixProtocolTest.AssertHttp2Answer(const AWire: RawByteString);
var
  Frames: TArray<TFrame>;
  Status: string;
begin
  Frames := ParseFrames(AWire);
  AssertTrue('the server sends frames', Length(Frames) > 0);
  AssertEquals('the first frame is SETTINGS', Ord(ftSettings),
    Ord(Frames[0].Header.FrameType));
  AssertFalse('the first SETTINGS is not an ACK', Frames[0].IsAck);
  AssertTrue('a HEADERS frame answers stream 1',
    StatusOnStream(Frames, 1, Status));
  AssertEquals('the status is 200', '200', Status);
end;

procedure TUnixProtocolTest.TestH2cPriorKnowledgeOverUnix;
var
  Fd: Integer;
  Fields: THeaderBlock;
  Enc: THpackCodec;
  Wire: RawByteString;
  Preface: TBytes;
  Settings, Headers: TFrame;
  Block: TBytes;
begin
  StartServer;
  SetLength(Fields, 4);
  Fields[0].Name := ':method';
  Fields[0].Value := 'GET';
  Fields[1].Name := ':scheme';
  Fields[1].Value := 'http';
  Fields[2].Name := ':path';
  Fields[2].Value := '/';
  Fields[3].Name := ':authority';
  Fields[3].Value := 'localhost';
  Enc := THpackCodec.Create;
  try
    Block := Enc.Encode(Fields);
  finally
    Enc.Free;
  end;
  SetLength(Preface, ClientPrefaceSize);
  Move(ClientPreface, Preface[0], ClientPrefaceSize);
  Settings := TFrame.Create(ftSettings, [], 0, nil);
  Headers := BuildHeadersFrame(1, Block, True, True);
  Wire := BytesToRaw(Preface) + FrameToWire(Settings) + FrameToWire(Headers);

  Fd := UnixConnect(FPath, 2000);
  AssertTrue('the socket accepts a connect', Fd >= 0);
  try
    UnixSend(Fd, Wire);
    AssertHttp2Answer(UnixReadAll(Fd, 1500));
  finally
    UnixClose(Fd);
  end;
end;

procedure TUnixProtocolTest.TestManyConnectionsOverUnix;
const
  cSequential = 20;
  cParallel = 8;
var
  I: Integer;
  Answer: string;
  Threads: array of TUnixGetThread;
begin
  StartServer;
  for I := 1 to cSequential do
  begin
    Answer := OverUnixAnswer(FPath);
    AssertTrue('sequential request ' + IntToStr(I) + ': ' + Answer,
      IsHiAnswer(Answer));
  end;
  SetLength(Threads, cParallel);
  for I := 0 to cParallel - 1 do
    Threads[I] := TUnixGetThread.Create(FPath);
  try
    for I := 0 to cParallel - 1 do
    begin
      Threads[I].WaitFor;
      AssertTrue('parallel request ' + IntToStr(I + 1) + ' answers 200 hi',
        Threads[I].Ok);
    end;
  finally
    for I := 0 to cParallel - 1 do
      Threads[I].Free;
  end;
end;

initialization
  RegisterTest(TUnixProtocolTest);

end.
