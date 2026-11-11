{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, contract, test
notes:
  - This program runs bounded provider-neutral TLS contract checks.
---
}
program Http2.Common.Tls.Contract.Run;
{$mode delphi}{$H+}{$interfaces com}
uses SysUtils, Http2.Common, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Context, Http2.Test.Tls.Fake;
var
  CaseCount: Integer;
  Context: ITLSContext;
  DirectContext: Http2.Common.Tls.Context.ITLSContext;
  ClientOptions: TTlsClientSessionOptions;
  ServerOptions: TTlsServerSessionOptions;
  ClientSession, ServerSession: ITLSSession;
  Policy: TTlsClientPolicy;
  ServerPolicy: TTlsServerPolicy;
  Anchors, Alpns: TArray<string>;
  Buffer: TBytes;
  N: SizeInt;
  Progress: TTlsProgress;
  Failed: Boolean;
  TimeoutSession, AlertSession, EofSession: ITLSSession;
  ShutdownSession: ITLSSession;
  TimeoutOptions: TTlsClientSessionOptions;
  Peer: ITLSPeerCertificate;
  Leaf: TTlsCertificateSummary;
  Chain: TArray<TTlsCertificateSummary>;
  Lifetime: ITlsFakeLifetime;
  Control: ITlsFakeContextControl;
  Payload, Captured: TBytes;
  RoundtripSession: ITLSSession;
  I, Total: Integer;
  FakeInfo: ITlsFakeSessionInfo;
  Capabilities: TTlsCapabilities;

procedure Check(const ACondition: Boolean; const AMessage: string);
begin
  if not ACondition then raise Exception.Create(AMessage);
end;

procedure Pass(const AName: string);
begin
  Inc(CaseCount);
  WriteLn('PASS ', AName);
end;

begin
  CaseCount := 0;
  try
    Check(TTlsClientPolicy.SecureDefault.VerifyPeer, 'secure default trust');
    Check(TTlsClientPolicy.SecureDefault.VerifyHostname, 'secure default hostname');
    Check(TTlsClientPolicy.SecureDefault.MinVersion = tls12, 'minimum version');
    Check(TTlsClientPolicy.SecureDefault.MaxVersion = tls13, 'maximum version');
    Pass('secure defaults and protocol bounds');

    Policy := TTlsClientPolicy.SecureDefault.WithVerificationDepth(0);
    ServerPolicy := TTlsServerPolicy.SecureDefault.WithVerificationDepth(0);
    Check(Policy.HasVerificationDepth and (Policy.VerificationDepth = 0),
      'explicit client depth zero was lost');
    Check(ServerPolicy.HasVerificationDepth and (ServerPolicy.VerificationDepth = 0),
      'explicit server depth zero was lost');
    Failed := False;
    try Policy := Policy.WithVerificationDepth(-1);
    except on E: ETlsContextError do Failed := E.Category = tecConfiguration; end;
    Check(Failed, 'negative client depth was accepted');
    Failed := False;
    try ServerPolicy := ServerPolicy.WithVerificationDepth(-1);
    except on E: ETlsContextError do Failed := E.Category = tecConfiguration; end;
    Check(Failed, 'negative server depth was accepted');
    Pass('explicit verification depth and invalid depth');

    SetLength(Anchors, 1); Anchors[0] := 'root-a.pem';
    Policy := TTlsClientPolicy.SecureDefault.WithTrustAnchors(Anchors);
    Anchors[0] := 'mutated.pem';
    Anchors := Policy.TrustAnchors;
    Check(Anchors[0] = 'root-a.pem', 'policy retained caller array');
    Anchors[0] := 'changed-return.pem';
    Check(Policy.TrustAnchors[0] = 'root-a.pem', 'policy getter exposed backing array');
    Pass('policy array isolation');

    ClientOptions := Default(TTlsClientSessionOptions);
    ClientOptions.IdentitySelection := tisExplicit;
    ClientOptions.Identity := nil;
    ClientOptions := ClientOptions.WithAlpns(['h2', 'http/1.1']);
    Alpns := ClientOptions.AlpnValues;
    Check((Length(Alpns) = 2) and (Alpns[0] = 'h2'), 'ALPN values missing');
    Alpns[0] := 'mutated';
    Check(ClientOptions.AlpnValues[0] = 'h2', 'ALPN getter exposed backing array');
    Check((ClientOptions.IdentitySelection = tisExplicit) and (ClientOptions.Identity = nil),
      'explicit nil identity was not retained');
    Pass('ALPN copies and explicit nil identity');

    Leaf := Default(TTlsCertificateSummary);
    Leaf.Subject := 'CN=localhost'; Leaf.CommonName := 'localhost';
    Leaf.Serial := '01'; Leaf.FingerprintSha256 := 'aa'; Leaf.Pem := 'leaf pem';
    Peer := NewTlsPeerCertificate(True, Leaf, [], ['localhost'], ['127.0.0.1'],
      ['spiffe://example.test/client'], ['client@example.test']);
    Alpns := Peer.DnsNames;
    Alpns[0] := 'changed';
    Check(Peer.DnsNames[0] = 'localhost', 'peer SAN getter exposed backing array');
    Check(Peer.Verified and (Peer.Leaf.Serial = '01') and
      (Peer.Leaf.CommonName = 'localhost') and (Peer.Leaf.Pem = 'leaf pem'),
      'peer metadata missing');
    SetLength(Chain, 1); Chain[0] := Leaf;
    Peer := NewTlsPeerCertificate(True, Leaf, Chain, ['localhost'],
      ['127.0.0.1'], ['spiffe://example.test/client'], ['client@example.test']);
    Chain[0].Serial := 'mutated';
    Check(Peer.Chain[0].Serial = '01', 'peer chain getter exposed backing data');
    Alpns := Peer.IpAddresses; Alpns[0] := 'changed';
    Check(Peer.IpAddresses[0] = '127.0.0.1', 'peer IP getter exposed backing array');
    Pass('immutable peer metadata snapshots');

    Context := TTlsFakeContext.Create([trClient, trServer], tlsAuthRequire, 8000);
    DirectContext := Context;
    Check(DirectContext = Context, 'facade declared a second context interface');
    DirectContext := nil;
    Check(Supports(Context, ITlsFakeContextControl, Control), 'fake context control missing');
    Lifetime := Control.Lifetime;
    Check(Context.Info.RequiresClientCertificate, 'required client auth summary');
    Check(Context.Info.Roles = [trClient, trServer], 'context roles summary');
    Capabilities := Context.Capabilities;
    Check((not Capabilities.SessionResumption) and (not Capabilities.EarlyData),
      'fake enabled disabled session features');
    ClientSession := Context.CreateClientSession(ClientOptions);
    ServerOptions := Default(TTlsServerSessionOptions).WithAlpns(['h2']);
    ServerSession := Context.CreateServerSession(ServerOptions);
    Check(ClientSession <> ServerSession, 'context reused one session');
    Check(Supports(ServerSession, ITlsFakeSessionInfo, FakeInfo), 'server fake options missing');
    Alpns := FakeInfo.ServerOptions.AlpnValues;
    Check(FakeInfo.IsServer and (Length(Alpns) = 1) and (Alpns[0] = 'h2'),
      'server options changed at session creation');
    Check(Supports(ClientSession, ITlsFakeSessionInfo, FakeInfo), 'fake session details missing');
    Check((not FakeInfo.IsServer) and
      (FakeInfo.ClientOptions.IdentitySelection = tisExplicit) and
      (FakeInfo.ClientOptions.Identity = nil), 'client options changed at session creation');
    Check(ClientSession.State = tssNew, 'new session state');
    Failed := False;
    try ClientSession.NegotiatedInfo;
    except on ETlsSessionError do Failed := True; end;
    Check(Failed, 'negotiated info available before handshake');
    Progress := ClientSession.Advance(1);
    Check(ClientSession.NegotiatedInfo.Role = trClient, 'negotiated info role');
    Pass('dual role distinct sessions and handshake metadata');

    ClientSession := nil;
    ServerSession := nil;
    ClientSession := Context.CreateClientSession(ClientOptions);
    Control := nil;
    Context := nil;
    Check(Lifetime.IsAlive, 'context released while a session retained it');
    Progress := ClientSession.Advance(1);
    Check((Progress.State = tssOpen) and Progress.MadeProgress, 'session lost context lifetime');
    Pass('session retains context lifetime');
    Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 100);

    SetLength(Buffer, TlsMaxEncryptedInput + 4);
    N := ClientSession.FeedEncrypted(Buffer, 0, Length(Buffer));
    Check(N = TlsMaxEncryptedInput, 'input bound not enforced');
    Progress := ClientSession.Advance(2);
    Check(Progress.State = tssOpen, 'session left open after input');
    SetLength(Buffer, 8);
    N := ClientSession.DrainEncrypted(Buffer, 2, 3);
    Check(N = 3, 'partial ciphertext drain failed');
    Check(Length(Buffer) = 8, 'drain resized caller buffer');
    Pass('bounded feed and partial output drain');

    SetLength(Buffer, 5); Buffer[0] := 1; Buffer[1] := 2; Buffer[2] := 3;
    N := ClientSession.WritePlaintext(Buffer, 0, 3);
    Check(N = 3, 'plaintext acceptance count');
    SetLength(Buffer, 8);
    N := ClientSession.DrainEncrypted(Buffer, 0, 2);
    Check(N = 2, 'partial record drain count');
    Pass('accepted plaintext and partial record output');

    RoundtripSession := Context.CreateClientSession(ClientOptions);
    RoundtripSession.Advance(2);
    SetLength(Buffer, 4);
    N := RoundtripSession.DrainEncrypted(Buffer, 0, Length(Buffer));
    Check(N = 4, 'handshake output count');
    Check(RoundtripSession.FeedEncrypted(Buffer, 0, 0) = 0,
      'zero-byte encrypted input was not accepted');
    Failed := False;
    try RoundtripSession.FeedEncrypted(Buffer, -1, 1);
    except on ETlsSessionError do Failed := True; end;
    Check(Failed and (RoundtripSession.State = tssOpen),
      'invalid range changed the session state');
    Pass('zero-length input and invalid range handling');
    SetLength(Payload, TlsMaxEncryptedOutput + 10);
    for I := 0 to High(Payload) do Payload[I] := Byte(I mod 251);
    N := RoundtripSession.WritePlaintext(Payload, 0, Length(Payload));
    Check(N = TlsMaxEncryptedOutput - 2, 'write backpressure prefix count');
    Check(RoundtripSession.WritePlaintext(Payload, N, Length(Payload) - N) = 0,
      'full output queue accepted extra plaintext');
    SetLength(Captured, N); Total := 0;
    while Total < N do begin
      Buffer := nil; SetLength(Buffer, 4096);
      I := RoundtripSession.DrainEncrypted(Buffer, 0, Length(Buffer));
      Check(I > 0, 'output drain stalled before pending bytes were empty');
      Move(Buffer[0], Captured[Total], I); Inc(Total, I);
    end;
    for I := 0 to N - 1 do
      Check(Captured[I] = Payload[I], 'accepted plaintext was lost or repeated');
    Pass('plaintext credit and ciphertext drain under backpressure');

    RoundtripSession := nil;
    EofSession := Context.CreateClientSession(ClientOptions);
    EofSession.Advance(3);
    SetLength(Buffer, 3); Buffer[0] := 8; Buffer[1] := 9; Buffer[2] := 10;
    Check(EofSession.FeedEncrypted(Buffer, 0, 3) = 3, 'EOF test input accept count');
    EofSession.Advance(4);
    EofSession.NotifyTransportEof;
    SetLength(Buffer, 4);
    Check(EofSession.ReadPlaintext(Buffer, 0, 4) = 3, 'EOF discarded buffered plaintext');
    Check((Buffer[0] = 8) and (Buffer[2] = 10), 'EOF changed buffered plaintext');
    Failed := False;
    try EofSession.ReadPlaintext(Buffer, 0, 4);
    except on E: ETlsSessionError do Failed := E.Category = tecTransportEof; end;
    Check(Failed, 'EOF did not report truncation after buffered plaintext');
    Pass('buffered plaintext before abrupt EOF error');

    EofSession := Context.CreateClientSession(ClientOptions);
    EofSession.Advance(5);
    SetLength(Buffer, 4); Buffer[0] := 11; Buffer[1] := 12;
    Buffer[2] := 13; Buffer[3] := $FE;
    EofSession.FeedEncrypted(Buffer, 0, 4);
    Progress := EofSession.Advance(6);
    Check(Progress.State = tssClosed, 'authenticated close-notify not recognized');
    Check(EofSession.ReadPlaintext(Buffer, 0, 4) = 3,
      'authenticated close discarded buffered data');
    Check((Buffer[0] = 11) and (Buffer[2] = 13), 'close changed buffered data');
    Check(EofSession.ReadPlaintext(Buffer, 0, 1) = 0,
      'authenticated close returned extra data');
    Pass('authenticated close differs from truncated EOF');

    ShutdownSession := Context.CreateClientSession(ClientOptions);
    ShutdownSession.Advance(7);
    SetLength(Buffer, 4);
    ShutdownSession.DrainEncrypted(Buffer, 0, 4);
    ShutdownSession.BeginShutdown;
    SetLength(Buffer, 1); Buffer[0] := $FE;
    Check(ShutdownSession.FeedEncrypted(Buffer, 0, 1) = 1,
      'closing session rejected peer close data');
    Progress := ShutdownSession.Advance(8);
    Check(Progress.State = tssClosed, 'shutdown did not finish after peer close');
    SetLength(Buffer, 2);
    Check(ShutdownSession.DrainEncrypted(Buffer, 0, 2) = 2,
      'local close-notify output was lost');
    Pass('duplex close and output while shutting down');

    ClientSession.Abort;
    Check(ClientSession.State = tssFailed, 'abort not terminal');
    Failed := False;
    try ClientSession.NegotiatedInfo;
    except on ETlsSessionError do Failed := True; end;
    Check(Failed, 'failed session exposed negotiated metadata');
    Pass('abort terminal state and metadata guard');

    Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 100);
    TimeoutOptions := ClientOptions;
    TimeoutOptions.HandshakeDeadlineMs := 10;
    TimeoutSession := Context.CreateClientSession(TimeoutOptions);
    Failed := False;
    try TimeoutSession.Advance(10);
    except on E: ETlsSessionError do Failed := E.Category = tecTimeout; end;
    Check(Failed and (TimeoutSession.State = tssFailed), 'deadline did not fail session');
    SetLength(Buffer, 4);
    Check(TimeoutSession.DrainEncrypted(Buffer, 0, 4) = 2, 'timeout alert was not drainable');
    Pass('absolute deadline and failed alert drain');

    AlertSession := Context.CreateClientSession(ClientOptions);
    SetLength(Buffer, 1); Buffer[0] := $FF;
    AlertSession.FeedEncrypted(Buffer, 0, 1);
    Failed := False;
    try AlertSession.Advance(1);
    except on E: ETlsSessionError do Failed := E.Category = tecAlert; end;
    Check(Failed and (AlertSession.State = tssFailed), 'fatal alert state');
    SetLength(Buffer, 4);
    Check(AlertSession.DrainEncrypted(Buffer, 0, 4) = 4,
      'fatal alert prefix drain count');
    SetLength(Buffer, 2);
    Check(AlertSession.DrainEncrypted(Buffer, 0, 2) = 2,
      'fatal alert output was lost');
    Check((Buffer[0] = $15) and (Buffer[1] = $02),
      'fatal alert output changed');
    Pass('fatal alert remains drainable after failure');

    EofSession := Context.CreateClientSession(ClientOptions);
    EofSession.Advance(1);
    EofSession.NotifyTransportEof;
    Check(EofSession.State = tssFailed, 'abrupt EOF was reported as clean close');
    Pass('abrupt EOF is terminal failure');

    ClientOptions.HandshakeStartMs := 100;
    ClientOptions.HandshakeDeadlineMs := 1000;
    TimeoutSession := Context.CreateClientSession(ClientOptions);
    Failed := False;
    try TimeoutSession.Advance(200);
    except on E: ETlsSessionError do Failed := E.Category = tecTimeout; end;
    Check(Failed, 'context deadline did not beat later role deadline');
    Pass('context timeout bounds the role deadline');

    Context := TTlsFakeContext.Create([trClient], tlsAuthNone, 100, True);
    TimeoutOptions := Default(TTlsClientSessionOptions);
    TimeoutOptions.HandshakeStartMs := 0;
    TimeoutOptions.HandshakeDeadlineMs := 1000;
    TimeoutSession := Context.CreateClientSession(TimeoutOptions);
    Progress := TimeoutSession.Advance(50);
    Check((Progress.State = tssHandshaking) and Progress.NeedInput,
      'held handshake did not wait for input');
    Failed := False;
    try TimeoutSession.Advance(100);
    except on E: ETlsSessionError do Failed := E.Category = tecTimeout; end;
    Check(Failed, 'input wait reset context deadline');
    Pass('held handshake deadline does not reset');

    TimeoutSession := Context.CreateClientSession(TimeoutOptions);
    TimeoutSession.Advance(1);
    SetLength(Buffer, 1); Buffer[0] := $FC;
    Check(TimeoutSession.FeedEncrypted(Buffer, 0, 1) = 1,
      'held handshake did not accept input');
    Progress := TimeoutSession.Advance(2);
    Check(Progress.State = tssOpen, 'held handshake did not open on scripted input');
    Check(TimeoutSession.ReadPlaintext(Buffer, 0, 1) = 0,
      'handshake script leaked into application plaintext');
    Pass('fake held handshake accepts scripted readiness');

    Failed := False;
    try Context.CreateServerSession(ServerOptions);
    except on ETlsContextError do Failed := True; end;
    Check(Failed, 'unavailable role created a session');
    Pass('role availability fails before transport use');

    ClientSession := nil; ServerSession := nil; TimeoutSession := nil;
    AlertSession := nil; EofSession := nil; Context := nil; Control := nil;
    FakeInfo := nil;
    Check(not Lifetime.IsAlive, 'context stayed alive after final session release');

    WriteLn('PASS ', CaseCount, ' cases');
  except
    on E: Exception do begin
      WriteLn('FAIL after ', CaseCount, ' cases: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
