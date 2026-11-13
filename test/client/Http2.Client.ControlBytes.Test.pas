{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: client_test, control_bytes, header, request_target, connect, h2c
notes:
  - this tests the control byte checks at each client call site that writes
    a request line, a header field or a CONNECT authority
---
}
/// Control byte tests for the client (doc/design/common/headers.md).
// - a header value, a header name, a request target, a CONNECT authority and
//   an h2c upgrade request that carry a control byte raise EHttpProtocolError
//   before any byte goes on the wire.
unit Http2.Client.ControlBytes.Test;

{$mode delphi}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, Http2.Client.Errors,
  Http2.Client, Http2.Client.Tls, Http2.Client.Stream, Http2.Client.Http1,
  Http2.Client.Upgrade, Http2.Client.Tls.Tunnel, Http2.Client.Socks,
  Http2.Client.ClearText.Support;

type
  /// an ISocksChannel that records the bytes written to it
  TRecordingChannel = class(TInterfacedObject, ISocksChannel)
  private
    FWritten: Integer;
  public
    procedure WriteAll(const AData: TBytes);
    function ReadSome(var ABuffer; const ACount: Integer): Integer;
    property Written: Integer read FWritten;
  end;

  TControlByteTest = class(TTestCase)
  published
    procedure TestHeaderValueWithCrLfRaisesBeforeTheWire;
    procedure TestHeaderValueWithNulRaisesBeforeTheWire;
    procedure TestHeaderNameWithSpaceRaisesBeforeTheWire;
    procedure TestHeaderNameWithColonRaisesBeforeTheWire;
    procedure TestUrlPathWithSpaceRaisesBeforeTheWire;
    procedure TestMethodWithSpaceRaisesBeforeTheWire;
    procedure TestHttp1PathWithSpaceRaisesBeforeTheWire;
    procedure TestHttp1HostWithControlByteRaisesBeforeTheWire;
    procedure TestConnectHostWithControlByteRaisesBeforeTheWire;
    procedure TestH2cUpgradePathWithSpaceRaisesBeforeTheWire;
    procedure TestH2cUpgradeHostWithControlByteRaisesBeforeTheWire;
    procedure TestValidTargetAndHostStillBuild;
  end;

implementation

procedure TRecordingChannel.WriteAll(const AData: TBytes);
begin
  Inc(FWritten, Length(AData));
end;

function TRecordingChannel.ReadSome(var ABuffer; const ACount: Integer): Integer;
begin
  Result := 0;
end;

{ TControlByteTest }

procedure TControlByteTest.TestHeaderValueWithCrLfRaisesBeforeTheWire;
var
  Factory: TScriptProtocolFactory;
  Client: IHttpClient;
  Raised: Boolean;
begin
  Factory := TScriptProtocolFactory.Create(npHttp1Cleartext, '');
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithClearText(ctHttp1)
    .Build;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'http://plain.example/x')
      .WithHeader('X-Id', 'a'#13#10'Set-Cookie: x'));
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a CRLF in a header value raises EHttpProtocolError', Raised);
  AssertEquals('no socket was dialled', 0, Factory.Dials);
end;

procedure TControlByteTest.TestHeaderValueWithNulRaisesBeforeTheWire;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpRequest.Create(hmGet, 'https://a.example/')
      .WithHeader('X-Id', 'a'#0'b');
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a NUL in a header value raises EHttpProtocolError', Raised);
end;

procedure TControlByteTest.TestHeaderNameWithSpaceRaisesBeforeTheWire;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpRequest.Create(hmGet, 'https://a.example/')
      .WithHeader('bad name', 'x');
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a space in a header name raises EHttpProtocolError', Raised);
end;

procedure TControlByteTest.TestHeaderNameWithColonRaisesBeforeTheWire;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpRequest.Create(hmGet, 'https://a.example/')
      .WithHeader('a:b', 'x');
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a colon in a header name raises EHttpProtocolError', Raised);
end;

procedure TControlByteTest.TestUrlPathWithSpaceRaisesBeforeTheWire;
var
  Factory: TScriptProtocolFactory;
  Client: IHttpClient;
  Raised: Boolean;
begin
  // ParseURI rejects the space before any socket is dialled
  Factory := TScriptProtocolFactory.Create(npHttp1Cleartext, '');
  Client := THttpClientFactory.Create
    .WithSocketFactory(Factory)
    .WithClearText(ctHttp1)
    .Build;
  Raised := False;
  try
    Client.Send(THttpRequest.Create(hmGet, 'http://plain.example/a b'));
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a space in the URL path raises EHttpProtocolError', Raised);
  AssertEquals('no socket was dialled', 0, Factory.Dials);
end;

procedure TControlByteTest.TestMethodWithSpaceRaisesBeforeTheWire;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    THttpRequest.Create(hmGet, 'https://a.example/').WithMethodToken('GE T');
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a space in the method raises EHttpProtocolError', Raised);
end;

procedure TControlByteTest.TestHttp1PathWithSpaceRaisesBeforeTheWire;
var
  Req: TStreamRequest;
  Raised: Boolean;
  Bytes: TBytes;
begin
  Req := TStreamRequest.Create('GET', 'example.com').WithPath('/a b');
  Raised := False;
  try
    Bytes := BuildHttp1Request(Req);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a space in the HTTP/1 target raises EHttpProtocolError', Raised);
  AssertEquals('no bytes were built', 0, Length(Bytes));
end;

procedure TControlByteTest.TestHttp1HostWithControlByteRaisesBeforeTheWire;
var
  Req: TStreamRequest;
  Raised: Boolean;
  Bytes: TBytes;
begin
  Req := TStreamRequest.Create('GET', 'example.com'#13#10'X-Evil: 1');
  Raised := False;
  try
    Bytes := BuildHttp1Request(Req);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a CRLF in the HTTP/1 host raises EHttpProtocolError', Raised);
  AssertEquals('no bytes were built', 0, Length(Bytes));
end;

procedure TControlByteTest.TestConnectHostWithControlByteRaisesBeforeTheWire;
var
  Channel: TRecordingChannel;
  ChannelRef: ISocksChannel;
  Raised: Boolean;
begin
  Channel := TRecordingChannel.Create;
  ChannelRef := Channel;
  Raised := False;
  try
    EstablishConnectTunnel(ChannelRef, 'proxied.example'#13#10'X: y', 443, '', '');
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a CRLF in the CONNECT host raises EHttpProtocolError', Raised);
  AssertEquals('no CONNECT bytes were written', 0, Channel.Written);
end;

procedure TControlByteTest.TestH2cUpgradePathWithSpaceRaisesBeforeTheWire;
var
  Req: TStreamRequest;
  Raised: Boolean;
  Bytes: TBytes;
begin
  Req := TStreamRequest.Create('GET', 'example.com').WithPath('/a b');
  Raised := False;
  try
    Bytes := BuildH2cUpgradeRequest(Req);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('a space in the h2c target raises EHttpProtocolError', Raised);
  AssertEquals('no bytes were built', 0, Length(Bytes));
end;

procedure TControlByteTest.TestH2cUpgradeHostWithControlByteRaisesBeforeTheWire;
var
  Req: TStreamRequest;
  Raised: Boolean;
  Bytes: TBytes;
begin
  Req := TStreamRequest.Create('GET', 'example.com'#10'X: y');
  Raised := False;
  try
    Bytes := BuildH2cUpgradeRequest(Req);
  except
    on E: EHttpProtocolError do Raised := True;
  end;
  AssertTrue('an LF in the h2c host raises EHttpProtocolError', Raised);
  AssertEquals('no bytes were built', 0, Length(Bytes));
end;

procedure TControlByteTest.TestValidTargetAndHostStillBuild;
var
  Req: TStreamRequest;
  Bytes: TBytes;
  Wire: string;
begin
  Req := TStreamRequest.Create('GET', 'example.com').WithPath('/a/b?c=d&e=%20');
  Bytes := BuildHttp1Request(Req);
  SetString(Wire, PAnsiChar(@Bytes[0]), Length(Bytes));
  AssertTrue('a valid target is written',
    Pos('GET /a/b?c=d&e=%20 HTTP/1.1', Wire) = 1);
  Bytes := BuildH2cUpgradeRequest(Req);
  SetString(Wire, PAnsiChar(@Bytes[0]), Length(Bytes));
  AssertTrue('a valid h2c target is written',
    Pos('GET /a/b?c=d&e=%20 HTTP/1.1', Wire) = 1);
end;

initialization
  RegisterTest(TControlByteTest);

end.
