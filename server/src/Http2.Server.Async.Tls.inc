{**
---
license: Apache-2.0 OR (LGPL-2.1-only WITH Independent-modules-exception)
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: tls, server, async, transport pump
notes:
  - This include holds the TLS-aware async connection input and write methods.
  - The parent unit declares the connection fields and session adapter.
---
}
function THttp2AsyncConnection.OnFirstRead(aOwner: TPollAsyncSockets): boolean;
begin
  // The mORMot2 read path calls this method and never catches what it
  // raises: an exception here reaches TAsyncConnectionsThread.DoExecute,
  // whose handler ends the pool thread for ever
  // (mormot.net.async.pas:2354 calls OnFirstRead, :2811 runs the pool loop,
  // :4474 catches the escape; read 2026-10-08).  A dead pool thread reads no
  // socket again, so one fault would stop the whole server while the
  // listener stays bound.  Every failure below is therefore reported as a
  // refusal, and a refused connection is closed by the caller.
  result := false;
  // the first read event of the connection: the trace cannot raise
  TraceFirstRead(FTrace);
  try
    // a server that stops accepts no new connection
    if FServer.Draining then
      exit;
    // mORMot TLS is disabled. The raw read path feeds ciphertext to the
    // per-connection common session in OnRead.
    result := True;
  except
    on E: Exception do
      // an unreadable socket is refused, and the refusal keeps the read
      // thread alive, which is worth more than any one connection
    begin
      result := false;
      FServer.TlsHandshakeFailed(E.Message);
    end;
  end;
end;

function THttp2AsyncConnection.CheckHeaderDeadline: Boolean;
begin
  if (FMode = cmHttp2) and (FCore <> nil) and
     (FCore.LastProcessedStreamId <> 0) then
    FHeaderDeadlineSec := 0;
  Result := (FHeaderDeadlineSec <> 0) and
    (TAsyncConnectionSec(mormot.core.os.GetTickCount64 div 1000) >
     FHeaderDeadlineSec);
end;

function THttp2AsyncConnection.PumpTlsInput(out AProgress: Boolean): Boolean;
var
  Cipher, Plain: TBytes;
  Used, N: SizeInt;
  Progress: TTlsProgress;
  Info: TTlsNegotiatedInfo;
begin
  Result := True;
  AProgress := False;
  if FTlsAdapter = nil then Exit;
  if (FHandshakeDeadlineMs > 0) and
     (Int64(mormot.core.os.GetTickCount64) >= FHandshakeDeadlineMs) and
     (FTlsAdapter.State in [tssNew, tssHandshaking]) then
    raise ETlsSessionError.Create('TLS handshake deadline expired', tecTimeout);
  while fRd.Len > 0 do
  begin
    N := fRd.Len;
    if N > TlsMaxEncryptedInput then N := TlsMaxEncryptedInput;
    SetLength(Cipher, N);
    Move(fRd.Buffer^, Cipher[0], N);
    Used := FTlsAdapter.FeedEncrypted(Cipher, 0, N);
    if Used <= 0 then Break;
    AProgress := True;
    Dec(fRd.Len, Used);
    if fRd.Len > 0 then
      Move((PByte(fRd.Buffer) + Used)^, fRd.Buffer^, fRd.Len);
  end;
  Progress := FTlsAdapter.Advance(mormot.core.os.GetTickCount64);
  if (AProgress) and (Progress.State in [tssClosing, tssClosed]) then
    FPeerTlsClosed := True;
  Result := Progress.State = tssOpen;
  AProgress := AProgress or Progress.MadeProgress;
  if Progress.State = tssFailed then
    raise ETlsSessionError.Create('TLS session failed', tecProtocol);
  if Progress.State = tssOpen then
  begin
    FHandshakeDeadlineMs := 0;
    if FMode = cmUndecided then
    begin
      Info := FTlsAdapter.NegotiatedInfo;
      if Info.PeerCertificate <> nil then
        FClientCert := ClientCertificateFromPeer(Info.PeerCertificate,
          FServer.Factory.ClientCertPrincipal);
      if Info.SelectedAlpn = 'h2' then
        StartHttp2
      else if (Info.SelectedAlpn = 'http/1.1') and
              FServer.Factory.Http11Fallback then
        StartHttp1
      else if (Info.SelectedAlpn = '') and FServer.Factory.Http11Fallback then
        StartHttp1
      else
        raise ETlsSessionError.Create('TLS ALPN policy rejected the peer',
          tecProtocol);
    end;
  end;
  // Providers may return authenticated final data and a close reply while
  // they move through Closing or Closed.  Keep reading that data after the
  // protocol mode has been selected.
  if (Progress.State in [tssOpen, tssClosing, tssClosed]) and
     (FMode <> cmUndecided) then
  begin
    SetLength(Plain, 16384);
    repeat
      N := FTlsAdapter.ReadPlaintext(Plain, 0, Length(Plain));
      if N > 0 then
      begin
        AProgress := True;
        SetLength(Plain, N);
        if FMode = cmHttp1 then
          FH1.Received(Plain, FServer.Factory.HeaderTimeoutMs)
        else
        begin
          FCore.Feed(Plain);
          if CheckHeaderDeadline then
            raise ETlsSessionError.Create('HTTP header deadline expired',
              tecTimeout);
        end;
        SetLength(Plain, 16384);
      end;
    until N = 0;
  end;
end;

function THttp2AsyncConnection.DrainTlsClose: Boolean;
var
  State: TTlsSessionState;
begin
  Result := True;
  if FTlsAdapter = nil then Exit;
  State := FTlsAdapter.State;
  if State = tssFailed then
  begin
    PumpTlsOutput;
    Exit((FTlsAdapter.PendingCipherCount = 0) and
      (PendingWriteBytes = 0));
  end;
  if (not FPeerTlsClosed) and (FPendingTlsCount > 0) then
  begin
    if not AcceptPendingTlsPlaintext then Exit(False);
    PumpTlsOutput;
    if FPendingTlsCount > 0 then Exit(False);
  end;
  if (not FPeerTlsClosed) and (State = tssOpen) then
  begin
    FLocalTlsShutdown := True;
    FTlsAdapter.BeginShutdown;
  end;
  PumpTlsOutput;
  State := FTlsAdapter.State;
  Result := (State in [tssClosing, tssClosed]) and
    FTlsAdapter.OutputDrained and (PendingWriteBytes = 0);
end;

function THttp2AsyncConnection.PumpTlsOutput: Boolean;
var
  Cipher: TBytes;
  Written: Boolean;
  CompletedPlaintext: Int64;
begin
  Result := False;
  if FTlsAdapter = nil then Exit;
  while FTlsAdapter.PrepareCipher(Cipher) do
  begin
    Written := fOwner.Write(Self, @Cipher[0], Length(Cipher), cWriteTimeoutMs);
    if not Written then
      Written := fOwner.Write(Self, @Cipher[0], Length(Cipher), cWriteTimeoutMs);
    FTlsAdapter.CompleteCipher(Written);
    if not Written then Exit;
    Result := True;
  end;
  if (FCore <> nil) and (PendingWriteBytes = 0) and
     FTlsAdapter.TryGetCompletedPlaintext(CompletedPlaintext) then
    FCore.ReportWritten(CompletedPlaintext);
end;

function THttp2AsyncConnection.AcceptPendingTlsPlaintext: Boolean;
var N: SizeInt;
begin
  Result := True;
  if (FTlsAdapter = nil) or (FPendingTlsCount = 0) then Exit;
  N := FTlsAdapter.WritePlaintext(FPendingTlsPlain, FPendingTlsOffset,
    FPendingTlsCount);
  if N <= 0 then Exit(False);
  Inc(FPendingTlsOffset, N);
  Dec(FPendingTlsCount, N);
  if FPendingTlsCount = 0 then
  begin
    FPendingTlsPlain := nil;
    FPendingTlsOffset := 0;
  end;
  PumpTlsOutput;
end;

function THttp2AsyncConnection.OnRead: TPollAsyncSocketOnReadWrite;
var
  Data: TBytes;
  TlsProgress, TlsOpen, OutputProgress: Boolean;
begin
  Http2IoThreadEnter;
  try
    try
    result := soContinue;
    if (FTlsAdapter = nil) and not FClearTextTransport and
       (FServer.FTlsBinding <> nil) and (fRd.Len > 0) then
    begin
      if (Byte(fRd.Buffer^) = $16) and (fRd.Len = 1) then
        Exit;
      if (Byte(fRd.Buffer^) = $16) and (fRd.Len >= 2) and
         (Byte((PByte(fRd.Buffer) + 1)^) = $03) then
      begin
        FTlsAdapter := TServerTlsAdapter.Create(FServer.FTlsBinding,
          FAcceptedMs, FServer.Factory.Http11Fallback);
        FHandshakeDeadlineMs := FTlsAdapter.DeadlineMs;
      end
      else if FServer.Factory.ClearTextAllowed then
        FClearTextTransport := True
      else
        Exit(soClose);
    end;
    if FTlsAdapter <> nil then
    begin
      repeat
        TlsOpen := PumpTlsInput(TlsProgress);
        OutputProgress := PumpTlsOutput;
        TlsProgress := TlsProgress or OutputProgress;
        if FTlsAdapter.TransportFailed then
          Exit(soClose);
        if FTlsAdapter.State = tssFailed then
        begin
          if DrainTlsClose then Exit(soClose);
          Exit;
        end;
        if FPeerTlsClosed then
        begin
          if DrainTlsClose then Exit(soClose);
          Exit;
        end;
        if (fRd.Len = 0) or not TlsProgress then
          Break;
      until False;
      if not TlsOpen then
      begin
        Exit;
      end;
      if fRd.Len > 0 then
        Exit;
    end;
    if FMode = cmUndecided then
    begin
      if fRd.Len = 0 then
        exit;
      case SelectCleartextProtocol(fRd.Buffer^, fRd.Len) of
        pcNeedMore:
          begin
            // the octets so far could be the HTTP/2 preface; the header
            // deadline bounds the wait
            if (FHeaderDeadlineSec <> 0) and
               (TAsyncConnectionSec(mormot.core.os.GetTickCount64 div 1000) > FHeaderDeadlineSec) then
              exit(soClose);
            exit;
          end;
        pcHttp2:
          StartHttp2;
      else
        if FServer.Factory.Http11Fallback then
          StartHttp1
        else
          exit(soClose);
      end;
    end;
    if FMode = cmHttp1 then
      exit(OnReadHttp1);
    if FCore = nil then
      exit(soClose);
    if fRd.Len > 0 then
    begin
      SetLength(Data, fRd.Len);
      Move(fRd.Buffer^, Data[0], fRd.Len);
      fRd.Reset;
      FCore.Feed(Data);
      // a header block that arrives one byte at a time keeps the connection
      // busy, so the idle check never runs.  The deadline is judged here,
      // on every read, and a block that missed it ends the connection.
      if CheckHeaderDeadline then
        exit(soClose);
    end;
    SendPendingOutput;
    if FCore.Aborted then
      exit(soClose);
    // The GOAWAY frame of a trip or a graceful stop must reach the peer, so
    // the close waits for the whole output drain.  A close before the drain
    // drops the queued GOAWAY and the peer never learns why the socket ended.
    // The same holds for output that a handler thread took from the core and
    // did not yet hand to the socket: the core and mORMot2 show no bytes, and
    // the loop of that thread closes the connection after its write.
    if Http2Drained(FCore, PendingWrite) and not DeferCloseForSend then
    begin
      if DrainTlsClose then Exit(soClose);
      Exit;
    end;
    except
      on E: Exception do
      begin
        if (FServer <> nil) and (FTlsAdapter <> nil) then
          FServer.TlsHandshakeFailed(E.Message);
        if (FTlsAdapter <> nil) and
           (FTlsAdapter.State = tssFailed) then
        begin
          try
            PumpTlsOutput;
            if (FTlsAdapter.PendingCipherCount = 0) and
               (PendingWriteBytes = 0) then
              result := soClose
            else
              result := soContinue;
          except
            result := soClose;
          end;
        end
        else
          result := soClose;
      end;
    end;
  finally
    Http2IoThreadLeave;
  end;
end;

function THttp2AsyncConnection.AfterWrite: TPollAsyncSocketOnReadWrite;
var
  CompletedPlaintext: Int64;
begin
  Http2IoThreadEnter;
  try
    try
    // the write buffer drained.  The send loop of SendPendingOutput carries
    // the next pull, because fOwner.Write calls this method before it
    // returns, so a pull here would recurse into the same write path
    result := soContinue; FLastWriteProgressMs := mormot.core.os.GetTickCount64;
    if FTlsAdapter <> nil then
    begin
      PumpTlsOutput;
      if FTlsAdapter.TransportFailed then
        Exit(soClose);
      if (FTlsAdapter.State = tssFailed) and
         (FTlsAdapter.PendingCipherCount = 0) and
         (PendingWriteBytes = 0) then
        Exit(soClose);
      if FPeerTlsClosed then
      begin
        if DrainTlsClose then Exit(soClose);
        Exit;
      end;
      if ((FCore <> nil) or (FH1 <> nil)) and
         (FTlsAdapter.State = tssOpen) then
        SendPendingOutput;
      if (FCore <> nil) and (PendingWriteBytes = 0) and
         FTlsAdapter.TryGetCompletedPlaintext(CompletedPlaintext) then
        FCore.ReportWritten(CompletedPlaintext);
    end;
    if FMode = cmHttp1 then
    begin
      ApplyClosePhase;
      exit;
    end;
    if FCore = nil then
      exit;
    // the write buffer drained further, so the budget releases the batches
    // the peer received
    if FTlsAdapter = nil then
      FCore.ReportWritten(FCore.HandedOutTotal - PendingWriteBytes);
    // A GOAWAY trip or a graceful stop closes the connection once the last
    // frame left the socket.  OnRead cannot make that decision after the last
    // stream ends, because the trip already drained it, so the decision runs
    // here too: the close waits for the frames, and the peer learns why the
    // socket ended.
    if Http2Drained(FCore, PendingWrite) and not DeferCloseForSend then
      if DrainTlsClose then result := soClose;
    except
      on E: Exception do
      begin
        if (FServer <> nil) and (FTlsAdapter <> nil) then
          FServer.TlsHandshakeFailed(E.Message);
        result := soClose;
      end;
    end;
  finally
    Http2IoThreadLeave;
  end;
end;

function THttp2AsyncConnection.DeferCloseForSend: Boolean;
begin
  // A send loop owns FInSend from before it takes output from the core until
  // after its write returned. In that span the output is in neither the core
  // nor mORMot2, so a drained check would pass and the close would drop it.
  // The close is not awaited here, because the loop may wait for the
  // connection lock that this thread holds; the loop decides it at its end.
  Result := False;
  if FSendLock = nil then
    Exit;
  FSendLock.Acquire;
  try
    // the loop of this very thread runs inside fOwner.Write, where AfterWrite
    // reports its own chunk as sent and no later chunk is taken yet
    Result := FInSend and (FSendThread <> GetCurrentThreadId);
    if Result then
      FCloseWanted := True;
  finally
    FSendLock.Release;
  end;
  if Result then
    FlightCloseDeferred;
end;

function THttp2AsyncConnection.TakeDeferredClose: Boolean;
begin
  Result := FCloseWanted and (FCore <> nil) and
    Http2Drained(FCore, PendingWrite);
  FCloseWanted := False;
end;

procedure THttp2AsyncConnection.CheckHandshakeDeadline(const ANowMs: QWord);
var
  H: TConnectionAsyncHandle;
  Current: TAsyncConnection;
  Expired: Boolean;
begin
  if FClearTextTransport or (FServer = nil) or
     (FServer.FTlsBinding = nil) then Exit;
  H := Handle;
  Current := fOwner.ConnectionFind(H);
  if Current <> Self then Exit;
  if (FTlsAdapter <> nil) and (FPeerTlsClosed or FLocalTlsShutdown) then
  begin
    if DrainTlsClose then
      fOwner.ConnectionRemove(H);
    Exit;
  end;
  if FHandshakeDeadlineMs <= 0 then Exit;
  Expired := ((FTlsAdapter = nil) or
    (FTlsAdapter.State in [tssNew, tssHandshaking])) and
    (Int64(ANowMs) >= FHandshakeDeadlineMs);
  if Expired then
    fOwner.ConnectionRemove(H);
end;
