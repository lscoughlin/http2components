{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
---
}
unit Http2.Integration.Http.Test;
{$mode delphi}{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
interface
uses
  SysUtils, Classes, fpcunit, testregistry,
  Http2.Common, Http2.Client, Http2.Server, Http2.OpenSSL,
  Http2.Client.Messages, Http2.Client.Stream, Http2.Client.Tls;
type
  TCombinedHttpTest = class(TTestCase)
  private
    procedure Exchange(const ATls: Boolean; const APolicy: TClearTextPolicy);
  published
    procedure TestClearTextHttp2BinaryEcho;
    procedure TestClearTextHttp1ChunkedEcho;
    procedure TestTlsHttp2BinaryEcho;
    procedure TestRepeatedStartStop;
    procedure TestConcurrentHttp2Requests;
  end;
implementation
type
  TEchoHandler = class(TInterfacedObject, IHttp2Handler)
    procedure Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
  end;
  TRequestThread = class(TThread)
  private
    FClient: IHttpClient;
    FUrl: string;
  protected
    procedure Execute; override;
  public
    ErrorText: string;
    constructor Create(const AClient: IHttpClient; const AUrl: string);
  end;

procedure TEchoHandler.Handle(const ARequest: IServerRequest; const AResponse: IServerResponse);
var
  Buffer: array[0..4095] of Byte;
  Count: Integer;
  Headers: Http2.Common.THeaderBlock;
begin
  SetLength(Headers, 1);
  Headers[0].Name := 'x-stream-id';
  Headers[0].Value := IntToStr(ARequest.StreamId);
  AResponse.SendHeaders(200, Headers, False);
  repeat
    Count := ARequest.Read(Buffer, SizeOf(Buffer));
    if Count > 0 then AResponse.Write(Buffer, Count);
  until Count = 0;
  AResponse.Finish;
end;

function NewServer(const ATls: Boolean): IHttp2Server;
var
  Factory: THttp2ServerFactory;
  Pki: string;
  Identity: ITLSIdentity;
  Policy: TTlsServerPolicy;
begin
  Factory := THttp2ServerFactory.Create.WithHost('127.0.0.1').WithPort(0)
    .WithHandler(TEchoHandler.Create).WithHandlerThreads(2).WithIOThreads(1)
    .WithGracefulStopTimeout(250).WithClearTextAllowed(not ATls);
  if ATls then
  begin
    Pki := GetEnvironmentVariable('HTTP2_TEST_PKI');
    if not FileExists(Pki + '/server.crt') then
      raise Exception.Create('HTTP2_TEST_PKI does not contain server.crt');
    Identity := TOpenSSLIdentity.FromPemFiles(Pki + '/server.crt', Pki + '/server.key');
    Policy := TTlsServerPolicy.SecureDefault.WithServerIdentity(Identity);
    Factory := Factory.WithTlsContext(TOpenSSLTlsContextFactory.Create
      .WithServerPolicy(Policy).Build);
  end;
  Result := Factory.Build;
  Result.Start;
end;

function NewClient(const APolicy: TClearTextPolicy; const ATls: Boolean): IHttpClient;
var
  Factory: THttpClientFactory;
  TlsContext: ITLSContext;
begin
  Factory := THttpClientFactory.Create.WithClearText(APolicy)
    .WithConnectTimeout(2000).WithHeaderTimeout(3000).WithMaxConnectionsPerHost(1);
  if ATls then
  begin
    TlsContext := TOpenSSLTlsContextFactory.Create
      .WithClientPolicy(TTlsClientPolicy.SecureDefault.WithTrustAnchors([
        GetEnvironmentVariable('HTTP2_TEST_PKI') + '/ca.crt']))
      .Build;
    Factory := Factory.WithTlsContext(TlsContext);
  end;
  Result := Factory.Build;
end;

procedure TCombinedHttpTest.Exchange(const ATls: Boolean; const APolicy: TClearTextPolicy);
var
  Server: IHttp2Server;
  Client: IHttpClient;
  Response: IHttpResponse;
  Sent, Received: TBytes;
  I: Integer;
  Scheme, Url: string;
begin
  Server := NewServer(ATls);
  Client := NewClient(APolicy, ATls);
  try
    if ATls then Scheme := 'https' else Scheme := 'http';
    Url := Scheme + '://localhost:' + IntToStr(Server.Port) + '/echo';
    SetLength(Sent, 70003);
    for I := 0 to High(Sent) do Sent[I] := Byte(I mod 251);
    Response := Client.Send(THttpRequest.Create(hmPost, Url).WithBody(THttpBody.FromBytes(Sent)));
    AssertEquals('status', 200, Response.StatusCode);
    Received := ReadAllBodyBytes(Response.Body);
    AssertEquals('length across the default HTTP/2 window', Length(Sent), Length(Received));
    AssertTrue('binary echo preserves every byte', CompareMem(@Sent[0], @Received[0], Length(Sent)));
    Response := nil;
    Response := Client.Send(THttpRequest.Create(hmPost, Url).WithBody(THttpBody.FromString('reuse')));
    AssertEquals('connection reuse', 'reuse', ReadText(Response));
    Response := nil;
    Response := Client.Send(THttpRequest.Create(hmHead, Url));
    AssertEquals('HEAD status', 200, Response.StatusCode);
    AssertEquals('HEAD body', '', ReadText(Response));
    Response := nil;
  finally
    Client.Close;
    Server.Stop;
  end;
end;

procedure TCombinedHttpTest.TestClearTextHttp2BinaryEcho;
begin Exchange(False, ctPriorKnowledge); end;
procedure TCombinedHttpTest.TestClearTextHttp1ChunkedEcho;
begin Exchange(False, ctHttp1); end;
procedure TCombinedHttpTest.TestTlsHttp2BinaryEcho;
begin Exchange(True, ctReject); end;
procedure TCombinedHttpTest.TestRepeatedStartStop;
var I: Integer;
begin
  for I := 1 to 3 do Exchange(False, ctPriorKnowledge);
end;

constructor TRequestThread.Create(const AClient: IHttpClient; const AUrl: string);
begin
  inherited Create(True);
  FClient := AClient; FUrl := AUrl;
end;
procedure TRequestThread.Execute;
var
  Response: IHttpResponse;
begin
  try
    Response := FClient.Send(THttpRequest.Create(hmPost, FUrl).WithBody(THttpBody.FromString(FUrl)));
    if ReadText(Response) <> FUrl then ErrorText := 'concurrent response differs';
  except
    on E: Exception do ErrorText := E.ClassName + ': ' + E.Message;
  end;
end;
procedure TCombinedHttpTest.TestConcurrentHttp2Requests;
var
  Server: IHttp2Server;
  Client: IHttpClient;
  Workers: array[0..3] of TRequestThread;
  I: Integer;
begin
  FillChar(Workers, SizeOf(Workers), 0);
  Server := NewServer(False);
  Client := NewClient(ctPriorKnowledge, False);
  try
    for I := Low(Workers) to High(Workers) do
    begin
      Workers[I] := TRequestThread.Create(Client,
        'http://127.0.0.1:' + IntToStr(Server.Port) + '/echo/' + IntToStr(I));
      Workers[I].Start;
    end;
    for I := Low(Workers) to High(Workers) do
    begin
      Workers[I].WaitFor;
      AssertEquals('worker ' + IntToStr(I), '', Workers[I].ErrorText);
    end;
  finally
    for I := Low(Workers) to High(Workers) do Workers[I].Free;
    Client.Close;
    Server.Stop;
  end;
end;
initialization
  RegisterTest(TCombinedHttpTest);
end.
