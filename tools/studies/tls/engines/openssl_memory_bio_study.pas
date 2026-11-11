{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: openssl_memory_bio_study
notes:
  - This study uses local generated certificate fixtures.
---
}
program OpenSslMemoryBioStudy;

{$mode delphi}

uses
  SysUtils, mormot.core.base, mormot.lib.openssl11;

type
  TSide = record
    Ssl: PSSL;
    InputBio: PBIO;
    OutputBio: PBIO;
    Ready: Boolean;
  end;

procedure Check(AOk: Boolean; const AWhat: string);
begin
  if not AOk then
    raise Exception.Create(AWhat);
end;

function Transfer(var AFrom, ATo: TSide): Integer;
var
  LBuf: array[0..6] of Byte;
  LPending, LWant: Integer;
  LCount, LOffset, LPart: Integer;
begin
  Result := 0;
  repeat
    LPending := BIO_ctrl(AFrom.OutputBio, _BIO_CTRL_PENDING, 0, nil);
    if LPending <= 0 then
      Break;
    LWant := LPending;
    if LWant > SizeOf(LBuf) then
      LWant := SizeOf(LBuf);
    LCount := BIO_read(AFrom.OutputBio, @LBuf[0], LWant);
    Check(LCount > 0, 'BIO_read did not drain pending ciphertext');
    LOffset := 0;
    while LOffset < LCount do
    begin
      LPart := BIO_write(ATo.InputBio, @LBuf[LOffset], 1);
      Check(LPart = 1, 'BIO_write rejected fragmented ciphertext');
      Inc(LOffset, LPart);
      Inc(Result, LPart);
    end;
  until False;
end;

procedure DriveHandshake(var AClient, AServer: TSide);
var
  LRound, LMoved, LResult, LError: Integer;
begin
  for LRound := 1 to 10000 do
  begin
    LMoved := 0;
    if not AClient.Ready then
    begin
      LResult := SSL_connect(AClient.Ssl);
      if LResult = 1 then
        AClient.Ready := True
      else
      begin
        LError := SSL_get_error(AClient.Ssl, LResult);
        Check((LError = SSL_ERROR_WANT_READ) or (LError = SSL_ERROR_WANT_WRITE),
          'SSL_connect failed with error ' + IntToStr(LError));
      end;
    end;
    if not AServer.Ready then
    begin
      LResult := SSL_accept(AServer.Ssl);
      if LResult = 1 then
        AServer.Ready := True
      else
      begin
        LError := SSL_get_error(AServer.Ssl, LResult);
        Check((LError = SSL_ERROR_WANT_READ) or (LError = SSL_ERROR_WANT_WRITE),
          'SSL_accept failed with error ' + IntToStr(LError));
      end;
    end;
    Inc(LMoved, Transfer(AClient, AServer));
    Inc(LMoved, Transfer(AServer, AClient));
    if AClient.Ready and AServer.Ready then
      Exit;
    if LMoved = 0 then
      raise Exception.CreateFmt('memory-BIO handshake stalled at round %d', [LRound]);
  end;
  raise Exception.Create('memory-BIO handshake exceeded bounded rounds');
end;

procedure RunVersion(AProtocol: Integer; const ALabel, AHost: string;
  APartialChain: Boolean);
var
  LClientCtx, LServerCtx: PSSL_CTX;
  LClient, LServer: TSide;
  LPayload, LReceived: array[0..31] of Byte;
  LCipherText: array[0..255] of AnsiChar;
  LPeerCert: PX509;
  LResult, LError, I: Integer;
  LTrustFile: PChar;
begin
  FillChar(LClient, SizeOf(LClient), 0);
  FillChar(LServer, SizeOf(LServer), 0);
  Check(OpenSslInitialize, 'mORMot OpenSSL binding initialization failed');
  LClientCtx := SSL_CTX_new(TLS_client_method());
  LServerCtx := SSL_CTX_new(TLS_server_method());
  Check((LClientCtx <> nil) and (LServerCtx <> nil), 'SSL_CTX_new failed');
  try
    if APartialChain then
      LTrustFile := PChar(ParamStr(6))
    else
      LTrustFile := PChar(ParamStr(1));
    SSL_CTX_set_verify(LClientCtx, SSL_VERIFY_PEER, nil);
    Check(SSL_CTX_load_verify_locations(LClientCtx, LTrustFile, nil) = 1,
      'client trust root load failed');
    if APartialChain then
      Check(X509_STORE_set_flags(SSL_CTX_get_cert_store(LClientCtx),
        X509_V_FLAG_PARTIAL_CHAIN) = 1, 'client partial-chain policy setup failed');
    Check(SSL_CTX_use_certificate_chain_file(LClientCtx, PChar(ParamStr(4))) = 1,
      'client certificate load failed');
    Check(SSL_CTX_use_PrivateKey_file(LClientCtx, PChar(ParamStr(5)), SSL_FILETYPE_PEM) = 1,
      'client private key load failed');
    Check(SSL_CTX_check_private_key(LClientCtx) = 1, 'client certificate/key mismatch');
    Check(SSL_CTX_use_certificate_chain_file(LServerCtx, PChar(ParamStr(2))) = 1,
      'SSL_CTX_use_certificate_chain_file failed');
    Check(SSL_CTX_use_PrivateKey_file(LServerCtx, PChar(ParamStr(3)), SSL_FILETYPE_PEM) = 1,
      'SSL_CTX_use_PrivateKey_file failed');
    Check(SSL_CTX_check_private_key(LServerCtx) = 1, 'server certificate/key mismatch');
    Check(SSL_CTX_load_verify_locations(LServerCtx, LTrustFile, nil) = 1,
      'server client-certificate trust root load failed');
    if APartialChain then
      Check(X509_STORE_set_flags(SSL_CTX_get_cert_store(LServerCtx),
        X509_V_FLAG_PARTIAL_CHAIN) = 1, 'server partial-chain policy setup failed');
    SSL_CTX_set_verify(LServerCtx,
      SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil);
    Check(SSL_CTX_set_min_proto_version(LClientCtx, AProtocol) = 1,
      'client TLS minimum setup failed');
    Check(SSL_CTX_set_max_proto_version(LClientCtx, AProtocol) = 1,
      'client TLS maximum setup failed');
    Check(SSL_CTX_set_min_proto_version(LServerCtx, AProtocol) = 1,
      'server TLS minimum setup failed');
    Check(SSL_CTX_set_max_proto_version(LServerCtx, AProtocol) = 1,
      'server TLS maximum setup failed');
    LClient.Ssl := SSL_new(LClientCtx);
    LServer.Ssl := SSL_new(LServerCtx);
    Check((LClient.Ssl <> nil) and (LServer.Ssl <> nil), 'SSL_new failed');
    LClient.InputBio := BIO_new(BIO_s_mem());
    LClient.OutputBio := BIO_new(BIO_s_mem());
    LServer.InputBio := BIO_new(BIO_s_mem());
    LServer.OutputBio := BIO_new(BIO_s_mem());
    Check((LClient.InputBio <> nil) and (LClient.OutputBio <> nil) and
      (LServer.InputBio <> nil) and (LServer.OutputBio <> nil), 'BIO_new failed');
    SSL_set_bio(LClient.Ssl, LClient.InputBio, LClient.OutputBio);
    SSL_set_bio(LServer.Ssl, LServer.InputBio, LServer.OutputBio);
    Check(SSL_set1_host(LClient.Ssl, PChar(AHost)) = 1,
      'client DNS/IP hostname verification setup failed');
    if AHost = 'localhost' then
      Check(SSL_set_tlsext_host_name(LClient.Ssl, RawUtf8(AHost)) = 1,
        'client SNI setup failed');
    SSL_set_connect_state(LClient.Ssl);
    SSL_set_accept_state(LServer.Ssl);
    DriveHandshake(LClient, LServer);
    Check(SSL_get_verify_result(LClient.Ssl) = X509_V_OK,
      'client did not verify the server certificate chain and host');
    LPeerCert := SSL_get_peer_certificate(LServer.Ssl);
    Check(LPeerCert <> nil, 'server did not receive the required client certificate');
    X509_free(LPeerCert);
    Check(SSL_CIPHER_description(SSL_get_current_cipher(LClient.Ssl), @LCipherText[0],
      SizeOf(LCipherText)) <> nil, 'OpenSSL did not report a selected cipher');

    FillChar(LPayload, SizeOf(LPayload), Ord('P'));
    LResult := SSL_write(LClient.Ssl, @LPayload[0], SizeOf(LPayload));
    Check(LResult = SizeOf(LPayload), 'SSL_write did not accept the payload');
    Transfer(LClient, LServer);
    LResult := SSL_read(LServer.Ssl, @LReceived[0], SizeOf(LReceived));
    Check(LResult = SizeOf(LReceived), 'SSL_read did not return the payload');
    for I := Low(LPayload) to High(LPayload) do
      Check(LPayload[I] = LReceived[I], 'memory-BIO payload mismatch');

    if AHost = 'localhost' then
      Check(StrPas(SSL_get_servername(LServer.Ssl, TLSEXT_NAMETYPE_host_name)) = AHost,
        'server did not receive the DNS SNI name');
    LResult := SSL_shutdown(LClient.Ssl);
    Check(LResult >= 0, 'SSL_shutdown failed');
    Transfer(LClient, LServer);
    LResult := SSL_read(LServer.Ssl, @LReceived[0], SizeOf(LReceived));
    LError := SSL_get_error(LServer.Ssl, LResult);
    Check((LResult <= 0) and (LError = SSL_ERROR_ZERO_RETURN),
      'close_notify was not reported as orderly EOF');
    WriteLn('PASS: OpenSSL memory BIO ', ALabel, ' mTLS; verified ', AHost,
      '; cipher ', StrPas(@LCipherText[0]), '; SNI where DNS; byte-split input; ' +
      '7-byte drains; payload; close_notify; partial-chain=', APartialChain);
  finally
    if LClient.Ssl <> nil then
      SSL_free(LClient.Ssl);
    if LServer.Ssl <> nil then
      SSL_free(LServer.Ssl);
    SSL_CTX_free(LClientCtx);
    SSL_CTX_free(LServerCtx);
  end;
end;

procedure Run;
begin
  Check(OpenSslInitialize, 'mORMot OpenSSL binding initialization failed');
  RunVersion(TLS1_2_VERSION, 'TLS 1.2', 'localhost', False);
  RunVersion(TLS1_3_VERSION, 'TLS 1.3', 'localhost', False);
  RunVersion(TLS1_3_VERSION, 'TLS 1.3 IP SAN', '127.0.0.1', False);
  RunVersion(TLS1_3_VERSION, 'TLS 1.3 partial chain', 'localhost', True);
end;

begin
  try
    Run;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'FAIL: ', E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
