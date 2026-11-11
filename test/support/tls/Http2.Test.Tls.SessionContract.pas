{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, test, session, contract
notes:
  - Both providers use these buffer-session contract checks.
---
}
unit Http2.Test.Tls.SessionContract;

{$mode delphi}{$H+}{$interfaces com}

interface

uses SysUtils, Http2.Common.Tls.Types, Http2.Common.Tls.Context,
  Http2.Common.Tls.Policy, Http2.Common.Tls.Session;

{ The supplied context enables both roles and trusts its server identity.
  Session options select compatible ALPN and any required client identity.
  The result is the number of completed cases. Each case prints its name.
  The calling program owns the final case count and process deadline. }
function RunTlsSessionContract(const AContext: ITLSContext;
  const AClientOptions: TTlsClientSessionOptions;
  const AServerOptions: TTlsServerSessionOptions): Integer;

implementation

type
  TSessionPair = class
  private
    FClient, FServer: ITLSSession;
    FToClient, FToServer: TBytes;
    FClientOffset, FServerOffset: SizeInt;
    FStarted: QWord;
    FStep: Integer;
    procedure Transfer(const ASource, ADestination: ITLSSession;
      var APending: TBytes; var AOffset: SizeInt);
  public
    constructor Create(const AContext: ITLSContext;
      AClientOptions: TTlsClientSessionOptions;
      AServerOptions: TTlsServerSessionOptions);
    destructor Destroy; override;
    procedure Pump;
    procedure Open;
    procedure TransferPlaintext(const ASource, ADestination: ITLSSession);
    property Client: ITLSSession read FClient;
    property Server: ITLSSession read FServer;
  end;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then
    raise Exception.Create('TLS session contract: ' + AMessage);
end;

constructor TSessionPair.Create(const AContext: ITLSContext;
  AClientOptions: TTlsClientSessionOptions;
  AServerOptions: TTlsServerSessionOptions);
begin
  inherited Create;
  FStarted := GetTickCount64;
  AClientOptions.HandshakeStartMs := FStarted;
  AServerOptions.HandshakeStartMs := FStarted;
  AClientOptions.HandshakeDeadlineMs := FStarted + 10000;
  AServerOptions.HandshakeDeadlineMs := FStarted + 10000;
  FClient := AContext.CreateClientSession(AClientOptions);
  FServer := AContext.CreateServerSession(AServerOptions);
  Check(Pointer(FClient) <> Pointer(FServer), 'roles share a session object');
end;

destructor TSessionPair.Destroy;
begin
  if FClient <> nil then FClient.Abort;
  if FServer <> nil then FServer.Abort;
  FClient := nil;
  FServer := nil;
  inherited Destroy;
end;

procedure TSessionPair.Transfer(const ASource, ADestination: ITLSSession;
  var APending: TBytes; var AOffset: SizeInt);
var N, Capacity: SizeInt;
begin
  if AOffset = Length(APending) then
  begin
    { Small drains and input fragments exercise independent byte counts. }
    Capacity := 31;
    if FStep mod 4 = 0 then Capacity := 1;
    SetLength(APending, Capacity);
    N := ASource.DrainEncrypted(APending, 0, Capacity);
    Check((N >= 0) and (N <= Capacity), 'invalid encrypted drain count');
    SetLength(APending, N);
    AOffset := 0;
  end;
  if AOffset < Length(APending) then
  begin
    Capacity := Length(APending) - AOffset;
    if FStep mod 3 = 0 then Capacity := 1;
    N := ADestination.FeedEncrypted(APending, AOffset, Capacity);
    Check((N >= 0) and (N <= Capacity), 'invalid encrypted input count');
    Inc(AOffset, N);
  end;
end;

procedure TSessionPair.Pump;
begin
  Inc(FStep);
  Check(FStep < 200000, 'session pump did not stop');
  Check(GetTickCount64 - FStarted < 10000, 'session pair exceeded ten seconds');
  FClient.Advance(GetTickCount64);
  FServer.Advance(GetTickCount64);
  Transfer(FClient, FServer, FToServer, FServerOffset);
  Transfer(FServer, FClient, FToClient, FClientOffset);
end;

procedure TSessionPair.Open;
var I: Integer;
begin
  while (FClient.State <> tssOpen) or (FServer.State <> tssOpen) do
  begin
    Check(not (FClient.State in [tssFailed, tssClosed]), 'client handshake failed');
    Check(not (FServer.State in [tssFailed, tssClosed]), 'server handshake failed');
    Pump;
  end;
  { Pending handshake output can remain after one peer reports open. }
  for I := 1 to 128 do Pump;
end;

procedure TSessionPair.TransferPlaintext(const ASource, ADestination: ITLSSession);
const PayloadSize = 196613;
var Payload, Buffer: TBytes; Accepted, Received, N, I, FirstCredit: SizeInt;
begin
  SetLength(Payload, PayloadSize);
  SetLength(Buffer, 997);
  for I := 0 to High(Payload) do Payload[I] := Byte((I * 17 + 29) mod 251);
  Accepted := 0;
  Received := 0;
  repeat
    N := ASource.WritePlaintext(Payload, Accepted, Length(Payload) - Accepted);
    Check((N >= 0) and (N <= Length(Payload) - Accepted), 'invalid plaintext credit');
    Inc(Accepted, N);
    Check(Accepted <= TlsMaxEncryptedOutput + TlsMaxPlaintextBuffer,
      'plaintext writes do not apply bounded backpressure');
  until N = 0;
  FirstCredit := Accepted;
  Check(FirstCredit > 0, 'open session cannot accept plaintext');
  Check(ASource.Advance(GetTickCount64).NeedOutput,
    'blocked plaintext does not report pending ciphertext');
  while Received < Length(Payload) do
  begin
    if Accepted < Length(Payload) then
    begin
      N := ASource.WritePlaintext(Payload, Accepted, Length(Payload) - Accepted);
      Check((N >= 0) and (N <= Length(Payload) - Accepted), 'invalid later plaintext credit');
      Inc(Accepted, N);
    end;
    Pump;
    repeat
      N := ADestination.ReadPlaintext(Buffer, 0, Length(Buffer));
      Check((N >= 0) and (N <= Length(Buffer)), 'invalid plaintext read count');
      Check(Received + N <= Accepted, 'plaintext arrived without write credit');
      for I := 0 to N - 1 do
        Check(Buffer[I] = Payload[Received + I], 'plaintext changed or repeated');
      Inc(Received, N);
    until N = 0;
  end;
  Check(Accepted = Length(Payload), 'plaintext credit was lost');
  for I := 1 to 32 do Pump;
  Check(ADestination.ReadPlaintext(Buffer, 0, Length(Buffer)) = 0,
    'plaintext was delivered twice');
end;

procedure CheckRanges(const ASession: ITLSSession);
var Buffer: TBytes; Before: TTlsSessionState; Failed: Boolean; N: SizeInt;
begin
  SetLength(Buffer, 8);
  Before := ASession.State;
  Failed := False;
  try N := ASession.FeedEncrypted(Buffer, 7, 2);
  except on E: ETlsSessionError do Failed := True; end;
  Check(Failed and (ASession.State = Before), 'invalid input changed the session');
  Failed := False;
  try N := ASession.DrainEncrypted(Buffer, -1, 1);
  except on E: ETlsSessionError do Failed := True; end;
  Check(Failed and (ASession.State = Before), 'invalid drain changed the session');
  Failed := False;
  try N := ASession.WritePlaintext(Buffer, 0, High(SizeInt));
  except on E: ETlsSessionError do Failed := True; end;
  Check(Failed and (ASession.State = Before), 'invalid write changed the session');
  Failed := False;
  try N := ASession.ReadPlaintext(Buffer, 9, 0);
  except on E: ETlsSessionError do Failed := True; end;
  Check(Failed and (ASession.State = Before), 'invalid read changed the session');
  Check(ASession.FeedEncrypted(Buffer, 8, 0) = 0, 'zero encrypted input failed');
  Check(ASession.DrainEncrypted(Buffer, 8, 0) = 0, 'zero encrypted drain failed');
  Check(ASession.WritePlaintext(Buffer, 8, 0) = 0, 'zero plaintext write failed');
  Check(ASession.ReadPlaintext(Buffer, 8, 0) = 0, 'zero plaintext read failed');
end;

function RunTlsSessionContract(const AContext: ITLSContext;
  const AClientOptions: TTlsClientSessionOptions;
  const AServerOptions: TTlsServerSessionOptions): Integer;
var Pair: TSessionPair; Info: TTlsNegotiatedInfo; Buffer: TBytes;
  Failed: Boolean; N: SizeInt; I: Integer; Progress: TTlsProgress;
  procedure Pass(const AName: string);
  begin
    Inc(Result);
    WriteLn('PASS session contract ', AName);
  end;
begin
  Result := 0;
  Pair := TSessionPair.Create(AContext, AClientOptions, AServerOptions);
  try
    CheckRanges(Pair.Client);
    CheckRanges(Pair.Server);
    Pass('range validation and zero length');
    Pair.Open;
    Check(Pair.Client.NegotiatedInfo.Role = trClient, 'client role metadata is wrong');
    Check(Pair.Server.NegotiatedInfo.Role = trServer, 'server role metadata is wrong');
    Check(not Pair.Client.NegotiatedInfo.Resumed, 'client session resumed');
    Check(not Pair.Server.NegotiatedInfo.Resumed, 'server session resumed');
    Check(Pair.Client.NegotiatedInfo.Version = Pair.Server.NegotiatedInfo.Version,
      'negotiated versions differ');
    Check(Pair.Client.NegotiatedInfo.SelectedAlpn = Pair.Server.NegotiatedInfo.SelectedAlpn,
      'negotiated ALPN differs');
    Pass('fragmented handshake and distinct roles');
    Pair.TransferPlaintext(Pair.Client, Pair.Server);
    Pass('client write credit and backpressure');
    Pair.TransferPlaintext(Pair.Server, Pair.Client);
    Pass('server write credit and backpressure');
    for I := 1 to 128 do Pair.Pump;
    Progress := Pair.Client.Advance(GetTickCount64);
    Check(not Progress.MadeProgress, 'idle client reports progress');
    Progress := Pair.Server.Advance(GetTickCount64);
    Check(not Progress.MadeProgress, 'idle server reports progress');
    Pass('idle progress stops');
    Info := Pair.Client.NegotiatedInfo;
    Check(Info.PeerCertificate <> nil, 'server certificate metadata is absent');
    Check(Info.PeerCertificate.Verified, 'trusted server certificate is not verified');
    Check(Info.PeerCertificate.Leaf.Subject <> '', 'server certificate subject is empty');
    Pair.Client.BeginShutdown;
    Pair.Server.BeginShutdown;
    while (Pair.Client.State <> tssClosed) or (Pair.Server.State <> tssClosed) do Pair.Pump;
    Pair.Client.NotifyTransportEof;
    Pair.Server.NotifyTransportEof;
    Check((Pair.Client.State = tssClosed) and (Pair.Server.State = tssClosed),
      'authenticated close was treated as truncation');
    Pass('orderly close and transport EOF');
  finally
    Pair.Free;
  end;
  Check(Info.PeerCertificate.Leaf.Subject <> '', 'copied peer was invalid after teardown');
  Pass('peer snapshot survives session teardown');

  Pair := TSessionPair.Create(AContext, AClientOptions, AServerOptions);
  try
    Pair.Open;
    SetLength(Buffer, 5);
    for I := 0 to 4 do Buffer[I] := I + 31;
    Check(Pair.Server.WritePlaintext(Buffer, 0, 5) = 5,
      'small plaintext write was not accepted');
    for I := 1 to 256 do Pair.Pump;
    try Pair.Client.NotifyTransportEof;
    except on E: ETlsSessionError do
      Check(E.Category = tecTransportEof, 'EOF raised the wrong category'); end;
    Check(Pair.Client.State = tssFailed, 'abrupt EOF did not fail');
    Check(Pair.Client.ReadPlaintext(Buffer, 0, 5) = 5,
      'EOF discarded authenticated plaintext');
    for I := 0 to 4 do
      Check(Buffer[I] = I + 31, 'EOF changed authenticated plaintext');
    Pass('authenticated plaintext precedes EOF failure');
    SetLength(Buffer, 1);
    for I := 1 to 2 do
    begin
      Failed := False;
      try N := Pair.Client.ReadPlaintext(Buffer, 0, 1);
      except on E: ETlsSessionError do Failed := E.Category = tecTransportEof; end;
      Check(Failed, 'truncation error was not stable on repeated reads');
    end;
    Pass('abrupt EOF and repeated failure reads');
    Pair.Client.Abort;
    Pair.Client.Abort;
    Check(Pair.Client.State = tssClosed, 'abort is not terminal');
    Check(Pair.Client.DrainEncrypted(Buffer, 0, 1) = 0, 'abort retained ciphertext');
    Pass('abort clears output and is repeatable');
  finally
    Pair.Free;
  end;
end;

end.
