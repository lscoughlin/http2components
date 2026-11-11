{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test
notes:
  - this preserves request observer tests from the source project
---
}
unit Http2.Client.Http1Arrival.Test;

{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}

interface

uses
    SysUtils, Classes, SyncObjs, Generics.Collections, fpcunit, testregistry,
  Http2.Client.Errors, Http2.Common.Frames, Http2.Common.Headers, Http2.Client.Tls, Http2.Client.Stream,
  Http2.Client.Messages,
  Http2.Client, Http2.Client.Clock, Http2.Client.RequestObserver, Http2.Client.Redirects.Test,
  Http2.Client.ClearText.Support, Http2.Client.Http1, Http2.Client.Http1.Test, Http2.Client.Sse, Http2.Client.RequestObserver.Support;

type
  THttp1ArrivalTest = class(TTestCase)
  protected
    procedure TearDown; override;
  published
    // 19.5 / 19.6
    procedure TestTwoTransportReadsYieldTwoStamps;
    procedure TestChunkedBodyAgreesWithContentLength;
    procedure TestBufferMixingTwoReadsAttributesBytesCorrectly;
    procedure TestAggregatesFollowTheTransportReads;
    procedure TestResponseThroughTheClientReportsAggregates;
  end;


implementation

procedure THttp1ArrivalTest.TearDown;
begin
  ResetNowUsHook;
  inherited TearDown;
end;
procedure THttp1ArrivalTest.TestTwoTransportReadsYieldTwoStamps;
var
  Sock: TStagedSocket;
  SockRef: IHttp2Socket;
  Reader: TBufferedReader;
  BodyRef: IHttpBodyStream;
  Stamped: IStampedBodyStream;
  Buf: array[0..63] of Byte;
begin
  Sock := TStagedSocket.Create;
  SockRef := Sock;
  Sock.Add('abc', 100);     // 3 bytes, then a pause, then 5 more
  Sock.Add('defgh', 750);
  SetNowUsHook(ScriptedClock);
  Reader := TBufferedReader.Create(SockRef);
  try
    BodyRef := THttp1BodyStream.Create(Reader, bfContentLength, 8, nil);
    AssertTrue(Supports(BodyRef, IStampedBodyStream, Stamped));
    AssertEquals('first Read', 3, BodyRef.Read(Buf, SizeOf(Buf)));
    AssertEquals('first stamp', 100, Stamped.LastReadArrivedUs);
    AssertEquals('second Read', 5, BodyRef.Read(Buf, SizeOf(Buf)));
    AssertEquals('second stamp', 750, Stamped.LastReadArrivedUs);
    AssertEquals('EOF', 0, BodyRef.Read(Buf, SizeOf(Buf)));
  finally
    Stamped := nil;
    BodyRef := nil;
    Reader.Free;
  end;
end;

procedure THttp1ArrivalTest.TestChunkedBodyAgreesWithContentLength;
var
  Sock: TStagedSocket;
  SockRef: IHttp2Socket;
  Reader: TBufferedReader;
  BodyRef: IHttpBodyStream;
  Stamped: IStampedBodyStream;
  Buf: array[0..63] of Byte;
begin
  Sock := TStagedSocket.Create;
  SockRef := Sock;
  // the same 3 + 5 bytes, framed as chunks that split across the two reads
  Sock.Add('3'#13#10'abc'#13#10'5'#13#10'de', 100);
  Sock.Add('fgh'#13#10'0'#13#10#13#10, 750);
  SetNowUsHook(ScriptedClock);
  Reader := TBufferedReader.Create(SockRef);
  try
    BodyRef := THttp1BodyStream.Create(Reader, bfChunked, 0, nil);
    AssertTrue(Supports(BodyRef, IStampedBodyStream, Stamped));
    AssertEquals('first Read', 3, BodyRef.Read(Buf, SizeOf(Buf)));
    AssertEquals('first stamp', 100, Stamped.LastReadArrivedUs);
    AssertEquals('chunk bytes from the first read', 2,
      BodyRef.Read(Buf, SizeOf(Buf)));
    AssertEquals('same read, same stamp', 100, Stamped.LastReadArrivedUs);
    AssertEquals('the rest of the chunk', 3, BodyRef.Read(Buf, SizeOf(Buf)));
    AssertEquals('second read', 750, Stamped.LastReadArrivedUs);
    AssertEquals('EOF', 0, BodyRef.Read(Buf, SizeOf(Buf)));
  finally
    Stamped := nil;
    BodyRef := nil;
    Reader.Free;
  end;
end;

procedure THttp1ArrivalTest.TestBufferMixingTwoReadsAttributesBytesCorrectly;
var
  Sock: TStagedSocket;
  SockRef: IHttp2Socket;
  Reader: TBufferedReader;
  Line: string;
  Buf: array[0..63] of Byte;
begin
  Sock := TStagedSocket.Create;
  SockRef := Sock;
  Sock.Add('head'#13#10'ab', 10);
  Sock.Add('cd', 20);
  Sock.Add('ef', 30);
  SetNowUsHook(ScriptedClock);
  Reader := TBufferedReader.Create(SockRef);
  try
    AssertTrue(Reader.ReadLine(Line));
    AssertEquals('head', Line);
    // the buffer holds 'ab' from read 1; each later Fill appends a read
    AssertEquals(2, Reader.ReadBytes(Buf, 64));
    AssertEquals('bytes of read 1', 10, Reader.LastReadUs);
    AssertEquals(2, Reader.ReadBytes(Buf, 64));
    AssertEquals('bytes of read 2', 20, Reader.LastReadUs);
    AssertEquals(2, Reader.ReadBytes(Buf, 64));
    AssertEquals('bytes of read 3', 30, Reader.LastReadUs);
  finally
    Reader.Free;
  end;
end;

procedure THttp1ArrivalTest.TestAggregatesFollowTheTransportReads;
var
  Sock: TStagedSocket;
  SockRef: IHttp2Socket;
  Reader: TBufferedReader;
  Body: THttp1BodyStream;
  BodyRef: IHttpBodyStream;
  Cap: TCapturedExchange;
  CapRef: IExchangeObserver;
  Buf: array[0..63] of Byte;
begin
  Sock := TStagedSocket.Create;
  SockRef := Sock;
  Sock.Add('ab', 1000);
  Sock.Add('cd', 1300);
  Sock.Add('ef', 1350);
  SetNowUsHook(ScriptedClock);
  Cap := TCapturedExchange.Create;
  CapRef := Cap;
  Reader := TBufferedReader.Create(SockRef);
  try
    Body := THttp1BodyStream.Create(Reader, bfUntilClose, 0, nil);
    BodyRef := Body;
    Body.AttachExchange(CapRef, 0);
    // a 1-byte buffer: two Reads per transport read, still one arrival each
    while BodyRef.Read(Buf, 1) > 0 do ;
    AssertEquals('one end', 1, Cap.Ends);
    AssertEquals('three arrivals', 3, Cap.Last.Arrivals.Count);
    AssertEquals('first', 1000, Cap.Last.Arrivals.FirstUs);
    AssertEquals('last', 1350, Cap.Last.Arrivals.LastUs);
    AssertEquals('max gap', 300, Cap.Last.Arrivals.MaxGapUs);
    AssertEquals('sum', 350, Cap.Last.Arrivals.SumGapUs);
  finally
    BodyRef := nil;
    Reader.Free;
  end;
end;

procedure THttp1ArrivalTest.TestResponseThroughTheClientReportsAggregates;
var
  Obs: TRecordingRequestObserver;
  ObsRef: IHttpClientObserver;
  Client: IHttpClient;
  R: IHttpResponse;
  Buf: array[0..63] of Byte;
  O: THttpOutcome;
begin
  Obs := TRecordingRequestObserver.Create;
  ObsRef := Obs;
  GScriptedUs := 500000;
  SetNowUsHook(ScriptedClock);
  Client := THttpClientFactory.Create
    .WithSocketFactory(TScriptProtocolFactory.Create(npHttp1Tls,
      'HTTP/1.1 200 OK'#13#10'Content-Length: 5'#13#10#13#10'hello'))
    .WithHttp1Fallback.WithClearText(ctReject)
    .WithRequestObserver(ObsRef).Build;
  R := Client.Send(THttpRequest.Create(hmGet, 'https://secure.example/x'));
  GScriptedUs := 500900;
  while R.Body.Read(Buf, SizeOf(Buf)) > 0 do ;
  AssertTrue(Obs.WaitForEnds(1, 5000));
  O := Obs.Outcome(0).O;
  AssertEquals('head and body came in one read: one message', 1, O.MessagesIn);
  AssertEquals(O.FirstMessageUs, O.LastMessageUs);
  AssertEquals(0, O.MaxGapUs);
  AssertEquals(5, O.BytesIn);
  R := nil;
  Client.Close;
end;

initialization
  RegisterTest(THttp1ArrivalTest);
end.
