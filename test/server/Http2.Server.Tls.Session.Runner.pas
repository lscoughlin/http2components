{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, server, test, runner
notes:
  - This runner contains bounded tests for the provider-neutral server binding.
---
}
program Http2.Server.Tls.Session.Runner;
{$mode delphi}{$H+}
uses {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, fpcunit, testregistry,
  consoletestrunner, Http2.Common.Tls.Types, Http2.Common.Tls.Policy,
  Http2.Common.Tls.Session, Http2.Common.Tls.Context,
  Http2.Server.Tls.Binding, Http2.Server.Tls.Adapter,
  Http2.Server.Config,
  Http2.Test.Tls.Fake;
type
  TTlsServerBindingTest = class(TTestCase)
  published
    procedure ContextRoleAndLifetime;
    procedure ClientOnlyContextIsRejected;
    procedure SessionOptionsHaveAbsoluteStartAndHttpAlpns;
    procedure PlaintextCreditWaitsForEveryCipherChunk;
    procedure ZeroTimeoutHasNoDeadline;
    procedure StopAbortsHeldHandshake;
    procedure CiphertextRetriesKeepExactBytes;
    procedure RequiredClientAuthStaysBoundToContext;
    procedure FatalSessionErrorDoesNotHidePendingCiphertext;
    procedure RequiredClientAuthRejectsCleartext;
    procedure LocalShutdownDrainsCloseNotify;
    procedure PeerCloseKeepsFinalPlaintextAndReply;
    procedure AbruptEofFailsTheSession;
  end;
function ContextLifetime(const AAuth: TTlsClientAuthMode): ITlsFakeLifetime;
var C: ITLSContext; B: ITlsServerBinding; Control: ITlsFakeContextControl;
begin
  C := TTlsFakeContext.Create([trServer], AAuth, 2500);
  if not Supports(C, ITlsFakeContextControl, Control) then
    raise Exception.Create('the context exposes its lifetime control');
  Result := Control.Lifetime;
  Control := nil;
  B := NewTlsServerBinding(C);
  C := nil;
  if not Result.IsAlive then
    raise Exception.Create('the binding retains its context');
  B := nil;
end;
procedure TTlsServerBindingTest.ContextRoleAndLifetime;
var Life: ITlsFakeLifetime;
begin
  Life := ContextLifetime(tlsAuthNone);
  AssertFalse('the context is released with the binding', Life.IsAlive);
end;
procedure TTlsServerBindingTest.ClientOnlyContextIsRejected;
var C: ITLSContext; B: ITlsServerBinding; Rejected: Boolean;
begin
  C := TTlsFakeContext.Create([trClient], tlsAuthNone, 2500);
  Rejected := False;
  try
    B := NewTlsServerBinding(C);
  except
    on ETlsContextError do Rejected := True;
  end;
  AssertTrue('a client-only context cannot bind to the server', Rejected);
end;
procedure TTlsServerBindingTest.SessionOptionsHaveAbsoluteStartAndHttpAlpns;
var C: ITLSContext; B: ITlsServerBinding; S: ITLSSession;
    I: ITlsFakeSessionInfo; O: TTlsServerSessionOptions; A: TArray<string>;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  S := B.CreateSession(1200, True);
  I := S as ITlsFakeSessionInfo;
  O := I.ServerOptions;
  A := O.AlpnValues;
  AssertTrue('the session is a server session', I.IsServer);
  AssertEquals('the absolute handshake start is retained', 1200,
    O.HandshakeStartMs);
  AssertEquals('h2 is offered first', 'h2', A[0]);
  AssertEquals('HTTP/1.1 fallback is offered second', 'http/1.1', A[1]);
  S := B.CreateSession(2200, False);
  O := (S as ITlsFakeSessionInfo).ServerOptions;
  A := O.AlpnValues;
  AssertEquals('strict policy offers one protocol', 1, Length(A));
  AssertEquals('strict policy offers h2', 'h2', A[0]);
end;
procedure TTlsServerBindingTest.ZeroTimeoutHasNoDeadline;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 0);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 500, False);
  try
    AssertEquals('zero disables the handshake deadline', 0, A.DeadlineMs);
  finally
    A.Free;
  end;
end;
procedure TTlsServerBindingTest.PlaintextCreditWaitsForEveryCipherChunk;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    Input, Plain, Cipher: TBytes; Progress: TTlsProgress; I: Integer;
    Completed: Int64;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    Input := [$01];
    AssertEquals('handshake input is accepted', 1,
      A.FeedEncrypted(Input, 0, Length(Input)));
    Progress := A.Advance(101);
    AssertEquals('the handshake opens', Ord(tssOpen), Ord(Progress.State));
    while A.PrepareCipher(Cipher) do A.CompleteCipher(True);
    SetLength(Plain, 32768);
    for I := 0 to High(Plain) do Plain[I] := Byte(I);
    AssertEquals('the application batch is accepted', Length(Plain),
      A.WritePlaintext(Plain, 0, Length(Plain)));
    AssertFalse('credit waits before ciphertext leaves', A.CreditReady);
    AssertTrue('the provider emits the first bounded chunk', A.PrepareCipher(Cipher));
    AssertEquals('the output chunk is bounded', 16384, Length(Cipher));
    A.CompleteCipher(True);
    AssertFalse('credit stays closed after the first raw chunk', A.CreditReady);
    AssertTrue('the provider emits the next bounded chunk', A.PrepareCipher(Cipher));
    A.CompleteCipher(True);
    AssertFalse('credit stays closed until provider output is empty', A.CreditReady);
    AssertFalse('no third ciphertext chunk remains', A.PrepareCipher(Cipher));
    AssertTrue('credit opens after every ciphertext chunk drains', A.CreditReady);
    AssertEquals('plaintext credit keeps the plaintext byte count',
      Length(Plain), A.PlainAccepted);
    AssertTrue('a stable completed plaintext boundary is available',
      A.TryGetCompletedPlaintext(Completed));
    AssertEquals('the completed boundary includes the first batch',
      Length(Plain), Completed);
    SetLength(Input, 4);
    AssertEquals('a later batch can be accepted before reporting', 4,
      A.WritePlaintext(Input, 0, Length(Input)));
    AssertTrue('the prior completed boundary remains available',
      A.TryGetCompletedPlaintext(Completed));
    AssertEquals('a later write cannot move the earlier boundary',
      Length(Plain), Completed);
  finally
    A.Free;
  end;
end;

procedure TTlsServerBindingTest.StopAbortsHeldHandshake;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    P: TTlsProgress;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500, True);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    P := A.Advance(101);
    AssertEquals('the session waits for more handshake input',
      Ord(tssHandshaking), Ord(P.State));
    A.Abort;
    AssertEquals('stop cancels the held session', Ord(tssFailed), Ord(A.State));
  finally
    A.Free;
  end;
end;
procedure TTlsServerBindingTest.CiphertextRetriesKeepExactBytes;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    Input, First, Retry: TBytes;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    Input := [$01];
    A.FeedEncrypted(Input, 0, Length(Input));
    A.Advance(101);
    AssertTrue('handshake ciphertext is ready', A.PrepareCipher(First));
    A.CompleteCipher(False);
    AssertTrue('unsent ciphertext remains available', A.PrepareCipher(Retry));
    AssertEquals('retry has the same byte count', Length(First), Length(Retry));
    AssertTrue('retry keeps every ciphertext byte', CompareMem(@First[0],
      @Retry[0], Length(First)));
  finally
    A.Free;
  end;
end;
procedure TTlsServerBindingTest.RequiredClientAuthStaysBoundToContext;
var Life: ITlsFakeLifetime;
begin
  Life := ContextLifetime(tlsAuthRequire);
  AssertFalse('required client authentication context is released', Life.IsAlive);
end;

procedure TTlsServerBindingTest.FatalSessionErrorDoesNotHidePendingCiphertext;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    Input, Cipher: TBytes; Failed: Boolean;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    Input := [$01, $FF];
    A.FeedEncrypted(Input, 0, Length(Input));
    Failed := False;
    try
      A.Advance(101);
    except
      on ETlsSessionError do Failed := True;
    end;
    AssertTrue('the fake session reports a fatal error', Failed);
    AssertEquals('the session enters failed state', Ord(tssFailed), Ord(A.State));
    AssertTrue('already queued ciphertext remains drainable',
      A.PrepareCipher(Cipher));
    AssertEquals('queued handshake output and fatal alert are retained',
      6, Length(Cipher));
  finally
    A.Free;
  end;
end;

procedure TTlsServerBindingTest.RequiredClientAuthRejectsCleartext;
var C: ITLSContext; Factory: THttp2ServerFactory;
    Problems: TArray<string>; I: Integer; Found: Boolean;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthRequire, 2500);
  Factory := THttp2ServerFactory.Create.WithTlsContext(C)
    .WithClearTextAllowed(True);
  Factory.Validate(Problems);
  Found := False;
  for I := 0 to High(Problems) do
    if Problems[I] = 'the required client certificate mode needs cleartext off' then
      Found := True;
  AssertTrue('required client authentication refuses cleartext policy', Found);
end;

procedure TTlsServerBindingTest.LocalShutdownDrainsCloseNotify;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    Input, Cipher: TBytes; P: TTlsProgress; N: Integer;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    Input := [$01];
    A.FeedEncrypted(Input, 0, Length(Input));
    P := A.Advance(101);
    AssertEquals('the session opens before local shutdown', Ord(tssOpen), Ord(P.State));
    while A.PrepareCipher(Cipher) do A.CompleteCipher(True);
    A.BeginShutdown;
    N := 0;
    while A.PrepareCipher(Cipher) do
    begin
      Inc(N, Length(Cipher));
      A.CompleteCipher(True);
    end;
    AssertEquals('the local close-notify is emitted', 2, N);
    AssertEquals('the session closes after the alert drains', Ord(tssClosed),
      Ord(A.State));
  finally
    A.Free;
  end;
end;

procedure TTlsServerBindingTest.PeerCloseKeepsFinalPlaintextAndReply;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    Input, Plain, Cipher: TBytes; P: TTlsProgress; N, Total: Integer;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    Input := [$01];
    A.FeedEncrypted(Input, 0, Length(Input));
    A.Advance(101);
    SetLength(Plain, 8);
    AssertEquals('the fake handshake byte is consumed', 1,
      A.ReadPlaintext(Plain, 0, Length(Plain)));
    while A.PrepareCipher(Cipher) do A.CompleteCipher(True);
    Input := [$41, $FE];
    AssertEquals('the peer close record is accepted', 2,
      A.FeedEncrypted(Input, 0, Length(Input)));
    P := A.Advance(102);
    AssertEquals('the peer close moves the session to closed', Ord(tssClosed),
      Ord(P.State));
    SetLength(Plain, 8);
    N := A.ReadPlaintext(Plain, 0, Length(Plain));
    AssertEquals('final authenticated data is retained', 1, N);
    AssertEquals('final authenticated byte is preserved', Ord($41),
      Ord(Plain[0]));
    Total := 0;
    while A.PrepareCipher(Cipher) do
    begin
      Inc(Total, Length(Cipher));
      A.CompleteCipher(True);
    end;
    AssertEquals('the peer close reply is drained', 2, Total);
  finally
    A.Free;
  end;
end;

procedure TTlsServerBindingTest.AbruptEofFailsTheSession;
var C: ITLSContext; B: ITlsServerBinding; A: TServerTlsAdapter;
    Input: TBytes; P: TTlsProgress;
begin
  C := TTlsFakeContext.Create([trServer], tlsAuthNone, 2500);
  B := NewTlsServerBinding(C);
  A := TServerTlsAdapter.Create(B, 100, False);
  try
    Input := [$01];
    A.FeedEncrypted(Input, 0, Length(Input));
    P := A.Advance(101);
    AssertEquals('the session opens before transport EOF', Ord(tssOpen), Ord(P.State));
    A.NotifyTransportEof;
    AssertEquals('raw EOF without close-notify fails the session', Ord(tssFailed),
      Ord(A.State));
  finally
    A.Free;
  end;
end;

var App: TTestRunner;
begin
  RegisterTest(TTlsServerBindingTest);
  App := TTestRunner.Create(nil);
  try
    App.Initialize;
    App.Run;
  finally
    App.Free;
  end;
end.
